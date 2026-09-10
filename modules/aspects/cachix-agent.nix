{
  den,
  lib,
  self,
  ...
}: let
  deployLockPath = "/run/cachix-deploy-in-progress";
  mkDeployLock = pkgs:
    pkgs.writeShellScript "cachix-deploy-lock" ''
      set -eu

      action="$1"
      token="$2"
      marker="$3"
      exec 9>"$marker.lock"
      ${lib.getExe pkgs.flock} 9

      case "$action" in
        write)
          printf '%s\n' "$token" > "$marker"
          ;;
        read)
          if IFS= read -r current_token 2>/dev/null < "$marker"; then
            printf '%s\n' "$current_token"
          fi
          ;;
        clear)
          if IFS= read -r current_token 2>/dev/null < "$marker" \
            && [ "$current_token" = "$token" ]; then
            "$4" -f -- "$marker"
          fi
          ;;
      esac
    '';
  mkDeployLockExpiry = pkgs:
    pkgs.writeShellScript "cachix-deploy-lock-expiry" ''
      set -eu

      token="$1"
      marker="$2"
      systemd_run="$3"
      deploy_lock="$4"
      remove="$5"
      "$systemd_run" \
        --unit="cachix-deploy-lock-cleanup-$token" \
        --description="Clear stale Cachix deployment lock" \
        --collect \
        --on-active=45m \
        "$deploy_lock" clear "$token" "$marker" "$remove"
    '';
  mkDeploymentTarget = name: cfg:
    {
      system = cfg.pkgs.stdenv.hostPlatform.system;
      storePath = toString cfg.config.system.build.toplevel;
      rollbackScript = toString cfg.config.system.build.deployHealthRollbackScript;
      deployPin = "deployed-host-${name}";
    }
    // lib.optionalAttrs (name == "NPSB1") {
      deferred = true;
    };
in {
  den.aspects.cachix-agent.nixos = {
    config,
    pkgs,
    ...
  }: let
    hostName = config.networking.hostName;
    requiredSystemdUnits =
      [
        "cachix-agent.service"
        "alloy.service"
        "sshd.service"
        "tailscaled.service"
      ]
      ++ lib.optional config.virtualisation.docker.enable "docker.service"
      ++ lib.optional config.services.syncthing.enable "syncthing.service";
    requiredUnits = lib.escapeShellArgs requiredSystemdUnits;
    deployLock = mkDeployLock pkgs;
    deployLockExpiry = mkDeployLockExpiry pkgs;
    unitChecks =
      lib.concatMapStringsSep "\n" (unit: let
        attempts =
          if unit == "tailscaled.service"
          then "45"
          else "15";
      in ''
        check ${lib.escapeShellArg "systemd unit ${unit}"} ${attempts} ${pkgs.systemd}/bin/systemctl is-active --quiet ${lib.escapeShellArg unit}
      '')
      requiredSystemdUnits;
    expectedAgent = lib.getExe config.services.cachix-agent.package;
    rollbackScript = pkgs.writeTextFile {
      name = "deploy-health-rollback-script-${hostName}";
      executable = true;
      text = ''
        #!${pkgs.runtimeShell}
        set -euo pipefail

        deployment_token="$(${deployLock} read _ ${deployLockPath})"
        cleanup() {
          if [ -n "$deployment_token" ]; then
            ${deployLock} clear "$deployment_token" ${deployLockPath} ${pkgs.coreutils}/bin/rm
          fi
        }
        trap cleanup EXIT

        log() {
          echo "deploy-health: $*" >&2
        }

        diagnose() {
          ${pkgs.coreutils}/bin/timeout 10s \
            ${pkgs.systemd}/bin/systemctl show --no-pager \
              --property=Id --property=ActiveState --property=SubState --property=Result \
              ${requiredUnits} >&2 || true
        }

        check() {
          local name="$1"
          local attempts="$2"
          shift 2

          local attempt
          for attempt in $(${pkgs.coreutils}/bin/seq 1 "$attempts"); do
            if ${pkgs.coreutils}/bin/timeout --kill-after=2s 10s "$@" >/dev/null 2>&1; then
              log "$name passed"
              return 0
            fi
            if [ "$attempt" -lt "$attempts" ]; then
              ${pkgs.coreutils}/bin/sleep 2
            fi
          done

          log "$name failed after $attempts attempts"
          ${pkgs.coreutils}/bin/timeout --kill-after=2s 10s "$@" >&2 || true
          diagnose
          return 1
        }

        expected_host=${lib.escapeShellArg hostName}
        actual_host="$(${pkgs.coreutils}/bin/cat /proc/sys/kernel/hostname)"
        if [ "$actual_host" != "$expected_host" ]; then
          log "expected hostname $expected_host, got $actual_host"
          exit 1
        fi

        ${unitChecks}
        check 'command tailscale' 45 ${pkgs.bash}/bin/bash -c \
          ${lib.escapeShellArg "${lib.getExe config.services.tailscale.package} status --peers=false >/dev/null"}

        agent_pid="$(${pkgs.systemd}/bin/systemctl show --property=MainPID --value cachix-agent.service 2>/dev/null || true)"
        if [ -n "$agent_pid" ] && [ "$agent_pid" -ne 0 ] 2>/dev/null; then
          running_agent="$(${pkgs.coreutils}/bin/readlink -f "/proc/$agent_pid/exe" 2>/dev/null || true)"
          expected_agent="$(${pkgs.coreutils}/bin/readlink -f ${lib.escapeShellArg expectedAgent} 2>/dev/null || true)"
          if [ -n "$running_agent" ] && [ -n "$expected_agent" ] && [ "$running_agent" != "$expected_agent" ]; then
            log "scheduling Cachix agent restart after deployment reporting"
            ${pkgs.systemd}/bin/systemd-run \
              --unit=restart-cachix-agent-deferred \
              --description="Deferred Cachix agent restart after deploy" \
              --collect \
              --on-active=30s \
              ${pkgs.systemd}/bin/systemctl restart cachix-agent.service \
              || log "could not schedule the Cachix agent restart"
          fi
        fi

        log "all checks passed for $actual_host"
      '';
      checkPhase = ''
        ${pkgs.bash}/bin/bash -n "$target"
        ${lib.getExe pkgs.shellcheck} -s bash "$target"
      '';
    };
  in {
    sops.secrets.cachixAgentToken = {};
    services.cachix-agent = {
      enable = true;
      credentialsFile = config.sops.secrets.cachixAgentToken.path;
    };

    systemd.services = {
      cachix-agent.restartIfChanged = false;
      nix-gc.unitConfig.ConditionPathExists = "!${deployLockPath}";
      nix-optimise.unitConfig.ConditionPathExists = "!${deployLockPath}";
      restart-cachix-agent = {
        description = "Restart a changed Cachix agent after a manual activation";
        wantedBy = ["multi-user.target"];
        after = ["cachix-agent.service"];
        restartTriggers = [config.services.cachix-agent.package];
        unitConfig.ConditionPathExists = "!${deployLockPath}";
        serviceConfig.Type = "oneshot";
        script = ''
          expected="$(${pkgs.coreutils}/bin/readlink -f ${lib.escapeShellArg expectedAgent} 2>/dev/null || true)"
          pid="$(${pkgs.systemd}/bin/systemctl show --property=MainPID --value cachix-agent.service 2>/dev/null || true)"
          if [ -n "$pid" ] && [ "$pid" -ne 0 ] 2>/dev/null; then
            running="$(${pkgs.coreutils}/bin/readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
            if [ -n "$running" ] && [ -n "$expected" ] && [ "$running" != "$expected" ]; then
              ${pkgs.systemd}/bin/systemctl restart cachix-agent.service
            fi
          fi
        '';
      };
    };

    # A Cachix activation inherits the agent cgroup. The lock keeps scheduled
    # store maintenance and agent restarts out of the activation window. Each
    # write gets a token-scoped timer, so pre-health failures cannot leave a
    # stale lock and an older timer cannot clear a rollback activation's lock.
    system.activationScripts.cachix-deploy-lock.text = ''
      if ${pkgs.gnugrep}/bin/grep -q cachix-agent.service /proc/self/cgroup 2>/dev/null; then
        token="$(${pkgs.coreutils}/bin/date +%s%N)-$$"
        ${deployLock} write "$token" ${deployLockPath}
        # Keep cleanup beyond the roughly 30-minute worst-case health budget.
        if ! ${deployLockExpiry} \
          "$token" ${deployLockPath} ${pkgs.systemd}/bin/systemd-run \
          ${deployLock} ${pkgs.coreutils}/bin/rm; then
          ${deployLock} clear "$token" ${deployLockPath} ${pkgs.coreutils}/bin/rm
          echo "cachix-deploy-lock: could not schedule bounded cleanup" >&2
          exit 1
        fi
      fi
    '';

    system.build.deployHealthRollbackScript = rollbackScript;
    system.extraDependencies = [rollbackScript];
  };

  flake.deploy.targets =
    lib.mapAttrs mkDeploymentTarget
    (lib.filterAttrs
      (_: cfg: cfg.config.services.cachix-agent.enable or false)
      (self.nixosConfigurations or {}));

  perSystem = {
    pkgs,
    system,
    ...
  }: let
    deployLock = mkDeployLock pkgs;
    deployLockExpiry = mkDeployLockExpiry pkgs;
    blockingRm = pkgs.writeShellScript "blocking-rm" ''
      touch "$DEPLOY_LOCK_TEST_READY"
      while [ ! -e "$DEPLOY_LOCK_TEST_RELEASE" ]; do
        sleep 0.01
      done
      exec ${pkgs.coreutils}/bin/rm "$@"
    '';
    immediateSystemdRun = pkgs.writeShellScript "immediate-systemd-run" ''
      set -eu

      [ "$4" = --on-active=45m ]
      shift 4
      exec "$@"
    '';
  in {
    checks =
      {
        deployLockCleanup = pkgs.runCommand "deploy-lock-cleanup-check" {} ''
          marker="$TMPDIR/deploy-lock"
          printf '%s\n' original > "$marker"
          printf '%s\n' rollback > "$marker"

          ${deployLock} clear original "$marker" ${pkgs.coreutils}/bin/rm
          test "$(cat "$marker")" = rollback

          ${deployLock} clear rollback "$marker" ${pkgs.coreutils}/bin/rm
          test ! -e "$marker"

          printf '%s\n' original > "$marker"
          export DEPLOY_LOCK_TEST_READY="$TMPDIR/ready"
          export DEPLOY_LOCK_TEST_RELEASE="$TMPDIR/release"
          ${deployLock} clear original "$marker" ${blockingRm} &
          cleanup_pid=$!
          while [ ! -e "$DEPLOY_LOCK_TEST_READY" ]; do
            sleep 0.01
          done
          ${deployLock} write rollback "$marker" &
          write_pid=$!
          sleep 0.1
          test "$(cat "$marker")" = original
          touch "$DEPLOY_LOCK_TEST_RELEASE"
          wait "$cleanup_pid"
          wait "$write_pid"
          test "$(cat "$marker")" = rollback

          ${deployLock} write orphan "$marker"
          ${deployLockExpiry} \
            orphan "$marker" ${immediateSystemdRun} \
            ${deployLock} ${pkgs.coreutils}/bin/rm
          test ! -e "$marker"

          touch "$out"
        '';
      }
      // lib.mapAttrs'
      (name: cfg:
        lib.nameValuePair
        "rollbackScript-${name}"
        cfg.config.system.build.deployHealthRollbackScript)
      (lib.filterAttrs
        (_: cfg:
          cfg.pkgs.stdenv.hostPlatform.system
          == system
          && (cfg.config.services.cachix-agent.enable or false))
        (self.nixosConfigurations or {}));
  };
}

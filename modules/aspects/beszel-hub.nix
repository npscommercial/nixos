{den, ...}: let
  hostName = "beszel.npscommercial.net.au";
in {
  den.aspects.beszel-hub = {
    includes = [den.aspects.caddy];
    nixos = {
      config,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.beszel.hub;
      # The hub keeps its data in beszel_data under its working directory.
      stateDir = "/var/lib/private/beszel-hub";
      marker = "${stateDir}/.imported-from-docker";
    in {
      services.beszel.hub = {
        enable = true;
        # The stable release lags the hub version whose database is in use.
        package = pkgs.unstable.beszel;
        environment.BESZEL_HUB_SHARE_ALL_SYSTEMS = "true";
      };

      # The 26.05 module calls `history-sync`, which this hub version moved
      # under `migrate`, as the unstable module already does.
      systemd.services.beszel-hub.serviceConfig.ExecStartPre = lib.mkForce [
        "${cfg.package}/bin/beszel-hub migrate up"
        "${cfg.package}/bin/beszel-hub migrate history-sync"
      ];

      services.caddy.virtualHosts.${hostName}.extraConfig = ''
        reverse_proxy 127.0.0.1:8090
      '';

      # One-off import of the hub data from the retired Docker deployment. It
      # replaces whatever the hub holds until the import has completed once.
      systemd.services.beszel-hub-import = {
        description = "Import Beszel hub data from Docker";
        requiredBy = ["beszel-hub.service"];
        before = ["beszel-hub.service"];
        unitConfig.ConditionPathExists = [
          "/opt/docker/beszel/beszel_data/data.db"
          "!${marker}"
        ];
        serviceConfig.Type = "oneshot";
        script = ''
          install -d -m 0700 /var/lib/private ${stateDir}
          rm -rf ${stateDir}/beszel_data
          cp -a /opt/docker/beszel/beszel_data ${stateDir}/beszel_data
          touch ${marker}
        '';
      };

      nps.deployment.health = {
        requiredSystemdUnits = ["beszel-hub.service"];
        requiredCommands = [
          {
            name = "Beszel answering through Caddy";
            command = "${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 5 --resolve ${hostName}:443:127.0.0.1 https://${hostName}/api/health >/dev/null";
          }
        ];
      };
    };
  };
}

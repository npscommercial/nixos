{...}: {
  den.aspects.docker = {
    nixos = {config, ...}: {
      nps.deployment.health = {
        requiredSystemdUnits = ["docker.service"];
        requiredCommands = [
          {
            name = "Docker responding";
            command = "${config.virtualisation.docker.package}/bin/docker info >/dev/null";
          }
        ];
      };
      virtualisation.docker.enable = true;
      virtualisation.docker.autoPrune.enable = true;
      systemd.tmpfiles.rules = ["d /opt/docker 0770 nobody docker"];
      environment.shellAliases = {
        dps = "docker ps -as --format 'table {{.Names}}\t{{.Status}}\t{{.Size}}'";
        dc = "docker compose";
        dcl = "dc logs -f --tail 20";
      };
    };
  };
}

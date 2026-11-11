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
    };
  };
}

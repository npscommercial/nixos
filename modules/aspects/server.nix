{den, ...}: {
  den.aspects.server = {
    includes = [
      den.aspects.alloy
      den.aspects.cachix-agent
    ];
    nixos = {
      config,
      pkgs,
      ...
    }: {
      nps.deployment.health = {
        requiredSystemdUnits = ["tailscaled.service"];
        requiredCommands = [
          {
            name = "Tailscale responding";
            command = "${config.services.tailscale.package}/bin/tailscale status --peers=false >/dev/null";
          }
        ];
      };

      sops.secrets.tailscaleOauthKey = {};
      services.tailscale = {
        enable = true;
        package = pkgs.unstable.tailscale;
        authKeyFile = config.sops.secrets.tailscaleOauthKey.path;
        authKeyParameters.ephemeral = false;
        extraUpFlags = ["--advertise-tags=tag:server"];
      };
    };
  };
}

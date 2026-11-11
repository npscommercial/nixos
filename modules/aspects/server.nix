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
      # No man pages or NixOS manual on headless servers.
      documentation.enable = false;

      environment.systemPackages = with pkgs; [
        service-wrapper
        iftop
        iotop
        ethtool
        lsof
        pciutils
        usbutils
      ];

      # Collect store garbage during builds and substitutions when free space
      # falls below 1 GiB, until 3 GiB is free. Generations are untouched.
      nix.settings = {
        min-free = 1024 * 1024 * 1024;
        max-free = 3 * 1024 * 1024 * 1024;
      };

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

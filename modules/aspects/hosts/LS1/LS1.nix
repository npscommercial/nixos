{den, ...}: let
  # Locally managed Cloudflare tunnel; its routes are declared below.
  tunnel = "5309663d-9573-4b26-a653-d5ae26ba514e";
  # Public names, served through the tunnel and Caddy.
  publicHosts = [
    "nextcloud.npscommercial.com.au"
    "twenty.npscommercial.net.au"
  ];
in {
  den.aspects.LS1 = {
    includes = [
      den.aspects.server
      den.aspects.nextcloud
      den.aspects.twenty
      den.aspects.stirling-pdf
      den.aspects.bentopdf
    ];
    nixos = {
      config,
      lib,
      ...
    }: {
      imports = [./_hardware.nix];

      system.stateVersion = "23.05"; # System state compatibility

      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      # Redis's own module enables memory overcommit.
      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv6.conf.all.forwarding" = 1;
      };

      fileSystems."/mnt/nextcloud" = {
        device = "/dev/disk/by-uuid/466019b6-27e5-407f-9088-6d6ef0fa35f5";
        fsType = "ext4";
      };

      sops.secrets."cloudflared/LS1/credentials.json" = {};
      services.cloudflared = {
        enable = true;
        tunnels.${tunnel} = {
          credentialsFile = config.sops.secrets."cloudflared/LS1/credentials.json".path;
          default = "http_status:404";
          # Through Caddy, so tunnel and LAN clients get the same site.
          ingress = lib.genAttrs publicHosts (hostName: {
            service = "https://localhost";
            originRequest.originServerName = hostName;
          });
        };
      };
      nps.deployment.health.requiredSystemdUnits = ["cloudflared-tunnel-${tunnel}.service"];
    };
  };
}

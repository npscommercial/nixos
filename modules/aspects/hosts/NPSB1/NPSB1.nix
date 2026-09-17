{den, ...}: {
  den.aspects.NPSB1 = {
    includes = [
      den.aspects.server
      den.aspects.wireless
      den.aspects.company-data-replica
    ];
    nixos = {config, ...}: {
      # Bootloader
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      imports = [./_hardware.nix];
      system.stateVersion = "23.11";

      sops.secrets."syncthing/NPSB1/key.pem" = {};
      sops.secrets."syncthing/NPSB1/cert.pem" = {};
      services.syncthing = {
        key = config.sops.secrets."syncthing/NPSB1/key.pem".path;
        cert = config.sops.secrets."syncthing/NPSB1/cert.pem".path;
      };
    };
  };
}

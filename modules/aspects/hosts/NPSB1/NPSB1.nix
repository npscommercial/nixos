{den, ...}: {
  den.aspects.NPSB1 = {
    includes = [den.aspects.server den.aspects.backup den.aspects.office-wireless];
    nixos = {config, ...}: {
      nps.deployment.deferred = true;
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

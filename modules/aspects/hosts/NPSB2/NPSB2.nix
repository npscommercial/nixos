{den, ...}: {
  den.aspects.NPSB2 = {
    includes = [den.aspects.server den.aspects.backup den.aspects.office-wireless];
    nixos = {config, ...}: {
      # Bootloader
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      imports = [./_hardware.nix];
      system.stateVersion = "23.11";
      users.users.matt.uid = 1000;

      sops.secrets."syncthing/NPSB2/key.pem" = {};
      sops.secrets."syncthing/NPSB2/cert.pem" = {};
      services.syncthing = {
        key = config.sops.secrets."syncthing/NPSB2/key.pem".path;
        cert = config.sops.secrets."syncthing/NPSB2/cert.pem".path;
      };
    };
  };
}

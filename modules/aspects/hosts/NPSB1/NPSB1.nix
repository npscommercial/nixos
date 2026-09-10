{den, ...}: {
  den.aspects.NPSB1 = {
    includes = [den.aspects.backup];
    nixos = {config, ...}: {
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

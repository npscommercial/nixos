{
  den,
  inputs,
  ...
}: {
  den.aspects.NPSB2 = {
    includes = [
      den.aspects.server
      den.aspects.wireless
      den.aspects.company-data-replica
    ];

    nixos = {config, ...}: {
      system.stateVersion = "23.11";

      imports = [
        ./_hardware.nix
        (import ../_zfs-replica.nix {
          inherit (inputs) disko;
          disk = "/dev/disk/by-path/pci-0000:00:17.0-ata-1";
        })
      ];

      networking.hostId = "f2e52f86";

      sops.secrets."syncthing/NPSB2/key.pem" = {};
      sops.secrets."syncthing/NPSB2/cert.pem" = {};
      services.syncthing = {
        key = config.sops.secrets."syncthing/NPSB2/key.pem".path;
        cert = config.sops.secrets."syncthing/NPSB2/cert.pem".path;
      };
    };
  };
}

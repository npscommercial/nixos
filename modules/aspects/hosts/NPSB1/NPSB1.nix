{
  den,
  inputs,
  ...
}: {
  den.aspects.NPSB1 = {
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
          disk = "/dev/disk/by-id/ata-Samsung_SSD_870_QVO_2TB_S5SUNF0R118053T";
        })
      ];

      networking.hostId = "afdd6317";

      sops.secrets."syncthing/NPSB1/key.pem" = {};
      sops.secrets."syncthing/NPSB1/cert.pem" = {};
      services.syncthing = {
        key = config.sops.secrets."syncthing/NPSB1/key.pem".path;
        cert = config.sops.secrets."syncthing/NPSB1/cert.pem".path;
      };
    };
  };
}

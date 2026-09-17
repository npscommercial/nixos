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
        inputs.disko.nixosModules.disko
        (import ../_disko.uefi.default.nix {
          disks = ["/dev/disk/by-path/pci-0000:00:17.0-ata-1"];
          zpoolName = config.networking.hostName;
        })
      ];

      # UEFI: kernels live on the ESP, with the system and Syncthing data on ZFS.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.loader.systemd-boot.editor = false;
      boot.loader.systemd-boot.configurationLimit = 20;
      boot.zfs.devNodes = "/dev/disk/by-partuuid";
      boot.zfs.forceImportRoot = false;
      services.zfs.autoScrub.enable = true;
      networking.hostId = "f2e52f86";

      disko.devices.zpool.${config.networking.hostName}.datasets."user/npscommercial" = {
        type = "zfs_fs";
        mountpoint = "/npscommercial";
        options.mountpoint = "legacy";
      };

      sops.secrets."syncthing/NPSB2/key.pem" = {};
      sops.secrets."syncthing/NPSB2/cert.pem" = {};
      services.syncthing = {
        key = config.sops.secrets."syncthing/NPSB2/key.pem".path;
        cert = config.sops.secrets."syncthing/NPSB2/cert.pem".path;
      };
    };
  };
}

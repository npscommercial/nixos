{
  disko,
  disk,
}: {config, ...}: {
  imports = [
    disko.nixosModules.disko
    (import ./_disko.uefi.default.nix {
      disks = [disk];
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
  services.telegraf.enable = true;

  disko.devices.zpool.${config.networking.hostName}.datasets."user/npscommercial" = {
    type = "zfs_fs";
    mountpoint = "/npscommercial";
    options.mountpoint = "legacy";
  };
}

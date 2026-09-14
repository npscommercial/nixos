{den, ...}: {
  den.aspects.LS1 = {
    includes = [den.aspects.server den.aspects.docker];
    nixos = {
      imports = [./_hardware.nix];

      system.stateVersion = "23.05"; # System state compatibility

      # Use the systemd-boot EFI boot loader.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;

      # Enable memory overcommit https://github.com/nextcloud/all-in-one/discussions/1731
      boot.kernel.sysctl = {
        "vm.overcommit_memory" = 1;
        "net.ipv4.ip_forward" = 1;
        "net.ipv6.conf.all.forwarding" = 1;
      };

      networking.firewall.trustedInterfaces = ["nextcloud0"];

      users.users.matt.uid = 1000;
      users.users.www-data.isSystemUser = true;
      users.users.www-data.group = "www-data";
      users.users.www-data.uid = 33;
      users.groups.www-data.gid = 33;

      fileSystems."/mnt/nextcloud" = {
        device = "/dev/disk/by-uuid/466019b6-27e5-407f-9088-6d6ef0fa35f5";
        fsType = "ext4";
      };
    };
  };
}

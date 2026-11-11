{den, ...}: {
  den.aspects.oberon = {
    includes = [den.aspects.server den.aspects.docker];
    nixos = {
      imports = [./_hardware.nix];

      system.stateVersion = "22.11"; # System state compatibility

      # Use the GRUB 2 boot loader.
      boot.loader.grub.enable = true;
      boot.loader.grub.device = "/dev/vda";
      boot.kernel.sysctl."vm.overcommit_memory" = 1;

      # Compress swap in RAM, bound Alloy's Go heap and cap the journal.
      zramSwap.enable = true;
      systemd.services.alloy.environment.GOMEMLIMIT = "150MiB";
      services.journald.extraConfig = "SystemMaxUse=200M";
    };
  };
}

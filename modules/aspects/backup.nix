{den, ...}: {
  den.aspects.backup = {
    includes = [den.aspects.server];
    nixos = {config, ...}: {
      # Bootloader
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.kernel.sysctl = {
        "fs.inotify.max_user_watches" = 204800;
      };

      # wpa-supplicant and systemd networking
      sops.secrets.wirelessEnv = {};
      networking.useNetworkd = true;
      systemd.network.enable = true;
      networking.wireless = {
        enable = true;
        secretsFile = config.sops.secrets.wirelessEnv.path;
        networks.NPSCOMMERCIAL.pskRaw = "ext:PSK_NPSCOMMERCIAL";
        networks.WiFi-3040.pskRaw = "ext:PSK_WIFI3040";
      };

      # Enable Syncthing service
      services.syncthing = {
        enable = true;
        guiAddress = "127.0.0.1:8384";
        openDefaultPorts = true;
        user = "root";
        group = "root";
        settings.gui.insecureSkipHostcheck = true;
        settings.gui.metricsWithoutAuth = true;
        settings.options.urAccepted = -1;
        settings.devices = {
          NPSSVR3.id = "7R2NY2E-CL4GBFE-ACYUP4F-IIRVLVT-2Z7RAPM-SXYDHRY-7NHBCJ6-M5ZH2QY";
          NPSB1.id = "KLUGLJC-OASBXDN-6TPRB72-3ZRPKUF-XL47M5L-TQBT6A5-4Y5EVNF-N7KXLAA";
          NPSB2.id = "Q4NBWLQ-KSJH3QG-O7CUGOW-TVFLCRK-BX7DG6I-WQNADE7-R5EQI4Q-VACVOA6";
        };
        settings.folders.NPS = {
          path = "/npscommercial";
          devices = ["NPSSVR3" "NPSB1" "NPSB2"];
          type = "receiveonly";
        };
      };
      systemd.tmpfiles.rules = ["d /npscommercial 0755 root root"];
      # Don't create default ~/Sync folder
      systemd.services.syncthing.environment.STNODEFAULTFOLDER = "true";
    };
  };
}

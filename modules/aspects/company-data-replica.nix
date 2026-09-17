{...}: {
  den.aspects.company-data-replica = {
    nixos = {
      nps.deployment.health.requiredSystemdUnits = [
        "syncthing.service"
        "syncthing-init.service"
      ];

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
          versioning = {
            type = "staggered";
            params.maxAge = "1209600"; # 14 days, in seconds
            cleanupIntervalS = 3600;
          };
        };
      };
      systemd.tmpfiles.rules = ["d /npscommercial 0755 root root"];
      systemd.services.syncthing.unitConfig.RequiresMountsFor = ["/npscommercial"];
    };
  };
}

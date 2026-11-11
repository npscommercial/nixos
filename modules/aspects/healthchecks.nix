{den, ...}: let
  hostName = "healthchecks.npscommercial.com.au";
in {
  den.aspects.healthchecks = {
    includes = [den.aspects.caddy];
    nixos = {
      config,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.healthchecks;
    in {
      # SECRET_KEY and EMAIL_HOST_PASSWORD, as environment lines.
      sops.secrets.healthchecksEnv.owner = cfg.user;

      services.healthchecks = {
        enable = true;
        # The stable release lags the version whose database is in use.
        package = pkgs.unstable.healthchecks;
        listenAddress = "127.0.0.1";
        port = 8000;
        settingsFile = config.sops.secrets.healthchecksEnv.path;
        settings = {
          SITE_ROOT = "https://${hostName}";
          SITE_NAME = "NPS Commercial Health Checks";
          SITE_LOGO_URL = "https://www.npscommercial.com.au/images/nps/nps.svg";
          ALLOWED_HOSTS = [hostName];
          SECURE_PROXY_SSL_HEADER = "HTTP_X_FORWARDED_PROTO,https";
          PING_EMAIL_DOMAIN = hostName;
          DEFAULT_FROM_EMAIL = "healthchecks@npscommercial.com.au";
          EMAIL_HOST = "smtp.mailgun.org";
          EMAIL_PORT = "465";
          EMAIL_HOST_USER = "healthchecks@npscommercial.com.au";
          EMAIL_USE_TLS = "False";
          EMAIL_USE_SSL = "True";
        };
      };

      # Pings also arrive by email; this listener records them.
      systemd.services.healthchecks-smtpd = {
        description = "Healthchecks SMTP listener";
        wantedBy = ["healthchecks.target"];
        after = ["healthchecks.service"];
        serviceConfig =
          config.systemd.services.healthchecks-sendalerts.serviceConfig
          // {
            ExecStart = "${cfg.package}/opt/healthchecks/manage.py smtpd --port 25";
            AmbientCapabilities = ["CAP_NET_BIND_SERVICE"];
          };
      };
      systemd.services.healthchecks.restartTriggers = [config.sops.secrets.healthchecksEnv.sopsFileHash];
      networking.firewall.allowedTCPPorts = [25];

      services.caddy.virtualHosts.${hostName}.extraConfig = ''
        reverse_proxy 127.0.0.1:${toString cfg.port}
      '';

      # One-off import of the database from the retired Docker deployment.
      # It runs only while the service has no database of its own.
      systemd.services.healthchecks-import = {
        description = "Import the Healthchecks database from Docker";
        requiredBy = ["healthchecks-migration.service"];
        before = ["healthchecks-migration.service"];
        unitConfig.ConditionPathExists = [
          "/opt/docker/healthchecks/conf/healthchecks/hc.sqlite"
          "!${cfg.dataDir}/healthchecks.sqlite"
        ];
        serviceConfig.Type = "oneshot";
        script = ''
          install -d -m 0750 -o ${cfg.user} -g ${cfg.group} ${cfg.dataDir}
          install -m 0640 -o ${cfg.user} -g ${cfg.group} \
            /opt/docker/healthchecks/conf/healthchecks/hc.sqlite ${cfg.dataDir}/healthchecks.sqlite
        '';
      };

      nps.deployment.health = {
        requiredSystemdUnits = [
          "healthchecks.service"
          "healthchecks-sendalerts.service"
          "healthchecks-smtpd.service"
        ];
        requiredCommands = [
          {
            name = "Healthchecks answering through Caddy";
            command = "${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 5 --resolve ${hostName}:443:127.0.0.1 https://${hostName}/api/v3/status/ >/dev/null";
          }
        ];
      };
    };
  };
}

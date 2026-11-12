{den, ...}: let
  hostName = "nextcloud.npscommercial.com.au";
  # Everything Nextcloud needs to come back lives on this disk: config/, data/,
  # home/ (store apps) and the nightly database dumps in backup/.
  disk = "/mnt/nextcloud";
  # nginx serves Nextcloud here; Caddy terminates TLS in front of it.
  port = 8080;
in {
  den.aspects.nextcloud = {
    includes = [den.aspects.caddy];
    nixos = {
      config,
      lib,
      pkgs,
      ...
    }: let
      ffmpeg = pkgs.ffmpeg-headless;
    in {
      # The disk's top level stays root's, so each directory under it can have
      # its own owner: systemd-tmpfiles refuses to cross from one non-root owner
      # to another.
      systemd.tmpfiles.rules = [
        "d ${disk} 0755 root root -"
        "d ${disk}/backup 0755 root root -"
      ];

      # Only read by the first installation; this instance came from Docker
      # already installed, so it is never used to log in.
      sops.secrets.nextcloudAdminPass.owner = "nextcloud";

      services.nextcloud = {
        enable = true;
        package = pkgs.nextcloud35;
        inherit hostName;
        home = "${disk}/home";
        datadir = disk;
        https = true;
        maxUploadSize = "16G";
        configureRedis = true;
        database.createLocally = true;
        config = {
          dbtype = "pgsql";
          adminpassFile = config.sops.secrets.nextcloudAdminPass.path;
        };
        # Apps stay with the app store, as they were under Docker.
        appstoreEnable = true;
        # External storage on the office's SMB shares.
        phpExtraExtensions = all: [all.smbclient];
        settings = {
          # Caddy terminates TLS, so nginx sees plain HTTP from 127.0.0.1.
          trusted_proxies = ["127.0.0.1" "::1"];
          overwriteprotocol = "https";
          # The module leaves this unset; Circles needs it to know its own instance.
          "overwrite.cli.url" = "https://${hostName}";
          default_phone_region = "AU";
          maintenance_window_start = 1;
          skeletondirectory = "";
          log_type = "syslog";
          loglevel = 2;
          activity_use_cached_mountpoints = true;
          enabledPreviewProviders = [
            "OC\\Preview\\Image"
            "OC\\Preview\\HEIC"
            "OC\\Preview\\TIFF"
            "OC\\Preview\\Movie"
          ];
          preview_max_x = 1024;
          preview_max_y = 1024;
          preview_ffmpeg_path = lib.getExe ffmpeg;
          # Memories' bundled helpers are built for other distributions. With
          # exiftool_no_local it runs its bundled exiftool script through the
          # perl on PATH; memories.exiftool only satisfies its detection check.
          "memories.exiftool" = lib.getExe pkgs.exiftool;
          "memories.exiftool_no_local" = true;
          "memories.vod.ffmpeg" = lib.getExe ffmpeg;
          "memories.vod.ffprobe" = lib.getExe' ffmpeg "ffprobe";
        };
      };

      # Memories needs perl: PHP-FPM finds it through the system profile, and
      # cron needs it on its own PATH. A first indexing run can last hours, so a
      # changed cron unit waits for the next timer run instead of restarting
      # (and blocking) activation.
      environment.systemPackages = [pkgs.perl];
      systemd.services.nextcloud-cron = {
        path = [pkgs.perl];
        restartIfChanged = false;
      };

      # Keep the UID the data was written with under Docker.
      users.users.nextcloud.uid = 33;
      users.groups.nextcloud.gid = 33;

      services.nginx.virtualHosts.${hostName}.listen = [
        {
          addr = "127.0.0.1";
          inherit port;
        }
      ];

      services.caddy.virtualHosts.${hostName}.extraConfig = ''
        header Strict-Transport-Security "max-age=15552000; includeSubDomains"
        reverse_proxy 127.0.0.1:${toString port}
      '';

      # The host's single PostgreSQL instance. Each native service gets its own
      # database and role, reached over the local socket with peer authentication.
      services.postgresql.package = pkgs.postgresql_17;

      # Nightly dump beside the data, so a copy of the disk is a complete backup.
      # zstd's --rsyncable output keeps successive dumps deduplicable.
      services.postgresqlBackup = {
        enable = true;
        databases = ["nextcloud"];
        location = "${disk}/backup/postgresql";
        compression = "zstd";
      };

      nps.deployment.health = {
        requiredSystemdUnits = [
          "postgresql.service"
          "redis-nextcloud.service"
          "phpfpm-nextcloud.service"
          "nginx.service"
        ];
        requiredCommands = [
          {
            name = "Nextcloud answering through Caddy";
            command = "${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 10 --resolve ${hostName}:443:127.0.0.1 https://${hostName}/status.php | ${lib.getExe pkgs.jq} --exit-status '.installed and (.maintenance | not) and (.needsDbUpgrade | not)' >/dev/null";
          }
        ];
      };
    };
  };
}

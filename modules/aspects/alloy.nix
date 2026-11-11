{den, ...}: {
  den.aspects.alloy.nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    dockerEnabled = config.virtualisation.docker.enable;
    telegrafEnabled = config.services.telegraf.enable;
  in {
    nps.deployment.health = {
      requiredSystemdUnits = ["alloy.service"] ++ lib.optionals telegrafEnabled ["telegraf.service"];
      requiredCommands = lib.optionals telegrafEnabled [
        {
          name = "Telegraf endpoint responding";
          command = "${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 5 http://127.0.0.1:9273/metrics >/dev/null";
        }
      ];
    };
    sops.secrets.alloyEnv = {};

    services.alloy = {
      enable = true;
      environmentFile = config.sops.secrets.alloyEnv.path;
      extraFlags = ["--server.http.listen-addr=127.0.0.1:12345"];
    };

    services.telegraf = {
      enable = lib.mkDefault false;
      extraConfig = {
        agent = {
          interval = "60s";
          flush_interval = "5s";
          omit_hostname = true;
        };
        inputs = {
          smart = [
            {
              path_smartctl = lib.getExe pkgs.smartmontools;
              path_nvme = lib.getExe pkgs.nvme-cli;
              enable_extensions = [];
              timeout = "20s";
              attributes = false;
              namepass = ["smart_device"];
              fieldinclude = ["health_ok" "exit_status" "critical_warning" "media_errors" "available_spare" "available_spare_threshold" "percentage_used" "temp_c"];
              taginclude = ["device"];
            }
          ];
          exec = lib.optionals config.boot.zfs.enabled [
            {
              alias = "zfs_pool";
              commands = ["${lib.getBin config.boot.zfs.package}/libexec/zfs/zpool_influxdb -n"];
              timeout = "20s";
              data_format = "influx";
              namepass = ["zpool_stats" "zpool_scan_stats"];
              fieldinclude = ["alloc" "free" "read_errors" "write_errors" "checksum_errors" "end_ts" "errors"];
              taginclude = ["name" "state" "vdev" "function"];
              tagdrop = {vdev = ["root/*"];};
            }
            {
              alias = "zfs_dataset";
              commands = ["${lib.getBin config.boot.zfs.package}/bin/zfs list -Hp -t filesystem,volume -o name,type,used,available,usedbydataset,usedbysnapshots,usedbychildren"];
              timeout = "20s";
              data_format = "csv";
              name_override = "zfs_dataset";
              csv_header_row_count = 0;
              csv_delimiter = "\t";
              csv_column_names = ["name" "type" "used" "available" "usedbydataset" "usedbysnapshots" "usedbychildren"];
              csv_column_types = ["string" "string" "int" "int" "int" "int" "int"];
              csv_tag_columns = ["name" "type"];
              csv_skip_values = ["-"];
              tagpass = {name = ["*/*"];};
            }
          ];
          internal = [
            {
              collect_memstats = false;
              namepass = ["internal_gather"];
              fieldinclude = ["errors" "metrics_gathered"];
              taginclude = ["input" "alias"];
            }
          ];
        };
        outputs.prometheus_client = [
          {
            listen = "127.0.0.1:9273";
            metric_version = 1;
            string_as_label = true;
            export_timestamp = true;
            expiration_interval = "180s";
            collectors_exclude = ["gocollector" "process"];
          }
        ];
        processors.converter = [
          {
            namepass = ["smart_device"];
            fields.integer = ["health_ok"];
          }
        ];
      };
    };

    systemd.services.telegraf = lib.mkIf telegrafEnabled {
      serviceConfig = {
        User = lib.mkForce "root";
        Group = lib.mkForce "root";
        AmbientCapabilities = lib.mkForce [];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    systemd.services.alloy = {
      # Remote configuration needs DNS, so wait for an address before the
      # first Fleet Management lookup instead of failing and restarting.
      wants = ["network-online.target"];
      after = ["network-online.target"];
      restartTriggers = [config.sops.secrets.alloyEnv.sopsFileHash];
      environment = {
        GCLOUD_FM_COLLECTOR_ID = config.networking.hostName;
        GCLOUD_FM_POLL_FREQUENCY = "60s";
      };
      serviceConfig =
        {
          AmbientCapabilities = ["CAP_PERFMON"];
        }
        // lib.optionalAttrs dockerEnabled {
          DynamicUser = lib.mkForce false;
          User = "root";
          SupplementaryGroups = ["docker"];
        };
    };

    environment.etc."alloy/config.alloy".text = ''
      remotecfg {
        url            = sys.env("GCLOUD_FM_URL")
        id             = sys.env("GCLOUD_FM_COLLECTOR_ID")
        poll_frequency = sys.env("GCLOUD_FM_POLL_FREQUENCY")

        attributes = {
          "platform"              = "linux",
          "telemetry.docker"      = "${lib.boolToString dockerEnabled}",
          "telemetry.tailscale"   = "${lib.boolToString config.services.tailscale.enable}",
          "telemetry.syncthing"   = "${lib.boolToString config.services.syncthing.enable}",
          "telemetry.telegraf"    = "${lib.boolToString telegrafEnabled}",
          "telemetry.zfs"         = "${lib.boolToString (telegrafEnabled && config.boot.zfs.enabled)}",
        }

        basic_auth {
          username = sys.env("GCLOUD_FM_HOSTED_ID")
          password = sys.env("GCLOUD_RW_API_KEY")
        }
      }
    '';
  };
}

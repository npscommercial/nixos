{den, ...}: {
  den.aspects.alloy.nixos = {
    config,
    lib,
    ...
  }: let
    dockerEnabled = config.virtualisation.docker.enable;
  in {
    sops.secrets.alloyEnv = {};

    services.alloy = {
      enable = true;
      environmentFile = config.sops.secrets.alloyEnv.path;
      extraFlags = ["--server.http.listen-addr=127.0.0.1:12345"];
    };

    systemd.services.alloy = {
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
        }

        basic_auth {
          username = sys.env("GCLOUD_FM_HOSTED_ID")
          password = sys.env("GCLOUD_RW_API_KEY")
        }
      }
    '';
  };
}

{
  den,
  lib,
  ...
}: let
  hostName = "twenty.npscommercial.net.au";
  images = import ../_dockerfile.nix lib ./Dockerfile;
  # Files and database, kept where the Docker deployment had them.
  dataDir = "/opt/docker/twenty";
  network = "twenty";
  containers = ["twenty" "twenty-worker" "twenty-db" "twenty-redis"];
in {
  den.aspects.twenty = {
    includes = [den.aspects.caddy];
    nixos = {
      config,
      lib,
      pkgs,
      ...
    }: let
      # Settings shared by the server and the worker.
      app = {
        image = images.twenty;
        networks = [network];
        volumes = ["${dataDir}/storage:/app/packages/twenty-server/.local-storage"];
        environmentFiles = [config.sops.secrets.twentyEnv.path];
        environment = {
          SERVER_URL = "https://${hostName}";
          REDIS_URL = "redis://twenty-redis:6379";
          STORAGE_TYPE = "local";
        };
      };
    in {
      # PG_DATABASE_URL and APP_SECRET, as environment lines.
      sops.secrets.twentyEnv = {};

      virtualisation.oci-containers.containers = {
        twenty = lib.recursiveUpdate app {
          ports = ["127.0.0.1:3000:3000"];
          environment.NODE_PORT = "3000";
          dependsOn = ["twenty-db" "twenty-redis"];
        };
        twenty-worker = lib.recursiveUpdate app {
          cmd = ["yarn" "worker:prod"];
          # The server runs migrations and registers cron jobs.
          environment = {
            DISABLE_DB_MIGRATIONS = "true";
            DISABLE_CRON_JOBS_REGISTRATION = "true";
          };
          dependsOn = ["twenty"];
        };
        twenty-db = {
          image = images.db;
          networks = [network];
          volumes = ["${dataDir}/database:/var/lib/postgresql/data"];
          environment.POSTGRES_USER = "postgres";
        };
        twenty-redis = {
          image = images.redis;
          networks = [network];
          # Twenty's job queue must not lose entries to eviction.
          cmd = ["--maxmemory-policy" "noeviction"];
        };
      };

      # Podman does not create named networks itself. Containers on this one
      # find each other by name through Podman's DNS server on the bridge.
      systemd.services =
        {
          podman-network-twenty = {
            description = "Podman network for Twenty";
            path = [config.virtualisation.podman.package];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = "podman network exists ${network} || podman network create --interface-name=${network}0 ${network}";
          };
        }
        // lib.genAttrs (map (name: "podman-${name}") containers) (name: {
          requires = ["podman-network-twenty.service"];
          after = ["podman-network-twenty.service"];
          restartTriggers = lib.optional (lib.elem name ["podman-twenty" "podman-twenty-worker"]) config.sops.secrets.twentyEnv.sopsFileHash;
        });
      networking.firewall.interfaces."${network}0".allowedUDPPorts = [53];

      services.caddy.virtualHosts.${hostName}.extraConfig = ''
        reverse_proxy 127.0.0.1:3000
      '';

      nps.deployment.health = {
        requiredSystemdUnits = map (name: "podman-${name}.service") containers;
        requiredCommands = [
          {
            name = "Twenty answering through Caddy";
            command = "${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 10 --resolve ${hostName}:443:127.0.0.1 https://${hostName}/healthz >/dev/null";
          }
        ];
      };
    };
  };
}

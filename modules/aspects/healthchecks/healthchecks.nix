{
  den,
  lib,
  ...
}: let
  hostName = "healthchecks.npscommercial.com.au";
  # The image reference lives in a Dockerfile so Dependabot can update it.
  image = (import ../_dockerfile.nix lib ./Dockerfile).default;
  # Configuration and SQLite database, kept where the Docker deployment had them.
  dataDir = "/opt/docker/healthchecks/conf/healthchecks";
in {
  den.aspects.healthchecks = {
    includes = [den.aspects.caddy];
    nixos = {
      config,
      lib,
      pkgs,
      ...
    }: {
      # The nixpkgs package lacks minismtpd, which Healthchecks 5's email ping
      # listener needs, so this runs the upstream-built image instead.

      # SECRET_KEY and EMAIL_HOST_PASSWORD, as environment lines.
      sops.secrets.healthchecksEnv = {};

      virtualisation.oci-containers.containers.healthchecks = {
        inherit image;
        volumes = ["${dataDir}:/config"];
        ports = [
          "127.0.0.1:8000:8000"
          "25:2525"
        ];
        environmentFiles = [config.sops.secrets.healthchecksEnv.path];
        environment = {
          PUID = "1000";
          PGID = "1000";
          TZ = config.time.timeZone;
          SITE_ROOT = "https://${hostName}";
          SITE_NAME = "NPS Commercial Health Checks";
          SITE_LOGO_URL = "https://www.npscommercial.com.au/images/nps/nps.svg";
          ALLOWED_HOSTS = hostName;
          REGISTRATION_OPEN = "False";
          DEBUG = "False";
          PING_EMAIL_DOMAIN = hostName;
          DEFAULT_FROM_EMAIL = "healthchecks@npscommercial.com.au";
          EMAIL_HOST = "smtp.mailgun.org";
          EMAIL_PORT = "465";
          EMAIL_HOST_USER = "healthchecks@npscommercial.com.au";
          EMAIL_USE_TLS = "False";
          EMAIL_USE_SSL = "True";
        };
      };
      systemd.services.podman-healthchecks.restartTriggers = [config.sops.secrets.healthchecksEnv.sopsFileHash];
      networking.firewall.allowedTCPPorts = [25];

      services.caddy.virtualHosts.${hostName}.extraConfig = ''
        reverse_proxy 127.0.0.1:8000
      '';

      nps.deployment.health = {
        requiredSystemdUnits = ["podman-healthchecks.service"];
        requiredCommands = [
          {
            name = "Healthchecks answering through Caddy";
            command = "${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 5 --resolve ${hostName}:443:127.0.0.1 https://${hostName}/api/v3/status/ >/dev/null";
          }
          {
            name = "Healthchecks accepting email pings";
            command = "${lib.getExe pkgs.curl} --silent --max-time 5 --connect-timeout 3 telnet://127.0.0.1:25 </dev/null | ${pkgs.gnugrep}/bin/grep -q '^220'";
          }
        ];
      };
    };
  };
}

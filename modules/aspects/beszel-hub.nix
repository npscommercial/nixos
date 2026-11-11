{den, ...}: let
  hostName = "beszel.npscommercial.net.au";
in {
  den.aspects.beszel-hub = {
    includes = [den.aspects.caddy];
    nixos = {
      lib,
      pkgs,
      ...
    }: {
      services.beszel.hub = {
        enable = true;
        # The stable release lags the hub version whose database is in use.
        package = pkgs.unstable.beszel;
        environment.BESZEL_HUB_SHARE_ALL_SYSTEMS = "true";
      };

      services.caddy.virtualHosts.${hostName}.extraConfig = ''
        reverse_proxy 127.0.0.1:8090
      '';

      # One-off import of the hub data from the retired Docker deployment.
      # It runs only while the hub has no database of its own.
      systemd.services.beszel-hub-import = {
        description = "Import Beszel hub data from Docker";
        requiredBy = ["beszel-hub.service"];
        before = ["beszel-hub.service"];
        unitConfig.ConditionPathExists = [
          "/opt/docker/beszel/beszel_data/data.db"
          "!/var/lib/private/beszel-hub/data.db"
        ];
        serviceConfig.Type = "oneshot";
        script = ''
          install -d -m 0700 /var/lib/private
          install -d -m 0700 /var/lib/private/beszel-hub
          cp -a /opt/docker/beszel/beszel_data/. /var/lib/private/beszel-hub/
        '';
      };

      nps.deployment.health = {
        requiredSystemdUnits = ["beszel-hub.service"];
        requiredCommands = [
          {
            name = "Beszel answering through Caddy";
            command = "${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 5 --resolve ${hostName}:443:127.0.0.1 https://${hostName}/api/health >/dev/null";
          }
        ];
      };
    };
  };
}

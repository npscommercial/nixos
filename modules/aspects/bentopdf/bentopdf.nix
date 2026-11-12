{
  den,
  lib,
  ...
}: let
  # Only resolvable on the office network; certificates come from DNS challenges.
  hostName = "bentopdf.npscommercial.net.au";
  inherit (import ../_dockerfile.nix lib ./Dockerfile) default;
  port = 8082;
in {
  den.aspects.bentopdf = {
    includes = [den.aspects.caddy];
    nixos = {pkgs, ...}: {
      # A static site: the PDF work happens in the browser.
      virtualisation.oci-containers.containers.bentopdf = {
        image = default;
        ports = ["127.0.0.1:${toString port}:8080"];
      };

      services.caddy.virtualHosts.${hostName}.extraConfig = ''
        reverse_proxy 127.0.0.1:${toString port}
      '';

      nps.deployment.health = {
        requiredSystemdUnits = ["podman-bentopdf.service"];
        requiredCommands = [
          {
            name = "BentoPDF answering";
            command = "${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 10 http://127.0.0.1:${toString port}/ >/dev/null";
          }
        ];
      };
    };
  };
}

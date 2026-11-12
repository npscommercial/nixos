{
  den,
  lib,
  ...
}: let
  # Only resolvable on the office network; certificates come from DNS challenges.
  hostNames = ["pdf.npscommercial.net.au" "stirlingpdf.npscommercial.net.au"];
  inherit (import ../_dockerfile.nix lib ./Dockerfile) default;
  # Settings and OCR language data, kept where the Docker deployment had them.
  dataDir = "/opt/docker/stirling";
  port = 8081;
in {
  den.aspects.stirling-pdf = {
    includes = [den.aspects.caddy];
    nixos = {pkgs, ...}: {
      virtualisation.oci-containers.containers.stirling-pdf = {
        image = default;
        ports = ["127.0.0.1:${toString port}:8080"];
        volumes = [
          "${dataDir}/configs:/configs"
          "${dataDir}/tessdata:/usr/share/tesseract-ocr/5/tessdata"
        ];
        environment.DOCKER_ENABLE_SECURITY = "false";
      };

      services.caddy.virtualHosts.${lib.concatStringsSep ", " hostNames}.extraConfig = ''
        reverse_proxy 127.0.0.1:${toString port}
      '';

      nps.deployment.health = {
        requiredSystemdUnits = ["podman-stirling-pdf.service"];
        requiredCommands = [
          {
            name = "Stirling PDF answering";
            command = "${lib.getExe pkgs.curl} --fail --silent --show-error --max-time 10 http://127.0.0.1:${toString port}/ >/dev/null";
          }
        ];
      };
    };
  };
}

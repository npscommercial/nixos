{...}: {
  den.aspects.caddy.nixos = {
    config,
    pkgs,
    ...
  }: {
    # Certificates come from ACME DNS challenges against Cloudflare, so names
    # behind the Cloudflare proxy or reachable only on the LAN still validate.
    sops.secrets.cloudflareDnsEnv = {};

    services.caddy = {
      enable = true;
      # Built from ./build; see _package.nix.
      package = pkgs.callPackage ./_package.nix {};
      email = "tech@npscommercial.com.au";
      environmentFile = config.sops.secrets.cloudflareDnsEnv.path;
      globalConfig = ''
        acme_dns cloudflare {env.CF_API_TOKEN}
      '';
    };
    systemd.services.caddy.restartTriggers = [config.sops.secrets.cloudflareDnsEnv.sopsFileHash];

    networking.firewall.allowedTCPPorts = [80 443];
    networking.firewall.allowedUDPPorts = [443];

    nps.deployment.health.requiredSystemdUnits = ["caddy.service"];
  };
}

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
      package = pkgs.caddy.withPlugins {
        plugins = ["github.com/caddy-dns/cloudflare@v0.2.4"];
        hash = "sha256-tubXIDCJnO2mvdnPlZclwDhNGaeeYLSt7lnni3+pXDo=";
      };
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

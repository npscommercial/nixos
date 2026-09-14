{...}: {
  den.aspects.office-wireless.nixos = {config, ...}: {
    # wpa-supplicant and systemd networking
    sops.secrets.wirelessEnv = {};
    networking.useNetworkd = true;
    systemd.network.enable = true;
    networking.wireless = {
      enable = true;
      secretsFile = config.sops.secrets.wirelessEnv.path;
      networks.NPSCOMMERCIAL.pskRaw = "ext:PSK_NPSCOMMERCIAL";
      networks.WiFi-3040.pskRaw = "ext:PSK_WIFI3040";
    };
  };
}

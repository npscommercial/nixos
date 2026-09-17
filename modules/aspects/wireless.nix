{...}: {
  den.aspects.wireless.nixos = {config, ...}: {
    # wpa-supplicant and systemd networking
    # Hardened wpa_supplicant runs unprivileged in NixOS 26.05.
    sops.secrets.wirelessEnv = {
      group = "wpa_supplicant";
      mode = "0440";
      restartUnits = ["wpa_supplicant.service"];
    };
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

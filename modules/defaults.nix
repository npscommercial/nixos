{
  den,
  inputs,
  ...
}: {
  den.default.includes = [den.batteries.hostname];

  den.default.nixos = {pkgs, ...}: {
    networking.domain = "npscommercial.net.au";
    time.timeZone = "Australia/Brisbane";

    nix.settings = {
      experimental-features = ["nix-command" "flakes"];
      auto-optimise-store = true;
      trusted-users = ["@wheel"];
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
        "https://npscommercial.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "npscommercial.cachix.org-1:reHRgPxKuZD3uceoIDTl1YCZqzvVa8Bw1x9k0U/0LKM="
      ];
    };
    nix.optimise.automatic = true;
    nix.gc = {
      automatic = true;
      options = "--delete-older-than 30d";
    };

    nixpkgs.overlays = [
      # Add unstable package set to pkgs
      (final: _prev: {
        unstable = inputs.nixpkgs-unstable.legacyPackages.${final.stdenv.hostPlatform.system};
      })
    ];

    # Fix to allow non-nix executables
    programs.nix-ld.enable = true;
    # programs.nix-ld.libraries = with pkgs; [
    #   # Add any missing dynamic libraries for unpackaged programs
    #   # here, NOT in environment.systemPackages
    # ];

    # Allow sudo via SSH key
    security.pam.sshAgentAuth.enable = true;
    security.pam.services.sudo.sshAgentAuth = true;

    # Allow unfree and configure base system packages
    nixpkgs.config.allowUnfree = true;
    environment.systemPackages = with pkgs; [
      # Misc
      btop
      fish
      powershell
      helix
      nh

      # Files
      dua
      tree
      rclone

      # HTTP
      wget
      curl
      xh

      # JSON
      jq
      fx

      # Net
      dig
      whois
      rdap
      iperf

      # Linux
      service-wrapper
      iftop
      iotop
      ethtool
      pciutils
      usbutils
    ];

    # Enable git usage
    programs.git.enable = true;

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
    };

    # Set up basic SSH protection
    services.sshguard.enable = true;
    services.openssh.enable = true;
    services.openssh.settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };
}

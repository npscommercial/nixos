{
  den,
  inputs,
  config,
  lib,
  ...
}: {
  den.schema.user.classes = lib.mkDefault ["homeManager"];

  den.default.includes = [den.provides.hostname];

  den.default.wsl-host = {pkgs, ...}: {
    wsl.ssh-agent.enable = true;
    environment.systemPackages = with pkgs; [
      parallel
      qpdf
      ocrmypdf
      sops
      age
      nil
      alejandra
    ];
  };

  den.default.nixos = {pkgs, ...}: {
    nps.deployment.health.requiredSystemdUnits = ["sshd.service"];
    networking.domain = "npscommercial.net.au";
    time.timeZone = "Australia/Brisbane";

    nix.settings = {
      experimental-features = ["nix-command" "flakes"];
      auto-optimise-store = true;
      trusted-users = ["@wheel"];
      substituters = config.flake-file.nixConfig.extra-substituters;
      trusted-public-keys = config.flake-file.nixConfig.extra-trusted-public-keys;
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

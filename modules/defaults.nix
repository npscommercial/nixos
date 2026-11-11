{
  den,
  inputs,
  config,
  lib,
  ...
}: {
  den.schema.user.classes = lib.mkDefault ["homeManager"];

  den.default.includes = [den.provides.hostname];

  # Hosts accept host-level content (nixos/os) from the admin user's aspect,
  # such as the sops-backed password and authorised keys. den delivers user
  # content to hosts only when the host opts in.
  den.schema.host.includes = [(den.batteries.user-aspects {users = ["whitestrake"];})];

  den.default.wsl-host = {pkgs, ...}: {
    wsl.ssh-agent.enable = true;
    environment.systemPackages = with pkgs; [
      powershell
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
    # Expire old generations daily, always keeping five for rollback.
    programs.nh = {
      enable = true;
      flake = "github:npscommercial/nixos";
      clean = {
        enable = true;
        dates = "daily";
        extraArgs = "--keep-since 7d --keep 5";
      };
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
      helix
      nh

      # File system tools
      dua
      tree
      rclone

      # Search tools
      fd
      ripgrep

      # Data inspection
      jq
      fx

      # Network clients
      wget
      curl
      xh

      # Troubleshooting
      btop
      mtr
      tcpdump
      dig
      whois
      rdap
      iperf
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

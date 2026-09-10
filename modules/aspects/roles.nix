{
  den,
  inputs,
  ...
}: {
  flake-file.inputs = {
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  den.aspects.server = {
    includes = [
      den.aspects.alloy
      den.aspects.cachix-agent
    ];
    nixos = {pkgs, ...}: {
      services.tailscale = {
        enable = true;
        package = pkgs.unstable.tailscale;
      };
    };
  };

  den.aspects.docker = {
    includes = [den.aspects.server];
    nixos = {
      virtualisation.docker.enable = true;
      virtualisation.docker.autoPrune.enable = true;
      systemd.tmpfiles.rules = ["d /opt/docker 0770 nobody docker"];
      environment.shellAliases = {
        dps = "docker ps -as --format 'table {{.Names}}\t{{.Status}}\t{{.Size}}'";
        dc = "docker compose";
        dcl = "dc logs -f --tail 20";
      };
    };
  };

  den.aspects.wsl-workstation.nixos = {pkgs, ...}: {
    imports = [inputs.vscode-server.nixosModules.default];
    wsl = {
      enable = true;
      ssh-agent.enable = true;
    };
    services.vscode-server.enable = true;
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
}

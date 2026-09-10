{den, ...}: {
  den.aspects.NPS04 = {
    includes = [den.aspects.wsl-workstation];
    nixos = {pkgs, ...}: {
      system.stateVersion = "24.11";
      environment.systemPackages = [pkgs.vscode];
    };
  };
}

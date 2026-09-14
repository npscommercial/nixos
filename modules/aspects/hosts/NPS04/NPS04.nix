{...}: {
  den.aspects.NPS04 = {
    nixos = {pkgs, ...}: {
      system.stateVersion = "24.11";
      environment.systemPackages = [pkgs.vscode];
    };
  };
}

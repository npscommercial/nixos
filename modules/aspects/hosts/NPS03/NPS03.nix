{den, ...}: {
  den.aspects.NPS03 = {
    includes = [den.aspects.wsl-workstation];
    nixos.system.stateVersion = "23.11";
  };
}

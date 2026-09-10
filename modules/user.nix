{
  den,
  inputs,
  lib,
  ...
}: {
  flake-file.inputs.whitestrake-source = {
    url = "github:whitestrake/nixos/5d6f0578c2fa748e347a1d5f86c13a4a608adad7";
    flake = false;
  };

  imports = [
    (inputs.whitestrake-source + "/modules/aspects/users/whitestrake.nix")
  ];

  den.aspects.whitestrake.nixos = lib.mkForce ({
    user,
    config,
    ...
  }: {
    sops.secrets.mattPassword.neededForUsers = true;
    users.users.${user.userName} = {
      hashedPasswordFile = config.sops.secrets.mattPassword.path;
      extraGroups = lib.optionals config.virtualisation.docker.enable ["docker"];
      openssh.authorizedKeys.keyFiles = [inputs.whitestrake-github-keys.outPath];
    };
  });
}

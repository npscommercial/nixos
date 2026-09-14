{
  den,
  lib,
  ...
}: {
  flake-file.inputs.nixos-wsl = {
    url = "github:nix-community/NixOS-WSL/main";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  den.classes.wsl-host.description = "WSL workstation configuration";
  den.policies.wsl-host-to-host = {host, ...}:
    lib.optional (host ? class && host.class == "nixos" && ((host.wsl or {}).enable or false))
    (den.lib.policy.route {
      fromClass = "wsl-host";
      intoClass = host.class;
      path = [];
    });
  den.schema.host.includes = [den.policies.wsl-host-to-host];

  den.classes.hmLinux.description = "Linux-only Home Manager configuration";

  den.batteries.hmLinux = {
    host,
    user,
    ...
  }:
    den.batteries.forward {
      each = ["Linux"];
      fromClass = _: "hmLinux";
      intoClass = _: "homeManager";
      intoPath = _: [];
      fromAspect = _: den.lib.resolveEntity "user" {inherit host user;};
      guard = {pkgs, ...}: _: lib.mkIf pkgs.stdenv.isLinux;
      adaptArgs = {config, ...}: {osConfig = config;};
    };

  den.schema.user.includes = [den.batteries.hmLinux];
}

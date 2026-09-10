{
  den,
  lib,
  ...
}: {
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

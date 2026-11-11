# Caddy with plugins, built as an ordinary Go main module from ./build.
#
# ./build/go.mod pins Caddy and each plugin, and Dependabot keeps them current.
# vendorHash depends only on go.mod and go.sum, so it changes when Dependabot
# changes them and never when nixpkgs updates its own Caddy or Go. After such a
# change the build fails and reports the new hash as `got:`.
{
  lib,
  caddy,
}: let
  goMod = builtins.readFile ./build/go.mod;
  caddyVersion = builtins.match ".*\n\tgithub.com/caddyserver/caddy/v2 v([^ \n]+)\n.*" goMod;
in
  caddy.overrideAttrs (old: {
    version =
      if caddyVersion == null
      then throw "caddy: no github.com/caddyserver/caddy/v2 requirement in build/go.mod"
      else lib.head caddyVersion;
    src = ./build;
    vendorHash = "sha256-tIK6jtak2LTadTzEx7D+BFl4BdfmJ2fVwQ2sAN8kKD4=";
    subPackages = ["."];

    # nixpkgs removes Caddy's embedded CA bundle so that only the system store
    # is used. Here Caddy is a dependency, so the file is under vendor/.
    postConfigure = ''
      chmod u+w vendor/github.com/caddyserver/caddy/v2/cmd
      rm vendor/github.com/caddyserver/caddy/v2/cmd/x509rootsfallback.go
    '';

    # The systemd units come from Caddy's dist repository at a tag derived
    # from the version, with a hash nixpkgs records for its own version. Keep
    # nixpkgs' copy so that fetch does not depend on this version.
    passthru = old.passthru // {inherit (caddy) dist;};
  })

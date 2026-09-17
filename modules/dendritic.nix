{
  config,
  inputs,
  lib,
  ...
}: {
  flake-file = {
    description = "NPS Commercial NixOS systems";

    nixConfig = {
      lazy-trees = true;
      extra-substituters = [
        "https://cache.nixos.org"
        "https://npscommercial.cachix.org"
      ];
      extra-trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "npscommercial.cachix.org-1:reHRgPxKuZD3uceoIDTl1YCZqzvVa8Bw1x9k0U/0LKM="
      ];
    };

    inputs = {
      den.url = "github:denful/den";
      flake-file.url = "github:denful/flake-file";
      disko = {
        url = "github:nix-community/disko/latest";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      flake-parts = {
        url = "github:hercules-ci/flake-parts";
        inputs.nixpkgs-lib.follows = "nixpkgs";
      };
      home-manager = {
        url = "github:nix-community/home-manager/release-26.05";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      import-tree.url = "github:denful/import-tree";
      nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
      nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    };
  };

  systems = lib.unique (
    builtins.attrNames config.den.hosts
    ++ ["aarch64-darwin"]
  );

  imports = [
    inputs.flake-file.flakeModules.dendritic
    inputs.den.flakeModule
  ];
}

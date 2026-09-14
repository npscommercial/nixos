{
  config,
  inputs,
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
      den.url = "github:vic/den";
      flake-file.url = "github:denful/flake-file";
      flake-parts = {
        url = "github:hercules-ci/flake-parts";
        inputs.nixpkgs-lib.follows = "nixpkgs";
      };
      home-manager = {
        url = "github:nix-community/home-manager/release-26.05";
        inputs.nixpkgs.follows = "nixpkgs";
      };
      import-tree.url = "github:vic/import-tree";
      nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
      nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    };
  };

  systems = builtins.attrNames config.den.hosts;

  imports = [
    inputs.flake-file.flakeModules.dendritic
    inputs.den.flakeModule
  ];
}

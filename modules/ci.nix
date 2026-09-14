{
  inputs,
  lib,
  self,
  ...
}: {
  perSystem = {
    pkgs,
    system,
    ...
  }: let
    unstable = inputs.nixpkgs-unstable.legacyPackages.${system};
    ci-tools = pkgs.buildEnv {
      name = "nps-ci-tools";
      paths = [
        unstable.nix-fast-build
        unstable.cachix
        unstable.erofs-utils
      ];
      pathsToLink = ["/bin"];
    };
  in {
    packages.ci-tools = ci-tools;
    checks.ciBoundaries = pkgs.runCommand "ci-boundaries" {nativeBuildInputs = [pkgs.python3];} ''
      export PYTHONDONTWRITEBYTECODE=1
      ${lib.getExe pkgs.python3} ${self}/.github/scripts/check_ci.py
      ${lib.getExe pkgs.python3} -m unittest discover -s ${self}/.github/scripts -p 'test_*.py'
      touch "$out"
    '';
  };
}

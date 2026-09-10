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
    nix-fast-build = assert lib.assertMsg (unstable.nix-fast-build.version == "2.0.2") "review nix-fast-build patches for the new pinned version";
      unstable.nix-fast-build.overridePythonAttrs (old: {
        postPatch =
          (old.postPatch or "")
          + ''
            substituteInPlace nix_fast_build/options.py \
              --replace-fail \
                '        fail_fast=a.fail_fast,' \
                $'        retries=a.retries,\n        fail_fast=a.fail_fast,'
          ''
          + ''
            substituteInPlace nix_fast_build/__init__.py \
              --replace-fail \
                'assert task.done(), f"Task {task.get_name()} is not done"' \
                'await task'
          '';
      });
    ci-tools = pkgs.buildEnv {
      name = "nps-ci-tools";
      paths = [
        nix-fast-build
        unstable.cachix
        unstable.erofs-utils
      ];
      pathsToLink = ["/bin"];
    };
  in {
    packages.ci-tools = ci-tools;
    checks.ciBoundaries = pkgs.runCommand "ci-boundaries" {nativeBuildInputs = [pkgs.python3];} ''
      ${lib.getExe pkgs.python3} ${self}/.github/scripts/check_ci.py
      touch "$out"
    '';
  };
}

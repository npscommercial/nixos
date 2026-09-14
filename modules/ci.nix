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
    # NFB can finish build queues before its eval-stderr task finishes.
    # Await tracked tasks so successful work reaches exit-code/result handling.
    # Remove when the upstream shutdown race is fixed.
    nix-fast-build = assert lib.assertMsg (unstable.nix-fast-build.version == "2.0.2") "review the nix-fast-build shutdown workaround after updating";
      unstable.nix-fast-build.overridePythonAttrs (old: {
        postPatch =
          (old.postPatch or "")
          + ''
            substituteInPlace nix_fast_build/__init__.py --replace-fail 'assert task.done(), f"Task {task.get_name()} is not done"' 'await task'
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
      export PYTHONDONTWRITEBYTECODE=1
      ${lib.getExe pkgs.python3} ${self}/.github/scripts/check_ci.py
      ${lib.getExe pkgs.python3} -m unittest discover -s ${self}/.github/scripts -p 'test_*.py'
      touch "$out"
    '';
  };
}

#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

guard_environment() {
  [ "${CI:-}" = true ] || die "seed operations require CI=true"
  [ "${RUNNER_OS:-}" = Linux ] || die "seed operations require RUNNER_OS=Linux"
  [ "${RUNNER_ARCH:-}" = X64 ] || die "seed operations require RUNNER_ARCH=X64"
  [ -n "${RUNNER_TEMP:-}" ] || die "RUNNER_TEMP is required"
  [ -n "${NIX_SEED_COMPATIBILITY_HASH:-}" ] || die "NIX_SEED_COMPATIBILITY_HASH is required"
  [[ "$NIX_SEED_COMPATIBILITY_HASH" =~ ^[0-9a-f]{64}$ ]] || die "invalid seed compatibility hash"
}

temp_child() {
  local runner path parent
  runner="$(realpath "${RUNNER_TEMP:?RUNNER_TEMP is required}")"
  parent="$(realpath "$(dirname "$1")")" || return 1
  path="$parent/$(basename "$1")"
  [ "$parent" = "$runner" ] || return 1
  printf '%s\n' "$path"
}

remove_temp() {
  local path
  path="$(temp_child "$1")" || die "path must be an exact child of RUNNER_TEMP: $1"
  sudo rm -rf -- "$path"
}

validate() {
  local cache="$1"
  guard_environment
  cache="$(temp_child "$cache")" || die "cache must be an exact child of RUNNER_TEMP"
  [ -d "$cache" ] && [ ! -L "$cache" ] || die "seed cache is not a regular directory"
  [ -f "$cache/manifest.json" ] && [ ! -L "$cache/manifest.json" ] || die "seed manifest is missing"
  [ -f "$cache/image.erofs" ] && [ ! -L "$cache/image.erofs" ] || die "seed image is missing"
  [ -f "$cache/image.erofs.sha256" ] && [ ! -L "$cache/image.erofs.sha256" ] || die "seed checksum is missing"

  python3 - "$cache/manifest.json" "$cache/image.erofs.sha256" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest_path, checksum_path = map(Path, sys.argv[1:])
try:
    manifest = json.loads(manifest_path.read_text())
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid seed manifest: {error}")

required = {
    "schemaVersion",
    "system",
    "runner",
    "nixVersion",
    "format",
    "compatibilityHash",
    "imageSha256",
    "roots",
}
store = re.compile(r"^/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$")
valid = (
    isinstance(manifest, dict)
    and set(manifest) == required
    and manifest["schemaVersion"] == 1
    and manifest["system"] == "x86_64-linux"
    and manifest["runner"] == "ubuntu-24.04"
    and manifest["nixVersion"] == "2.34.7"
    and manifest["format"] == "erofs-lz4hc"
    and isinstance(manifest["compatibilityHash"], str)
    and re.fullmatch(r"[0-9a-f]{64}", manifest["compatibilityHash"])
    and isinstance(manifest["imageSha256"], str)
    and re.fullmatch(r"[0-9a-f]{64}", manifest["imageSha256"])
    and isinstance(manifest["roots"], list)
    and bool(manifest["roots"])
    and len(manifest["roots"]) == len(set(manifest["roots"]))
    and all(isinstance(path, str) and store.fullmatch(path) for path in manifest["roots"])
)
if not valid:
    raise SystemExit("seed manifest does not match the required contract")
expected_checksum = f'{manifest["imageSha256"]}  image.erofs\n'
if checksum_path.read_text() != expected_checksum:
    raise SystemExit("seed checksum file does not match the manifest")
PY
  (cd "$cache" && sha256sum --status -c image.erofs.sha256) || die "seed image checksum failed"
}

cleanup() {
  local state="$1" status=0 root_created=false
  guard_environment
  state="$(temp_child "$state")" || die "state must be an exact child of RUNNER_TEMP"
  if [ -e "$state" ] || [ -L "$state" ]; then
    [ -d "$state" ] && [ ! -L "$state" ] || die "seed state is not a regular directory"
  fi
  [ -f "$state/owned" ] || return 0
  [ ! -f "$state/root-created" ] || root_created=true

  if mountpoint -q /nix; then
    sudo umount /nix || status=$?
  fi
  if mountpoint -q "$state/lower"; then
    sudo umount "$state/lower" || status=$?
  fi
  if [ "$root_created" = true ] && [ -d /nix ] && ! mountpoint -q /nix; then
    sudo rmdir /nix || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    remove_temp "$state"
  fi
  return "$status"
}

restore() {
  local cache="$1" state="$2" database result
  guard_environment
  cache="$(temp_child "$cache")" || die "cache must be an exact child of RUNNER_TEMP"
  state="$(temp_child "$state")" || die "state must be an exact child of RUNNER_TEMP"
  [ ! -e /nix ] || die "/nix already exists before seed restore"
  [ ! -e "$state" ] && [ ! -L "$state" ] || die "seed state already exists"
  validate "$cache"

  mkdir -p "$state/lower" "$state/upper" "$state/work"
  touch "$state/owned" "$state/root-created"
  if ! sudo mkdir /nix \
    || ! sudo modprobe erofs \
    || ! sudo modprobe overlay \
    || ! sudo mount -t erofs -o loop,ro "$cache/image.erofs" "$state/lower" \
    || ! sudo mount -t overlay overlay \
      -o "lowerdir=$state/lower,upperdir=$state/upper,workdir=$state/work" /nix; then
    cleanup "$state" || die "failed seed restore could not be cleaned up"
    return 1
  fi

  database=/nix/var/nix/db/db.sqlite
  if ! mountpoint -q /nix || [ ! -f "$database" ]; then
    cleanup "$state" || die "invalid seed mount could not be cleaned up"
    return 1
  fi
  result="$(sqlite3 -readonly -batch "$database" \
    "PRAGMA quick_check; SELECT count(*) FROM sqlite_master WHERE type='table' AND name='ValidPaths';")"
  if [ "$result" != $'ok\n1' ]; then
    cleanup "$state" || die "invalid seed database could not be cleaned up"
    return 1
  fi
}

discard() {
  local cache="$1" state="$2"
  cleanup "$state" || die "failed seed state cleanup"
  remove_temp "$cache"
}

scan_secret() {
  local name="$1"
  [ -n "${!name:-}" ] || die "$name is unavailable for the seed-content scan"
  python3 - "$name" <<'PY'
import os
import stat
import sys

name = sys.argv[1]
secret = os.environ[name].encode()
carry = b""
try:
    def walk_error(error):
        raise error

    for directory, _, files in os.walk("/nix", onerror=walk_error, followlinks=False):
        for filename in files:
            path = os.path.join(directory, filename)
            if not stat.S_ISREG(os.lstat(path).st_mode):
                continue
            with open(path, "rb") as source:
                carry = b""
                while chunk := source.read(1024 * 1024):
                    block = carry + chunk
                    if secret in block:
                        raise SystemExit(f"{name} was found in the candidate seed")
                    carry = block[-(len(secret) - 1):] if len(secret) > 1 else b""
except OSError as error:
    raise SystemExit(f"{name} seed-content scan failed: {error.strerror}")
PY
}

refresh() {
  local candidate="$1" state="$2" tools="$3" record="$4" archive="$5"
  local roots profile checkpoint options status input_file garbage_file root_dir
  local -a inputs=()
  guard_environment
  candidate="$(temp_child "$candidate")" || die "candidate must be an exact child of RUNNER_TEMP"
  state="$(temp_child "$state")" || die "state must be an exact child of RUNNER_TEMP"
  record="$(temp_child "$record")" || die "build record must be an exact child of RUNNER_TEMP"
  archive="$(temp_child "$archive")" || die "flake archive must be an exact child of RUNNER_TEMP"
  [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || die "seed candidate already exists"
  [ -f "$record" ] && [ ! -L "$record" ] || die "build record is not a regular file"
  [ -f "$archive" ] && [ ! -L "$archive" ] || die "flake archive is not a regular file"
  if [ -e "$state" ] || [ -L "$state" ]; then
    [ -d "$state" ] && [ ! -L "$state" ] || die "seed state is not a regular directory"
  fi
  [ -d /nix ] || die "/nix is missing"
  [[ "$tools" =~ ^/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$ ]] || die "invalid CI tools path"
  [ -x "$tools/bin/nix-fast-build" ] \
    && [ -x "$tools/bin/cachix" ] \
    && [ -x "$tools/bin/mkfs.erofs" ] || die "CI tools closure is incomplete"

  input_file="$RUNNER_TEMP/nix-seed-inputs"
  garbage_file="$RUNNER_TEMP/nix-seed-garbage"
  [ ! -e "$input_file" ] && [ ! -e "$garbage_file" ] || die "seed intermediate files already exist"
  python3 - "$archive" "$record" "$input_file" "$garbage_file" <<'PY'
import json
import re
import sys
from pathlib import Path

archive_path, record_path, inputs_path, garbage_path = map(Path, sys.argv[1:])
archive = json.loads(archive_path.read_text())
record = json.loads(record_path.read_text())
store = re.compile(r"^/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$")
if not isinstance(archive, dict) or not store.fullmatch(archive.get("path", "")):
    raise SystemExit("flake archive root is malformed")
if record.get("schemaVersion") != 1 or not isinstance(record.get("hosts"), dict):
    raise SystemExit("build record is malformed")

paths = set()
def visit(node):
    if not isinstance(node, dict):
        return
    path = node.get("path")
    if isinstance(path, str):
        if not store.fullmatch(path):
            raise SystemExit("flake archive input path is malformed")
        paths.add(path)
    for child in node.get("inputs", {}).values():
        visit(child)

for child in archive.get("inputs", {}).values():
    visit(child)
paths.discard(archive["path"])
if not paths:
    raise SystemExit("flake archive has no external inputs")
inputs_path.write_text("".join(f"{path}\n" for path in sorted(paths)))

garbage = {archive["path"]}
garbage.update(record["hosts"].values())
for target in record.get("targets", {}).values():
    garbage.add(target.get("rollbackScript"))
if not all(isinstance(path, str) and store.fullmatch(path) for path in garbage):
    raise SystemExit("build garbage path is malformed")
garbage_path.write_text("".join(f"{path}\n" for path in sorted(garbage)))
PY

  profile="$(readlink -e "$HOME/.nix-profile")"
  [[ "$profile" =~ ^/nix/store/[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+$ ]] || die "Nix profile does not resolve into the store"
  root_dir=/nix/var/nix/gcroots/nps-ci-seed
  rm -rf -- "$root_dir"
  mkdir -p "$root_dir"
  ln -s "$profile" "$root_dir/profile"
  ln -s "$tools" "$root_dir/ci-tools"
  mapfile -t inputs < "$input_file"
  index=0
  for path in "${inputs[@]}"; do
    index=$((index + 1))
    ln -s "$path" "$root_dir/input-$(printf '%03d' "$index")"
  done

  mapfile -t roots < <(find "$root_dir" -mindepth 1 -maxdepth 1 -type l -print | sort)
  [ "${#roots[@]}" -gt 2 ] || die "seed roots are incomplete"
  for root in "${roots[@]}"; do
    readlink -e "$root" >/dev/null || die "seed root is dangling"
  done
  nix path-info --recursive "$profile" "$tools" "${inputs[@]}" >/dev/null

  if [ -d /nix/var/log/nix/drvs ]; then
    find /nix/var/log/nix/drvs -type f -delete
  fi
  nix store gc
  nix path-info --recursive "$profile" "$tools" "${inputs[@]}" >/dev/null
  while IFS= read -r path; do
    [ ! -e "$path" ] || die "build or checkout path remained rooted after GC"
  done < "$garbage_file"

  scan_secret CACHIX_AUTH_TOKEN
  scan_secret GITHUB_TOKEN
  [ -z "${CACHIX_ACTIVATE_TOKEN:-}" ] || die "CACHIX_ACTIVATE_TOKEN must not enter the build job"
  if find /nix/var/nix -xdev \( -name .netrc -o -name credentials -o -name '*access-token*' \) -print -quit | grep -q .; then
    die "credential material exists in the Nix runtime state"
  fi
  for config in /nix/etc/nix/nix.conf /nix/var/nix/etc/nix/nix.conf; do
    if [ -f "$config" ] && grep -Eq '(^|[[:space:]])(access-tokens|netrc-file)[[:space:]]*=' "$config"; then
      die "credential-bearing Nix configuration exists in the seed"
    fi
  done

  ! pgrep -x nix-daemon >/dev/null || die "nix-daemon is still running"
  [ ! -e /nix/var/nix/daemon-socket/socket ] || die "Nix daemon socket exists"
  checkpoint="$(sqlite3 /nix/var/nix/db/db.sqlite 'PRAGMA wal_checkpoint(TRUNCATE);')"
  case "$checkpoint" in
    0\|*) ;;
    *) die "SQLite checkpoint did not complete" ;;
  esac
  sync

  if [ ! -f "$state/owned" ]; then
    [ ! -e "$state" ] || die "unowned seed state exists"
    mkdir -p "$state"
    touch "$state/owned"
  fi
  if mountpoint -q /nix; then
    sudo mount -o remount,ro /nix
  else
    touch "$state/root-pre-existing"
    sudo mount --bind /nix /nix
    sudo mount -o remount,bind,ro /nix
  fi
  options="$(findmnt -no OPTIONS /nix)"
  [[ ",$options," == *,ro,* ]] || die "/nix is not read-only for packing"

  finish_refresh() {
    status=$?
    trap - EXIT
    cleanup "$state" || status=1
    if [ "$status" -ne 0 ]; then
      remove_temp "$candidate"
    fi
    rm -f -- "$input_file" "$garbage_file"
    exit "$status"
  }
  trap finish_refresh EXIT

  mkdir "$candidate"
  "$tools/bin/mkfs.erofs" --quiet -zlz4hc "$candidate/image.erofs" /nix
  digest="$(sha256sum "$candidate/image.erofs" | cut -d' ' -f1)"
  printf '%s  image.erofs\n' "$digest" > "$candidate/image.erofs.sha256"
  python3 - "$candidate/manifest.json" "$digest" "$NIX_SEED_COMPATIBILITY_HASH" "$profile" "$tools" "$input_file" <<'PY'
import json
import sys
from pathlib import Path

manifest_path, digest, compatibility, profile, tools, inputs_path = sys.argv[1:]
roots = sorted({profile, tools, *Path(inputs_path).read_text().splitlines()})
manifest = {
    "schemaVersion": 1,
    "system": "x86_64-linux",
    "runner": "ubuntu-24.04",
    "nixVersion": "2.34.7",
    "format": "erofs-lz4hc",
    "compatibilityHash": compatibility,
    "imageSha256": digest,
    "roots": roots,
}
Path(manifest_path).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
  finish_refresh
}

command="${1:-}"
shift || true
case "$command" in
  cleanup) cleanup "$@" ;;
  discard) discard "$@" ;;
  refresh) refresh "$@" ;;
  restore) restore "$@" ;;
  validate) validate "$@" ;;
  *) exit 64 ;;
esac

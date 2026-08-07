#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT_DIR}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

source ./scripts/lib/logging.sh
source ./scripts/lib/filesystem.sh

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

source ./scripts/lib/mods.sh
source ./scripts/lib/modpack_overrides.sh

fail() {
  printf 'modpack override smoke failed: %s\n' "$*" >&2
  exit 1
}

pack_dir="$tmp/packs"
mkdir -p "$pack_dir"

PACK_DIR="$pack_dir" python3 - <<'PY'
import json
import os
from pathlib import Path
import zipfile

root = Path(os.environ["PACK_DIR"])
index = {
    "formatVersion": 1,
    "game": "minecraft",
    "versionId": "override-test",
    "files": [],
    "dependencies": {"minecraft": "1.21.8"},
}

with zipfile.ZipFile(root / "valid.mrpack", "w") as zf:
    zf.writestr("modrinth.index.json", json.dumps(index))
    zf.writestr("overrides/config/shared.toml", "base value\n")
    zf.writestr("overrides/config/base-only.toml", "base only\n")
    zf.writestr("overrides/config/user.toml", "pack value\n")
    zf.writestr("server-overrides/config/shared.toml", "server value\n")
    zf.writestr("server-overrides/config/server-only.toml", "server only\n")
    zf.writestr("client-overrides/config/client-only.toml", "client only\n")

with zipfile.ZipFile(root / "reserved.mrpack", "w") as zf:
    zf.writestr("modrinth.index.json", json.dumps(index | {"versionId": "reserved"}))
    zf.writestr("overrides/world/level.dat", b"must not be written")

with zipfile.ZipFile(root / "symlink.mrpack", "w") as zf:
    zf.writestr("modrinth.index.json", json.dumps(index | {"versionId": "symlink"}))
    zf.writestr("overrides/config/escape.toml", "must stay inside data\n")
PY

configure_pack() {
  local data_dir="$1"
  local pack="$2"

  DATA_DIR="$data_dir"
  MODPACK_URL="file://${pack}"
  MODPACK_FORMAT=mrpack
  MODPACK_INSTALL_MODE=server
  MODPACK_FORCE_REINSTALL=false
  MODPACK_REMOVE_EXTRA=false
  MODPACK_INCLUDE_OPTIONAL=false
  MODPACK_ALLOW_FILE_URL=true
}

data="$tmp/data"
mkdir -p "$data/config"
printf 'operator value\n' > "$data/config/user.toml"
configure_pack "$data" "$pack_dir/valid.mrpack"
install_modpack_with_overrides

grep -Fx 'server value' "$data/config/shared.toml" >/dev/null || fail 'server-overrides did not win over overrides'
grep -Fx 'base only' "$data/config/base-only.toml" >/dev/null || fail 'base-only override was not seeded'
grep -Fx 'server only' "$data/config/server-only.toml" >/dev/null || fail 'server-only override was not seeded'
grep -Fx 'operator value' "$data/config/user.toml" >/dev/null || fail 'operator-owned override target was modified'
[[ ! -e "$data/config/client-only.toml" ]] || fail 'client-overrides content was installed on the server'

shared_sha512="$(sha512sum "$data/config/shared.toml")"
shared_sha512="${shared_sha512%% *}"
if ! jq -e --arg sha "$shared_sha512" '
  (.overrides | length) == 4
  and any(.overrides[]; .path == "config/shared.toml" and .layer == "server-overrides" and .action == "seeded" and .sha512 == $sha)
  and any(.overrides[]; .path == "config/base-only.toml" and .layer == "overrides" and .action == "seeded")
  and any(.overrides[]; .path == "config/server-only.toml" and .layer == "server-overrides" and .action == "seeded")
  and any(.overrides[]; .path == "config/user.toml" and .action == "skipped")
  and all(.overrides[]; .path != "config/client-only.toml")
' "$data/.modpack-install.json" >/dev/null; then
  cat "$data/.modpack-install.json" >&2
  fail 'first-install override marker did not match expected ownership state'
fi

# A user edit after a seeded install must not be overwritten on the next install.
printf 'operator changed managed file\n' > "$data/config/shared.toml"
install_modpack_with_overrides
grep -Fx 'operator changed managed file' "$data/config/shared.toml" >/dev/null \
  || fail 'operator edit to a previously seeded override was overwritten'
if ! jq -e '
  any(.overrides[]; .path == "config/shared.toml" and .layer == "server-overrides" and .action == "skipped")
' "$data/.modpack-install.json" >/dev/null; then
  cat "$data/.modpack-install.json" >&2
  fail 'operator-edited override was not downgraded to skipped ownership'
fi

# Reserved world paths are rejected before any archive content is written.
reserved_data="$tmp/reserved-data"
mkdir -p "$reserved_data"
set +e
reserved_output="$(
  (
    configure_pack "$reserved_data" "$pack_dir/reserved.mrpack"
    install_modpack_with_overrides
  ) 2>&1
)"
reserved_status=$?
set -e
if [[ "$reserved_status" -eq 0 ]]; then
  printf '%s\n' "$reserved_output" >&2
  fail 'reserved world override unexpectedly succeeded'
fi
[[ ! -e "$reserved_data/world/level.dat" ]] || fail 'reserved world override wrote data before rejection'
if ! grep -F 'Unsafe override path: reserved path: world/level.dat' <<< "$reserved_output" >/dev/null; then
  printf '%s\n' "$reserved_output" >&2
  fail 'reserved world override failed without the expected safety diagnostic'
fi

# Existing symlinked parents may not redirect an override outside DATA_DIR.
symlink_data="$tmp/symlink-data"
outside="$tmp/outside"
mkdir -p "$symlink_data" "$outside"
ln -s "$outside" "$symlink_data/config"
set +e
symlink_output="$(
  (
    configure_pack "$symlink_data" "$pack_dir/symlink.mrpack"
    install_modpack_with_overrides
  ) 2>&1
)"
symlink_status=$?
set -e
if [[ "$symlink_status" -eq 0 ]]; then
  printf '%s\n' "$symlink_output" >&2
  fail 'symlink escape override unexpectedly succeeded'
fi
[[ ! -e "$outside/escape.toml" ]] || fail 'symlink escape wrote outside DATA_DIR before rejection'
if ! grep -F 'Refusing modpack override target outside DATA_DIR: config/escape.toml' <<< "$symlink_output" >/dev/null; then
  printf '%s\n' "$symlink_output" >&2
  fail 'symlink escape failed without the expected safety diagnostic'
fi

printf 'modpack override smoke passed\n'

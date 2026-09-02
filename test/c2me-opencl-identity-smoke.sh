#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export DATA_DIR="$tmp/data"
mkdir -p "$DATA_DIR/mods"

make_fabric_mod_jar() {
  local path="$1"
  local id="$2"
  local version="$3"
  local metadata="$tmp/fabric.mod.json"

  cat > "$metadata" <<JSON
{"schemaVersion":1,"id":"${id}","version":"${version}"}
JSON
  python3 - "$path" "$metadata" <<'PY'
import sys
import zipfile

jar, metadata = sys.argv[1:]
with zipfile.ZipFile(jar, "w") as zf:
    zf.write(metadata, "fabric.mod.json")
PY
}

make_fabric_mod_jar "$DATA_DIR/mods/base-random-name.jar" "c2me" "base-test"
make_fabric_mod_jar "$DATA_DIR/mods/ocl-random-name.jar" "c2me-opts-accel-opencl" "ocl-test"

# shellcheck source=scripts/lib/fabric_mod_metadata.sh
source ./scripts/lib/fabric_mod_metadata.sh
# shellcheck source=scripts/lib/c2me_opencl.sh
source ./scripts/lib/c2me_opencl.sh

has_c2me_base_mod || fail "base C2ME mod was not detected by metadata id"
has_c2me_opencl_mod || fail "C2ME OpenCL addon was not detected by metadata id"

rm -f "$DATA_DIR/mods/base-random-name.jar"
! has_c2me_base_mod || fail "base C2ME detection matched OpenCL addon"
has_c2me_opencl_mod || fail "OpenCL addon disappeared after base removal"

printf 'c2me opencl identity smoke: PASS\n'

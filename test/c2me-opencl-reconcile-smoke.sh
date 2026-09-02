#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

log() {
  : "$@"
}

die() {
  printf '%s\n' "$*" >&2
  return 1
}

safe_rm_f() {
  rm -f -- "$1"
}

safe_mv_f() {
  mv -f -- "$1" "$2"
}

# shellcheck source=scripts/lib/fabric_mod_metadata.sh
source ./scripts/lib/fabric_mod_metadata.sh
# shellcheck source=scripts/lib/modrinth_api.sh
source ./scripts/lib/modrinth_api.sh
# shellcheck source=scripts/lib/c2me_opencl.sh
source ./scripts/lib/c2me_opencl.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_fabric_mod_jar() {
  local jar="$1"
  local mod_id="$2"
  local version="$3"
  local metadata="$tmp/fabric.mod.json"

  cat > "$metadata" <<JSON
{"schemaVersion":1,"id":"${mod_id}","version":"${version}"}
JSON
  python3 - "$jar" "$metadata" <<'PY'
import sys
import zipfile

jar, metadata = sys.argv[1:]
with zipfile.ZipFile(jar, "w") as zf:
    zf.write(metadata, "fabric.mod.json")
PY
}

export ENABLE_C2ME=true
export ENABLE_C2ME_OPENCL=true
unset ENABLE_C2ME_HARDWARE_ACCELERATION || true
export I_KNOW_C2ME_IS_EXPERIMENTAL=true
export TYPE=fabric
export JAVA_MAJOR=25
export VERSION=26.2

payload="$tmp/c2me-opencl-payload.jar"
make_fabric_mod_jar "$payload" c2me-opts-accel-opencl 0.4.2-test
payload_sha512="$(sha512sum "$payload" | awk '{print $1}')"

versions_json="$(jq -nc --arg sha "$payload_sha512" '[{
  id:"version-id",
  version_number:"0.4.2-test",
  status:"listed",
  date_published:"2026-09-01T00:00:00Z",
  files:[{
    filename:"c2me-opencl-test.jar",
    primary:true,
    url:"https://cdn.modrinth.com/data/qtPMklut/versions/version-id/c2me-opencl-test.jar",
    hashes:{sha512:$sha}
  }]
}]')"

api_log="$tmp/api.log"
: > "$api_log"
modrinth_list_project_versions() {
  printf 'call\n' >> "$api_log"
  printf '%s\n' "$versions_json"
}

modrinth_download_verified_file() {
  local _file_json="$1"
  local out="$2"
  : "$_file_json"
  cp "$payload" "$out"
}

export DATA_DIR="$tmp/managed"
mkdir -p "$DATA_DIR/mods"
make_fabric_mod_jar "$DATA_DIR/mods/base.jar" c2me base-test

reconcile_c2me_opencl
has_c2me_opencl_mod || fail "managed addon was not installed"
marker="$(c2me_opencl_marker_path)"
[[ -f "$marker" ]] || fail "managed marker was not written"
[[ "$(jq -r '.versionId' "$marker")" == "version-id" ]] || fail "marker version id mismatch"
[[ "$(jq -r '.requestedVersion' "$marker")" == "latest-compatible" ]] || fail "marker request pin mismatch"
[[ "$(wc -l < "$api_log")" -eq 1 ]] || fail "unexpected Modrinth API call count after first reconcile"

modrinth_list_project_versions() {
  fail "Modrinth API was called despite a valid pinned marker"
}
reconcile_c2me_opencl

export DATA_DIR="$tmp/unmanaged"
mkdir -p "$DATA_DIR/mods"
make_fabric_mod_jar "$DATA_DIR/mods/base.jar" c2me base-test
make_fabric_mod_jar "$DATA_DIR/mods/manual-ocl.jar" c2me-opts-accel-opencl manual-test
reconcile_c2me_opencl
[[ ! -e "$(c2me_opencl_marker_path)" ]] || fail "unmanaged addon unexpectedly became managed"

export DATA_DIR="$tmp/missing-base"
mkdir -p "$DATA_DIR/mods"
if (set -e; reconcile_c2me_opencl >/dev/null 2>&1); then
  fail "reconcile succeeded without base C2ME"
fi

printf 'c2me opencl reconcile smoke: PASS\n'

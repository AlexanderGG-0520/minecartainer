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
mkdir -p "$DATA_DIR/mods" "$tmp/jar"

make_fabric_mod_jar() {
  local path="$1"
  local id="$2"
  local version="$3"

  rm -rf "$tmp/jar"/*
  cat > "$tmp/jar/fabric.mod.json" <<JSON
{"schemaVersion":1,"id":"${id}","version":"${version}"}
JSON
  (cd "$tmp/jar" && zip -q "$path" fabric.mod.json)
}

make_fabric_mod_jar "$DATA_DIR/mods/renamed-base.jar" "c2me" "test-base"
make_fabric_mod_jar "$DATA_DIR/mods/not-c2me.jar" "example" "1.0.0"
printf 'not a jar\n' > "$DATA_DIR/mods/broken.jar"

# shellcheck source=scripts/lib/fabric_mod_metadata.sh
source ./scripts/lib/fabric_mod_metadata.sh

base_jar="$(find_fabric_mod_by_id c2me)"
[[ "$base_jar" == "$DATA_DIR/mods/renamed-base.jar" ]] || fail "find_fabric_mod_by_id did not use metadata identity"
[[ "$(fabric_mod_id "$base_jar")" == "c2me" ]] || fail "fabric_mod_id mismatch"
[[ "$(fabric_mod_version "$base_jar")" == "test-base" ]] || fail "fabric_mod_version mismatch"
has_fabric_mod_id c2me || fail "has_fabric_mod_id did not find c2me"
! has_fabric_mod_id missing || fail "has_fabric_mod_id found nonexistent id"

printf 'fabric mod metadata smoke: PASS\n'

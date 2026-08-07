#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log() {
  : "$1" "$2"
}
die() {
  printf '%s\n' "$*" >&2
  return 1
}
is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}
fail() {
  printf 'modpack path policy smoke failed: %s\n' "$*" >&2
  exit 1
}

source ./scripts/lib/filesystem.sh
source ./scripts/lib/world_paths.sh
source ./scripts/lib/mods.sh
source ./scripts/lib/modpack_overrides.sh
source ./scripts/lib/modpack_policy.sh
source ./scripts/lib/modpack_remove_extra.sh
# The extension modules source the base mods.sh dependency internally. Load the
# path policy last to mirror install_phase.sh and make it authoritative.
source ./scripts/lib/modpack_path_policy.sh

assert_class() {
  local expected="$1"
  local path="$2"
  local actual
  actual="$(modpack_path_classify "$path" test-path)" || fail "classification failed for $path"
  [[ "$actual" == "$expected" ]] || fail "$path classified as $actual, expected $expected"
}

for path in \
  mods/example.jar \
  config/example.toml \
  defaultconfigs/example.toml \
  datapacks/example/pack.mcmeta \
  resourcepacks/example.zip \
  kubejs/server_scripts/recipes.js \
  scripts/recipes.zs \
  global_packs/required_data/example.zip \
  openloader/data/example.zip \
  patchouli_books/example/book.json; do
  assert_class managed-content "$path"
  safe_modpack_path "$path" test-path || fail "allowed path rejected: $path"
done

for path in \
  world/level.dat \
  saves/world/level.dat \
  logs/latest.log \
  backups/world.tar.gz \
  plugins/plugin.jar \
  libraries/runtime.jar \
  versions/1.21/server.jar \
  crash-reports/crash.txt \
  .minecraft/options.txt \
  .fabric/cache.bin \
  .minecartainer/state.json \
  server.properties \
  eula.txt \
  ops.json \
  whitelist.json \
  jvm.args \
  reset-world.flag \
  server.jar \
  fabric-server-launch.jar \
  velocity.jar \
  run.sh \
  user_jvm_args.txt; do
  assert_class reserved "$path"
  if safe_modpack_path "$path" test-path >/dev/null 2>&1; then
    fail "reserved path accepted: $path"
  fi
done

LEVEL_NAME=adventure
assert_class reserved adventure/level.dat
assert_class reserved adventure_nether/DIM-1/region.mca
assert_class reserved adventure_the_end/DIM1/region.mca
unset LEVEL_NAME

for path in shaderpacks/example.zip screenshots/example.png arbitrary/file.txt; do
  assert_class unsupported "$path"
  if safe_modpack_path "$path" test-path >/dev/null 2>&1; then
    fail "unsupported path accepted: $path"
  fi
done

for path in '../evil.jar' '/abs.jar' 'C:\evil.jar' 'config//bad.toml' 'config/./bad.toml'; do
  if safe_modpack_path "$path" test-path >/dev/null 2>&1; then
    fail "malformed path accepted: $path"
  fi
done

# Indexed files under a newly supported root use the normal atomic installer.
DATA_DIR="$tmp/indexed/data"
mkdir -p "$DATA_DIR"
indexed_src="$tmp/indexed.js"
printf '%s\n' 'ServerEvents.recipes(event => {})' > "$indexed_src"
indexed_sha1="$(sha1sum "$indexed_src")"
indexed_sha1="${indexed_sha1%% *}"
indexed_sha512="$(sha512sum "$indexed_src")"
indexed_sha512="${indexed_sha512%% *}"
install_modpack_file kubejs/server_scripts/indexed.js "$indexed_src" "$indexed_sha1" "$indexed_sha512"
cmp -s "$indexed_src" "$DATA_DIR/kubejs/server_scripts/indexed.js" \
  || fail "indexed file was not installed under kubejs"

# A non-jar operator-owned file under a new root remains operator-owned.
printf '%s\n' operator > "$DATA_DIR/kubejs/server_scripts/operator.js"
operator_src="$tmp/operator.js"
printf '%s\n' pack > "$operator_src"
operator_sha1="$(sha1sum "$operator_src")"
operator_sha1="${operator_sha1%% *}"
operator_sha512="$(sha512sum "$operator_src")"
operator_sha512="${operator_sha512%% *}"
set +e
install_modpack_file kubejs/server_scripts/operator.js "$operator_src" "$operator_sha1" "$operator_sha512"
operator_rc=$?
set -e
[[ "$operator_rc" -eq 2 ]] || fail "operator-owned indexed seed did not return skip status"
[[ "$(cat "$DATA_DIR/kubejs/server_scripts/operator.js")" == operator ]] \
  || fail "operator-owned indexed seed was overwritten"

# Override layering works under new roots and preserves an existing operator file.
DATA_DIR="$tmp/overrides/data"
mkdir -p "$DATA_DIR/scripts"
printf '%s\n' operator > "$DATA_DIR/scripts/operator.zs"
cat > "$DATA_DIR/.modpack-install.json" <<'JSON'
{"schemaVersion":1,"files":[],"overrides":[]}
JSON
archive="$tmp/overrides.mrpack"
ARCHIVE_PATH="$archive" python3 - <<'PY'
import os
import zipfile

with zipfile.ZipFile(os.environ["ARCHIVE_PATH"], "w") as zf:
    zf.writestr("overrides/kubejs/server_scripts/layer.js", "base\n")
    zf.writestr("server-overrides/kubejs/server_scripts/layer.js", "server\n")
    zf.writestr("overrides/scripts/operator.zs", "pack\n")
PY
apply_tmp="$tmp/apply"
mkdir -p "$apply_tmp"
apply_modpack_overrides "$archive" "$tmp/no-previous-marker.json" "$DATA_DIR/.modpack-install.json" "$apply_tmp"
[[ "$(cat "$DATA_DIR/kubejs/server_scripts/layer.js")" == server ]] \
  || fail "server-overrides did not win under kubejs"
[[ "$(cat "$DATA_DIR/scripts/operator.zs")" == operator ]] \
  || fail "operator-owned override was overwritten"
jq -e '.overrides[] | select(.path == "kubejs/server_scripts/layer.js" and .action == "seeded")' \
  "$DATA_DIR/.modpack-install.json" >/dev/null || fail "seeded kubejs override not recorded"
jq -e '.overrides[] | select(.path == "scripts/operator.zs" and .action == "skipped")' \
  "$DATA_DIR/.modpack-install.json" >/dev/null || fail "skipped scripts override not recorded"

# Remove-extra applies the same policy: only an unchanged, previously managed
# stale file under a newly supported root is removed. Unmanaged siblings survive.
DATA_DIR="$tmp/remove/data"
mkdir -p "$DATA_DIR/openloader/data"
printf '%s\n' managed > "$DATA_DIR/openloader/data/old.txt"
printf '%s\n' unmanaged > "$DATA_DIR/openloader/data/operator.txt"
old_sha512="$(sha512sum "$DATA_DIR/openloader/data/old.txt")"
old_sha512="${old_sha512%% *}"
previous_marker="$tmp/remove/previous.json"
cat > "$previous_marker" <<JSON
{"schemaVersion":1,"files":[{"path":"openloader/data/old.txt","sha512":"$old_sha512"}],"overrides":[],"retainedManaged":[]}
JSON
current_marker="$DATA_DIR/.modpack-install.json"
cat > "$current_marker" <<'JSON'
{"schemaVersion":1,"files":[],"overrides":[],"retainedManaged":[]}
JSON
current_pack="$tmp/remove/current.mrpack"
CURRENT_PACK="$current_pack" python3 - <<'PY'
import json
import os
import zipfile

index = {
    "formatVersion": 1,
    "game": "minecraft",
    "versionId": "path-policy-current",
    "files": [],
    "dependencies": {"minecraft": "1.21.8"},
}
with zipfile.ZipFile(os.environ["CURRENT_PACK"], "w") as zf:
    zf.writestr("modrinth.index.json", json.dumps(index))
PY
MODPACK_REMOVE_EXTRA=true
remove_tmp="$tmp/remove/work"
mkdir -p "$remove_tmp"
reconcile_modpack_managed_extras "$current_pack" "$previous_marker" "$current_marker" "$remove_tmp"
[[ ! -e "$DATA_DIR/openloader/data/old.txt" ]] || fail "stale managed openloader file was not removed"
[[ "$(cat "$DATA_DIR/openloader/data/operator.txt")" == unmanaged ]] \
  || fail "unmanaged openloader sibling was modified"

printf 'modpack path policy smoke passed\n'

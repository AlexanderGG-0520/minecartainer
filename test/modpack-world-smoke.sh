#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

logs=""
log() {
  logs+="[$1] $2\n"
}
die() {
  printf '%s\n' "$*" >&2
  exit 1
}
is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}
fail() {
  printf 'Modpack world smoke failed: %s\n' "$*" >&2
  exit 1
}

source ./scripts/lib/filesystem.sh
source ./scripts/lib/runtime.sh
source ./scripts/lib/world_paths.sh
source ./scripts/lib/mods.sh
source ./scripts/lib/modpack_overrides.sh
source ./scripts/lib/modpack_policy.sh
source ./scripts/lib/modpack_remove_extra.sh
source ./scripts/lib/modpack_runtime_inference.sh
source ./scripts/lib/modpack_curseforge.sh
source ./scripts/lib/modpack_curseforge_runtime.sh
source ./scripts/lib/modpack_curseforge_remove_extra.sh
source ./scripts/lib/modpack_world.sh
source ./scripts/lib/modpack_path_policy.sh
source ./scripts/lib/world_install.sh

make_zip() {
  local archive="$1"
  shift
  python3 - "$archive" "$@" <<'PY'
import sys
import zipfile

archive = sys.argv[1]
with zipfile.ZipFile(archive, "w") as zf:
    for item in sys.argv[2:]:
        path, content = item.split("=", 1)
        zf.writestr(path, content)
PY
}

make_mrpack() {
  local archive="$1"
  shift
  MRPACK_ARCHIVE="$archive" python3 - "$@" <<'PY'
import json
import os
import sys
import zipfile

index = {
    "formatVersion": 1,
    "game": "minecraft",
    "versionId": "world-fixture",
    "name": "World Fixture",
    "files": [],
    "dependencies": {"minecraft": "1.21.1"},
}
with zipfile.ZipFile(os.environ["MRPACK_ARCHIVE"], "w") as zf:
    zf.writestr("modrinth.index.json", json.dumps(index))
    for item in sys.argv[1:]:
        path, content = item.split("=", 1)
        zf.writestr(path, content)
PY
}

write_marker() {
  local format="$1"
  jq -n --arg format "$format" '{schemaVersion:1,format:$format,files:[],overrides:[]}' \
    > "$DATA_DIR/.modpack-install.json"
}

reset_case() {
  local name="$1"
  DATA_DIR="$tmp/$name/data"
  rm -rf "$DATA_DIR"
  mkdir -p "$DATA_DIR/world"
  LEVEL_NAME=world
  TYPE=fabric
  VERSION=1.21.1
  MODPACK_FORMAT=mrpack
  MODPACK_INSTALL_MODE=server
  MODPACK_INSTALL_WORLD=true
  MODPACK_INCLUDE_OPTIONAL=false
  MODPACK_REMOVE_EXTRA=false
  MODPACK_INFER_RUNTIME=false
  MODPACK_FORCE_REINSTALL=false
  WORLDS_ENABLED=false
  ENABLE_RCON=false
  EULA=true
  unset WORLDS_S3_BUCKET WORLDS_S3_PREFIX MODPACK_URL
  logs=""
}

# World paths remain outside the normal managed-content policy even when the
# explicit seed feature is enabled.
reset_case policy-separation
write_marker mrpack
if (safe_modpack_path world/level.dat override) >/dev/null 2>&1; then
  fail "world path entered normal managed-content policy"
fi

# Without the explicit opt-in, a world subtree in overrides keeps the previous
# fail-fast behavior.
archive="$tmp/disabled.mrpack"
make_mrpack "$archive" 'overrides/world/level.dat=base-world'
unzip -Z1 "$archive" > "$tmp/disabled-listing.txt"
MODPACK_INSTALL_WORLD=false
if (collect_modpack_override_entries "$tmp/disabled-listing.txt" overrides "$tmp/disabled.tsv") >/dev/null 2>&1; then
  fail "world override was accepted while MODPACK_INSTALL_WORLD=false"
fi

# Modrinth: world subtree is removed from ordinary override ownership, then
# seeded once. server-overrides wins over overrides while base-only files merge.
reset_case mrpack-seed
write_marker mrpack
archive="$tmp/world.mrpack"
make_mrpack "$archive" \
  'overrides/world/level.dat=base-level' \
  'overrides/world/region/r.0.0.mca=base-region' \
  'overrides/config/normal.toml=normal-config' \
  'server-overrides/world/level.dat=server-level'
unzip -Z1 "$archive" > "$tmp/world-listing.txt"
collect_modpack_override_entries "$tmp/world-listing.txt" overrides "$tmp/world-overrides.tsv"
grep -F $'config/normal.toml\toverrides/config/normal.toml' "$tmp/world-overrides.tsv" >/dev/null \
  || fail "normal override disappeared when world seeding was enabled"
! grep -F 'world/' "$tmp/world-overrides.tsv" >/dev/null \
  || fail "world subtree leaked into ordinary override ownership"

install_modpack_world_from_archive "$archive" mrpack "$DATA_DIR/.modpack-install.json" "$tmp"
[[ "$(cat "$DATA_DIR/world/level.dat")" == server-level ]] \
  || fail "server-overrides did not win for seeded Modrinth world"
[[ "$(cat "$DATA_DIR/world/region/r.0.0.mca")" == base-region ]] \
  || fail "base world file was not merged into seeded Modrinth world"
jq -e '.world.path == "world" and .world.action == "seeded" and .world.ownership == "seed-only" and .world.sourceLayer == "overrides+server-overrides"' \
  "$DATA_DIR/.modpack-install.json" >/dev/null || fail "Modrinth world marker metadata missing"

# remove-extra current-path collection must ignore the special world subtree
# rather than rejecting it or treating it as deletable managed content.
collect_current_modpack_paths "$archive" "$tmp/current-paths.txt" "$tmp"
! grep -F 'world/' "$tmp/current-paths.txt" >/dev/null \
  || fail "world subtree entered remove-extra managed paths"

# Existing valid worlds are immutable from the modpack seed path, even when the
# pack later contains a different seed.
printf 'operator-world\n' > "$DATA_DIR/world/level.dat"
write_marker mrpack
install_modpack_world_from_archive "$archive" mrpack "$DATA_DIR/.modpack-install.json" "$tmp"
[[ "$(cat "$DATA_DIR/world/level.dat")" == operator-world ]] \
  || fail "existing world was overwritten by modpack seed"
jq -e '.world.action == "preserved-existing" and .world.ownership == "seed-only"' \
  "$DATA_DIR/.modpack-install.json" >/dev/null || fail "existing-world preservation was not recorded"

# Non-empty ambiguous world state without level.dat is never replaced.
reset_case partial-world
write_marker mrpack
printf 'partial\n' > "$DATA_DIR/world/unknown.dat"
if (install_modpack_world_from_archive "$archive" mrpack "$DATA_DIR/.modpack-install.json" "$tmp") >"$tmp/partial.out" 2>&1; then
  fail "non-empty partial world directory was replaced"
fi
grep -F 'Refusing modpack world seed into non-empty world directory without level.dat' "$tmp/partial.out" >/dev/null \
  || { cat "$tmp/partial.out" >&2; fail "partial-world rejection diagnostic missing"; }
[[ "$(cat "$DATA_DIR/world/unknown.dat")" == partial ]] || fail "partial world state was modified"

# Explicit opt-in with no seed is a configuration error for a fresh world.
reset_case missing-seed
write_marker mrpack
no_world="$tmp/no-world.mrpack"
make_mrpack "$no_world" 'overrides/config/only.toml=config'
if (install_modpack_world_from_archive "$no_world" mrpack "$DATA_DIR/.modpack-install.json" "$tmp") >"$tmp/missing.out" 2>&1; then
  fail "missing requested modpack world seed unexpectedly succeeded"
fi
grep -F 'MODPACK_INSTALL_WORLD=true but the modpack contains no world/ world seed' "$tmp/missing.out" >/dev/null \
  || { cat "$tmp/missing.out" >&2; fail "missing-world diagnostic missing"; }
[[ -d "$DATA_DIR/world" ]] || fail "empty world target was removed after missing seed rejection"

# Traversal inside the selected world subtree is rejected before extraction.
reset_case traversal
write_marker mrpack
traversal="$tmp/traversal.mrpack"
make_mrpack "$traversal" \
  'overrides/world/level.dat=level' \
  'overrides/world/../escape.dat=escape'
if (install_modpack_world_from_archive "$traversal" mrpack "$DATA_DIR/.modpack-install.json" "$tmp") >"$tmp/traversal.out" 2>&1; then
  fail "world traversal entry unexpectedly succeeded"
fi
grep -F 'parent traversal' "$tmp/traversal.out" >/dev/null \
  || { cat "$tmp/traversal.out" >&2; fail "world traversal diagnostic missing"; }
[[ ! -e "$DATA_DIR/escape.dat" && ! -e "$tmp/escape.dat" ]] || fail "world traversal escaped staging"

# CurseForge uses the standard overrides layer and gets the same seed-only
# semantics without needing API resolution in this isolated archive test.
reset_case curseforge-seed
MODPACK_FORMAT=curseforge
write_marker curseforge
curseforge_zip="$tmp/curseforge.zip"
make_zip "$curseforge_zip" \
  'overrides/world/level.dat=curseforge-level' \
  'overrides/world/DIM-1/data.bin=nether-data'
install_modpack_world_from_archive "$curseforge_zip" curseforge "$DATA_DIR/.modpack-install.json" "$tmp"
[[ "$(cat "$DATA_DIR/world/level.dat")" == curseforge-level ]] \
  || fail "CurseForge world was not seeded"
[[ "$(cat "$DATA_DIR/world/DIM-1/data.bin")" == nether-data ]] \
  || fail "CurseForge world nested file was not seeded"
jq -e '.world.action == "seeded" and .world.sourceLayer == "overrides" and .world.ownership == "seed-only"' \
  "$DATA_DIR/.modpack-install.json" >/dev/null || fail "CurseForge world marker metadata missing"

# Custom level names use only their matching override subtree.
reset_case custom-level
LEVEL_NAME=custom-world
rm -rf "$DATA_DIR/world"
mkdir -p "$DATA_DIR/custom-world"
write_marker mrpack
custom_zip="$tmp/custom.mrpack"
make_mrpack "$custom_zip" \
  'overrides/world/level.dat=wrong-world' \
  'overrides/custom-world/level.dat=custom-level'
install_modpack_world_from_archive "$custom_zip" mrpack "$DATA_DIR/.modpack-install.json" "$tmp"
[[ "$(cat "$DATA_DIR/custom-world/level.dat")" == custom-level ]] \
  || fail "custom level-name world seed was not selected"
[[ ! -e "$DATA_DIR/world/level.dat" ]] || fail "default world subtree was used for custom level-name"

# Preflight rejects missing modpack source and ambiguous dual world sources.
validate_shutdown_numeric_config() { return 0; }
source ./scripts/lib/preflight.sh

reset_case preflight-missing-url
MODPACK_INSTALL_WORLD=true
if (preflight) >"$tmp/preflight-missing.out" 2>&1; then
  fail "preflight accepted MODPACK_INSTALL_WORLD without MODPACK_URL"
fi
grep -F 'MODPACK_INSTALL_WORLD=true requires MODPACK_URL' "$tmp/preflight-missing.out" >/dev/null \
  || { cat "$tmp/preflight-missing.out" >&2; fail "missing MODPACK_URL preflight diagnostic missing"; }

reset_case preflight-conflict
MODPACK_URL='https://example.invalid/pack.mrpack'
WORLDS_ENABLED=true
WORLDS_S3_BUCKET=bucket
WORLDS_S3_PREFIX=worlds
if (preflight) >"$tmp/preflight-conflict.out" 2>&1; then
  fail "preflight accepted simultaneous S3 and modpack world sources"
fi
grep -F 'World source conflict' "$tmp/preflight-conflict.out" >/dev/null \
  || { cat "$tmp/preflight-conflict.out" >&2; fail "dual world-source preflight diagnostic missing"; }

printf 'Modpack world smoke passed\n'

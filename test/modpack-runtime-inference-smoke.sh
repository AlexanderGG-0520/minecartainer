#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT_DIR}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; rm -f /tmp/minecartainer-mrpack-infer.*.mrpack 2>/dev/null || true' EXIT

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

source ./scripts/lib/filesystem.sh
source ./scripts/lib/runtime.sh
source ./scripts/lib/mods.sh
source ./scripts/lib/modpack_overrides.sh
source ./scripts/lib/modpack_policy.sh
source ./scripts/lib/modpack_remove_extra.sh
source ./scripts/lib/modpack_runtime_inference.sh

fail() {
  printf 'modpack runtime inference smoke failed: %s\n' "$*" >&2
  exit 1
}

make_pack() {
  local archive="$1"
  local dependencies="$2"
  ARCHIVE_PATH="$archive" DEPENDENCIES_JSON="$dependencies" python3 - <<'PY'
import json
import os
import zipfile

archive = os.environ["ARCHIVE_PATH"]
dependencies = json.loads(os.environ["DEPENDENCIES_JSON"])
index = {
    "formatVersion": 1,
    "game": "minecraft",
    "versionId": "runtime-inference-test",
    "files": [],
    "dependencies": dependencies,
}
with zipfile.ZipFile(archive, "w") as zf:
    zf.writestr("modrinth.index.json", json.dumps(index))
PY
}

reset_case() {
  local name="$1"
  DATA_DIR="$tmp/$name/data"
  rm -rf "$DATA_DIR"
  mkdir -p "$DATA_DIR"
  TYPE=auto
  VERSION=auto
  MODPACK_FORMAT=mrpack
  MODPACK_INSTALL_MODE=server
  MODPACK_INFER_RUNTIME=true
  MODPACK_ALLOW_FILE_URL=true
  unset FABRIC_LOADER_VERSION FORGE_VERSION NEOFORGE_VERSION
  MODPACK_PREFETCH_ARCHIVE=""
  MODPACK_PREFETCH_SOURCE=""
  MODPACK_PREFETCH_READY=false
  logs=""
}

fabric_pack="$tmp/fabric.mrpack"
make_pack "$fabric_pack" '{"minecraft":"1.21.8","fabric-loader":"0.16.14"}'

reset_case fresh-fabric
MODPACK_URL="file://$fabric_pack"
resolve_type_auto
[[ "$TYPE" == fabric ]] || fail "fresh fabric TYPE was not inferred"
[[ "$VERSION" == 1.21.8 ]] || fail "fresh fabric VERSION was not inferred"
[[ "${FABRIC_LOADER_VERSION:-}" == 0.16.14 ]] || fail "fabric loader version was not pinned"
[[ "${MODPACK_PREFETCH_READY:-false}" == true ]] || fail "mrpack archive was not prefetched"
[[ -f "${MODPACK_PREFETCH_ARCHIVE:-}" ]] || fail "prefetched mrpack archive is missing"
printf '%b' "$logs" | grep -F "TYPE auto-resolved to 'fabric' from Modrinth loader dependency" >/dev/null \
  || fail "fabric inference log missing"

prefetched_target="$tmp/reused.mrpack"
rm -f "$fabric_pack"
acquire_modpack_archive "$MODPACK_URL" "$prefetched_target"
[[ -s "$prefetched_target" ]] || fail "prefetched mrpack was not reused after source disappeared"
[[ "${MODPACK_PREFETCH_READY:-true}" == false ]] || fail "prefetch state was not consumed"

make_pack "$fabric_pack" '{"minecraft":"1.21.8","fabric-loader":"0.16.14"}'
reset_case explicit-mismatch
TYPE=forge
VERSION=1.21.8
MODPACK_URL="file://$fabric_pack"
if (resolve_type_auto) >"$tmp/type-mismatch.out" 2>&1; then
  fail "explicit TYPE mismatch unexpectedly succeeded"
fi
grep -F "Configured/resolved TYPE=forge conflicts with Modrinth loader dependency fabric-loader=0.16.14" "$tmp/type-mismatch.out" >/dev/null \
  || { cat "$tmp/type-mismatch.out" >&2; fail "explicit TYPE mismatch diagnostic missing"; }

reset_case version-mismatch
TYPE=auto
VERSION=1.21.7
MODPACK_URL="file://$fabric_pack"
if (resolve_type_auto) >"$tmp/version-mismatch.out" 2>&1; then
  fail "explicit VERSION mismatch unexpectedly succeeded"
fi
grep -F "Configured/resolved VERSION=1.21.7 conflicts with Modrinth minecraft dependency 1.21.8" "$tmp/version-mismatch.out" >/dev/null \
  || { cat "$tmp/version-mismatch.out" >&2; fail "explicit VERSION mismatch diagnostic missing"; }

reset_case loader-pin-mismatch
TYPE=auto
VERSION=auto
FABRIC_LOADER_VERSION=0.16.13
MODPACK_URL="file://$fabric_pack"
if (resolve_type_auto) >"$tmp/loader-pin-mismatch.out" 2>&1; then
  fail "explicit loader pin mismatch unexpectedly succeeded"
fi
grep -F "Explicit FABRIC_LOADER_VERSION=0.16.13 conflicts with Modrinth dependency fabric-loader=0.16.14" "$tmp/loader-pin-mismatch.out" >/dev/null \
  || { cat "$tmp/loader-pin-mismatch.out" >&2; fail "loader pin mismatch diagnostic missing"; }

multiple_pack="$tmp/multiple.mrpack"
make_pack "$multiple_pack" '{"minecraft":"1.21.8","fabric-loader":"0.16.14","forge":"47.3.0"}'
reset_case multiple-loaders
MODPACK_URL="file://$multiple_pack"
if (resolve_type_auto) >"$tmp/multiple-loaders.out" 2>&1; then
  fail "multiple loader dependencies unexpectedly succeeded"
fi
grep -F "Modpack declares multiple loader dependencies; cannot infer a single server TYPE" "$tmp/multiple-loaders.out" >/dev/null \
  || { cat "$tmp/multiple-loaders.out" >&2; fail "multiple loader diagnostic missing"; }

reset_case existing-marker
MODPACK_URL="file://$fabric_pack"
touch "$DATA_DIR/fabric-server-launch.jar"
cat > "$DATA_DIR/.server-install.json" <<'JSON'
{"artifact":"fabric-server-launch.jar","type":"fabric","version":"1.21.8","build":"0.16.14"}
JSON
resolve_type_auto
[[ "$TYPE" == fabric ]] || fail "existing marker TYPE was not preserved"
[[ "$VERSION" == 1.21.8 ]] || fail "existing marker VERSION was not used"
[[ "${FABRIC_LOADER_VERSION:-}" == 0.16.14 ]] || fail "pack loader pin was not aligned with existing marker"
printf '%b' "$logs" | grep -F "VERSION auto-resolved to '1.21.8' from existing server install marker" >/dev/null \
  || fail "existing marker VERSION inference log missing"

marker_mismatch_pack="$tmp/marker-mismatch.mrpack"
make_pack "$marker_mismatch_pack" '{"minecraft":"1.21.9","fabric-loader":"0.16.14"}'
reset_case marker-version-mismatch
MODPACK_URL="file://$marker_mismatch_pack"
touch "$DATA_DIR/fabric-server-launch.jar"
cat > "$DATA_DIR/.server-install.json" <<'JSON'
{"artifact":"fabric-server-launch.jar","type":"fabric","version":"1.21.8","build":"0.16.14"}
JSON
if (resolve_type_auto) >"$tmp/marker-version-mismatch.out" 2>&1; then
  fail "marker/pack version mismatch unexpectedly succeeded"
fi
grep -F "Configured/resolved VERSION=1.21.8 conflicts with Modrinth minecraft dependency 1.21.9" "$tmp/marker-version-mismatch.out" >/dev/null \
  || { cat "$tmp/marker-version-mismatch.out" >&2; fail "marker/pack version mismatch diagnostic missing"; }

reset_case unmarked-artifact
MODPACK_URL="file://$fabric_pack"
touch "$DATA_DIR/server.jar"
if (resolve_type_auto) >"$tmp/unmarked.out" 2>&1; then
  fail "VERSION inference with an unmarked existing artifact unexpectedly succeeded"
fi
grep -F "Cannot safely infer VERSION from mrpack while an existing server artifact has no active install marker" "$tmp/unmarked.out" >/dev/null \
  || { cat "$tmp/unmarked.out" >&2; fail "unmarked artifact diagnostic missing"; }

vanilla_pack="$tmp/vanilla.mrpack"
make_pack "$vanilla_pack" '{"minecraft":"1.21.8"}'
reset_case vanilla-fallback
MODPACK_URL="file://$vanilla_pack"
resolve_type_auto
[[ "$TYPE" == vanilla ]] || fail "loader-less mrpack did not fall back through normal TYPE=auto resolution"
[[ "$VERSION" == 1.21.8 ]] || fail "loader-less mrpack VERSION was not inferred"
printf '%b' "$logs" | grep -F "No recognized Modrinth loader dependency found" >/dev/null \
  || fail "loader-less fallback log missing"

reset_case disabled
MODPACK_INFER_RUNTIME=false
MODPACK_URL="file://$tmp/does-not-exist.mrpack"
VERSION=1.21.8
resolve_type_auto
[[ "$TYPE" == vanilla ]] || fail "disabled inference changed normal TYPE=auto fallback"
[[ "$VERSION" == 1.21.8 ]] || fail "disabled inference changed VERSION"
[[ "${MODPACK_PREFETCH_READY:-false}" == false ]] || fail "disabled inference unexpectedly prefetched a pack"

printf 'modpack runtime inference smoke passed\n'

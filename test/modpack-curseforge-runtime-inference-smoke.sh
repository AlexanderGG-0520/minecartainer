#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT_DIR}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; rm -f /tmp/minecartainer-curseforge-infer.*.zip 2>/dev/null || true' EXIT

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
source ./scripts/lib/world_paths.sh
source ./scripts/lib/mods.sh
source ./scripts/lib/modpack_overrides.sh
source ./scripts/lib/modpack_policy.sh
source ./scripts/lib/modpack_remove_extra.sh
source ./scripts/lib/modpack_runtime_inference.sh
source ./scripts/lib/modpack_curseforge.sh
source ./scripts/lib/modpack_curseforge_runtime.sh
source ./scripts/lib/modpack_path_policy.sh

fail() {
  printf 'CurseForge runtime inference smoke failed: %s\n' "$*" >&2
  exit 1
}

assert_no_curseforge_prefetch() {
  ! find /tmp -maxdepth 1 -type f -name 'minecartainer-curseforge-infer.*.zip' -print -quit | grep -q .
}

make_pack() {
  local archive="$1"
  local minecraft="$2"
  local loader="$3"
  ARCHIVE_PATH="$archive" MC_VERSION="$minecraft" LOADER_ID="$loader" python3 - <<'PY'
import json
import os
import zipfile

manifest = {
    "minecraft": {
        "version": os.environ["MC_VERSION"],
        "modLoaders": [{"id": os.environ["LOADER_ID"], "primary": True}],
    },
    "manifestType": "minecraftModpack",
    "manifestVersion": 1,
    "name": "CurseForge Runtime Inference Fixture",
    "version": "1.0.0",
    "author": "Minecartainer CI",
    "files": [],
    "overrides": "overrides",
}
with zipfile.ZipFile(os.environ["ARCHIVE_PATH"], "w") as zf:
    zf.writestr("manifest.json", json.dumps(manifest))
    zf.writestr("overrides/config/curseforge-runtime-inference.toml", "inferred = true\n")
PY
}

reset_case() {
  local name="$1"
  cleanup_modpack_prefetch
  DATA_DIR="$tmp/$name/data"
  rm -rf "$DATA_DIR"
  mkdir -p "$DATA_DIR"
  TYPE=auto
  VERSION=auto
  MODPACK_FORMAT=curseforge
  MODPACK_INSTALL_MODE=server
  MODPACK_INFER_RUNTIME=true
  MODPACK_ALLOW_FILE_URL=true
  MODPACK_REMOVE_EXTRA=false
  MODPACK_INCLUDE_OPTIONAL=false
  MODPACK_FORCE_REINSTALL=false
  CURSEFORGE_API_KEY=test-key
  unset FABRIC_LOADER_VERSION FORGE_VERSION NEOFORGE_VERSION
  logs=""
}

fabric_pack="$tmp/fabric.zip"
make_pack "$fabric_pack" 1.21.1 fabric-0.16.14

reset_case fresh-fabric
MODPACK_URL="file://$fabric_pack"
resolve_type_auto
[[ "$TYPE" == fabric ]] || fail "fresh CurseForge Fabric TYPE was not inferred"
[[ "$VERSION" == 1.21.1 ]] || fail "fresh CurseForge VERSION was not inferred"
[[ "${FABRIC_LOADER_VERSION:-}" == 0.16.14 ]] || fail "CurseForge Fabric loader version was not pinned"
[[ "${MODPACK_PREFETCH_READY:-false}" == true ]] || fail "CurseForge archive was not prefetched"
[[ "${MODPACK_PREFETCH_FORMAT:-}" == curseforge ]] || fail "CurseForge prefetch format was not recorded"
[[ -f "${MODPACK_PREFETCH_ARCHIVE:-}" ]] || fail "prefetched CurseForge archive is missing"
printf '%b' "$logs" | grep -F "TYPE auto-resolved to 'fabric' from CurseForge primary loader fabric-0.16.14" >/dev/null \
  || fail "CurseForge TYPE inference log missing"
printf '%b' "$logs" | grep -F "VERSION auto-resolved to '1.21.1' from CurseForge manifest" >/dev/null \
  || fail "CurseForge VERSION inference log missing"

# Installation must consume the exact prefetched ZIP even when the original
# source disappears after inference.
rm -f "$fabric_pack"
install_curseforge_modpack_with_overrides
[[ "${MODPACK_PREFETCH_READY:-true}" == false ]] || fail "CurseForge prefetch state was not consumed"
[[ -z "${MODPACK_PREFETCH_FORMAT:-}" ]] || fail "CurseForge prefetch format was not cleared"
assert_no_curseforge_prefetch || fail "CurseForge prefetch temp remained after archive reuse"
[[ "$(cat "$DATA_DIR/config/curseforge-runtime-inference.toml")" == 'inferred = true' ]] \
  || fail "prefetched CurseForge ZIP was not used for override installation"
jq -e '.format == "curseforge" and .dependencies.minecraft == "1.21.1" and .dependencies.loader == "fabric-0.16.14"' \
  "$DATA_DIR/.modpack-install.json" >/dev/null || fail "CurseForge marker was not written from prefetched archive"

make_pack "$fabric_pack" 1.21.1 fabric-0.16.14
reset_case explicit-type-mismatch
TYPE=forge
VERSION=1.21.1
MODPACK_URL="file://$fabric_pack"
if (resolve_type_auto) >"$tmp/type-mismatch.out" 2>&1; then
  fail "explicit CurseForge TYPE mismatch unexpectedly succeeded"
fi
grep -F "Configured/resolved TYPE=forge conflicts with CurseForge primary loader fabric-0.16.14" "$tmp/type-mismatch.out" >/dev/null \
  || { cat "$tmp/type-mismatch.out" >&2; fail "CurseForge TYPE mismatch diagnostic missing"; }
assert_no_curseforge_prefetch || fail "CurseForge prefetch remained after TYPE mismatch"

reset_case explicit-version-mismatch
TYPE=auto
VERSION=1.21.2
MODPACK_URL="file://$fabric_pack"
if (resolve_type_auto) >"$tmp/version-mismatch.out" 2>&1; then
  fail "explicit CurseForge VERSION mismatch unexpectedly succeeded"
fi
grep -F "Configured/resolved VERSION=1.21.2 conflicts with CurseForge Minecraft version 1.21.1" "$tmp/version-mismatch.out" >/dev/null \
  || { cat "$tmp/version-mismatch.out" >&2; fail "CurseForge VERSION mismatch diagnostic missing"; }
assert_no_curseforge_prefetch || fail "CurseForge prefetch remained after VERSION mismatch"

reset_case explicit-loader-mismatch
FABRIC_LOADER_VERSION=0.16.13
MODPACK_URL="file://$fabric_pack"
if (resolve_type_auto) >"$tmp/loader-mismatch.out" 2>&1; then
  fail "explicit CurseForge loader mismatch unexpectedly succeeded"
fi
grep -F "Explicit FABRIC_LOADER_VERSION=0.16.13 conflicts with CurseForge primary loader fabric-0.16.14" "$tmp/loader-mismatch.out" >/dev/null \
  || { cat "$tmp/loader-mismatch.out" >&2; fail "CurseForge loader mismatch diagnostic missing"; }
assert_no_curseforge_prefetch || fail "CurseForge prefetch remained after loader mismatch"

reset_case existing-marker
MODPACK_URL="file://$fabric_pack"
touch "$DATA_DIR/fabric-server-launch.jar"
cat > "$DATA_DIR/.server-install.json" <<'JSON'
{"artifact":"fabric-server-launch.jar","type":"fabric","version":"1.21.1","build":"0.16.14"}
JSON
resolve_type_auto
[[ "$TYPE" == fabric ]] || fail "existing marker TYPE was not preserved for CurseForge"
[[ "$VERSION" == 1.21.1 ]] || fail "existing marker VERSION was not used for CurseForge"
[[ "${FABRIC_LOADER_VERSION:-}" == 0.16.14 ]] || fail "CurseForge loader pin was not aligned with existing marker"
printf '%b' "$logs" | grep -F "VERSION auto-resolved to '1.21.1' from existing server install marker" >/dev/null \
  || fail "existing marker VERSION inference log missing for CurseForge"
cleanup_modpack_prefetch

marker_mismatch_pack="$tmp/marker-mismatch.zip"
make_pack "$marker_mismatch_pack" 1.21.2 fabric-0.16.14
reset_case marker-version-mismatch
MODPACK_URL="file://$marker_mismatch_pack"
touch "$DATA_DIR/fabric-server-launch.jar"
cat > "$DATA_DIR/.server-install.json" <<'JSON'
{"artifact":"fabric-server-launch.jar","type":"fabric","version":"1.21.1","build":"0.16.14"}
JSON
if (resolve_type_auto) >"$tmp/marker-version-mismatch.out" 2>&1; then
  fail "CurseForge marker/pack version mismatch unexpectedly succeeded"
fi
grep -F "Configured/resolved VERSION=1.21.1 conflicts with CurseForge Minecraft version 1.21.2" "$tmp/marker-version-mismatch.out" >/dev/null \
  || { cat "$tmp/marker-version-mismatch.out" >&2; fail "CurseForge marker/version mismatch diagnostic missing"; }
assert_no_curseforge_prefetch || fail "CurseForge prefetch remained after marker/version mismatch"

reset_case unmarked-artifact
MODPACK_URL="file://$fabric_pack"
touch "$DATA_DIR/server.jar"
if (resolve_type_auto) >"$tmp/unmarked.out" 2>&1; then
  fail "CurseForge VERSION inference with unmarked artifact unexpectedly succeeded"
fi
grep -F "Cannot safely infer VERSION from CurseForge pack while an existing server artifact has no active install marker" "$tmp/unmarked.out" >/dev/null \
  || { cat "$tmp/unmarked.out" >&2; fail "CurseForge unmarked artifact diagnostic missing"; }
assert_no_curseforge_prefetch || fail "CurseForge prefetch remained after unmarked artifact rejection"

reset_case auto-zip-refusal
MODPACK_FORMAT=auto
MODPACK_URL="file://$fabric_pack"
if (resolve_type_auto) >"$tmp/auto-zip.out" 2>&1; then
  fail "runtime inference guessed CurseForge from a generic ZIP"
fi
grep -F "does not guess .zip formats" "$tmp/auto-zip.out" >/dev/null \
  || { cat "$tmp/auto-zip.out" >&2; fail "generic ZIP inference refusal diagnostic missing"; }
assert_no_curseforge_prefetch || fail "generic ZIP refusal unexpectedly created a prefetch"

# Changing MODPACK_URL after inference must not allow a different archive to be
# installed than the one whose runtime metadata was trusted.
reset_case source-change
MODPACK_URL="file://$fabric_pack"
resolve_type_auto
other_pack="$tmp/other.zip"
make_pack "$other_pack" 1.21.1 fabric-0.16.14
MODPACK_URL="file://$other_pack"
if (acquire_curseforge_modpack_archive "$MODPACK_URL" "$tmp/source-change-target.zip") >"$tmp/source-change.out" 2>&1; then
  fail "changed CurseForge source was accepted after inference"
fi
grep -F "MODPACK_URL changed after runtime inference" "$tmp/source-change.out" >/dev/null \
  || { cat "$tmp/source-change.out" >&2; fail "CurseForge source-change diagnostic missing"; }
cleanup_modpack_prefetch
assert_no_curseforge_prefetch || fail "CurseForge prefetch remained after source-change cleanup"

# Preflight accepts auto runtime only when CurseForge inference is explicitly
# enabled, while retaining the API-key and remove-extra safety requirements.
validate_shutdown_numeric_config() { return 0; }
source ./scripts/lib/preflight.sh
reset_case preflight-inference
MODPACK_URL="file://$fabric_pack"
EULA=true
ENABLE_RCON=false
preflight

reset_case preflight-disabled
MODPACK_INFER_RUNTIME=false
MODPACK_URL="file://$fabric_pack"
EULA=true
ENABLE_RCON=false
if (preflight) >"$tmp/preflight-disabled.out" 2>&1; then
  fail "CurseForge preflight accepted TYPE/VERSION auto with inference disabled"
fi
grep -F "require an explicit TYPE unless MODPACK_INFER_RUNTIME=true" "$tmp/preflight-disabled.out" >/dev/null \
  || { cat "$tmp/preflight-disabled.out" >&2; fail "CurseForge preflight diagnostic missing"; }

# Runtime-phase EXIT cleanup must recognize the CurseForge prefetch pattern.
exit_guard_archive="$(mktemp /tmp/minecartainer-curseforge-infer.XXXXXX.zip)"
printf '%s\n' prefetched > "$exit_guard_archive"
set +e
(
  source ./scripts/lib/runtime_phase.sh
  MODPACK_INFER_RUNTIME=true
  MODPACK_PREFETCH_ARCHIVE="$exit_guard_archive"
  MODPACK_PREFETCH_SOURCE='file:///fixture.zip'
  MODPACK_PREFETCH_FORMAT=curseforge
  MODPACK_PREFETCH_READY=true
  install() { exit 7; }
  runtime() { return 0; }
  run_runtime_phase
)
exit_guard_status=$?
set -e
[[ "$exit_guard_status" -eq 7 ]] || fail "CurseForge runtime-phase EXIT guard returned unexpected status"
[[ ! -e "$exit_guard_archive" ]] || fail "runtime-phase EXIT guard did not clean CurseForge prefetch"

printf 'CurseForge runtime inference smoke passed\n'

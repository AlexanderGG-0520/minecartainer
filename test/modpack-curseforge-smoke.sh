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
  printf 'CurseForge modpack smoke failed: %s\n' "$*" >&2
  exit 1
}

source ./scripts/lib/filesystem.sh
source ./scripts/lib/world_paths.sh
source ./scripts/lib/mods.sh
source ./scripts/lib/modpack_overrides.sh
source ./scripts/lib/modpack_policy.sh
source ./scripts/lib/modpack_remove_extra.sh
source ./scripts/lib/modpack_runtime_inference.sh
source ./scripts/lib/modpack_curseforge.sh
source ./scripts/lib/modpack_path_policy.sh

required_jar="$tmp/required.jar"
optional_jar="$tmp/optional.jar"
printf 'required curseforge fixture\n' > "$required_jar"
printf 'optional curseforge fixture\n' > "$optional_jar"
required_sha1="$(sha1sum "$required_jar")"
required_sha1="${required_sha1%% *}"
optional_sha1="$(sha1sum "$optional_jar")"
optional_sha1="${optional_sha1%% *}"

archive="$tmp/fixture.zip"
ARCHIVE_PATH="$archive" python3 - <<'PY'
import json
import os
import zipfile

manifest = {
    "minecraft": {
        "version": "1.21.1",
        "modLoaders": [{"id": "fabric-0.16.14", "primary": True}],
    },
    "manifestType": "minecraftModpack",
    "manifestVersion": 1,
    "name": "Minecartainer CurseForge Fixture",
    "version": "1.0.0",
    "author": "CI",
    "files": [
        {"projectID": 100, "fileID": 200, "required": True},
        {"projectID": 101, "fileID": 201, "required": False},
    ],
    "overrides": "overrides",
}
with zipfile.ZipFile(os.environ["ARCHIVE_PATH"], "w") as zf:
    zf.writestr("manifest.json", json.dumps(manifest))
    zf.writestr("overrides/config/curseforge-fixture.toml", "from-curseforge = true\n")
PY

restricted_archive="$tmp/restricted.zip"
ARCHIVE_PATH="$restricted_archive" python3 - <<'PY'
import json
import os
import zipfile

manifest = {
    "minecraft": {
        "version": "1.21.1",
        "modLoaders": [{"id": "fabric-0.16.14", "primary": True}],
    },
    "manifestType": "minecraftModpack",
    "manifestVersion": 1,
    "name": "Restricted Fixture",
    "version": "1.0.0",
    "files": [{"projectID": 102, "fileID": 202, "required": True}],
    "overrides": "overrides",
}
with zipfile.ZipFile(os.environ["ARCHIVE_PATH"], "w") as zf:
    zf.writestr("manifest.json", json.dumps(manifest))
PY

mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

out=""
url=""
has_key=false
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --output)
      ((i+=1))
      out="${args[$i]}"
      ;;
    --header)
      ((i+=1))
      [[ "${args[$i]}" == x-api-key:* ]] && has_key=true
      ;;
    --)
      ((i+=1))
      url="${args[$i]}"
      ;;
  esac
done

[[ -n "$out" ]] || exit 90
[[ -n "$url" ]] || exit 91
printf '%s\tkey=%s\n' "$url" "$has_key" >> "$CF_REQUEST_LOG"

case "$url" in
  https://api.curseforge.com/v1/mods/100/files/200/download-url)
    [[ "$has_key" == true ]] || exit 92
    printf '{"data":"https://cdn.example.test/required.jar"}\n' > "$out"
    ;;
  https://api.curseforge.com/v1/mods/100/files/200)
    [[ "$has_key" == true ]] || exit 92
    printf '{"data":{"id":200,"modId":100,"isAvailable":true,"fileName":"required.jar","hashes":[{"value":"%s","algo":1}]}}\n' "$CF_REQUIRED_SHA1" > "$out"
    ;;
  https://api.curseforge.com/v1/mods/101/files/201/download-url)
    [[ "$has_key" == true ]] || exit 92
    printf '{"data":"https://cdn.example.test/optional.jar"}\n' > "$out"
    ;;
  https://api.curseforge.com/v1/mods/101/files/201)
    [[ "$has_key" == true ]] || exit 92
    printf '{"data":{"id":201,"modId":101,"isAvailable":true,"fileName":"optional.jar","hashes":[{"value":"%s","algo":1}]}}\n' "$CF_OPTIONAL_SHA1" > "$out"
    ;;
  https://api.curseforge.com/v1/mods/102/files/202/download-url)
    [[ "$has_key" == true ]] || exit 92
    printf '{"data":null}\n' > "$out"
    ;;
  https://api.curseforge.com/v1/mods/102/files/202)
    [[ "$has_key" == true ]] || exit 92
    printf '{"data":{"id":202,"modId":102,"isAvailable":true,"fileName":"restricted.jar","hashes":[{"value":"%s","algo":1}]}}\n' "$CF_REQUIRED_SHA1" > "$out"
    ;;
  https://cdn.example.test/required.jar)
    [[ "$has_key" == false ]] || exit 93
    cp "$CF_REQUIRED_JAR" "$out"
    ;;
  https://cdn.example.test/optional.jar)
    [[ "$has_key" == false ]] || exit 93
    cp "$CF_OPTIONAL_JAR" "$out"
    ;;
  *)
    exit 94
    ;;
esac
SH
chmod +x "$tmp/bin/curl"

export PATH="$tmp/bin:$PATH"
export CF_REQUEST_LOG="$tmp/curl-requests.log"
export CF_REQUIRED_SHA1="$required_sha1"
export CF_OPTIONAL_SHA1="$optional_sha1"
export CF_REQUIRED_JAR="$required_jar"
export CF_OPTIONAL_JAR="$optional_jar"
: > "$CF_REQUEST_LOG"

export TYPE=fabric
export VERSION=1.21.1
export FABRIC_LOADER_VERSION=0.16.14
export MODPACK_INSTALL_MODE=server
export MODPACK_FORMAT=curseforge
export MODPACK_URL="file://${archive}"
export MODPACK_ALLOW_FILE_URL=true
export MODPACK_FORCE_REINSTALL=false
export MODPACK_REMOVE_EXTRA=false
export MODPACK_INCLUDE_OPTIONAL=false
export MODPACK_INFER_RUNTIME=false
export CURSEFORGE_API_KEY='test-secret-api-key'

DATA_DIR="$tmp/data"
export DATA_DIR
mkdir -p "$DATA_DIR"
install_modpack_dispatch

cmp -s "$required_jar" "$DATA_DIR/mods/required.jar" || fail "required CurseForge file was not installed"
[[ ! -e "$DATA_DIR/mods/optional.jar" ]] || fail "optional CurseForge file was installed without opt-in"
[[ "$(cat "$DATA_DIR/config/curseforge-fixture.toml")" == 'from-curseforge = true' ]] \
  || fail "CurseForge overrides were not applied"

marker="$DATA_DIR/.modpack-install.json"
jq -e '
  .schemaVersion == 1
  and .format == "curseforge"
  and .versionId == "1.0.0"
  and .includeOptional == false
  and .dependencies.minecraft == "1.21.1"
  and .dependencies.loader == "fabric-0.16.14"
  and ([.files[] | select(.path == "mods/required.jar" and .projectId == 100 and .fileId == 200)] | length == 1)
  and ([.files[] | select(.path == "mods/optional.jar")] | length == 0)
  and ([.overrides[] | select(.path == "config/curseforge-fixture.toml" and .action == "seeded")] | length == 1)
' "$marker" >/dev/null || fail "CurseForge marker is incomplete"
if grep -F 'test-secret-api-key' "$marker" >/dev/null; then
  fail "CurseForge API key leaked into install marker"
fi
grep -F 'https://api.curseforge.com/v1/mods/100/files/200' "$CF_REQUEST_LOG" | grep -F 'key=true' >/dev/null \
  || fail "CurseForge API request did not carry API key"
grep -F 'https://cdn.example.test/required.jar' "$CF_REQUEST_LOG" | grep -F 'key=false' >/dev/null \
  || fail "CurseForge CDN download unexpectedly carried API key"

# A fully matching marker must avoid resolving/downloading manifest files again.
: > "$CF_REQUEST_LOG"
install_modpack_dispatch
[[ ! -s "$CF_REQUEST_LOG" ]] || fail "matching CurseForge marker still triggered API/download requests"

# Seeded overrides are part of marker integrity. If one disappears, the pack
# must reconcile instead of treating the marker as complete.
rm -f "$DATA_DIR/config/curseforge-fixture.toml"
: > "$CF_REQUEST_LOG"
install_modpack_dispatch
[[ "$(cat "$DATA_DIR/config/curseforge-fixture.toml")" == 'from-curseforge = true' ]] \
  || fail "missing managed CurseForge override was not restored"

# Optional manifest entries are explicit opt-in and become part of marker policy.
export MODPACK_INCLUDE_OPTIONAL=true
install_modpack_dispatch
cmp -s "$optional_jar" "$DATA_DIR/mods/optional.jar" || fail "optional CurseForge file was not installed after opt-in"
jq -e '.includeOptional == true and ([.files[] | select(.path == "mods/optional.jar")] | length == 1)' "$marker" >/dev/null \
  || fail "optional CurseForge marker policy was not recorded"

# Distribution-restricted files fail before any target can be seeded.
DATA_DIR="$tmp/restricted-data"
export DATA_DIR
mkdir -p "$DATA_DIR"
export MODPACK_URL="file://${restricted_archive}"
export MODPACK_INCLUDE_OPTIONAL=false
if install_modpack_dispatch >/dev/null 2>&1; then
  fail "CurseForge file without a download URL was accepted"
fi
[[ ! -e "$DATA_DIR/mods/restricted.jar" ]] || fail "restricted CurseForge file was written"

# Runtime metadata is validated before file API calls.
DATA_DIR="$tmp/mismatch-data"
export DATA_DIR
mkdir -p "$DATA_DIR"
export MODPACK_URL="file://${archive}"
export VERSION=1.20.1
: > "$CF_REQUEST_LOG"
if install_modpack_dispatch >/dev/null 2>&1; then
  fail "CurseForge Minecraft version mismatch was accepted"
fi
[[ ! -s "$CF_REQUEST_LOG" ]] || fail "runtime mismatch reached CurseForge file API"
export VERSION=1.21.1

# Cleanup and inference remain format-specific until their ownership/inference
# semantics are explicitly extended to CurseForge.
export MODPACK_REMOVE_EXTRA=true
if install_modpack_dispatch >/dev/null 2>&1; then
  fail "CurseForge MODPACK_REMOVE_EXTRA=true was accepted"
fi
export MODPACK_REMOVE_EXTRA=false
export MODPACK_INFER_RUNTIME=true
if install_modpack_dispatch >/dev/null 2>&1; then
  fail "CurseForge MODPACK_INFER_RUNTIME=true was accepted"
fi
export MODPACK_INFER_RUNTIME=false

# Auto mode deliberately refuses ambiguous generic ZIP files.
export MODPACK_FORMAT=auto
if install_modpack_dispatch >/dev/null 2>&1; then
  fail "MODPACK_FORMAT=auto guessed a CurseForge ZIP"
fi

printf 'CurseForge modpack smoke passed\n'

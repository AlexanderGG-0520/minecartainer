#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT_DIR}"

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

source ./scripts/lib/filesystem.sh
source ./scripts/lib/runtime.sh
source ./scripts/lib/mods.sh
source ./scripts/lib/modpack_overrides.sh
source ./scripts/lib/modpack_policy.sh
source ./scripts/lib/modpack_remove_extra.sh

fail() {
  printf 'modpack remove-extra smoke failed: %s\n' "$*" >&2
  exit 1
}

sha512_of() {
  local file="$1"
  local value
  value="$(sha512sum "$file")"
  printf '%s\n' "${value%% *}"
}

make_archive() {
  local archive="$1"
  ARCHIVE_PATH="$archive" python3 - <<'PY'
import json
import os
import zipfile

archive = os.environ["ARCHIVE_PATH"]
index = {
    "formatVersion": 1,
    "game": "minecraft",
    "versionId": "remove-extra-current",
    "files": [
        {
            "path": "mods/current.jar",
            "hashes": {"sha1": "0" * 40, "sha512": "1" * 128},
            "downloads": ["https://example.invalid/current.jar"],
            "env": {"server": "required", "client": "unsupported"},
        }
    ],
    "dependencies": {"minecraft": "1.21.8"},
}
with zipfile.ZipFile(archive, "w") as zf:
    zf.writestr("modrinth.index.json", json.dumps(index))
    zf.writestr("overrides/config/current.toml", "current=true\n")
    zf.writestr("client-overrides/config/client.toml", "client=true\n")
PY
}

DATA_DIR="$tmp/data"
mkdir -p "$DATA_DIR/mods" "$DATA_DIR/config"
TYPE=fabric
VERSION=1.21.8
MODPACK_INCLUDE_OPTIONAL=false
MODPACK_REMOVE_EXTRA=false

archive="$tmp/current.mrpack"
make_archive "$archive"

printf 'old managed jar\n' > "$DATA_DIR/mods/old.jar"
printf 'old override\n' > "$DATA_DIR/config/old.toml"
printf 'current path\n' > "$DATA_DIR/mods/current.jar"
printf 'operator changed\n' > "$DATA_DIR/mods/modified.jar"
printf 'operator skipped\n' > "$DATA_DIR/config/skipped.toml"
printf 'unmanaged extra\n' > "$DATA_DIR/mods/unmanaged.jar"

old_jar_sha="$(sha512_of "$DATA_DIR/mods/old.jar")"
old_override_sha="$(sha512_of "$DATA_DIR/config/old.toml")"
current_sha="$(sha512_of "$DATA_DIR/mods/current.jar")"
modified_previous="$tmp/modified-previous"
printf 'previous managed value\n' > "$modified_previous"
modified_previous_sha="$(sha512_of "$modified_previous")"

previous="$tmp/previous-marker.json"
jq -n \
  --arg oldJarSha "$old_jar_sha" \
  --arg oldOverrideSha "$old_override_sha" \
  --arg currentSha "$current_sha" \
  --arg modifiedSha "$modified_previous_sha" \
  '{
    schemaVersion: 1,
    format: "mrpack",
    sourceUrl: "https://example.invalid/old.mrpack",
    versionId: "old",
    indexSha512: "old-index",
    installMode: "server",
    files: [
      {path:"mods/old.jar",sha1:("0"*40),sha512:$oldJarSha},
      {path:"mods/current.jar",sha1:("0"*40),sha512:$currentSha},
      {path:"mods/modified.jar",sha1:("0"*40),sha512:$modifiedSha}
    ],
    overrides: [
      {path:"config/old.toml",layer:"overrides",action:"seeded",sha512:$oldOverrideSha},
      {path:"config/skipped.toml",layer:"overrides",action:"skipped"}
    ]
  }' > "$previous"

marker="$DATA_DIR/.modpack-install.json"
jq -n \
  --arg currentSha "$current_sha" \
  '{
    schemaVersion: 1,
    format: "mrpack",
    sourceUrl: "https://example.invalid/current.mrpack",
    versionId: "remove-extra-current",
    indexSha512: "current-index",
    installMode: "server",
    includeOptional: false,
    dependencies: {minecraft:"1.21.8"},
    files: [{path:"mods/current.jar",sha1:("0"*40),sha512:$currentSha}],
    overrides: [{path:"config/current.toml",layer:"overrides",action:"skipped"}]
  }' > "$marker"

reconcile_modpack_managed_extras "$archive" "$previous" "$marker" "$tmp"

[[ -f "$DATA_DIR/mods/old.jar" ]] || fail 'remove-extra=false deleted stale indexed file'
[[ -f "$DATA_DIR/config/old.toml" ]] || fail 'remove-extra=false deleted stale override'
[[ -f "$DATA_DIR/mods/modified.jar" ]] || fail 'modified former managed file was deleted'
[[ -f "$DATA_DIR/config/skipped.toml" ]] || fail 'skipped operator-owned override was deleted'
[[ -f "$DATA_DIR/mods/unmanaged.jar" ]] || fail 'unmanaged extra was deleted'
[[ -f "$DATA_DIR/mods/current.jar" ]] || fail 'current pack path was deleted'

jq -e \
  --arg oldJarSha "$old_jar_sha" \
  --arg oldOverrideSha "$old_override_sha" '
    (.retainedManaged | length) == 2
    and any(.retainedManaged[]; .path == "mods/old.jar" and .sha512 == $oldJarSha)
    and any(.retainedManaged[]; .path == "config/old.toml" and .sha512 == $oldOverrideSha)
    and (all(.retainedManaged[]; .path != "mods/modified.jar"))
    and (all(.retainedManaged[]; .path != "config/skipped.toml"))
    and (all(.retainedManaged[]; .path != "mods/current.jar"))
  ' "$marker" >/dev/null || fail 'retained managed marker did not preserve only unchanged stale ownership'

previous_retained="$tmp/previous-retained.json"
cp "$marker" "$previous_retained"
MODPACK_REMOVE_EXTRA=true
reconcile_modpack_managed_extras "$archive" "$previous_retained" "$marker" "$tmp"

[[ ! -e "$DATA_DIR/mods/old.jar" ]] || fail 'stale indexed file was not removed'
[[ ! -e "$DATA_DIR/config/old.toml" ]] || fail 'stale seeded override was not removed'
[[ -f "$DATA_DIR/mods/modified.jar" ]] || fail 'modified former managed file was removed'
[[ -f "$DATA_DIR/config/skipped.toml" ]] || fail 'skipped operator-owned override was removed'
[[ -f "$DATA_DIR/mods/unmanaged.jar" ]] || fail 'unmanaged extra was removed'
[[ -f "$DATA_DIR/mods/current.jar" ]] || fail 'current pack path was removed'
jq -e '(.retainedManaged | length) == 0' "$marker" >/dev/null \
  || fail 'removed stale entries remained under retainedManaged'

baseline_data="$tmp/baseline-data"
mkdir -p "$baseline_data"
DATA_DIR="$baseline_data"
MODPACK_URL='file:///does-not-need-to-exist.mrpack'
MODPACK_INSTALL_MODE=server
MODPACK_FORMAT=mrpack
MODPACK_REMOVE_EXTRA=true
if (install_modpack_with_overrides) >"$tmp/baseline.out" 2>&1; then
  fail 'remove-extra without a baseline marker unexpectedly succeeded'
fi
grep -F 'MODPACK_REMOVE_EXTRA=true is not supported in this phase without an existing modpack marker' "$tmp/baseline.out" >/dev/null \
  || { cat "$tmp/baseline.out" >&2; fail 'baseline marker safety diagnostic missing'; }

escape_data="$tmp/escape-data"
outside="$tmp/outside"
mkdir -p "$escape_data" "$outside"
printf 'outside managed-looking content\n' > "$outside/escape.toml"
escape_sha="$(sha512_of "$outside/escape.toml")"
ln -s "$outside" "$escape_data/config"
DATA_DIR="$escape_data"
escape_previous="$tmp/escape-previous.json"
escape_marker="$escape_data/.modpack-install.json"
jq -n --arg sha "$escape_sha" '{
  schemaVersion:1,
  format:"mrpack",
  files:[],
  overrides:[{path:"config/escape.toml",layer:"overrides",action:"seeded",sha512:$sha}]
}' > "$escape_previous"
jq -n '{schemaVersion:1,format:"mrpack",files:[],overrides:[]}' > "$escape_marker"

if (reconcile_modpack_managed_extras "$archive" "$escape_previous" "$escape_marker" "$tmp") >"$tmp/escape.out" 2>&1; then
  fail 'parent symlink escape unexpectedly succeeded'
fi
grep -F 'Refusing mrpack remove-extra target outside DATA_DIR: config/escape.toml' "$tmp/escape.out" >/dev/null \
  || { cat "$tmp/escape.out" >&2; fail 'symlink escape diagnostic missing'; }
[[ -f "$outside/escape.toml" ]] || fail 'symlink escape removed file outside DATA_DIR'

printf 'modpack remove-extra smoke passed\n'

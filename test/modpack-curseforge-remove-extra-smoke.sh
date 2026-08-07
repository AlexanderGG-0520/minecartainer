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
  printf 'CurseForge remove-extra smoke failed: %s\n' "$*" >&2
  exit 1
}
sha512_of() {
  local value
  value="$(sha512sum "$1")"
  printf '%s\n' "${value%% *}"
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
source ./scripts/lib/modpack_path_policy.sh

DATA_DIR="$tmp/data"
mkdir -p "$DATA_DIR/mods" "$DATA_DIR/config"
TYPE=fabric
VERSION=1.21.1
MODPACK_FORMAT=curseforge
MODPACK_INSTALL_MODE=server
MODPACK_INFER_RUNTIME=false
MODPACK_ALLOW_FILE_URL=true
MODPACK_INCLUDE_OPTIONAL=false
MODPACK_FORCE_REINSTALL=false
MODPACK_REMOVE_EXTRA=false
CURSEFORGE_API_KEY=test-key

printf 'old managed jar\n' > "$DATA_DIR/mods/old.jar"
printf 'old managed override\n' > "$DATA_DIR/config/old.toml"
printf 'current managed jar\n' > "$DATA_DIR/mods/current.jar"
printf 'operator changed\n' > "$DATA_DIR/mods/modified.jar"
printf 'operator skipped\n' > "$DATA_DIR/config/skipped.toml"
printf 'unmanaged extra\n' > "$DATA_DIR/mods/unmanaged.jar"

old_jar_sha="$(sha512_of "$DATA_DIR/mods/old.jar")"
old_override_sha="$(sha512_of "$DATA_DIR/config/old.toml")"
current_sha="$(sha512_of "$DATA_DIR/mods/current.jar")"
modified_previous="$tmp/modified-previous"
printf 'previous managed value\n' > "$modified_previous"
modified_previous_sha="$(sha512_of "$modified_previous")"

previous="$tmp/previous-curseforge-marker.json"
jq -n \
  --arg oldJarSha "$old_jar_sha" \
  --arg oldOverrideSha "$old_override_sha" \
  --arg currentSha "$current_sha" \
  --arg modifiedSha "$modified_previous_sha" '
  {
    schemaVersion:1,
    format:"curseforge",
    sourceUrl:"https://example.invalid/old.zip",
    versionId:"old",
    installMode:"server",
    files:[
      {path:"mods/old.jar",sha1:("0"*40),sha512:$oldJarSha,projectId:1,fileId:1},
      {path:"mods/current.jar",sha1:("0"*40),sha512:$currentSha,projectId:2,fileId:2},
      {path:"mods/modified.jar",sha1:("0"*40),sha512:$modifiedSha,projectId:3,fileId:3}
    ],
    overrides:[
      {path:"config/old.toml",layer:"curseforge-overrides",action:"seeded",sha512:$oldOverrideSha},
      {path:"config/skipped.toml",layer:"curseforge-overrides",action:"skipped"}
    ],
    retainedManaged:[]
  }
' > "$previous"

marker="$DATA_DIR/.modpack-install.json"
jq -n --arg currentSha "$current_sha" '
  {
    schemaVersion:1,
    format:"curseforge",
    sourceUrl:"https://example.invalid/current.zip",
    versionId:"current",
    installMode:"server",
    files:[{path:"mods/current.jar",sha1:("0"*40),sha512:$currentSha,projectId:2,fileId:2}],
    overrides:[{path:"config/current.toml",layer:"curseforge-overrides",action:"skipped"}]
  }
' > "$marker"

reconcile_curseforge_managed_extras "$previous" "$marker" "$tmp"

[[ -f "$DATA_DIR/mods/old.jar" ]] || fail 'remove-extra=false deleted stale CurseForge file'
[[ -f "$DATA_DIR/config/old.toml" ]] || fail 'remove-extra=false deleted stale CurseForge override'
[[ -f "$DATA_DIR/mods/modified.jar" ]] || fail 'modified former CurseForge file was deleted'
[[ -f "$DATA_DIR/config/skipped.toml" ]] || fail 'skipped operator-owned override was deleted'
[[ -f "$DATA_DIR/mods/unmanaged.jar" ]] || fail 'unmanaged file was deleted'
[[ -f "$DATA_DIR/mods/current.jar" ]] || fail 'current CurseForge file was deleted'

jq -e \
  --arg oldJarSha "$old_jar_sha" \
  --arg oldOverrideSha "$old_override_sha" '
    (.retainedManaged | length) == 2
    and any(.retainedManaged[]; .path == "mods/old.jar" and .sha512 == $oldJarSha)
    and any(.retainedManaged[]; .path == "config/old.toml" and .sha512 == $oldOverrideSha)
    and all(.retainedManaged[]; .path != "mods/modified.jar")
    and all(.retainedManaged[]; .path != "mods/current.jar")
    and all(.retainedManaged[]; .path != "config/skipped.toml")
  ' "$marker" >/dev/null || fail 'CurseForge retainedManaged did not preserve only unchanged stale ownership'

previous_retained="$tmp/previous-retained.json"
cp "$marker" "$previous_retained"
MODPACK_REMOVE_EXTRA=true
reconcile_curseforge_managed_extras "$previous_retained" "$marker" "$tmp"

[[ ! -e "$DATA_DIR/mods/old.jar" ]] || fail 'stale CurseForge indexed file was not removed'
[[ ! -e "$DATA_DIR/config/old.toml" ]] || fail 'stale CurseForge seeded override was not removed'
[[ -f "$DATA_DIR/mods/modified.jar" ]] || fail 'modified former CurseForge file was removed'
[[ -f "$DATA_DIR/config/skipped.toml" ]] || fail 'skipped operator-owned override was removed'
[[ -f "$DATA_DIR/mods/unmanaged.jar" ]] || fail 'unmanaged file was removed'
[[ -f "$DATA_DIR/mods/current.jar" ]] || fail 'current CurseForge file was removed'
jq -e '(.retainedManaged | length) == 0' "$marker" >/dev/null \
  || fail 'removed CurseForge stale entries remained retained'

# Parent-directory symlink escapes remain blocked even when the previous marker
# claims ownership of the target.
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
  format:"curseforge",
  files:[],
  overrides:[{path:"config/escape.toml",layer:"curseforge-overrides",action:"seeded",sha512:$sha}],
  retainedManaged:[]
}' > "$escape_previous"
jq -n '{schemaVersion:1,format:"curseforge",files:[],overrides:[]}' > "$escape_marker"
if (reconcile_curseforge_managed_extras "$escape_previous" "$escape_marker" "$tmp") >"$tmp/escape.out" 2>&1; then
  fail 'CurseForge parent symlink escape unexpectedly succeeded'
fi
grep -F 'Refusing mrpack remove-extra target outside DATA_DIR: config/escape.toml' "$tmp/escape.out" >/dev/null \
  || { cat "$tmp/escape.out" >&2; fail 'CurseForge symlink escape diagnostic missing'; }
[[ -f "$outside/escape.toml" ]] || fail 'CurseForge cleanup removed file outside DATA_DIR'

# Enabling cleanup without a CurseForge ownership baseline fails before any
# archive download or installation can occur.
DATA_DIR="$tmp/no-baseline"
mkdir -p "$DATA_DIR"
MODPACK_REMOVE_EXTRA=true
MODPACK_URL='file:///does-not-exist.zip'
if (install_curseforge_modpack_with_overrides) >"$tmp/no-baseline.out" 2>&1; then
  fail 'CurseForge remove-extra without baseline unexpectedly succeeded'
fi
grep -F 'requires an existing CurseForge modpack marker' "$tmp/no-baseline.out" >/dev/null \
  || { cat "$tmp/no-baseline.out" >&2; fail 'CurseForge baseline diagnostic missing'; }

# A marker from another modpack format must never grant deletion authority.
DATA_DIR="$tmp/cross-format"
mkdir -p "$DATA_DIR/mods"
printf 'old mrpack-owned value\n' > "$DATA_DIR/mods/old-format.jar"
old_format_sha="$(sha512_of "$DATA_DIR/mods/old-format.jar")"
jq -n --arg sha "$old_format_sha" '{
  schemaVersion:1,
  format:"mrpack",
  files:[{path:"mods/old-format.jar",sha1:("0"*40),sha512:$sha}],
  overrides:[],
  retainedManaged:[]
}' > "$DATA_DIR/.modpack-install.json"
MODPACK_REMOVE_EXTRA=true
MODPACK_URL='file:///does-not-exist.zip'
if (install_curseforge_modpack_with_overrides) >"$tmp/cross-format.out" 2>&1; then
  fail 'cross-format CurseForge remove-extra unexpectedly succeeded'
fi
grep -F 'requires an existing CurseForge-format ownership marker' "$tmp/cross-format.out" >/dev/null \
  || { cat "$tmp/cross-format.out" >&2; fail 'cross-format cleanup diagnostic missing'; }
[[ -f "$DATA_DIR/mods/old-format.jar" ]] || fail 'cross-format cleanup removed previous-format file'

# A normal format switch is allowed with cleanup disabled, but it starts a new
# CurseForge cleanup baseline instead of inheriting prior-format ownership.
empty_pack="$tmp/empty-curseforge.zip"
ARCHIVE_PATH="$empty_pack" python3 - <<'PY'
import json
import os
import zipfile

manifest = {
    "minecraft": {"version": "1.21.1", "modLoaders": [{"id": "fabric-0.16.14", "primary": True}]},
    "manifestType": "minecraftModpack",
    "manifestVersion": 1,
    "name": "Empty CurseForge Cleanup Fixture",
    "version": "1.0.0",
    "author": "Minecartainer CI",
    "files": [],
}
with zipfile.ZipFile(os.environ["ARCHIVE_PATH"], "w") as zf:
    zf.writestr("manifest.json", json.dumps(manifest))
PY
MODPACK_REMOVE_EXTRA=false
MODPACK_URL="file://$empty_pack"
install_curseforge_modpack_with_overrides
[[ -f "$DATA_DIR/mods/old-format.jar" ]] || fail 'format switch removed old-format file with cleanup disabled'
jq -e '.format == "curseforge" and (.retainedManaged | length) == 0' "$DATA_DIR/.modpack-install.json" >/dev/null \
  || fail 'format switch inherited prior-format cleanup ownership'

printf 'CurseForge remove-extra smoke passed\n'

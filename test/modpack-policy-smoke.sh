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

fail() {
  printf 'modpack policy smoke failed: %s\n' "$*" >&2
  exit 1
}

write_index() {
  local path="$1"
  local dependencies="$2"
  jq -n --argjson dependencies "$dependencies" '{
    formatVersion: 1,
    game: "minecraft",
    versionId: "dependency-test",
    files: [],
    dependencies: $dependencies
  }' > "$path"
}

DATA_DIR="$tmp/data"
mkdir -p "$DATA_DIR"
TYPE=fabric
VERSION=1.21.8
MODPACK_INCLUDE_OPTIONAL=false

cat > "$DATA_DIR/.server-install.json" <<'JSON'
{"artifact":"fabric-server-launch.jar","type":"fabric","version":"1.21.8","build":"0.16.14"}
JSON

write_index "$tmp/matching.json" '{"minecraft":"1.21.8","fabric-loader":"0.16.14"}'
validate_mrpack_dependencies "$tmp/matching.json"

write_index "$tmp/minecraft-mismatch.json" '{"minecraft":"1.21.7","fabric-loader":"0.16.14"}'
if (validate_mrpack_dependencies "$tmp/minecraft-mismatch.json") >"$tmp/minecraft.out" 2>&1; then
  fail 'minecraft dependency mismatch unexpectedly succeeded'
fi
grep -F 'Modpack Minecraft dependency mismatch: pack=1.21.7 server=1.21.8' "$tmp/minecraft.out" >/dev/null \
  || { cat "$tmp/minecraft.out" >&2; fail 'minecraft mismatch diagnostic missing'; }

write_index "$tmp/type-mismatch.json" '{"minecraft":"1.21.8","forge":"47.3.0"}'
if (validate_mrpack_dependencies "$tmp/type-mismatch.json") >"$tmp/type.out" 2>&1; then
  fail 'loader type mismatch unexpectedly succeeded'
fi
grep -F 'Modpack loader dependency mismatch: pack requires forge=47.3.0 but server TYPE=fabric' "$tmp/type.out" >/dev/null \
  || { cat "$tmp/type.out" >&2; fail 'loader type mismatch diagnostic missing'; }

write_index "$tmp/version-mismatch.json" '{"minecraft":"1.21.8","fabric-loader":"0.16.15"}'
if (validate_mrpack_dependencies "$tmp/version-mismatch.json") >"$tmp/loader-version.out" 2>&1; then
  fail 'loader version mismatch unexpectedly succeeded'
fi
grep -F 'Modpack loader version mismatch: pack fabric-loader=0.16.15 server=0.16.14' "$tmp/loader-version.out" >/dev/null \
  || { cat "$tmp/loader-version.out" >&2; fail 'loader version mismatch diagnostic missing'; }

write_index "$tmp/multiple-loaders.json" '{"minecraft":"1.21.8","fabric-loader":"0.16.14","forge":"47.3.0"}'
if (validate_mrpack_dependencies "$tmp/multiple-loaders.json") >"$tmp/multiple.out" 2>&1; then
  fail 'multiple loader dependencies unexpectedly succeeded'
fi
grep -F 'Modpack declares multiple loader dependencies' "$tmp/multiple.out" >/dev/null \
  || { cat "$tmp/multiple.out" >&2; fail 'multiple-loader diagnostic missing'; }

logs=""
write_index "$tmp/future.json" '{"minecraft":"1.21.8","fabric-loader":"0.16.14","future-runtime":"9.0"}'
validate_mrpack_dependencies "$tmp/future.json"
printf '%b' "$logs" | grep -F "Unrecognized Modrinth dependency 'future-runtime=9.0'; leaving it unvalidated" >/dev/null \
  || fail 'unknown dependency was not surfaced as a warning'

cat > "$tmp/invalid-dependency.json" <<'JSON'
{
  "formatVersion": 1,
  "game": "minecraft",
  "versionId": "bad-dependency",
  "files": [],
  "dependencies": {"minecraft": 1218}
}
JSON
if (validate_modrinth_index "$tmp/invalid-dependency.json") >"$tmp/schema.out" 2>&1; then
  fail 'non-string dependency version unexpectedly passed schema validation'
fi
grep -F 'Invalid Modrinth index schema' "$tmp/schema.out" >/dev/null \
  || { cat "$tmp/schema.out" >&2; fail 'dependency schema diagnostic missing'; }

printf '[]\n' > "$tmp/files-array.json"
MODPACK_INCLUDE_OPTIONAL=true
marker="$DATA_DIR/.modpack-install.json"
write_modpack_marker \
  "$marker" "$tmp/files-array.json" 'https://example.invalid/pack.mrpack' \
  'dependency-test' 'aaaaaaaa' '{"minecraft":"1.21.8","fabric-loader":"0.16.14"}'

jq -e '
  .includeOptional == true
  and .dependencies.minecraft == "1.21.8"
  and .dependencies["fabric-loader"] == "0.16.14"
' "$marker" >/dev/null || fail 'marker did not persist optional/dependency policy'

modpack_marker_matches \
  "$marker" 'https://example.invalid/pack.mrpack' 'dependency-test' 'aaaaaaaa' \
  || fail 'marker should match with the same optional policy'

MODPACK_INCLUDE_OPTIONAL=false
if modpack_marker_matches \
  "$marker" 'https://example.invalid/pack.mrpack' 'dependency-test' 'aaaaaaaa'; then
  fail 'marker unexpectedly matched after optional policy changed'
fi

printf 'modpack policy smoke passed\n'

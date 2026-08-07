#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT_DIR}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log() { :; }
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

source ./scripts/lib/mods.sh
source ./scripts/lib/modpack_policy.sh

cat > "$tmp/modrinth.index.json" <<'JSON'
{
  "formatVersion": 1,
  "game": "minecraft",
  "versionId": "server-filter-test",
  "files": [
    {
      "path": "mods/common.jar",
      "hashes": {"sha1": "0000000000000000000000000000000000000000", "sha512": "11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111"},
      "downloads": ["https://example.invalid/common.jar"],
      "env": {"client": "required", "server": "required"}
    },
    {
      "path": "mods/server-only.jar",
      "hashes": {"sha1": "0000000000000000000000000000000000000000", "sha512": "11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111"},
      "downloads": ["https://example.invalid/server-only.jar"],
      "env": {"client": "unsupported", "server": "required"}
    },
    {
      "path": "mods/default-server.jar",
      "hashes": {"sha1": "0000000000000000000000000000000000000000", "sha512": "11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111"},
      "downloads": ["https://example.invalid/default-server.jar"]
    },
    {
      "path": "mods/client-only.jar",
      "hashes": {"sha1": "0000000000000000000000000000000000000000", "sha512": "11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111"},
      "downloads": ["https://example.invalid/client-only.jar"],
      "env": {"client": "required", "server": "unsupported"}
    },
    {
      "path": "mods/client-optional.jar",
      "hashes": {"sha1": "0000000000000000000000000000000000000000", "sha512": "11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111"},
      "downloads": ["https://example.invalid/client-optional.jar"],
      "env": {"client": "optional", "server": "unsupported"}
    },
    {
      "path": "mods/server-optional.jar",
      "hashes": {"sha1": "0000000000000000000000000000000000000000", "sha512": "11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111"},
      "downloads": ["https://example.invalid/server-optional.jar"],
      "env": {"client": "required", "server": "optional"}
    }
  ]
}
JSON

validate_modrinth_index "$tmp/modrinth.index.json"

MODPACK_INCLUDE_OPTIONAL=false
select_modrinth_server_files "$tmp/modrinth.index.json" \
  | jq -r '.path' > "$tmp/selected-default.txt"

cat > "$tmp/expected-default.txt" <<'EOF'
mods/common.jar
mods/server-only.jar
mods/default-server.jar
EOF

diff -u "$tmp/expected-default.txt" "$tmp/selected-default.txt"

MODPACK_INCLUDE_OPTIONAL=true
select_modrinth_server_files "$tmp/modrinth.index.json" \
  | jq -r '.path' > "$tmp/selected-optional.txt"

cat > "$tmp/expected-optional.txt" <<'EOF'
mods/common.jar
mods/server-only.jar
mods/default-server.jar
mods/server-optional.jar
EOF

diff -u "$tmp/expected-optional.txt" "$tmp/selected-optional.txt"

for excluded in \
  'mods/client-only.jar' \
  'mods/client-optional.jar'; do
  if grep -Fx -- "$excluded" "$tmp/selected-optional.txt" >/dev/null; then
    printf 'unexpected server-selected modpack file: %s\n' "$excluded" >&2
    exit 1
  fi
done

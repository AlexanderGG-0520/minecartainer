#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

die() {
  printf '%s\n' "$*" >&2
  return 1
}

# shellcheck source=scripts/lib/modrinth_api.sh
source ./scripts/lib/modrinth_api.sh

versions='[
  {
    "id":"older",
    "version_number":"0.1.0-alpha.1",
    "status":"listed",
    "date_published":"2026-08-01T00:00:00Z",
    "files":[{"filename":"older.jar","primary":true,"url":"https://cdn.modrinth.com/data/test/older.jar","hashes":{"sha512":"abc"}}]
  },
  {
    "id":"newer",
    "version_number":"0.2.0-alpha.1",
    "status":"listed",
    "date_published":"2026-09-01T00:00:00Z",
    "files":[
      {"filename":"sources.jar","primary":false,"url":"https://cdn.modrinth.com/data/test/sources.jar","hashes":{"sha512":"def"}},
      {"filename":"main.jar","primary":true,"url":"https://cdn.modrinth.com/data/test/main.jar","hashes":{"sha512":"123"}}
    ]
  }
]'

selected="$(modrinth_select_project_version "$versions" latest-compatible)"
[[ "$(jq -r '.id' <<< "$selected")" == "newer" ]] || fail "latest-compatible did not select newest version"

selected="$(modrinth_select_project_version "$versions" older)"
[[ "$(jq -r '.id' <<< "$selected")" == "older" ]] || fail "explicit version id was not selected"

selected="$(modrinth_select_project_version "$versions" 0.2.0-alpha.1)"
[[ "$(jq -r '.id' <<< "$selected")" == "newer" ]] || fail "explicit version number was not selected"

file="$(modrinth_select_primary_jar_file "$(modrinth_select_project_version "$versions" newer)")"
[[ "$(jq -r '.filename' <<< "$file")" == "main.jar" ]] || fail "primary JAR was not selected"

fallback='{"files":[{"filename":"fallback.jar","primary":false,"url":"https://cdn.modrinth.com/data/test/fallback.jar","hashes":{"sha512":"abc"}}]}'
file="$(modrinth_select_primary_jar_file "$fallback")"
[[ "$(jq -r '.filename' <<< "$file")" == "fallback.jar" ]] || fail "first JAR fallback was not selected"

if modrinth_select_project_version '[]' latest-compatible >/dev/null 2>&1; then
  fail "empty version list unexpectedly resolved"
fi

if modrinth_select_primary_jar_file '{"files":[]}' >/dev/null 2>&1; then
  fail "version without JAR unexpectedly resolved"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'verified payload\n' > "$tmp/source.jar"
sha512="$(sha512sum "$tmp/source.jar" | awk '{print $1}')"
file_json="$(jq -nc --arg sha "$sha512" '{filename:"payload.jar",primary:true,url:"https://cdn.modrinth.com/data/test/payload.jar",hashes:{sha512:$sha}}')"

curl() {
  local out=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --output)
        out="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done
  cp "$tmp/source.jar" "$out"
}

modrinth_download_verified_file "$file_json" "$tmp/output.jar"
cmp -s "$tmp/source.jar" "$tmp/output.jar" || fail "verified download payload mismatch"

printf 'modrinth api smoke: PASS\n'

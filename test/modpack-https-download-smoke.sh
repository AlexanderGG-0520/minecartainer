#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT_DIR}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

: "${CURL_ARGS_LOG:?}"
printf '%s\n' "$@" > "$CURL_ARGS_LOG"

out=""
url=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output|-o)
      out="$2"
      shift 2
      ;;
    --proto|--proto-redir|--retry|--retry-delay|--connect-timeout|--max-time)
      shift 2
      ;;
    --fail|--location|--silent|--show-error|--retry-all-errors)
      shift
      ;;
    --)
      shift
      url="${1:-}"
      shift || true
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

[[ -n "$out" ]] || { echo 'missing curl output path' >&2; exit 90; }
[[ "$url" == https://* ]] || { echo "unexpected curl URL: $url" >&2; exit 91; }

if [[ "${CURL_EXIT_STATUS:-0}" != "0" ]]; then
  printf '%s' partial > "$out"
  exit "$CURL_EXIT_STATUS"
fi

: "${CURL_PAYLOAD:?}"
cp "$CURL_PAYLOAD" "$out"
MOCK
chmod +x "$tmp/bin/curl"
PATH="$tmp/bin:$PATH"
export PATH

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
safe_rm_f() {
  rm -f -- "$1"
}

source ./scripts/lib/mods.sh

printf '%s' 'https payload' > "$tmp/payload"
export CURL_PAYLOAD="$tmp/payload"
export CURL_ARGS_LOG="$tmp/curl.args"

download_modpack_file \
  'https://cdn.modrinth.com/data/example/versions/1/example.jar' \
  "$tmp/downloaded.jar" \
  'mods/example.jar'
cmp "$tmp/payload" "$tmp/downloaded.jar"

for expected in \
  '--fail' \
  '--location' \
  '--silent' \
  '--show-error' \
  '--proto' \
  '=https' \
  '--proto-redir' \
  '--retry' \
  '3' \
  '--retry-delay' \
  '1' \
  '--retry-all-errors' \
  '--connect-timeout' \
  '15' \
  '--max-time' \
  '300' \
  '--output' \
  "$tmp/downloaded.jar" \
  '--' \
  'https://cdn.modrinth.com/data/example/versions/1/example.jar'; do
  grep -Fx -- "$expected" "$tmp/curl.args" >/dev/null
done

set +e
failure_output="$(
  (
    export CURL_EXIT_STATUS=22
    download_modpack_file \
      'https://cdn.modrinth.com/data/example/versions/2/failure.jar' \
      "$tmp/failure.jar" \
      'mods/failure.jar'
  ) 2>&1
)"
failure_status=$?
set -e
[[ "$failure_status" -eq 1 ]]
[[ ! -e "$tmp/failure.jar" ]]
grep -F 'Failed to download modpack file: mods/failure.jar' <<< "$failure_output" >/dev/null

: > "$tmp/empty"
export CURL_PAYLOAD="$tmp/empty"
set +e
empty_output="$(
  download_modpack_file \
    'https://cdn.modrinth.com/data/example/versions/3/empty.jar' \
    "$tmp/empty.jar" \
    'mods/empty.jar' 2>&1
)"
empty_status=$?
set -e
[[ "$empty_status" -eq 1 ]]
[[ ! -e "$tmp/empty.jar" ]]
grep -F 'Downloaded modpack file is empty for mods/empty.jar' <<< "$empty_output" >/dev/null

rm -f "$tmp/curl.args"
set +e
http_output="$(
  download_modpack_file \
    'http://cdn.modrinth.com/data/example/insecure.jar' \
    "$tmp/insecure.jar" \
    'mods/insecure.jar' 2>&1
)"
http_status=$?
set -e
[[ "$http_status" -eq 1 ]]
[[ ! -e "$tmp/curl.args" ]]
grep -F 'Unsupported modpack download URL for mods/insecure.jar' <<< "$http_output" >/dev/null

printf '%s' 'local payload' > "$tmp/local-source.jar"
MODPACK_ALLOW_FILE_URL=true download_modpack_file \
  "file://$tmp/local-source.jar" \
  "$tmp/local-downloaded.jar" \
  'mods/local.jar'
cmp "$tmp/local-source.jar" "$tmp/local-downloaded.jar"

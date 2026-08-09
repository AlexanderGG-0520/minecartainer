#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT_DIR}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

source ./scripts/lib/logging.sh
source ./scripts/lib/filesystem.sh
source ./scripts/lib/s3_client.sh
source ./scripts/lib/content_assets.sh

aws_calls="$tmp/aws-calls"
: > "$aws_calls"

aws() {
  local dest
  printf '%s\n' "$*" >> "$aws_calls"
  case "$*" in
    *"list-objects-v2"*)
      printf '%s\n' '{"Contents":[{"Key":"prefix/good.jar"},{"Key":"prefix/good.jar.disabled"},{"Key":"prefix/nested/other.jar"},{"Key":"prefix/readme.txt"}]}'
      ;;
    *"s3api get-object"*)
      dest="${*: -1}"
      mkdir -p "$(dirname "$dest")"
      printf '%s\n' jar > "$dest"
      printf '%s\n' '{}'
      ;;
    *"s3 cp"*)
      dest="${*: -1}"
      mkdir -p "$(dirname "$dest")"
      printf '%s\n' jar > "$dest"
      ;;
    *)
      return 0
      ;;
  esac
}

S3_ENDPOINT_URL="https://objects.example.test"
S3_ACCESS_KEY_ID="project-access-key"
S3_SECRET_ACCESS_KEY="project-secret-key"
S3_REGION="auto"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_REGION
unset AWS_REQUEST_CHECKSUM_CALCULATION AWS_RESPONSE_CHECKSUM_VALIDATION

output_file="$tmp/s3-prepare-output"
s3_prepare_env "smoke" >"$output_file" 2>&1
output="$(cat "$output_file")"
test -z "$output"
test "$AWS_ACCESS_KEY_ID" = "project-access-key"
test "$AWS_SECRET_ACCESS_KEY" = "project-secret-key"
test "$AWS_DEFAULT_REGION" = "auto"
test "$AWS_REGION" = "auto"
test "$AWS_REQUEST_CHECKSUM_CALCULATION" = "when_required"
test "$AWS_RESPONSE_CHECKSUM_VALIDATION" = "when_required"

AWS_REQUEST_CHECKSUM_CALCULATION="when_supported"
AWS_RESPONSE_CHECKSUM_VALIDATION="when_supported"
s3_prepare_env "smoke"
test "$AWS_REQUEST_CHECKSUM_CALCULATION" = "when_required"
test "$AWS_RESPONSE_CHECKSUM_VALIDATION" = "when_required"

s3_cp "s3/bucket/prefix/good.jar" "$tmp/good.jar"
test -f "$tmp/good.jar"
test "$(cat "$aws_calls")" = "--endpoint-url https://objects.example.test s3api get-object --bucket bucket --key prefix/good.jar $tmp/good.jar"
if grep -F 'project-secret-key' "$aws_calls" >/dev/null; then
  echo "FAIL: secret was written to aws call log" >&2
  exit 1
fi
if grep -F ' s3 cp ' "$aws_calls" >/dev/null; then
  echo "FAIL: custom endpoint download used high-level aws s3 cp" >&2
  exit 1
fi

: > "$aws_calls"
sync_dir="$tmp/sync"
mkdir -p "$sync_dir"
printf '%s\n' stale > "$sync_dir/stale.jar"
s3_sync "s3/bucket/prefix" "$sync_dir" --remove
test -f "$sync_dir/good.jar"
test -f "$sync_dir/good.jar.disabled"
test -f "$sync_dir/nested/other.jar"
test -f "$sync_dir/readme.txt"
test ! -e "$sync_dir/stale.jar"
grep -F -- '--endpoint-url https://objects.example.test s3api list-objects-v2 --bucket bucket --prefix prefix/ --output json' "$aws_calls" >/dev/null
grep -F -- '--endpoint-url https://objects.example.test s3api get-object --bucket bucket --key prefix/good.jar' "$aws_calls" >/dev/null
if grep -F ' s3 sync ' "$aws_calls" >/dev/null; then
  echo "FAIL: custom endpoint sync used high-level aws s3 sync" >&2
  exit 1
fi

: > "$aws_calls"
unset S3_ENDPOINT_URL S3_ENDPOINT
unset AWS_REQUEST_CHECKSUM_CALCULATION AWS_RESPONSE_CHECKSUM_VALIDATION
s3_prepare_env "aws-s3"
test -z "${AWS_REQUEST_CHECKSUM_CALCULATION+x}"
test -z "${AWS_RESPONSE_CHECKSUM_VALIDATION+x}"
s3_cp "s3/bucket/prefix/good.jar" "$tmp/good-no-endpoint.jar"
test "$(cat "$aws_calls")" = "s3 cp s3://bucket/prefix/good.jar $tmp/good-no-endpoint.jar"

: > "$aws_calls"
S3_ENDPOINT_URL="https://objects.example.test"
s3_prepare_env "plugins"
plugins_dir="$tmp/plugins"
TYPE=paper
PLUGINS_ENABLED=true
PLUGINS_S3_BUCKET=bucket
PLUGINS_S3_PREFIX=prefix
PLUGINS_SYNC_ONCE=false
PLUGINS_REMOVE_EXTRA=false
INPUT_PLUGINS_DIR="$plugins_dir"
install_plugins
test -f "$plugins_dir/good.jar"
test ! -f "$plugins_dir/good.jar.disabled"
test ! -e "$plugins_dir/nested/other.jar"
grep -F 's3api get-object --bucket bucket --key prefix/good.jar' "$aws_calls" >/dev/null
if grep -F 'good.jar.disabled' "$aws_calls" | grep -F 'get-object' >/dev/null; then
  echo "FAIL: disabled jar was copied" >&2
  exit 1
fi

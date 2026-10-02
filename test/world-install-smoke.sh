#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT_DIR}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

source ./scripts/lib/logging.sh
source ./scripts/lib/filesystem.sh
source ./scripts/lib/s3_client.sh
source ./scripts/lib/world_paths.sh
source ./scripts/lib/world_install.sh

archive="$tmp/world.zip"
fixture_dir="$tmp/fixture"
mkdir -p "$fixture_dir/world"
printf '%s\n' world > "$fixture_dir/world/level.dat"
chmod 0400 "$fixture_dir/world/level.dat"
(cd "$fixture_dir" && zip -qr "$archive" world)

configure_calls="$tmp/configure-calls"
aws_calls="$tmp/aws-calls"
: > "$configure_calls"
: > "$aws_calls"

configure_s3_client() {
  printf '%s\n' "$1" >> "$configure_calls"
}

aws() {
  printf '%s\n' "$*" >> "$aws_calls"
  case "$1 $2" in
    "s3api list-objects-v2")
      case "${S3_LS_MODE:-single}" in
        single) printf '%s\n' '{"Contents":[{"Key":"prefix/world.zip"}]}' ;;
        empty)
          printf '%s\n' '{"Contents":[{"Key":"prefix/notes.txt"},{"Key":"prefix/nested.zip/file.txt"}]}'
          ;;
        multiple)
          printf '%s\n' '{"Contents":[{"Key":"prefix/first.zip"},{"Key":"prefix/second.zip"}]}'
          ;;
        *) return 99 ;;
      esac
      ;;
    "s3 cp")
      command cp "$archive" "$4"
      ;;
    *)
      return 99
      ;;
  esac
}

reset_calls() {
  : > "$configure_calls"
  : > "$aws_calls"
}

assert_no_s3_calls() {
  test ! -s "$configure_calls"
  test ! -s "$aws_calls"
}

DATA_DIR="$tmp/disabled-unset"
unset WORLDS_ENABLED
reset_calls
output="$(install_world 2>&1)"
printf '%s\n' "$output" | grep -q 'Worlds disabled'
assert_no_s3_calls
test ! -e "$DATA_DIR/world"

DATA_DIR="$tmp/disabled-false"
WORLDS_ENABLED=false
reset_calls
output="$(install_world 2>&1)"
printf '%s\n' "$output" | grep -q 'Worlds disabled'
assert_no_s3_calls
test ! -e "$DATA_DIR/world"

DATA_DIR="$tmp/success"
WORLDS_ENABLED=true
WORLDS_S3_BUCKET=bucket
WORLDS_S3_PREFIX=prefix/
S3_LS_MODE=single
reset_calls
install_world
test "$(cat "$configure_calls")" = "world"
test "$(sed -n '1p' "$aws_calls")" = "s3api list-objects-v2 --bucket bucket --prefix prefix/ --output json"
case "$(sed -n '2p' "$aws_calls")" in
  "s3 cp s3://bucket/prefix/world.zip /tmp/world."*.zip) ;;
  *) echo "unexpected world archive copy call" >&2; exit 1 ;;
esac
test -f "$DATA_DIR/world/level.dat"
test -r "$DATA_DIR/world/level.dat"
test -w "$DATA_DIR/world/level.dat"

DATA_DIR="$tmp/missing-bucket"
unset WORLDS_S3_BUCKET
WORLDS_S3_PREFIX=prefix
reset_calls
output="$(install_world 2>&1)"
printf '%s\n' "$output" | grep -q 'WORLDS_S3_BUCKET or WORLDS_S3_PREFIX not set, skipping world install'
assert_no_s3_calls
test ! -e "$DATA_DIR/world"

DATA_DIR="$tmp/missing-prefix"
WORLDS_S3_BUCKET=bucket
unset WORLDS_S3_PREFIX
reset_calls
output="$(install_world 2>&1)"
printf '%s\n' "$output" | grep -q 'WORLDS_S3_BUCKET or WORLDS_S3_PREFIX not set, skipping world install'
assert_no_s3_calls
test ! -e "$DATA_DIR/world"

DATA_DIR="$tmp/no-archive"
WORLDS_S3_BUCKET=bucket
WORLDS_S3_PREFIX=prefix
S3_LS_MODE=empty
reset_calls
set +e
output="$(install_world 2>&1)"
status=$?
set -e
test "$status" -eq 1
printf '%s\n' "$output" | grep -q 'No world archive found under s3://bucket/prefix'
test "$(cat "$configure_calls")" = "world"
test "$(cat "$aws_calls")" = "s3api list-objects-v2 --bucket bucket --prefix prefix/ --output json"
test ! -e "$DATA_DIR/world"

DATA_DIR="$tmp/ambiguous-archive"
S3_LS_MODE=multiple
reset_calls
set +e
output="$(install_world 2>&1)"
status=$?
set -e
test "$status" -eq 1
printf '%s\n' "$output" | grep -q 'Ambiguous world archive source under s3://bucket/prefix'
test "$(cat "$configure_calls")" = "world"
test "$(cat "$aws_calls")" = "s3api list-objects-v2 --bucket bucket --prefix prefix/ --output json"
test ! -e "$DATA_DIR/world"

DATA_DIR="$tmp/empty-world"
S3_LS_MODE=single
mkdir -p "$DATA_DIR/world"
reset_calls
install_world
test "$(cat "$configure_calls")" = "world"
test "$(sed -n '1p' "$aws_calls")" = "s3api list-objects-v2 --bucket bucket --prefix prefix/ --output json"
test -f "$DATA_DIR/world/level.dat"

DATA_DIR="$tmp/existing-world"
WORLDS_S3_BUCKET=bucket
WORLDS_S3_PREFIX=prefix
S3_LS_MODE=single
mkdir -p "$DATA_DIR/world"
printf '%s\n' existing > "$DATA_DIR/world/level.dat"
reset_calls
output="$(install_world 2>&1)"
printf '%s\n' "$output" | grep -q 'World already exists, skipping world install'
assert_no_s3_calls
test "$(cat "$DATA_DIR/world/level.dat")" = "existing"

DATA_DIR="$tmp/custom-level"
LEVEL_NAME=custom-world
WORLDS_S3_BUCKET=bucket
WORLDS_S3_PREFIX=prefix
S3_LS_MODE=single
reset_calls
install_world
test -f "$DATA_DIR/custom-world/level.dat"
test ! -e "$DATA_DIR/world"

DATA_DIR="$tmp/custom-level-existing"
LEVEL_NAME=custom-world
mkdir -p "$DATA_DIR/custom-world"
printf '%s\n' existing-custom > "$DATA_DIR/custom-world/level.dat"
reset_calls
output="$(install_world 2>&1)"
printf '%s\n' "$output" | grep -q 'World already exists, skipping world install'
assert_no_s3_calls
test "$(cat "$DATA_DIR/custom-world/level.dat")" = "existing-custom"

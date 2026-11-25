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
source ./scripts/lib/world_reset.sh
source ./scripts/lib/world_install.sh

flag_removals_file="$tmp/flag-removals"
: > "$flag_removals_file"

safe_rm_f() {
  local path="${1:-}"

  if [[ -n "${DATA_DIR:-}" && "${path}" == "${DATA_DIR}/reset-world.flag" ]]; then
    printf '%s\n' "$path" >> "$flag_removals_file"
  fi

  command rm -f -- "$path"
}

reset_flag_removal_count() {
  : > "$flag_removals_file"
}

flag_removal_count() {
  wc -l < "$flag_removals_file"
}

assert_file_absent() {
  local path="$1"

  if [[ -e "$path" ]]; then
    echo "FAIL: expected ${path} to be absent" >&2
    exit 1
  fi
}

assert_file_present() {
  local path="$1"

  if [[ ! -e "$path" ]]; then
    echo "FAIL: expected ${path} to exist" >&2
    exit 1
  fi
}

assert_no_backup_temps() {
  local dir="$1"

  if find "$dir" -maxdepth 1 -name '.world-*.tar.gz.tmp.*' -print -quit 2>/dev/null | grep -q .; then
    echo "FAIL: expected no world reset backup temp files in ${dir}" >&2
    exit 1
  fi
}

assert_flag_removals() {
  local expected="$1"
  local actual

  actual="$(flag_removal_count)"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: expected ${expected} reset flag removals, got ${actual}" >&2
    exit 1
  fi
}

expect_failure() {
  local name="$1"
  shift

  set +e
  "$@" >/dev/null 2>&1
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "FAIL: expected failure for ${name}" >&2
    exit 1
  fi
}

run_successful_reset_consumes_flag_once() {
  DATA_DIR="$tmp/success"
  RESET_WORLD_BACKUP=false
  RESET_WORLD_REMOVE_MODS=false
  mkdir -p "$DATA_DIR/world"
  printf '%s\n' world > "$DATA_DIR/world/level.dat"
  touch "$DATA_DIR/.ready" "$DATA_DIR/reset-world.flag"

  reset_flag_removal_count
  output="$(handle_reset_world_flag 2>&1)"

  assert_file_absent "$DATA_DIR/reset-world.flag"
  assert_file_absent "$DATA_DIR/.ready"
  assert_file_absent "$DATA_DIR/world/level.dat"
  assert_file_absent "$DATA_DIR/world"
  assert_flag_removals 1

  if [[ "$(printf '%s\n' "$output" | grep -c 'reset-world.flag consumed')" != "1" ]]; then
    echo "FAIL: expected one consumed log line" >&2
    exit 1
  fi
}

run_direct_reset_world_consumes_flag_once() {
  DATA_DIR="$tmp/direct"
  RESET_WORLD_BACKUP=false
  RESET_WORLD_REMOVE_MODS=false
  mkdir -p "$DATA_DIR/world"
  printf '%s\n' world > "$DATA_DIR/world/level.dat"
  touch "$DATA_DIR/reset-world.flag"

  reset_flag_removal_count
  output="$(reset_world 2>&1)"

  assert_file_absent "$DATA_DIR/reset-world.flag"
  assert_file_absent "$DATA_DIR/world/level.dat"
  assert_file_absent "$DATA_DIR/world"
  assert_flag_removals 1

  if ! printf '%s\n' "$output" | grep -q 'World reset completed successfully'; then
    echo "FAIL: expected direct reset success log line" >&2
    exit 1
  fi
}

run_absent_flag_skips_reset() {
  DATA_DIR="$tmp/absent"
  RESET_WORLD_BACKUP=false
  RESET_WORLD_REMOVE_MODS=false
  mkdir -p "$DATA_DIR/world"
  printf '%s\n' world > "$DATA_DIR/world/level.dat"

  reset_flag_removal_count
  output="$(handle_reset_world_flag 2>&1)"

  assert_file_present "$DATA_DIR/world/level.dat"
  assert_flag_removals 0

  if ! printf '%s\n' "$output" | grep -q 'No reset-world.flag detected, skipping world reset'; then
    echo "FAIL: expected no-reset log line" >&2
    exit 1
  fi
}

run_missing_world_consumes_flag_once() {
  DATA_DIR="$tmp/missing-world"
  RESET_WORLD_BACKUP=false
  RESET_WORLD_REMOVE_MODS=false
  mkdir -p "$DATA_DIR"
  touch "$DATA_DIR/reset-world.flag"

  reset_flag_removal_count
  output="$(handle_reset_world_flag 2>&1)"

  assert_file_absent "$DATA_DIR/reset-world.flag"
  assert_flag_removals 1

  if ! printf '%s\n' "$output" | grep -q 'World directory does not exist, nothing to reset'; then
    echo "FAIL: expected missing-world log line" >&2
    exit 1
  fi
}

run_expired_flag_is_removed_once() {
  DATA_DIR="$tmp/expired"
  RESET_WORLD_BACKUP=false
  RESET_WORLD_REMOVE_MODS=false
  mkdir -p "$DATA_DIR/world"
  touch -d '1 hour ago' "$DATA_DIR/reset-world.flag"

  reset_flag_removal_count
  output="$(handle_reset_world_flag 2>&1)"

  assert_file_absent "$DATA_DIR/reset-world.flag"
  assert_file_present "$DATA_DIR/world"
  assert_flag_removals 1

  if ! printf '%s\n' "$output" | grep -q 'reset-world.flag expired'; then
    echo "FAIL: expected expired-flag log line" >&2
    exit 1
  fi
}

run_backup_success_publishes_final_archive_only() {
  DATA_DIR="$tmp/backup-success"
  RESET_WORLD_BACKUP=true
  RESET_WORLD_REMOVE_MODS=false
  mkdir -p "$DATA_DIR/world"
  printf '%s\n' world > "$DATA_DIR/world/level.dat"
  touch "$DATA_DIR/reset-world.flag"

  reset_flag_removal_count
  reset_world >/dev/null 2>&1

  assert_file_absent "$DATA_DIR/reset-world.flag"
  assert_file_absent "$DATA_DIR/world"
  assert_no_backup_temps "$DATA_DIR/backups"
  test "$(find "$DATA_DIR/backups" -maxdepth 1 -type f -name 'world-*.tar.gz' | wc -l)" -eq 1
}

run_reset_then_installs_s3_world() {
  DATA_DIR="$tmp/reset-then-install"
  RESET_WORLD_BACKUP=false
  RESET_WORLD_REMOVE_MODS=false
  WORLDS_ENABLED=true
  WORLDS_S3_BUCKET=bucket
  WORLDS_S3_PREFIX=world

  mkdir -p "$DATA_DIR/world"
  printf '%s\n' old-world > "$DATA_DIR/world/level.dat"
  touch "$DATA_DIR/reset-world.flag"

  local fixture_dir="$tmp/reset-install-fixture"
  local fixture_archive="$tmp/reset-install-world.zip"
  local aws_calls="$tmp/reset-install-aws-calls"
  mkdir -p "$fixture_dir/world"
  printf '%s\n' s3-world > "$fixture_dir/world/level.dat"
  (cd "$fixture_dir" && zip -qr "$fixture_archive" world)
  : > "$aws_calls"

  configure_s3_client() {
    test "$1" = "world"
  }

  aws() {
    printf '%s\n' "$*" >> "$aws_calls"
    case "$1 $2" in
      "s3api list-objects-v2")
        printf '%s\n' '{"Contents":[{"Key":"world/world.zip"}]}'
        ;;
      "s3 cp")
        test "$3" = "s3://bucket/world/world.zip"
        command cp "$fixture_archive" "$4"
        ;;
      *)
        return 99
        ;;
    esac
  }

  handle_reset_world_flag >/dev/null 2>&1
  assert_file_absent "$DATA_DIR/reset-world.flag"
  assert_file_absent "$DATA_DIR/world"

  install_world >/dev/null 2>&1
  assert_file_present "$DATA_DIR/world/level.dat"
  test "$(cat "$DATA_DIR/world/level.dat")" = "s3-world"
  test "$(sed -n '1p' "$aws_calls")" = "s3api list-objects-v2 --bucket bucket --prefix world/ --output json"
}

run_backup_failure_removes_staged_archive() {
  DATA_DIR="$tmp/backup-failure"
  RESET_WORLD_BACKUP=true
  RESET_WORLD_REMOVE_MODS=false
  mkdir -p "$DATA_DIR/world"
  printf '%s\n' world > "$DATA_DIR/world/level.dat"
  touch "$DATA_DIR/reset-world.flag"

  local fail_bin="$tmp/backup-failure-bin"
  mkdir -p "$fail_bin"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "printf '%s\\n' partial > \"\$2\""
    printf '%s\n' 'exit 7'
  } > "$fail_bin/tar"
  chmod +x "$fail_bin/tar"

  reset_flag_removal_count
  set +e
  output="$(
    PATH="$fail_bin:$PATH"
    reset_world 2>&1
  )"
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "FAIL: expected backup failure to fail reset" >&2
    exit 1
  fi

  assert_file_present "$DATA_DIR/reset-world.flag"
  assert_file_present "$DATA_DIR/world/level.dat"
  assert_flag_removals 0
  assert_no_backup_temps "$DATA_DIR/backups"
  test "$(find "$DATA_DIR/backups" -maxdepth 1 -type f -name 'world-*.tar.gz' | wc -l)" -eq 0

  if ! printf '%s\n' "$output" | grep -q 'World backup failed; refusing to delete world'; then
    echo "FAIL: expected backup failure log line" >&2
    exit 1
  fi
}

run_unsafe_reset_paths_are_rejected() {
  expect_failure \
    "empty DATA_DIR reset paths" \
    validate_world_reset_paths "" "/world" "/reset-world.flag" "/backups" "" "" false false

  expect_failure \
    "root DATA_DIR reset paths" \
    validate_world_reset_paths "/" "/world" "/reset-world.flag" "/backups" "" "" false false

  local data_root="$tmp/data-root"
  mkdir -p "$data_root"
  expect_failure \
    "WORLD_DIR equals DATA_DIR" \
    validate_world_reset_paths \
      "$data_root" \
      "$data_root" \
      "$data_root/reset-world.flag" \
      "$data_root/backups" \
      "" \
      "$data_root/mods" \
      false \
      false
}

run_relative_data_dir_reset_is_rejected() {
  local case_dir="$tmp/relative-case"
  mkdir -p "$case_dir/relative-data/world"
  printf '%s\n' world > "$case_dir/relative-data/world/level.dat"
  touch "$case_dir/relative-data/reset-world.flag"

  reset_flag_removal_count
  set +e
  output="$(
    cd "$case_dir"
    DATA_DIR="relative-data"
    RESET_WORLD_BACKUP=false
    RESET_WORLD_REMOVE_MODS=false
    reset_world 2>&1
  )"
  local status=$?
  set -e

  if [[ "$status" -eq 0 ]]; then
    echo "FAIL: expected relative DATA_DIR reset to fail" >&2
    exit 1
  fi

  assert_file_present "$case_dir/relative-data/reset-world.flag"
  assert_file_present "$case_dir/relative-data/world/level.dat"
  assert_flag_removals 0

  if ! printf '%s\n' "$output" | grep -q 'Refusing unsafe world reset path'; then
    echo "FAIL: expected unsafe reset path log line" >&2
    exit 1
  fi
}

run_custom_level_name_reset_uses_matching_world_dir() {
  DATA_DIR="$tmp/custom-level-reset"
  LEVEL_NAME=custom-world
  RESET_WORLD_BACKUP=true
  RESET_WORLD_REMOVE_MODS=false
  mkdir -p "$DATA_DIR/custom-world" "$DATA_DIR/world"
  printf '%s\n' custom > "$DATA_DIR/custom-world/level.dat"
  printf '%s\n' default > "$DATA_DIR/world/level.dat"
  touch "$DATA_DIR/reset-world.flag"

  reset_flag_removal_count
  reset_world >/dev/null 2>&1

  assert_file_absent "$DATA_DIR/custom-world"
  assert_file_present "$DATA_DIR/world/level.dat"
  test "$(cat "$DATA_DIR/world/level.dat")" = "default"
  assert_file_absent "$DATA_DIR/reset-world.flag"
  assert_flag_removals 1

  local backup_archive
  backup_archive="$(find "$DATA_DIR/backups" -maxdepth 1 -type f -name 'world-*.tar.gz' -print)"
  test "$(printf '%s\n' "$backup_archive" | sed '/^$/d' | wc -l)" -eq 1

  tar -tzf "$backup_archive" | grep -Fx 'custom-world/level.dat' >/dev/null
  if tar -tzf "$backup_archive" | grep -Fx 'world/level.dat' >/dev/null; then
    echo "FAIL: backup archive included unrelated default world" >&2
    exit 1
  fi

  unset LEVEL_NAME
}

run_dash_prefixed_level_name_backup_archives_member() {
  DATA_DIR="$tmp/dash-prefixed-level-reset"
  LEVEL_NAME=--checkpoint=1
  RESET_WORLD_BACKUP=true
  RESET_WORLD_REMOVE_MODS=false
  mkdir -p "$DATA_DIR/$LEVEL_NAME"
  printf '%s\n' dash > "$DATA_DIR/$LEVEL_NAME/level.dat"
  touch "$DATA_DIR/reset-world.flag"

  reset_flag_removal_count
  reset_world >/dev/null 2>&1

  assert_file_absent "$DATA_DIR/$LEVEL_NAME"
  assert_file_absent "$DATA_DIR/reset-world.flag"
  assert_no_backup_temps "$DATA_DIR/backups"
  assert_flag_removals 1

  local backup_archive
  backup_archive="$(find "$DATA_DIR/backups" -maxdepth 1 -type f -name 'world-*.tar.gz' -print)"
  test "$(printf '%s\n' "$backup_archive" | sed '/^$/d' | wc -l)" -eq 1
  tar -tzf "$backup_archive" | grep -Fx -- '--checkpoint=1/level.dat' >/dev/null

  unset LEVEL_NAME
}


run_managed_world_names_are_rejected() (
  DATA_DIR="$tmp/reserved-worlds"
  RESET_WORLD_BACKUP=true
  RESET_WORLD_REMOVE_MODS=false
  mkdir -p "$DATA_DIR"
  touch "$DATA_DIR/reset-world.flag"
  local name
  for name in backups mods plugins config logs libraries versions resourcepacks datapacks crash-reports .managed; do
    LEVEL_NAME="$name"
    mkdir -p "$DATA_DIR/$name"
    printf '%s\n' keep > "$DATA_DIR/$name/sentinel"
    expect_failure "reserved world name $name" reset_world
    test "$(cat "$DATA_DIR/$name/sentinel")" = keep
    assert_file_present "$DATA_DIR/reset-world.flag"
  done
)

run_invalid_reset_options_preserve_world() (
  DATA_DIR="$tmp/invalid-reset-options"
  mkdir -p "$DATA_DIR/world"
  printf '%s\n' keep > "$DATA_DIR/world/level.dat"
  touch "$DATA_DIR/reset-world.flag"
  RESET_WORLD_BACKUP=TRUE
  RESET_WORLD_REMOVE_MODS=false
  expect_failure "invalid backup option" reset_world
  RESET_WORLD_BACKUP=true
  RESET_WORLD_REMOVE_MODS=maybe
  expect_failure "invalid remove-mods option" reset_world
  test "$(cat "$DATA_DIR/world/level.dat")" = keep
  assert_file_present "$DATA_DIR/reset-world.flag"
  assert_file_absent "$DATA_DIR/backups"
)

run_symlink_reset_paths_are_rejected() (
  DATA_DIR="$tmp/symlink-reset"
  RESET_WORLD_BACKUP=true
  RESET_WORLD_REMOVE_MODS=false
  mkdir -p "$DATA_DIR/nested/world" "$DATA_DIR/nested/backups"
  printf '%s\n' keep > "$DATA_DIR/nested/world/level.dat"
  touch "$DATA_DIR/reset-world.flag"
  ln -s nested/world "$DATA_DIR/world"
  expect_failure "symlink world" reset_world
  test "$(cat "$DATA_DIR/nested/world/level.dat")" = keep
  test -L "$DATA_DIR/world"
  rm -- "$DATA_DIR/world"
  mkdir "$DATA_DIR/world"
  printf '%s\n' keep > "$DATA_DIR/world/level.dat"
  ln -s nested/backups "$DATA_DIR/backups"
  expect_failure "symlink backups" reset_world
  test "$(cat "$DATA_DIR/world/level.dat")" = keep
  assert_file_present "$DATA_DIR/reset-world.flag"
)

run_successful_reset_consumes_flag_once
run_direct_reset_world_consumes_flag_once
run_absent_flag_skips_reset
run_missing_world_consumes_flag_once
run_expired_flag_is_removed_once
run_backup_success_publishes_final_archive_only
run_reset_then_installs_s3_world
run_backup_failure_removes_staged_archive
run_unsafe_reset_paths_are_rejected
run_relative_data_dir_reset_is_rejected
run_custom_level_name_reset_uses_matching_world_dir
run_dash_prefixed_level_name_backup_archives_member

run_managed_world_names_are_rejected
run_invalid_reset_options_preserve_world
run_symlink_reset_paths_are_rejected

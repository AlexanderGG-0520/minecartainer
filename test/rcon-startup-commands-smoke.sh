#!/usr/bin/env bash
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log() {
  :
}

make_fake_rcon() {
  local bin_dir="$1"

  mkdir -p "$bin_dir"
  cat > "$bin_dir/rcon-cli" <<'RCON'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMP_DIR/commands.txt"
if [[ "$*" == *" fail-now" ]]; then
  exit 1
fi
RCON
  chmod +x "$bin_dir/rcon-cli"
}

setup_rcon_env() {
  TMP_DIR="$tmp/$1"
  export TMP_DIR
  mkdir -p "$TMP_DIR/bin"
  make_fake_rcon "$TMP_DIR/bin"
  PATH="$TMP_DIR/bin:$ORIGINAL_PATH"
  export PATH

  DATA_DIR="$TMP_DIR/data"
  ENABLE_RCON=true
  RCON_HOST=127.0.0.1
  RCON_PORT=25575
  RCON_PASSWORD=secret
  RCON_TIMEOUT=1
  RCON_RETRIES=1
  RCON_RETRY_DELAY=0
  TYPE=paper
  export DATA_DIR ENABLE_RCON RCON_HOST RCON_PORT RCON_PASSWORD RCON_TIMEOUT RCON_RETRIES RCON_RETRY_DELAY TYPE

  mkdir -p "$DATA_DIR"
  : > "$TMP_DIR/commands.txt"
}

assert_command() {
  local line="$1"
  local expected="$2"
  local actual

  actual="$(sed -n "$line"p "$TMP_DIR/commands.txt")"
  [[ "$actual" == "$expected" ]] || {
    printf 'expected command %s: %s\nactual: %s\n' "$line" "$expected" "$actual" >&2
    return 1
  }
}

run_order_and_blank_line_smoke() {
  setup_rcon_env order
  RCON_CMDS_STARTUP=$'gamerule doFireTick false\n \n  say ready\n'
  export RCON_CMDS_STARTUP

  run_rcon_startup_commands

  assert_command 1 "--host 127.0.0.1 --port 25575 --password secret gamerule doFireTick false"
  assert_command 2 "--host 127.0.0.1 --port 25575 --password secret   say ready"
  [[ "$(wc -l < "$TMP_DIR/commands.txt")" -eq 2 ]]
}

run_failure_stops_sequence_smoke() {
  setup_rcon_env failure
  RCON_CMDS_STARTUP=$'first-command\nfail-now\nthird-command'
  export RCON_CMDS_STARTUP

  set +e
  run_rcon_startup_commands
  local rc=$?
  set -e

  [[ "$rc" -ne 0 ]]
  assert_command 1 "--host 127.0.0.1 --port 25575 --password secret first-command"
  assert_command 2 "--host 127.0.0.1 --port 25575 --password secret fail-now"
  [[ "$(wc -l < "$TMP_DIR/commands.txt")" -eq 2 ]]
}

run_validation_smoke() {
  setup_rcon_env validation
  RCON_CMDS_STARTUP=list
  ENABLE_RCON=false
  export RCON_CMDS_STARTUP ENABLE_RCON

  set +e
  validate_rcon_startup_commands_config
  local rc=$?
  set -e
  [[ "$rc" -ne 0 ]]

  ENABLE_RCON=true
  TYPE=velocity
  export ENABLE_RCON TYPE
  set +e
  validate_rcon_startup_commands_config
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]]
}

ORIGINAL_PATH="$PATH"
export ORIGINAL_PATH

# shellcheck source=scripts/lib/numeric_validation.sh
source "$repo/scripts/lib/numeric_validation.sh"
# shellcheck source=scripts/lib/rcon.sh
source "$repo/scripts/lib/rcon.sh"

run_order_and_blank_line_smoke
run_failure_stops_sequence_smoke
run_validation_smoke

printf 'rcon startup commands smoke passed\n'

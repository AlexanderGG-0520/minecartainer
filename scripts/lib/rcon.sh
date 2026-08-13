# shellcheck shell=bash

rcon_client() {
  if command -v rcon-cli >/dev/null 2>&1; then
    echo "rcon-cli"
    return 0
  fi
  if command -v mcrcon >/dev/null 2>&1; then
    echo "mcrcon"
    return 0
  fi
  return 1
}

rcon_exec() {
  local command="$*"
  local attempt=1

  validate_shutdown_numeric_value rcon RCON_RETRIES positive "${RCON_RETRIES:-}" || return 1
  validate_shutdown_numeric_value rcon RCON_RETRY_DELAY nonnegative "${RCON_RETRY_DELAY:-}" || return 1
  validate_shutdown_numeric_value rcon RCON_TIMEOUT positive "${RCON_TIMEOUT:-}" || return 1

  if [[ "${ENABLE_RCON}" != "true" ]]; then
    log INFO "RCON disabled, skipping command: ${command}"
    return 1
  fi

  if [[ -z "${RCON_PASSWORD:-}" ]]; then
    log ERROR "RCON_PASSWORD is empty, cannot execute: ${command}"
    return 1
  fi

  local client
  if ! client="$(rcon_client)"; then
    log ERROR "No RCON client found (rcon-cli or mcrcon), cannot execute: ${command}"
    return 1
  fi

  while true; do
    log INFO "[rcon] exec attempt ${attempt}/${RCON_RETRIES}: ${command}"
    if [[ "${client}" == "rcon-cli" ]]; then
      if timeout "${RCON_TIMEOUT}" \
        rcon-cli --host "${RCON_HOST}" --port "${RCON_PORT}" --password "${RCON_PASSWORD}" "${command}"; then
        log INFO "[rcon] exec succeeded: ${command}"
        return 0
      fi
    else
      if timeout "${RCON_TIMEOUT}" \
        mcrcon -H "${RCON_HOST}" -P "${RCON_PORT}" -p "${RCON_PASSWORD}" "${command}"; then
        log INFO "[rcon] exec succeeded: ${command}"
        return 0
      fi
    fi

    if (( attempt >= RCON_RETRIES )); then
      log ERROR "RCON command failed after ${attempt} attempts: ${command}"
      return 1
    fi

    log WARN "RCON command failed (attempt ${attempt}/${RCON_RETRIES}), retrying: ${command}"
    attempt=$((attempt + 1))
    sleep "${RCON_RETRY_DELAY}"
  done
}


rcon_startup_commands_configured() {
  [[ -n "${RCON_CMDS_STARTUP//[[:space:]]/}" ]]
}

validate_rcon_startup_commands_config() {
  rcon_startup_commands_configured || return 0

  if [[ "${ENABLE_RCON:-false}" != "true" ]]; then
    log ERROR "RCON_CMDS_STARTUP requires ENABLE_RCON=true"
    return 1
  fi

  if [[ "${TYPE:-}" == "velocity" ]]; then
    log ERROR "RCON_CMDS_STARTUP is not supported for TYPE=velocity"
    return 1
  fi

  return 0
}

run_rcon_startup_commands() {
  local command
  local command_number=0
  local executed=0

  rcon_startup_commands_configured || return 0
  validate_rcon_startup_commands_config || return 1

  while IFS= read -r command || [[ -n "${command}" ]]; do
    command_number=$((command_number + 1))

    [[ "${command}" =~ ^[[:space:]]*$ ]] && continue

    executed=$((executed + 1))
    log INFO "[rcon] startup command ${executed} (line ${command_number}): ${command}"
    if ! rcon_exec "${command}"; then
      log ERROR "[rcon] startup command ${executed} failed: ${command}"
      return 1
    fi
  done <<< "${RCON_CMDS_STARTUP}"

  log INFO "[rcon] completed ${executed} startup command(s)"
}

rcon_say() {
  rcon_exec "say $*"
}

rcon_tellraw_all() {
  local message="$*"
  local shown
  shown="$(json_escape "$message")"

  # tellraw first; if it fails, fallback to say
  if ! rcon_exec "tellraw @a {\"text\":\"${shown}\",\"color\":\"yellow\"}"; then
    log WARN "tellraw failed; falling back to say"
    rcon_exec "say ${message}" || true
    return 1
  fi
  return 0
}

rcon_stop() {
  if [[ "${ENABLE_RCON}" != "true" ]]; then
    log INFO "RCON disabled, skipping rcon_stop"
    return 1
  fi

  local delay="${STOP_SERVER_ANNOUNCE_DELAY:-0}"
  local save_wait="${SHUTDOWN_SAVE_WAIT_SECONDS:-3}"
  local save_succeeded=0
  local citizens_file="${DATA_DIR}/plugins/Citizens/saves.yml"

  validate_shutdown_numeric_value shutdown STOP_SERVER_ANNOUNCE_DELAY nonnegative "${delay}" || return 1
  validate_shutdown_numeric_value shutdown SHUTDOWN_SAVE_WAIT_SECONDS nonnegative "${save_wait}" || return 1

  if [[ -f "${citizens_file}" ]]; then
    log INFO "Citizens data detected: ${citizens_file}"
  else
    log INFO "Citizens data not found at shutdown: ${citizens_file}"
  fi

  if (( delay > 0 )); then
    log INFO "[shutdown] rcon: announce shutdown delay ${delay}s"
    rcon_tellraw_all "Server shutting down in ${delay} seconds." || true
    sleep "${delay}"
  else
    log INFO "[shutdown] rcon: immediate shutdown announcement skipped to prioritize save/stop"
  fi

  log INFO "[shutdown] rcon: citizens save"
  if rcon_exec "citizens save"; then
    log INFO "[shutdown] rcon: citizens save succeeded"
  else
    log WARN "[shutdown] rcon: citizens save failed"
  fi

  log INFO "[shutdown] rcon: save-all flush"
  if rcon_exec "save-all flush"; then
    log INFO "[shutdown] rcon: save-all flush succeeded"
    save_succeeded=1
  else
    log WARN "[shutdown] rcon: save-all flush failed; falling back to save-all"
    log INFO "[shutdown] rcon: save-all fallback"
    if rcon_exec "save-all"; then
      log WARN "[shutdown] rcon: save-all fallback succeeded after save-all flush failure"
      save_succeeded=1
    else
      log ERROR "[shutdown] rcon: save-all fallback failed; continuing to stop without explicit save confirmation"
    fi
  fi

  if (( save_succeeded == 1 && save_wait > 0 )); then
    log INFO "[shutdown] waiting ${save_wait}s after save before stop"
    sleep "${save_wait}"
  elif (( save_succeeded == 0 )); then
    log WARN "[shutdown] explicit save commands failed; skipping save wait and sending stop"
  fi

  log INFO "[shutdown] rcon: stop"
  if rcon_exec "stop"; then
    log INFO "[shutdown] rcon: stop succeeded"
  else
    log WARN "[shutdown] rcon: stop failed"
    return 1
  fi

  return 0
}

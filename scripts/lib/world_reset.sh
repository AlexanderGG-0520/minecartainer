# shellcheck shell=bash

validate_world_reset_flag_path() {
  local data_dir="${1:-}"
  local flag_path="${2:-}"

  if [[ -z "${data_dir}" ]]; then
    log ERROR "DATA_DIR is required for world reset"
    return 1
  fi

  if [[ -z "${flag_path}" ]]; then
    log ERROR "Refusing unsafe reset flag path"
    return 1
  fi

  if [[ "${data_dir}" != /* || "${data_dir}" == "/" ]]; then
    log ERROR "Refusing unsafe reset flag path"
    return 1
  fi

  if [[ -L "${flag_path}" || "${flag_path}" != "${data_dir}/reset-world.flag" ]]; then
    log ERROR "Refusing unsafe reset flag path"
    return 1
  fi

  case "${flag_path}" in
    /|/reset-world.flag|/tmp/reset-world.flag|/data)
      log ERROR "Refusing unsafe reset flag path"
      return 1
      ;;
  esac

  if [[ "${flag_path}" == "${data_dir}" ]]; then
    log ERROR "Refusing unsafe reset flag path"
    return 1
  fi

  if ! command -v realpath >/dev/null 2>&1; then
    log ERROR "Refusing unsafe reset flag path"
    return 1
  fi

  local resolved_data_dir resolved_flag_path expected_flag_path
  if ! resolved_data_dir="$(realpath -m -- "${data_dir}")"; then
    log ERROR "Refusing unsafe reset flag path"
    return 1
  fi

  if ! resolved_flag_path="$(realpath -m -- "${flag_path}")"; then
    log ERROR "Refusing unsafe reset flag path"
    return 1
  fi

  if ! expected_flag_path="$(realpath -m -- "${resolved_data_dir}/reset-world.flag")"; then
    log ERROR "Refusing unsafe reset flag path"
    return 1
  fi

  if [[ "${resolved_data_dir}" == "/" ||
    "${resolved_flag_path}" == "/" ||
    "${resolved_flag_path}" == "/reset-world.flag" ||
    "${resolved_flag_path}" == "/tmp/reset-world.flag" ||
    "${resolved_flag_path}" == "/data" ||
    "${resolved_flag_path}" == "${resolved_data_dir}" ||
    "${resolved_flag_path}" != "${expected_flag_path}" ||
    "${resolved_flag_path##*/}" != "reset-world.flag" ]]; then
    log ERROR "Refusing unsafe reset flag path"
    return 1
  fi

  case "${resolved_flag_path}" in
    "${resolved_data_dir}"/*) ;;
    *)
      log ERROR "Refusing unsafe reset flag path"
      return 1
      ;;
  esac

  return 0
}

remove_reset_world_flag() {
  local data_dir="${1:-}"
  local flag_path="${2:-}"

  validate_world_reset_flag_path "${data_dir}" "${flag_path}" || return 1
  safe_rm_f "${flag_path}"
}

cleanup_world_reset_backup_tmp() {
  local tmp="${1:-}"

  [[ -z "${tmp}" ]] || safe_rm_f "${tmp}"
}

create_world_reset_backup() {
  local data_dir="$1"
  local backup_dir="$2"
  local backup_archive="$3"
  local world_dir="$4"
  local backup_base
  local backup_tmp=""
  local world_name

  backup_base="$(basename "${backup_archive}")"
  world_name="$(basename "${world_dir}")"

  mkdir -p "${backup_dir}" || return 1
  backup_tmp="$(mktemp "${backup_dir}/.${backup_base}.tmp.XXXXXX")" || return 1

  local umask_value mode
  umask_value="$(umask)" || { cleanup_world_reset_backup_tmp "${backup_tmp}"; return 1; }
  mode=$((0666 & ~8#${umask_value}))
  printf -v mode '%03o' "${mode}"
  chmod "${mode}" -- "${backup_tmp}" || { cleanup_world_reset_backup_tmp "${backup_tmp}"; return 1; }

  if ! tar -czf "${backup_tmp}" -C "${data_dir}" -- "${world_name}"; then
    cleanup_world_reset_backup_tmp "${backup_tmp}"
    return 1
  fi

  if ! safe_mv_f "${backup_tmp}" "${backup_archive}"; then
    cleanup_world_reset_backup_tmp "${backup_tmp}"
    return 1
  fi

  cleanup_world_reset_backup_tmp "${backup_tmp}"
}

validate_world_reset_paths() {
  local data_dir="${1:-}"
  local world_dir="${2:-}"
  local flag_file="${3:-}"
  local backup_dir="${4:-}"
  local backup_archive="${5:-}"
  local mods_dir="${6:-}"
  local remove_mods="${7:-false}"
  local backup_enabled="${8:-true}"
  local expected_world_dir_literal

  if [[ -z "${data_dir}" ]]; then
    log ERROR "DATA_DIR is required for world reset"
    return 1
  fi

  if [[ -z "${world_dir}" ||
    -z "${flag_file}" ||
    -z "${backup_dir}" ||
    "${data_dir}" != /* ||
    "${data_dir}" == "/" ]]; then
    log ERROR "Refusing unsafe world reset path"
    return 1
  fi

  expected_world_dir_literal="$(minecraft_world_dir "${data_dir}")" || return 1
  if [[ "${world_dir}" != "${expected_world_dir_literal}" ||
    "${backup_dir}" != "${data_dir}/backups" ||
    -L "${world_dir}" || -L "${backup_dir}" || -L "${flag_file}" ]]; then
    log ERROR "Refusing unsafe world reset path"
    return 1
  fi

  if [[ "${flag_file}" != "${data_dir}/reset-world.flag" ]]; then
    log ERROR "Refusing unsafe reset flag path"
    return 1
  fi

  case "${world_dir}" in
    /|/world|/tmp|/data)
      log ERROR "Refusing unsafe world reset path"
      return 1
      ;;
  esac

  if [[ "${world_dir}" == "${data_dir}" ]]; then
    log ERROR "Refusing unsafe world reset path"
    return 1
  fi

  if ! command -v realpath >/dev/null 2>&1; then
    log ERROR "Refusing unsafe world reset path"
    return 1
  fi

  local resolved_data_dir resolved_world_dir expected_world_dir expected_world_name
  local resolved_flag_file expected_flag_file
  local resolved_backup_dir expected_backup_dir resolved_backup_archive
  if ! resolved_data_dir="$(realpath -m -- "${data_dir}")"; then
    log ERROR "Refusing unsafe world reset path"
    return 1
  fi

  if ! resolved_world_dir="$(realpath -m -- "${world_dir}")"; then
    log ERROR "Refusing unsafe world reset path"
    return 1
  fi

  expected_world_name="$(minecraft_world_name)" || return 1
  if ! expected_world_dir="$(realpath -m -- "${resolved_data_dir}/${expected_world_name}")"; then
    log ERROR "Refusing unsafe world reset path"
    return 1
  fi

  if ! resolved_flag_file="$(realpath -m -- "${flag_file}")"; then
    log ERROR "Refusing unsafe reset flag path"
    return 1
  fi

  if ! expected_flag_file="$(realpath -m -- "${resolved_data_dir}/reset-world.flag")"; then
    log ERROR "Refusing unsafe reset flag path"
    return 1
  fi

  if ! resolved_backup_dir="$(realpath -m -- "${backup_dir}")"; then
    log ERROR "Refusing unsafe world reset path"
    return 1
  fi

  if ! expected_backup_dir="$(realpath -m -- "${resolved_data_dir}/backups")"; then
    log ERROR "Refusing unsafe world reset path"
    return 1
  fi

  if [[ "${resolved_data_dir}" == "/" ||
    "${resolved_world_dir}" == "/" ||
    "${resolved_world_dir}" == "/world" ||
    "${resolved_world_dir}" == "/tmp" ||
    "${resolved_world_dir}" == "/data" ||
    "${resolved_world_dir}" == "${resolved_data_dir}" ||
    "${resolved_world_dir}" != "${expected_world_dir}" ||
    "${resolved_world_dir##*/}" != "${expected_world_name}" ||
    "${resolved_flag_file}" != "${expected_flag_file}" ||
    "${resolved_flag_file##*/}" != "reset-world.flag" ||
    "${resolved_backup_dir}" != "${expected_backup_dir}" ||
    "${resolved_backup_dir}" == "${resolved_data_dir}" ||
    "${resolved_backup_dir##*/}" != "backups" ]]; then
    log ERROR "Refusing unsafe world reset path"
    return 1
  fi

  case "${resolved_world_dir}" in
    "${resolved_data_dir}"/*) ;;
    *)
      log ERROR "Refusing unsafe world reset path"
      return 1
      ;;
  esac

  case "${resolved_flag_file}" in
    "${resolved_data_dir}"/*) ;;
    *)
      log ERROR "Refusing unsafe reset flag path"
      return 1
      ;;
  esac

  case "${resolved_backup_dir}" in
    "${resolved_data_dir}"/*) ;;
    *)
      log ERROR "Refusing unsafe world reset path"
      return 1
      ;;
  esac

  if [[ "${backup_enabled}" == "true" ]]; then
    if [[ -z "${backup_archive}" ]]; then
      log ERROR "Refusing unsafe world reset path"
      return 1
    fi

    if ! resolved_backup_archive="$(realpath -m -- "${backup_archive}")"; then
      log ERROR "Refusing unsafe world reset path"
      return 1
    fi

    case "${resolved_backup_archive}" in
      "${resolved_backup_dir}"/*) ;;
      *)
        log ERROR "Refusing unsafe world reset path"
        return 1
        ;;
    esac
  fi

  if [[ "${remove_mods}" == "true" ]]; then
    if [[ -z "${mods_dir}" || "${mods_dir}" != "${data_dir}/mods" || -L "${mods_dir}" ]]; then
      log ERROR "Refusing unsafe world reset path"
      return 1
    fi

    local resolved_mods_dir expected_mods_dir
    if ! resolved_mods_dir="$(realpath -m -- "${mods_dir}")"; then
      log ERROR "Refusing unsafe world reset path"
      return 1
    fi

    if ! expected_mods_dir="$(realpath -m -- "${resolved_data_dir}/mods")"; then
      log ERROR "Refusing unsafe world reset path"
      return 1
    fi

    if [[ "${resolved_mods_dir}" == "/" ||
      "${resolved_mods_dir}" == "/mods" ||
      "${resolved_mods_dir}" == "/tmp" ||
      "${resolved_mods_dir}" == "/data" ||
      "${resolved_mods_dir}" == "${resolved_data_dir}" ||
      "${resolved_mods_dir}" == "${resolved_world_dir}" ||
      "${resolved_mods_dir}" != "${expected_mods_dir}" ||
      "${resolved_mods_dir##*/}" != "mods" ]]; then
      log ERROR "Refusing unsafe world reset path"
      return 1
    fi

    case "${resolved_mods_dir}" in
      "${resolved_data_dir}"/*) ;;
      *)
        log ERROR "Refusing unsafe world reset path"
        return 1
        ;;
    esac
  fi

  return 0
}

reset_world() {
  log INFO "Requested world reset"

  local data_dir="${DATA_DIR:-}"
  local flag_file="${data_dir}/reset-world.flag"  # flag file path
  local world_dir
  local mods_dir="${data_dir}/mods"
  local backup_dir="${data_dir}/backups"
  local backup_archive=""

  world_dir="$(minecraft_world_dir "${data_dir}")" || return 1

  # ---- Safety check 1: explicit confirmation ----
  if [[ ! -f "${flag_file}" ]]; then
    log INFO "reset-world.flag file is missing, cannot proceed with world reset"
    return  # return instead of die to avoid stopping the script
  fi

  # A typo must not silently disable the backup.
  case "${RESET_WORLD_BACKUP-true}" in
    true|false) ;;
    *) log ERROR "RESET_WORLD_BACKUP must be true or false"; return 1 ;;
  esac
  case "${RESET_WORLD_REMOVE_MODS-false}" in
    true|false) ;;
    *) log ERROR "RESET_WORLD_REMOVE_MODS must be true or false"; return 1 ;;
  esac

  if [[ "${RESET_WORLD_BACKUP:-true}" == "true" ]]; then
    local timestamp
    timestamp="$(date -u +'%Y%m%d-%H%M%S')"
    backup_archive="${backup_dir}/world-${timestamp}.tar.gz"
  fi

  validate_world_reset_paths \
    "${data_dir}" \
    "${world_dir}" \
    "${flag_file}" \
    "${backup_dir}" \
    "${backup_archive}" \
    "${mods_dir}" \
    "${RESET_WORLD_REMOVE_MODS:-false}" \
    "${RESET_WORLD_BACKUP:-true}" || return 1

  # ---- Safety check 2: directory sanity ----
  if [[ ! -d "${world_dir}" ]]; then
    log INFO "World directory does not exist, nothing to reset"
    return
  fi

  if [[ "${world_dir}" == "/" || "${world_dir}" == "${data_dir}" ]]; then
    log ERROR "Unsafe WORLD_DIR detected: ${world_dir}"
    return  # stop instead of die
  fi

  log INFO "Resetting world at ${world_dir}"

  # ---- Step 1: mark NotReady ----
  safe_rm_f "${data_dir}/.ready"

  # ---- Step 2: optional backup ----
  if [[ "${RESET_WORLD_BACKUP:-true}" == "true" ]]; then
    log INFO "Creating world backup"
    create_world_reset_backup "${data_dir}" "${backup_dir}" "${backup_archive}" "${world_dir}" \
      || die "World backup failed; refusing to delete world"
  fi

  # ---- Step 3: delete world directory completely ----
  log INFO "Deleting world directory"
  safe_rm_rf "${world_dir}" || return 1
  if [[ "${RESET_WORLD_REMOVE_MODS:-false}" == "true" ]]; then
    log WARN "RESET_WORLD_REMOVE_MODS=true, deleting mods directory"
    safe_rm_rf "${mods_dir}" || return 1
    mkdir -p "${mods_dir}"
  fi
  log INFO "World directory reset complete"

  # ---- Step 4: delete the FLAG file to prevent repeated resets ----
  remove_reset_world_flag "${data_dir}" "${flag_file}" || return 1

  log INFO "World reset completed successfully"
}

handle_reset_world_flag() {
  local max_age=1800  # 30 minutes
  local data_dir="${DATA_DIR:-}"
  local flag="${data_dir}/reset-world.flag"

  if [[ -f "$flag" ]]; then
    validate_world_reset_flag_path "${data_dir}" "${flag}" || return 1

    local now
    local mtime
    now=$(date +%s)
    mtime=$(stat -c %Y "$flag")

    if (( now - mtime > max_age )); then
      log ERROR "reset-world.flag expired (older than ${max_age}s), resetting aborted"
      remove_reset_world_flag "${data_dir}" "${flag}" || return 1
      return
    fi

    log WARN "reset-world.flag valid, proceeding to reset world"
    reset_world || return 1
    if [[ -f "${flag}" ]]; then
      remove_reset_world_flag "${data_dir}" "${flag}" || return 1
    fi
    log INFO "reset-world.flag consumed"
  else
    log INFO "No reset-world.flag detected, skipping world reset"
  fi
}

# shellcheck shell=bash

validate_world_install_paths() {
  local data_dir="${1:-}"
  local world_dir="${2:-}"
  local expected_world_dir_literal

  if [[ -z "${data_dir}" ]]; then
    log ERROR "DATA_DIR is required for world install"
    return 1
  fi

  if [[ -z "${world_dir}" ]]; then
    log ERROR "Refusing unsafe world install path"
    return 1
  fi

  if [[ "${data_dir}" != /* || "${data_dir}" == "/" ]]; then
    log ERROR "Refusing unsafe world install path"
    return 1
  fi

  expected_world_dir_literal="$(minecraft_world_dir "${data_dir}")" || return 1
  if [[ "${world_dir}" != "${expected_world_dir_literal}" ]]; then
    log ERROR "Refusing unsafe world install path"
    return 1
  fi

  case "${world_dir}" in
    /|/world|/tmp)
      log ERROR "Refusing unsafe world install path"
      return 1
      ;;
  esac

  if [[ "${world_dir}" == "${data_dir}" ]]; then
    log ERROR "Refusing unsafe world install path"
    return 1
  fi

  if ! command -v realpath >/dev/null 2>&1; then
    log ERROR "Refusing unsafe world install path"
    return 1
  fi

  local resolved_data_dir resolved_world_dir expected_world_dir expected_world_name
  if ! resolved_data_dir="$(realpath -m -- "${data_dir}")"; then
    log ERROR "Refusing unsafe world install path"
    return 1
  fi

  if ! resolved_world_dir="$(realpath -m -- "${world_dir}")"; then
    log ERROR "Refusing unsafe world install path"
    return 1
  fi

  expected_world_name="$(minecraft_world_name)" || return 1
  if ! expected_world_dir="$(realpath -m -- "${resolved_data_dir}/${expected_world_name}")"; then
    log ERROR "Refusing unsafe world install path"
    return 1
  fi

  if [[ "${resolved_data_dir}" == "/" ||
    "${resolved_world_dir}" == "/" ||
    "${resolved_world_dir}" == "/world" ||
    "${resolved_world_dir}" == "/tmp" ||
    "${resolved_world_dir}" == "/data" ||
    "${resolved_world_dir}" == "${resolved_data_dir}" ||
    "${resolved_world_dir}" != "${expected_world_dir}" ||
    "${resolved_world_dir##*/}" != "${expected_world_name}" ]]; then
    log ERROR "Refusing unsafe world install path"
    return 1
  fi

  case "${resolved_world_dir}" in
    "${resolved_data_dir}"/*) ;;
    *)
      log ERROR "Refusing unsafe world install path"
      return 1
      ;;
  esac

  return 0
}

cleanup_world_install_temps() {
  local archive="${1:-}"
  local extract_dir="${2:-}"

  [[ -z "${archive}" ]] || safe_rm_f "${archive}"
  [[ -z "${extract_dir}" ]] || safe_rm_rf "${extract_dir}"
}

normalize_world_archive_permissions() {
  local extract_dir="${1:-}"

  refuse_unsafe_filesystem_path "${extract_dir}" "chmod extracted world" || return 1
  chmod -R u+rwX -- "${extract_dir}"
}

install_world() {
  local WORLD_DIR
  WORLD_DIR="$(minecraft_world_dir)" || return 1

  # ------------------------------------------------------------
  # Guard
  # ------------------------------------------------------------
  if [[ "${WORLDS_ENABLED:-false}" != "true" ]]; then
    log INFO "Worlds disabled"
    return 0
  fi

  if [[ -n "${DATA_DIR:-}" &&
    -f "${WORLD_DIR}/level.dat" &&
    ! -f "${DATA_DIR}/reset-world.flag" ]]; then
    log INFO "World already exists, skipping world install"
    return 0
  fi

  if [[ -z "${WORLDS_S3_BUCKET:-}" || -z "${WORLDS_S3_PREFIX:-}" ]]; then
    log INFO "WORLDS_S3_BUCKET or WORLDS_S3_PREFIX not set, skipping world install"
    return 0
  fi

  log INFO "Installing world from S3"

  # ------------------------------------------------------------
  # Download
  # ------------------------------------------------------------
  configure_s3_client "world"

  local WORLD_PREFIX="${WORLDS_S3_PREFIX%/}"
  local WORLD_SOURCE_DISPLAY="s3://${WORLDS_S3_BUCKET}/${WORLD_PREFIX}"
  local WORLD_OBJECT_PREFIX="${WORLD_PREFIX}/"
  local WORLD_ARCHIVE_LISTING=""
  local WORLD_ARCHIVE_KEY=""
  local WORLD_ARCHIVES=()

  WORLD_ARCHIVE_LISTING="$(mktemp /tmp/world-source.XXXXXX.jsonl)" || return 1
  if ! s3api_list_objects_v2 "${WORLDS_S3_BUCKET}" "${WORLD_OBJECT_PREFIX}" --output json > "${WORLD_ARCHIVE_LISTING}"; then
    safe_rm_f "${WORLD_ARCHIVE_LISTING}"
    die "Failed to list world archive source under ${WORLD_SOURCE_DISPLAY}"
  fi

  while IFS= read -r WORLD_ARCHIVE_KEY; do
    WORLD_ARCHIVES+=("s3/${WORLDS_S3_BUCKET}/${WORLD_ARCHIVE_KEY}")
  done < <(jq -r --arg prefix "${WORLD_OBJECT_PREFIX}" '
    .Contents[]?.Key
    | select(startswith($prefix))
    | . as $key
    | ($key | ltrimstr($prefix)) as $rel
    | select($rel | test("^[^/]+\\.zip$"))
    | $key
  ' "${WORLD_ARCHIVE_LISTING}")
  safe_rm_f "${WORLD_ARCHIVE_LISTING}"

  if [[ "${#WORLD_ARCHIVES[@]}" -eq 0 ]]; then
    die "No world archive found under ${WORLD_SOURCE_DISPLAY}"
  fi

  if [[ "${#WORLD_ARCHIVES[@]}" -gt 1 ]]; then
    die "Ambiguous world archive source under ${WORLD_SOURCE_DISPLAY}"
  fi

  local TMP_ZIP="" EXTRACT_DIR=""
  TMP_ZIP="$(mktemp /tmp/world.XXXXXX.zip)" || return 1
  EXTRACT_DIR="$(mktemp -d /tmp/world-extract.XXXXXX)" || {
    cleanup_world_install_temps "${TMP_ZIP}" "${EXTRACT_DIR}"
    return 1
  }

  s3_cp "${WORLD_ARCHIVES[0]}" "${TMP_ZIP}" || {
    cleanup_world_install_temps "${TMP_ZIP}" "${EXTRACT_DIR}"
    die "Failed to download world archive"
  }

  # ------------------------------------------------------------
  # Extract
  # ------------------------------------------------------------
  if ! unzip -q "${TMP_ZIP}" -d "${EXTRACT_DIR}"; then
    cleanup_world_install_temps "${TMP_ZIP}" "${EXTRACT_DIR}"
    die "Failed to extract world archive with unzip"
  fi

  if ! normalize_world_archive_permissions "${EXTRACT_DIR}"; then
    cleanup_world_install_temps "${TMP_ZIP}" "${EXTRACT_DIR}"
    die "Failed to normalize extracted world permissions"
  fi

  # ------------------------------------------------------------
  # Detect
  # ------------------------------------------------------------
  local SELECTED_SOURCE=""
  local CANDIDATES=()
  local TOP_LEVEL_DIRS=()
  local TOP_LEVEL_DIR

  while IFS= read -r -d '' TOP_LEVEL_DIR; do
    TOP_LEVEL_DIRS+=("${TOP_LEVEL_DIR}")
    if [[ -f "${TOP_LEVEL_DIR}/level.dat" ]]; then
      CANDIDATES+=("${TOP_LEVEL_DIR}")
    fi
  done < <(find "${EXTRACT_DIR}" -mindepth 1 -maxdepth 1 -type d -print0)

  if [[ -f "${EXTRACT_DIR}/level.dat" ]]; then
    CANDIDATES+=("${EXTRACT_DIR}")
  fi

  if [[ "${#CANDIDATES[@]}" -gt 1 ]]; then
    cleanup_world_install_temps "${TMP_ZIP}" "${EXTRACT_DIR}"
    log ERROR "Ambiguous world archive layout"
    return 1
  fi

  if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
    cleanup_world_install_temps "${TMP_ZIP}" "${EXTRACT_DIR}"
    log ERROR "Failed to detect world directory in archive"
    return 1
  fi

  SELECTED_SOURCE="${CANDIDATES[0]}"

  if [[ "${SELECTED_SOURCE}" != "${EXTRACT_DIR}" &&
    "${SELECTED_SOURCE}" != "${EXTRACT_DIR}/world" &&
    "${#TOP_LEVEL_DIRS[@]}" -ne 1 ]]; then
    cleanup_world_install_temps "${TMP_ZIP}" "${EXTRACT_DIR}"
    log ERROR "Ambiguous world archive layout"
    return 1
  fi

  # ------------------------------------------------------------
  # Install
  # ------------------------------------------------------------
  if ! validate_world_install_paths "${DATA_DIR:-}" "${WORLD_DIR}"; then
    cleanup_world_install_temps "${TMP_ZIP}" "${EXTRACT_DIR}"
    return 1
  fi

  if ! mkdir -p "${DATA_DIR}"; then
    cleanup_world_install_temps "${TMP_ZIP}" "${EXTRACT_DIR}"
    return 1
  fi

  if ! validate_world_install_paths "${DATA_DIR:-}" "${WORLD_DIR}"; then
    cleanup_world_install_temps "${TMP_ZIP}" "${EXTRACT_DIR}"
    return 1
  fi

  safe_rm_rf "${WORLD_DIR}" || return 1
  if ! safe_mv "${SELECTED_SOURCE}" "${WORLD_DIR}"; then
    cleanup_world_install_temps "${TMP_ZIP}" "${EXTRACT_DIR}"
    return 1
  fi

  cleanup_world_install_temps "${TMP_ZIP}" "${EXTRACT_DIR}"
  safe_rm_f "${DATA_DIR}/reset-world.flag"

  log INFO "World installed successfully"
}

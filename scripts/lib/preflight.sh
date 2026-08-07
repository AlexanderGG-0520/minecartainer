# shellcheck shell=bash

preflight() {
  log INFO "Preflight checks..."

  [[ -d "${DATA_DIR}" ]] || die "${DATA_DIR} does not exist"
  touch "${DATA_DIR}/.write_test" 2>/dev/null || die "${DATA_DIR} is not writable"
  safe_rm_f "${DATA_DIR}/.write_test"

  [[ -n "${EULA:-}" ]] || die "EULA is not set"

  if ! is_auto_type "${TYPE:-vanilla}" && ! is_supported_runtime_type "${TYPE:-vanilla}"; then
    die "Invalid TYPE: ${TYPE}"
  fi

  if [[ -n "${MODPACK_URL:-}" && "${MODPACK_FORMAT:-auto}" == "curseforge" ]]; then
    [[ -n "${CURSEFORGE_API_KEY:-}" ]] \
      || die "MODPACK_FORMAT=curseforge requires CURSEFORGE_API_KEY"

    if ! is_true "${MODPACK_INFER_RUNTIME:-false}"; then
      ! is_auto_type "${TYPE:-auto}" \
        || die "CurseForge modpacks require an explicit TYPE unless MODPACK_INFER_RUNTIME=true"
      [[ -n "${VERSION:-}" && "${VERSION:-}" != "auto" && "${VERSION:-}" != "AUTO" ]] \
        || die "CurseForge modpacks require an explicit VERSION unless MODPACK_INFER_RUNTIME=true"
    fi
  fi

  if [[ "${VERSION:-}" == "auto" || "${VERSION:-}" == "AUTO" ]]; then
    if ! is_true "${MODPACK_INFER_RUNTIME:-false}" || [[ -z "${MODPACK_URL:-}" ]]; then
      die "VERSION=auto requires MODPACK_INFER_RUNTIME=true and MODPACK_URL"
    fi
  fi

  if [[ "${TYPE:-vanilla}" != "vanilla" && "${TYPE:-vanilla}" != "auto" \
    && "${TYPE:-vanilla}" != "AUTO" \
    && ( -z "${VERSION:-}" || "${VERSION:-}" == "auto" || "${VERSION:-}" == "AUTO" ) ]]; then
    if ! is_true "${MODPACK_INFER_RUNTIME:-false}" || [[ -z "${MODPACK_URL:-}" ]]; then
      die "VERSION must be set when TYPE is not vanilla, unless modpack runtime inference is explicitly enabled"
    fi
  fi

  if [[ "${ENABLE_RCON}" == "true" ]]; then
    [[ -n "${RCON_PASSWORD:-}" ]] || die "ENABLE_RCON=true but RCON_PASSWORD is empty"
    [[ "${RCON_PASSWORD}" != "changeme" ]] || die "RCON_PASSWORD=changeme is not allowed"
  fi

  validate_shutdown_numeric_config preflight || return 1

  safe_rm_f "${DATA_DIR}/.ready"
  log INFO "Preflight OK"
}

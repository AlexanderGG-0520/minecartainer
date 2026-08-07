# shellcheck shell=bash

modpack_runtime_inference_enabled() {
  is_true "${MODPACK_INFER_RUNTIME:-false}"
}

modpack_version_needs_inference() {
  local value="${1:-}"
  [[ -z "$value" || "$value" == "auto" || "$value" == "AUTO" ]]
}

modpack_existing_server_artifact_present() {
  [[ -f "${DATA_DIR}/velocity.jar" \
    || -f "${DATA_DIR}/fabric-server-launch.jar" \
    || -f "${DATA_DIR}/run.sh" \
    || -f "${DATA_DIR}/server.jar" ]]
}

modpack_loader_dependency_from_index() {
  local index="$1"
  local count

  count="$(jq -r '
    [(.dependencies // {}) | to_entries[]
      | select(.key == "fabric-loader" or .key == "quilt-loader" or .key == "forge" or .key == "neoforge")]
    | length
  ' "$index")" || return 1

  [[ "$count" -le 1 ]] || return 2

  if [[ "$count" -eq 1 ]]; then
    jq -r '
      (.dependencies // {}) | to_entries[]
      | select(.key == "fabric-loader" or .key == "quilt-loader" or .key == "forge" or .key == "neoforge")
      | [.key, .value] | @tsv
    ' "$index"
  fi
}

modpack_loader_env_name() {
  case "$1" in
    fabric-loader) printf '%s\n' FABRIC_LOADER_VERSION ;;
    forge) printf '%s\n' FORGE_VERSION ;;
    neoforge) printf '%s\n' NEOFORGE_VERSION ;;
    *) return 1 ;;
  esac
}

curseforge_loader_env_name() {
  case "$1" in
    fabric) printf '%s\n' FABRIC_LOADER_VERSION ;;
    forge) printf '%s\n' FORGE_VERSION ;;
    neoforge) printf '%s\n' NEOFORGE_VERSION ;;
    *) return 1 ;;
  esac
}

cleanup_modpack_prefetch() {
  local archive="${MODPACK_PREFETCH_ARCHIVE:-}"

  if [[ -n "$archive" && ( -e "$archive" || -L "$archive" ) ]]; then
    case "$archive" in
      /tmp/minecartainer-mrpack-infer.*.mrpack|/tmp/minecartainer-curseforge-infer.*.zip)
        safe_rm_f "$archive" || log WARN "Failed to clean prefetched modpack archive: ${archive}"
        ;;
      *)
        log WARN "Refusing to clean unexpected prefetched modpack path: ${archive}"
        ;;
    esac
  fi

  MODPACK_PREFETCH_ARCHIVE=""
  MODPACK_PREFETCH_SOURCE=""
  MODPACK_PREFETCH_FORMAT=""
  MODPACK_PREFETCH_READY=false
}

pin_inferred_modpack_loader_version() {
  local loader_key="$1"
  local loader_version="$2"
  local var_name current

  if ! var_name="$(modpack_loader_env_name "$loader_key")"; then
    log INFO "${loader_key} TYPE was inferred, but Minecartainer does not expose an exact loader-version selector for this loader"
    return 0
  fi

  if [[ ! -v $var_name || -z "${!var_name:-}" ]]; then
    printf -v "$var_name" '%s' "$loader_version"
    export "${var_name?}"
    log INFO "Pinned ${var_name}=${loader_version} from Modrinth dependencies"
    return 0
  fi

  current="${!var_name}"
  case "$current" in
    latest|recommended)
      log INFO "Keeping explicit ${var_name}=${current}; installed loader will still be validated against pack requirement ${loader_version}"
      ;;
    *)
      if [[ "$current" != "$loader_version" ]]; then
        cleanup_modpack_prefetch
        die "Explicit ${var_name}=${current} conflicts with Modrinth dependency ${loader_key}=${loader_version}"
      fi
      ;;
  esac
}

pin_inferred_curseforge_loader_version() {
  local loader_type="$1"
  local loader_version="$2"
  local loader_id="$3"
  local var_name current

  if ! var_name="$(curseforge_loader_env_name "$loader_type")"; then
    log INFO "CurseForge loader ${loader_id} was inferred, but Minecartainer does not expose an exact loader-version selector for this loader"
    return 0
  fi

  if [[ ! -v $var_name || -z "${!var_name:-}" ]]; then
    printf -v "$var_name" '%s' "$loader_version"
    export "${var_name?}"
    log INFO "Pinned ${var_name}=${loader_version} from CurseForge primary loader ${loader_id}"
    return 0
  fi

  current="${!var_name}"
  case "$current" in
    latest|recommended)
      log INFO "Keeping explicit ${var_name}=${current}; installed loader will still be validated against CurseForge requirement ${loader_id}"
      ;;
    *)
      if [[ "$current" != "$loader_version" ]]; then
        cleanup_modpack_prefetch
        die "Explicit ${var_name}=${current} conflicts with CurseForge primary loader ${loader_id}"
      fi
      ;;
  esac
}

prefetch_modpack_archive_for_runtime_inference() {
  local source="$1"
  local index_out="$2"
  local archive

  archive="$(mktemp /tmp/minecartainer-mrpack-infer.XXXXXX.mrpack)" \
    || die "Failed to create temporary mrpack archive for runtime inference"

  MODPACK_PREFETCH_ARCHIVE="$archive"
  MODPACK_PREFETCH_SOURCE="$source"
  MODPACK_PREFETCH_FORMAT=mrpack
  MODPACK_PREFETCH_READY=false

  download_modpack_file "$source" "$archive" "mrpack archive for runtime inference"
  extract_mrpack_index "$archive" "$index_out"
  validate_modrinth_index "$index_out"

  MODPACK_PREFETCH_READY=true
}

prefetch_curseforge_archive_for_runtime_inference() {
  local source="$1"
  local manifest_out="$2"
  local archive

  archive="$(mktemp /tmp/minecartainer-curseforge-infer.XXXXXX.zip)" \
    || die "Failed to create temporary CurseForge archive for runtime inference"

  MODPACK_PREFETCH_ARCHIVE="$archive"
  MODPACK_PREFETCH_SOURCE="$source"
  MODPACK_PREFETCH_FORMAT=curseforge
  MODPACK_PREFETCH_READY=false

  download_modpack_file "$source" "$archive" "CurseForge archive for runtime inference"
  extract_curseforge_manifest "$archive" "$manifest_out"
  validate_curseforge_manifest "$manifest_out"

  MODPACK_PREFETCH_READY=true
}

acquire_modpack_archive() {
  local source="$1"
  local out="$2"

  if modpack_runtime_inference_enabled; then
    [[ "${MODPACK_PREFETCH_READY:-false}" == true ]] \
      || die "Runtime inference was enabled but the prefetched mrpack archive is unavailable"
    [[ "${MODPACK_PREFETCH_FORMAT:-mrpack}" == mrpack ]] \
      || die "Runtime inference prefetched a different modpack format; refusing to consume it as mrpack"
    [[ "${MODPACK_PREFETCH_SOURCE:-}" == "$source" ]] \
      || die "MODPACK_URL changed after runtime inference; refusing to install a different pack than the one used for TYPE/VERSION inference"
    [[ -f "${MODPACK_PREFETCH_ARCHIVE:-}" ]] \
      || die "Prefetched mrpack archive disappeared before installation"

    safe_mv_f "$MODPACK_PREFETCH_ARCHIVE" "$out" \
      || die "Failed to reuse prefetched mrpack archive"
    MODPACK_PREFETCH_ARCHIVE=""
    MODPACK_PREFETCH_SOURCE=""
    MODPACK_PREFETCH_FORMAT=""
    MODPACK_PREFETCH_READY=false
    log INFO "Reusing prefetched mrpack archive from runtime inference"
    return 0
  fi

  download_modpack_file "$source" "$out" "mrpack archive"
}

acquire_curseforge_modpack_archive() {
  local source="$1"
  local out="$2"

  if modpack_runtime_inference_enabled; then
    [[ "${MODPACK_PREFETCH_READY:-false}" == true ]] \
      || die "Runtime inference was enabled but the prefetched CurseForge archive is unavailable"
    [[ "${MODPACK_PREFETCH_FORMAT:-}" == curseforge ]] \
      || die "Runtime inference prefetched a different modpack format; refusing to consume it as CurseForge"
    [[ "${MODPACK_PREFETCH_SOURCE:-}" == "$source" ]] \
      || die "MODPACK_URL changed after runtime inference; refusing to install a different pack than the one used for TYPE/VERSION inference"
    [[ -f "${MODPACK_PREFETCH_ARCHIVE:-}" ]] \
      || die "Prefetched CurseForge archive disappeared before installation"

    safe_mv_f "$MODPACK_PREFETCH_ARCHIVE" "$out" \
      || die "Failed to reuse prefetched CurseForge archive"
    MODPACK_PREFETCH_ARCHIVE=""
    MODPACK_PREFETCH_SOURCE=""
    MODPACK_PREFETCH_FORMAT=""
    MODPACK_PREFETCH_READY=false
    log INFO "Reusing prefetched CurseForge archive from runtime inference"
    return 0
  fi

  download_modpack_file "$source" "$out" "CurseForge modpack archive"
}

resolve_curseforge_runtime_from_pack() {
  local tmpdir manifest marker
  local pack_minecraft loader_type loader_version loader_id
  local marker_active=false marker_artifact marker_type marker_version
  local effective_type loader_line

  cleanup_modpack_prefetch

  tmpdir="$(mktemp -d)"
  manifest="${tmpdir}/manifest.json"
  prefetch_curseforge_archive_for_runtime_inference "$MODPACK_URL" "$manifest"

  pack_minecraft="$(jq -er '.minecraft.version' "$manifest")" || {
    safe_rm_rf "$tmpdir"
    cleanup_modpack_prefetch
    die "Failed to read CurseForge Minecraft version for runtime inference"
  }
  loader_line="$(curseforge_primary_loader "$manifest")" || {
    safe_rm_rf "$tmpdir"
    cleanup_modpack_prefetch
    die "Failed to read CurseForge primary loader for runtime inference"
  }
  IFS=$'\t' read -r loader_type loader_version loader_id <<< "$loader_line"

  marker="$(server_install_marker)"
  marker_artifact=""
  marker_type=""
  marker_version=""
  if [[ -f "$marker" ]]; then
    marker_artifact="$(read_server_install_marker_field "$marker" artifact)"
    marker_type="$(read_server_install_marker_field "$marker" type)"
    marker_version="$(read_server_install_marker_field "$marker" version)"
    read_server_install_marker_field "$marker" build >/dev/null

    if [[ -f "${DATA_DIR}/${marker_artifact}" ]]; then
      marker_active=true
    else
      log WARN "Server install marker exists but its artifact is missing; runtime inference will not trust the marker as active state: ${marker_artifact}"
    fi
  fi

  if modpack_version_needs_inference "${VERSION:-}"; then
    if [[ "$marker_active" == true ]]; then
      VERSION="$marker_version"
      log INFO "VERSION auto-resolved to '${VERSION}' from existing server install marker before modpack validation"
    elif modpack_existing_server_artifact_present; then
      safe_rm_rf "$tmpdir"
      cleanup_modpack_prefetch
      die "Cannot safely infer VERSION from CurseForge pack while an existing server artifact has no active install marker; set VERSION explicitly"
    else
      VERSION="$pack_minecraft"
      log INFO "VERSION auto-resolved to '${VERSION}' from CurseForge manifest"
    fi
  fi

  if [[ "${VERSION:-}" != "$pack_minecraft" ]]; then
    safe_rm_rf "$tmpdir"
    cleanup_modpack_prefetch
    die "Configured/resolved VERSION=${VERSION:-<empty>} conflicts with CurseForge Minecraft version ${pack_minecraft}"
  fi

  if is_auto_type "${TYPE:-auto}"; then
    if [[ "$marker_active" == true ]]; then
      effective_type="$marker_type"
      log INFO "Keeping TYPE=auto for existing server state; marker resolves to '${marker_type}'"
    elif modpack_existing_server_artifact_present; then
      effective_type=""
      log INFO "Keeping TYPE=auto because an existing unmarked server artifact must be resolved by the normal artifact detector"
    else
      TYPE="$loader_type"
      effective_type="$TYPE"
      log INFO "TYPE auto-resolved to '${TYPE}' from CurseForge primary loader ${loader_id}"
    fi
  else
    effective_type="${TYPE:-}"
  fi

  if [[ -n "$effective_type" && "$effective_type" != "$loader_type" ]]; then
    safe_rm_rf "$tmpdir"
    cleanup_modpack_prefetch
    die "Configured/resolved TYPE=${effective_type} conflicts with CurseForge primary loader ${loader_id}"
  fi

  if [[ -n "$effective_type" && "$effective_type" == "$loader_type" ]]; then
    pin_inferred_curseforge_loader_version "$loader_type" "$loader_version" "$loader_id"
  fi

  safe_rm_rf "$tmpdir"
}

resolve_modpack_runtime_from_pack() {
  local tmpdir index marker
  local pack_minecraft loader_key loader_version expected_type
  local marker_active=false marker_artifact marker_type marker_version
  local effective_type loader_line loader_status

  modpack_runtime_inference_enabled || return 0
  [[ -n "${MODPACK_URL:-}" ]] || {
    log WARN "MODPACK_INFER_RUNTIME=true but MODPACK_URL is empty; skipping modpack runtime inference"
    return 0
  }

  if [[ "${MODPACK_FORMAT:-auto}" == curseforge ]]; then
    resolve_curseforge_runtime_from_pack
    return
  fi

  case "${MODPACK_FORMAT:-auto}" in
    mrpack) ;;
    auto)
      case "$MODPACK_URL" in
        *.mrpack|*.mrpack\?*) ;;
        *.zip|*.zip\?*) die "MODPACK_INFER_RUNTIME=true does not guess .zip formats; set MODPACK_FORMAT=curseforge explicitly for a CurseForge export" ;;
        *) die "MODPACK_INFER_RUNTIME=true currently requires a .mrpack URL when MODPACK_FORMAT=auto" ;;
      esac
      ;;
    *)
      die "MODPACK_INFER_RUNTIME=true currently supports MODPACK_FORMAT=mrpack, curseforge, or auto for .mrpack URLs"
      ;;
  esac

  cleanup_modpack_prefetch

  tmpdir="$(mktemp -d)"
  index="${tmpdir}/modrinth.index.json"
  prefetch_modpack_archive_for_runtime_inference "$MODPACK_URL" "$index"

  pack_minecraft="$(jq -r '.dependencies.minecraft // empty' "$index")"
  loader_key=""
  loader_version=""
  loader_line=""
  if loader_line="$(modpack_loader_dependency_from_index "$index")"; then
    loader_status=0
  else
    loader_status=$?
    safe_rm_rf "$tmpdir"
    cleanup_modpack_prefetch
    if [[ "$loader_status" -eq 2 ]]; then
      die "Modpack declares multiple loader dependencies; cannot infer a single server TYPE"
    fi
    die "Failed to read Modrinth loader dependencies for runtime inference"
  fi
  if [[ -n "$loader_line" ]]; then
    IFS=$'\t' read -r loader_key loader_version <<< "$loader_line"
  fi

  marker="$(server_install_marker)"
  marker_artifact=""
  marker_type=""
  marker_version=""
  if [[ -f "$marker" ]]; then
    marker_artifact="$(read_server_install_marker_field "$marker" artifact)"
    marker_type="$(read_server_install_marker_field "$marker" type)"
    marker_version="$(read_server_install_marker_field "$marker" version)"
    read_server_install_marker_field "$marker" build >/dev/null

    if [[ -f "${DATA_DIR}/${marker_artifact}" ]]; then
      marker_active=true
    else
      log WARN "Server install marker exists but its artifact is missing; runtime inference will not trust the marker as active state: ${marker_artifact}"
    fi
  fi

  if modpack_version_needs_inference "${VERSION:-}"; then
    if [[ "$marker_active" == true ]]; then
      VERSION="$marker_version"
      log INFO "VERSION auto-resolved to '${VERSION}' from existing server install marker before modpack validation"
    elif modpack_existing_server_artifact_present; then
      safe_rm_rf "$tmpdir"
      cleanup_modpack_prefetch
      die "Cannot safely infer VERSION from mrpack while an existing server artifact has no active install marker; set VERSION explicitly"
    elif [[ -n "$pack_minecraft" ]]; then
      VERSION="$pack_minecraft"
      log INFO "VERSION auto-resolved to '${VERSION}' from Modrinth minecraft dependency"
    else
      safe_rm_rf "$tmpdir"
      cleanup_modpack_prefetch
      die "Cannot infer VERSION from mrpack because dependencies.minecraft is missing"
    fi
  fi

  if [[ -n "$pack_minecraft" && "${VERSION:-}" != "$pack_minecraft" ]]; then
    safe_rm_rf "$tmpdir"
    cleanup_modpack_prefetch
    die "Configured/resolved VERSION=${VERSION:-<empty>} conflicts with Modrinth minecraft dependency ${pack_minecraft}"
  fi

  expected_type=""
  if [[ -n "$loader_key" ]]; then
    expected_type="$(mrpack_loader_type_for_dependency "$loader_key")"
  fi

  if is_auto_type "${TYPE:-auto}"; then
    if [[ "$marker_active" == true ]]; then
      effective_type="$marker_type"
      log INFO "Keeping TYPE=auto for existing server state; marker resolves to '${marker_type}'"
    elif modpack_existing_server_artifact_present; then
      effective_type=""
      log INFO "Keeping TYPE=auto because an existing unmarked server artifact must be resolved by the normal artifact detector"
    elif [[ -n "$expected_type" ]]; then
      TYPE="$expected_type"
      effective_type="$TYPE"
      log INFO "TYPE auto-resolved to '${TYPE}' from Modrinth loader dependency ${loader_key}=${loader_version}"
    else
      effective_type=""
      log INFO "No recognized Modrinth loader dependency found; normal TYPE=auto fallback will determine the runtime"
    fi
  else
    effective_type="${TYPE:-}"
  fi

  if [[ -n "$expected_type" && -n "$effective_type" && "$effective_type" != "$expected_type" ]]; then
    safe_rm_rf "$tmpdir"
    cleanup_modpack_prefetch
    die "Configured/resolved TYPE=${effective_type} conflicts with Modrinth loader dependency ${loader_key}=${loader_version}"
  fi

  if [[ -n "$expected_type" && -n "$effective_type" && "$effective_type" == "$expected_type" ]]; then
    pin_inferred_modpack_loader_version "$loader_key" "$loader_version"
  fi

  safe_rm_rf "$tmpdir"
}

# Extends runtime.sh's TYPE=auto resolver. The entrypoint already calls
# resolve_type_auto() after preflight, so sourcing this file late lets modpack
# inference happen at exactly that point without changing the main lifecycle.
resolve_type_auto() {
  resolve_modpack_runtime_from_pack

  [[ "${TYPE:-}" == "auto" || "${TYPE:-}" == "AUTO" ]] || return 0

  local marker installed_type installed_artifact
  marker="$(server_install_marker)"

  if [[ -f "${marker}" ]]; then
    installed_artifact="$(read_server_install_marker_field "${marker}" artifact)"
    installed_type="$(read_server_install_marker_field "${marker}" type)"
    read_server_install_marker_field "${marker}" version >/dev/null
    read_server_install_marker_field "${marker}" build >/dev/null

    if ! is_marker_auto_resolvable_type "${installed_type}"; then
      log WARN "Install marker type is not supported for TYPE=auto, falling back to artifact detection: ${installed_type}"
    elif [[ -f "${DATA_DIR}/${installed_artifact}" ]]; then
      TYPE="${installed_type}"
      log INFO "TYPE auto-resolved to '${TYPE}' from install marker"
      return 0
    else
      log WARN "Install marker exists but artifact is missing, falling back to artifact detection: ${installed_artifact}"
    fi
  fi

  if [[ -f "${DATA_DIR}/velocity.jar" ]]; then
    TYPE="velocity"
  elif [[ -f "${DATA_DIR}/fabric-server-launch.jar" ]]; then
    TYPE="fabric"
  elif [[ -f "${DATA_DIR}/run.sh" ]]; then
    if compgen -G "${DATA_DIR}/.installed-neoforge-*" > /dev/null; then
      TYPE="neoforge"
    else
      TYPE="forge"
    fi
  elif [[ -f "${DATA_DIR}/server.jar" ]]; then
    TYPE="vanilla"
  else
    TYPE="vanilla"
  fi

  log INFO "TYPE auto-resolved to '${TYPE}'"
}

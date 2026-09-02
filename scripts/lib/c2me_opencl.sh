# shellcheck shell=bash

C2ME_BASE_MOD_ID="c2me"
C2ME_OPENCL_MOD_ID="c2me-opts-accel-opencl"
C2ME_OPENCL_MODRINTH_PROJECT_ID="qtPMklut"
C2ME_OPENCL_CONFIG_PROPERTY="c2me.base.config.override.openclAccel.enabled"
SCALABLELUX_MOD_ID="scalablelux"

has_c2me_base_mod() {
  has_fabric_mod_id "$C2ME_BASE_MOD_ID"
}

has_c2me_opencl_mod() {
  has_fabric_mod_id "$C2ME_OPENCL_MOD_ID"
}

c2me_base_version() {
  local jar
  jar="$(find_fabric_mod_by_id "$C2ME_BASE_MOD_ID")" || return 1
  fabric_mod_version "$jar"
}

c2me_opencl_requested() {
  local value

  if [[ -n "${ENABLE_C2ME_OPENCL+x}" ]]; then
    value="${ENABLE_C2ME_OPENCL}"
  else
    value="${ENABLE_C2ME_HARDWARE_ACCELERATION:-false}"
  fi

  case "${value,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

c2me_opencl_uses_legacy_env() {
  [[ -z "${ENABLE_C2ME_OPENCL+x}" ]] \
    && [[ -n "${ENABLE_C2ME_HARDWARE_ACCELERATION+x}" ]]
}

c2me_opencl_update_requested() {
  case "${C2ME_OPENCL_UPDATE:-false}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

c2me_opencl_requested_version() {
  printf '%s\n' "${C2ME_OPENCL_VERSION:-match-c2me}"
}

validate_c2me_opencl_policy() {
  c2me_opencl_requested || return 0

  case "${ENABLE_C2ME:-false}" in
    true) ;;
    *) die "ENABLE_C2ME_OPENCL=true requires ENABLE_C2ME=true" ;;
  esac

  case "${I_KNOW_C2ME_IS_EXPERIMENTAL:-false}" in
    true) ;;
    *) die "ENABLE_C2ME_OPENCL=true requires I_KNOW_C2ME_IS_EXPERIMENTAL=true" ;;
  esac

  [[ "${TYPE:-}" == "fabric" ]] \
    || die "C2ME OpenCL automatic integration currently supports TYPE=fabric only (current: ${TYPE:-unset})"

  [[ "${JAVA_MAJOR:-unknown}" == "25" ]] \
    || die "C2ME OpenCL requires Java 25 (current: ${JAVA_MAJOR:-unknown})"
}

c2me_opencl_jvm_arg() {
  printf '%s\n' "-D${C2ME_OPENCL_CONFIG_PROPERTY}=true"
}

c2me_opencl_marker_path() {
  printf '%s/.minecartainer/managed-mods/c2me-opencl.json\n' "${DATA_DIR}"
}

c2me_opencl_marker_filename() {
  local marker="$1"
  local filename

  filename="$(jq -er '.filename | strings | select(length > 0)' "$marker" 2>/dev/null)" || return 1
  [[ "$filename" == "$(basename -- "$filename")" ]] || return 1
  [[ "$filename" == *.jar ]] || return 1
  printf '%s\n' "$filename"
}

c2me_opencl_marker_matches_current_request() {
  local marker
  local filename file sha512 requested_version base_version

  marker="$(c2me_opencl_marker_path)"
  [[ -f "$marker" ]] || return 1

  requested_version="$(c2me_opencl_requested_version)"
  base_version="$(c2me_base_version)" || return 1
  jq -e \
    --arg project "$C2ME_OPENCL_MODRINTH_PROJECT_ID" \
    --arg requested "$requested_version" \
    --arg baseVersion "$base_version" \
    --arg minecraft "${VERSION:-}" '
      type == "object"
      and .schemaVersion == 1
      and .projectId == $project
      and .requestedVersion == $requested
      and .baseC2meVersion == $baseVersion
      and .minecraftVersion == $minecraft
      and .loader == "fabric"
      and (.versionId | type == "string" and length > 0)
      and (.versionNumber | type == "string" and length > 0)
      and (.sha512 | type == "string" and length > 0)
    ' "$marker" >/dev/null 2>&1 || return 1

  filename="$(c2me_opencl_marker_filename "$marker")" || return 1
  file="${DATA_DIR}/mods/${filename}"
  [[ -f "$file" ]] || return 1
  [[ "$(fabric_mod_id "$file" 2>/dev/null || true)" == "$C2ME_OPENCL_MOD_ID" ]] || return 1
  [[ "$(fabric_mod_version "$file" 2>/dev/null || true)" == "$base_version" ]] || return 1

  sha512="$(jq -er '.sha512' "$marker")" || return 1
  echo "${sha512}  ${file}" | sha512sum -c - >/dev/null 2>&1 || return 1
}

c2me_opencl_remove_managed_artifact() {
  local marker filename file

  marker="$(c2me_opencl_marker_path)"
  [[ -f "$marker" ]] || return 0

  filename="$(c2me_opencl_marker_filename "$marker" 2>/dev/null || true)"
  if [[ -n "$filename" ]]; then
    file="${DATA_DIR}/mods/${filename}"
    if [[ -f "$file" ]] \
      && [[ "$(fabric_mod_id "$file" 2>/dev/null || true)" == "$C2ME_OPENCL_MOD_ID" ]]; then
      log INFO "Removing previously managed C2ME OpenCL addon: ${filename}"
      safe_rm_f "$file"
    fi
  fi

  safe_rm_f "$marker"
}

write_c2me_opencl_marker() {
  local version_json="$1"
  local file_json="$2"
  local marker requested_version base_version version_id version_number filename sha512 tmp

  marker="$(c2me_opencl_marker_path)"
  requested_version="$(c2me_opencl_requested_version)"
  base_version="$(c2me_base_version)" || die "Unable to read installed C2ME base version"
  version_id="$(jq -er '.id' <<< "$version_json")"
  version_number="$(jq -er '.version_number' <<< "$version_json")"
  filename="$(jq -er '.filename' <<< "$file_json")"
  sha512="$(jq -er '.hashes.sha512' <<< "$file_json")"

  mkdir -p "$(dirname "$marker")"
  tmp="$(mktemp "${marker}.tmp.XXXXXX")"
  jq -n \
    --arg projectId "$C2ME_OPENCL_MODRINTH_PROJECT_ID" \
    --arg requestedVersion "$requested_version" \
    --arg baseC2meVersion "$base_version" \
    --arg versionId "$version_id" \
    --arg versionNumber "$version_number" \
    --arg minecraftVersion "${VERSION:-}" \
    --arg filename "$filename" \
    --arg sha512 "$sha512" \
    --arg installedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '
      {
        schemaVersion: 1,
        projectId: $projectId,
        requestedVersion: $requestedVersion,
        baseC2meVersion: $baseC2meVersion,
        versionId: $versionId,
        versionNumber: $versionNumber,
        minecraftVersion: $minecraftVersion,
        loader: "fabric",
        filename: $filename,
        sha512: $sha512,
        installedAt: $installedAt
      }
    ' > "$tmp"
  safe_mv_f "$tmp" "$marker"
}

resolve_c2me_opencl_version() {
  local versions requested selector base_version version resolved_version

  requested="$(c2me_opencl_requested_version)"
  base_version="$(c2me_base_version)" || die "Unable to read installed C2ME base version"
  selector="$requested"
  [[ "$selector" != "match-c2me" ]] || selector="$base_version"

  versions="$(modrinth_list_project_versions "$C2ME_OPENCL_MODRINTH_PROJECT_ID" "${VERSION:-}" fabric)" \
    || die "Failed to resolve C2ME OpenCL versions from Modrinth"
  version="$(modrinth_select_project_version "$versions" "$selector")" \
    || die "No C2ME OpenCL build found for C2ME ${base_version} / Minecraft ${VERSION:-unset} / Fabric"

  resolved_version="$(jq -er '.version_number' <<< "$version")"
  [[ "$resolved_version" == "$base_version" ]] \
    || die "Resolved C2ME OpenCL ${resolved_version} does not match installed C2ME ${base_version}"

  printf '%s\n' "$version"
}

warn_if_scalablelux_missing() {
  if ! has_fabric_mod_id "$SCALABLELUX_MOD_ID"; then
    log WARN "ScalableLux is not installed; C2ME OpenCL upstream strongly recommends it because lighting can bottleneck world generation"
  fi
}

reconcile_c2me_opencl() {
  local marker version_json file_json version_number filename target base_version existing_version
  local -a existing=()

  c2me_opencl_requested || return 0

  if c2me_opencl_uses_legacy_env; then
    log WARN "ENABLE_C2ME_HARDWARE_ACCELERATION is deprecated; use ENABLE_C2ME_OPENCL=true"
  fi

  validate_c2me_opencl_policy

  has_c2me_base_mod \
    || die "C2ME OpenCL requested, but base C2ME mod '${C2ME_BASE_MOD_ID}' is not installed"
  base_version="$(c2me_base_version)" \
    || die "C2ME OpenCL requested, but the base C2ME version could not be read"

  if c2me_opencl_marker_matches_current_request && ! c2me_opencl_update_requested; then
    mapfile -t existing < <(list_fabric_mods_by_id "$C2ME_OPENCL_MOD_ID")
    [[ "${#existing[@]}" -eq 1 ]] \
      || die "Multiple C2ME OpenCL addons detected; expected exactly the managed addon"
    version_number="$(jq -er '.versionNumber' "$(c2me_opencl_marker_path)")"
    log INFO "C2ME OpenCL managed addon already installed: ${version_number}"
    warn_if_scalablelux_missing
    return 0
  fi

  marker="$(c2me_opencl_marker_path)"
  if [[ -f "$marker" ]]; then
    log INFO "C2ME OpenCL managed state changed or is invalid; reconciling"
    c2me_opencl_remove_managed_artifact
  fi

  mapfile -t existing < <(list_fabric_mods_by_id "$C2ME_OPENCL_MOD_ID")
  if [[ "${#existing[@]}" -gt 1 ]]; then
    die "Multiple unmanaged C2ME OpenCL addons detected in mods/"
  fi
  if [[ "${#existing[@]}" -eq 1 ]]; then
    existing_version="$(fabric_mod_version "${existing[0]}" 2>/dev/null || true)"
    [[ "$existing_version" == "$base_version" ]] \
      || die "Existing C2ME OpenCL addon ${existing_version:-unknown} does not match installed C2ME ${base_version}"
    log INFO "Using existing unmanaged C2ME OpenCL addon: ${existing[0]##*/} (${existing_version})"
    warn_if_scalablelux_missing
    return 0
  fi

  log INFO "Resolving C2ME OpenCL for C2ME ${base_version} / Minecraft ${VERSION:-unset} / Fabric"
  version_json="$(resolve_c2me_opencl_version)"
  file_json="$(modrinth_select_primary_jar_file "$version_json")" \
    || die "Resolved C2ME OpenCL version does not contain a usable JAR"

  version_number="$(jq -er '.version_number' <<< "$version_json")"
  filename="$(jq -er '.filename' <<< "$file_json")"
  [[ "$filename" == "$(basename -- "$filename")" && "$filename" == *.jar ]] \
    || die "Unsafe C2ME OpenCL filename resolved from Modrinth: ${filename}"

  target="${DATA_DIR}/mods/${filename}"
  [[ ! -e "$target" ]] \
    || die "Refusing to overwrite existing unmanaged mod file: ${filename}"

  mkdir -p "${DATA_DIR}/mods"
  modrinth_download_verified_file "$file_json" "$target"

  if [[ "$(fabric_mod_id "$target" 2>/dev/null || true)" != "$C2ME_OPENCL_MOD_ID" ]]; then
    safe_rm_f "$target"
    die "Downloaded C2ME OpenCL JAR has unexpected Fabric mod id"
  fi
  if [[ "$(fabric_mod_version "$target" 2>/dev/null || true)" != "$base_version" ]]; then
    safe_rm_f "$target"
    die "Downloaded C2ME OpenCL JAR version does not match installed C2ME ${base_version}"
  fi

  write_c2me_opencl_marker "$version_json" "$file_json"
  log INFO "C2ME OpenCL managed addon installed: ${version_number}"
  warn_if_scalablelux_missing
}

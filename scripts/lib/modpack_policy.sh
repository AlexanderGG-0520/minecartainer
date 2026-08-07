# shellcheck shell=bash

modpack_include_optional_enabled() {
  is_true "${MODPACK_INCLUDE_OPTIONAL:-false}"
}

validate_modrinth_index() {
  local index="$1"

  [[ -f "$index" ]] || die "Modrinth index not found: ${index}"

  jq -e '
    type == "object"
    and (.formatVersion | type == "number")
    and .game == "minecraft"
    and (.versionId | type == "string")
    and (.files | type == "array")
    and ((has("dependencies") | not) or (
      (.dependencies | type == "object")
      and (.dependencies | to_entries | all(.[]; (.value | type == "string" and length > 0)))
    ))
    and (.files | all(.[];
      type == "object"
      and (.path | type == "string")
      and (.downloads | type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]+$")))
      and (.hashes | type == "object")
      and (.hashes.sha1 | type == "string")
      and (.hashes.sha512 | type == "string")
      and ((has("env") | not) or (.env | type == "object"))
      and (if has("env") and (.env | has("server")) then
        (.env.server == "required" or .env.server == "optional" or .env.server == "unsupported")
      else true end)
      and (if has("env") and (.env | has("client")) then
        (.env.client == "required" or .env.client == "optional" or .env.client == "unsupported")
      else true end)
    ))
  ' "$index" >/dev/null || die "Invalid Modrinth index schema: ${index}"
}

select_modrinth_server_files() {
  local index="$1"
  local include_optional=false
  local file path

  [[ -f "$index" ]] || die "Modrinth index not found: ${index}"
  if modpack_include_optional_enabled; then
    include_optional=true
  fi

  jq -c --argjson includeOptional "$include_optional" '
    .files[]
    | (.env.server? // "required") as $server
    | select($server == "required" or ($includeOptional and $server == "optional"))
  ' "$index" |
    while IFS= read -r file; do
      path="$(jq -er '.path' <<< "$file")" || die "Selected Modrinth file is missing path"
      safe_modpack_path "$path" file
      printf '%s\n' "$file"
    done
}

mrpack_runtime_marker() {
  printf '%s/.server-install.json' "${DATA_DIR:-/data}"
}

mrpack_runtime_marker_field() {
  local field="$1"
  local marker
  marker="$(mrpack_runtime_marker)"

  [[ -f "$marker" ]] || return 1
  if declare -F read_server_install_marker_field >/dev/null; then
    read_server_install_marker_field "$marker" "$field"
    return
  fi

  jq -er --arg field "$field" '
    type == "object"
    and has($field)
    and (.[$field] | type == "string")
    | if . then input_filename else empty end
  ' "$marker" >/dev/null 2>&1 || die "Invalid server install marker while validating modpack dependencies: ${marker}"
  jq -r --arg field "$field" '.[$field]' "$marker"
}

mrpack_runtime_type() {
  local value
  if value="$(mrpack_runtime_marker_field type 2>/dev/null)"; then
    printf '%s\n' "${value,,}"
  else
    printf '%s\n' "${TYPE:-}"
  fi
}

mrpack_runtime_version() {
  local value
  if value="$(mrpack_runtime_marker_field version 2>/dev/null)"; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "${VERSION:-}"
  fi
}

mrpack_explicit_loader_version() {
  local runtime_type="$1"
  local value=""

  case "$runtime_type" in
    fabric)
      value="${FABRIC_LOADER_VERSION:-}"
      [[ -n "$value" && "$value" != "latest" ]] || return 1
      ;;
    forge)
      value="${FORGE_VERSION:-}"
      [[ -n "$value" && "$value" != "latest" && "$value" != "recommended" ]] || return 1
      ;;
    neoforge)
      value="${NEOFORGE_VERSION:-}"
      [[ -n "$value" && "$value" != "latest" ]] || return 1
      ;;
    *)
      return 1
      ;;
  esac

  printf '%s\n' "$value"
}

mrpack_runtime_loader_version() {
  local runtime_type="$1"
  local marker_type marker_build

  marker_type="$(mrpack_runtime_marker_field type 2>/dev/null || true)"
  marker_build="$(mrpack_runtime_marker_field build 2>/dev/null || true)"
  if [[ "$marker_type" == "$runtime_type" && -n "$marker_build" ]]; then
    case "$runtime_type" in
      fabric|forge|neoforge)
        printf '%s\n' "$marker_build"
        return 0
        ;;
    esac
  fi

  mrpack_explicit_loader_version "$runtime_type"
}

mrpack_loader_type_for_dependency() {
  case "$1" in
    fabric-loader) printf '%s\n' fabric ;;
    quilt-loader) printf '%s\n' quilt ;;
    forge) printf '%s\n' forge ;;
    neoforge) printf '%s\n' neoforge ;;
    *) return 1 ;;
  esac
}

validate_mrpack_dependencies() {
  local index="$1"
  local minecraft_dependency loader_count loader_key loader_version expected_type
  local runtime_type runtime_version runtime_loader_version dependency_key dependency_value

  validate_modrinth_index "$index"

  minecraft_dependency="$(jq -r '.dependencies.minecraft // empty' "$index")"
  if [[ -n "$minecraft_dependency" ]]; then
    runtime_version="$(mrpack_runtime_version)"
    [[ -n "$runtime_version" ]] \
      || die "Cannot validate Modrinth minecraft dependency without configured VERSION or server install marker"
    [[ "$runtime_version" == "$minecraft_dependency" ]] \
      || die "Modpack Minecraft dependency mismatch: pack=${minecraft_dependency} server=${runtime_version}"
  fi

  loader_count="$(jq -r '
    [(.dependencies // {}) | to_entries[]
      | select(.key == "fabric-loader" or .key == "quilt-loader" or .key == "forge" or .key == "neoforge")]
    | length
  ' "$index")"
  [[ "$loader_count" -le 1 ]] \
    || die "Modpack declares multiple loader dependencies; Minecartainer requires one server loader"

  if [[ "$loader_count" -eq 1 ]]; then
    IFS=$'\t' read -r loader_key loader_version < <(jq -r '
      (.dependencies // {}) | to_entries[]
      | select(.key == "fabric-loader" or .key == "quilt-loader" or .key == "forge" or .key == "neoforge")
      | [.key, .value] | @tsv
    ' "$index")

    expected_type="$(mrpack_loader_type_for_dependency "$loader_key")"
    runtime_type="$(mrpack_runtime_type)"
    [[ -n "$runtime_type" ]] \
      || die "Cannot validate Modrinth loader dependency without configured TYPE or server install marker"
    [[ "$runtime_type" == "$expected_type" ]] \
      || die "Modpack loader dependency mismatch: pack requires ${loader_key}=${loader_version} but server TYPE=${runtime_type}"

    runtime_loader_version="$(mrpack_runtime_loader_version "$runtime_type" 2>/dev/null || true)"
    if [[ -n "$runtime_loader_version" ]]; then
      [[ "$runtime_loader_version" == "$loader_version" ]] \
        || die "Modpack loader version mismatch: pack ${loader_key}=${loader_version} server=${runtime_loader_version}"
    else
      log WARN "Could not verify exact ${loader_key} version ${loader_version}; server TYPE=${runtime_type} matches"
    fi
  fi

  while IFS=$'\t' read -r dependency_key dependency_value; do
    [[ -n "$dependency_key" ]] || continue
    case "$dependency_key" in
      minecraft|fabric-loader|quilt-loader|forge|neoforge) ;;
      *)
        log WARN "Unrecognized Modrinth dependency '${dependency_key}=${dependency_value}'; leaving it unvalidated"
        ;;
    esac
  done < <(jq -r '(.dependencies // {}) | to_entries[] | [.key, .value] | @tsv' "$index")
}

write_modpack_marker() {
  local marker="$1"
  local tmp_files="$2"
  local source_url="$3"
  local version_id="$4"
  local index_sha512="$5"
  local dependencies_json="${6:-{}}"
  local include_optional=false
  local tmp

  if modpack_include_optional_enabled; then
    include_optional=true
  fi

  tmp="$(mktemp "${marker}.tmp.XXXXXX")"
  if ! jq -n \
    --arg sourceUrl "$source_url" \
    --arg versionId "$version_id" \
    --arg indexSha512 "$index_sha512" \
    --arg installedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson includeOptional "$include_optional" \
    --argjson dependencies "$dependencies_json" \
    --slurpfile files "$tmp_files" \
    '{
      schemaVersion: 1,
      format: "mrpack",
      sourceUrl: $sourceUrl,
      versionId: $versionId,
      indexSha512: $indexSha512,
      installMode: "server",
      includeOptional: $includeOptional,
      dependencies: $dependencies,
      files: $files[0],
      overrides: [],
      installedAt: $installedAt
    }' > "$tmp"; then
    safe_rm_f "$tmp"
    return 1
  fi
  if ! safe_mv_f "$tmp" "$marker"; then
    safe_rm_f "$tmp"
    return 1
  fi
  set_readable_file_permissions "$marker"
}

modpack_marker_matches() {
  local marker="$1"
  local source_url="$2"
  local version_id="$3"
  local index_sha512="$4"
  local include_optional=false
  local relpath sha1 sha512

  if modpack_include_optional_enabled; then
    include_optional=true
  fi

  [[ -f "$marker" ]] || return 1
  jq -e 'type == "object" and .schemaVersion == 1 and (.files | type == "array")' "$marker" >/dev/null \
    || die "Invalid modpack install marker: ${marker}"

  jq -e \
    --arg sourceUrl "$source_url" \
    --arg versionId "$version_id" \
    --arg indexSha512 "$index_sha512" \
    --argjson includeOptional "$include_optional" \
    '.format == "mrpack"
      and .sourceUrl == $sourceUrl
      and .versionId == $versionId
      and .indexSha512 == $indexSha512
      and .installMode == "server"
      and ((.includeOptional // false) == $includeOptional)' "$marker" >/dev/null || return 1

  while IFS=$'\t' read -r relpath sha1 sha512; do
    [[ -n "$relpath" ]] || continue
    safe_modpack_path "$relpath" file
    modpack_file_hash_matches "${DATA_DIR}/${relpath}" "$sha1" "$sha512" || return 1
  done < <(jq -r '.files[] | [.path, .sha1, .sha512] | @tsv' "$marker")
}

install_modrinth_mrpack() {
  local archive="$1"
  local source_url="$2"
  local tmpdir index selected tmp_files marker version_id index_sha512 dependencies_json
  local file relpath url sha1 sha512 downloaded status

  tmpdir="$(mktemp -d)"
  index="${tmpdir}/modrinth.index.json"
  selected="${tmpdir}/selected.jsonl"
  tmp_files="${tmpdir}/files.json"
  marker="$(modpack_install_marker)"

  extract_mrpack_index "$archive" "$index"
  validate_modrinth_index "$index"
  validate_mrpack_dependencies "$index"
  version_id="$(jq -er '.versionId' "$index")"
  dependencies_json="$(jq -c '.dependencies // {}' "$index")"
  index_sha512="$(sha512sum "$index")"
  index_sha512="${index_sha512%% *}"

  if ! is_true "${MODPACK_FORCE_REINSTALL:-false}" \
    && modpack_marker_matches "$marker" "$source_url" "$version_id" "$index_sha512"; then
    log INFO "Modpack marker matches; skipping modpack install"
    safe_rm_rf "$tmpdir"
    return 0
  fi

  select_modrinth_server_files "$index" > "$selected"
  : > "$tmp_files"

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    relpath="$(jq -er '.path' <<< "$file")"
    url="$(jq -er '.downloads[0]' <<< "$file")"
    sha1="$(jq -er '.hashes.sha1' <<< "$file")"
    sha512="$(jq -er '.hashes.sha512' <<< "$file")"
    downloaded="$(mktemp "${tmpdir}/downloaded-$(basename "$relpath").XXXXXX")"

    download_modpack_file "$url" "$downloaded" "$relpath"
    verify_modpack_file "$downloaded" "$sha1" "$sha512" "$relpath"
    if install_modpack_file "$relpath" "$downloaded" "$sha1" "$sha512"; then
      jq -nc --arg path "$relpath" --arg sha1 "$sha1" --arg sha512 "$sha512" \
        '{path:$path,sha1:$sha1,sha512:$sha512}' >> "$tmp_files"
    else
      status=$?
      if [[ "$status" -ne 2 ]]; then
        safe_rm_rf "$tmpdir"
        return "$status"
      fi
    fi
  done < "$selected"

  if ! jq -s '.' "$tmp_files" > "${tmp_files}.array"; then
    safe_rm_rf "$tmpdir"
    return 1
  fi
  if ! write_modpack_marker \
    "$marker" "${tmp_files}.array" "$source_url" "$version_id" "$index_sha512" "$dependencies_json"; then
    safe_rm_rf "$tmpdir"
    return 1
  fi
  safe_rm_rf "$tmpdir"
  log INFO "Modpack install completed: ${version_id}"
}

install_modpack_with_overrides() {
  local format tmpdir archive source marker previous_marker

  [[ -n "${MODPACK_URL:-}" ]] || return 0

  [[ "${MODPACK_INSTALL_MODE}" == "server" ]] || die "Only MODPACK_INSTALL_MODE=server is supported in this phase"
  [[ "${MODPACK_FORMAT}" == "auto" || "${MODPACK_FORMAT}" == "mrpack" ]] || die "Only MODPACK_FORMAT=auto or mrpack is supported"
  is_true "${MODPACK_REMOVE_EXTRA:-false}" && die "MODPACK_REMOVE_EXTRA=true is not supported in this phase"

  format="${MODPACK_FORMAT}"
  if [[ "$format" == "auto" ]]; then
    case "${MODPACK_URL}" in
      *.mrpack) format="mrpack" ;;
      *) die "MODPACK_FORMAT=auto only recognizes .mrpack URLs in this phase" ;;
    esac
  fi

  [[ "$format" == "mrpack" ]] || die "Only Modrinth mrpack install is supported in this phase"

  tmpdir="$(mktemp -d)"
  archive="${tmpdir}/pack.mrpack"
  previous_marker="${tmpdir}/previous-marker.json"
  source="${MODPACK_URL}"
  marker="$(modpack_install_marker)"

  if [[ -f "$marker" ]]; then
    cp "$marker" "$previous_marker" \
      || { safe_rm_rf "$tmpdir"; die "Failed to preserve previous modpack marker"; }
  fi

  log INFO "Installing Modrinth mrpack"
  if modpack_include_optional_enabled; then
    log INFO "Including Modrinth files marked env.server=optional"
  fi
  download_modpack_file "$source" "$archive" "mrpack archive"
  if ! install_modrinth_mrpack "$archive" "$source"; then
    safe_rm_rf "$tmpdir"
    return 1
  fi
  if ! apply_modpack_overrides "$archive" "$previous_marker" "$marker" "$tmpdir"; then
    safe_rm_rf "$tmpdir"
    return 1
  fi
  safe_rm_rf "$tmpdir"
}

install_modpack() {
  install_modpack_with_overrides
}

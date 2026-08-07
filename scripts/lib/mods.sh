# shellcheck shell=bash

install_mods() {
  log INFO "Install mods"

  [[ "${MODS_ENABLED:-true}" == "true" ]] || {
    log INFO "Mods disabled"
    return
  }

  [[ -n "${MODS_S3_BUCKET:-}" ]] || {
    log INFO "MODS_S3_BUCKET not set, skipping mods"
    return
  }

  MODS_DIR="${INPUT_MODS_DIR}"
  mkdir -p "${MODS_DIR}"

  if [[ "${MODS_SYNC_ONCE}" == "true" ]] \
    && [[ -n "$(ls -A "${MODS_DIR}")" ]] \
    && [[ "${MODS_REMOVE_EXTRA}" != "true" ]]; then
    log INFO "Mods already present, skipping sync"
    return
  fi


  log INFO "Configuring S3 client"
  configure_s3_client "mods"

  local -a remove_args=()
  if [[ "${MODS_REMOVE_EXTRA}" == "true" ]]; then
    remove_args=(--remove)
    ensure_s3_source_nonempty_for_remove "s3/${MODS_S3_BUCKET}/${MODS_S3_PREFIX}" "mods"
  fi

  log INFO "Syncing mods from s3://${MODS_S3_BUCKET}/${MODS_S3_PREFIX}"

  s3_sync \
    "s3/${MODS_S3_BUCKET}/${MODS_S3_PREFIX}" \
    "${MODS_DIR}" \
    "${remove_args[@]}" \
    || die "Failed to sync mods from S3"

  shopt -s nullglob
  jars=("${MODS_DIR}"/*.jar)
  log INFO "Mods installed: ${#jars[@]}"
  shopt -u nullglob
}

activate_mods() {
  resolve_content_input_source INPUT_MODS_DIR /mods "${DATA_DIR}/mods" || return 1
  [[ "${CONTENT_INPUT_SOURCE_ALREADY_ACTIVE}" == true ]] && return 0
  activate_dir "${CONTENT_INPUT_SOURCE}" "${DATA_DIR}/mods" "mods"
}

extract_mrpack_index() {
  local archive="$1"
  local out="$2"

  [[ -f "$archive" ]] || die "mrpack archive not found: ${archive}"

  case "$out" in
    "${DATA_DIR}"|"${DATA_DIR}"/*)
      die "Refusing to write mrpack index under DATA_DIR: ${out}"
      ;;
  esac

  command -v unzip >/dev/null 2>&1 || die "unzip is required to read mrpack archives"

  if ! unzip -p "$archive" modrinth.index.json > "$out"; then
    die "modrinth.index.json not found in mrpack archive: ${archive}"
  fi

  [[ -s "$out" ]] || die "modrinth.index.json is empty: ${archive}"
  jq -e . "$out" >/dev/null || die "modrinth.index.json is not valid JSON: ${archive}"
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
    and ((has("dependencies") | not) or (.dependencies | type == "object"))
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

safe_modpack_path() {
  local path="$1"
  local kind="${2:-file}"
  local part
  local -a parts

  [[ -n "$path" ]] || die "Unsafe ${kind} path: empty"
  [[ "$path" != /* ]] || die "Unsafe ${kind} path: absolute path: ${path}"
  [[ ! "$path" =~ ^[A-Za-z]: ]] || die "Unsafe ${kind} path: Windows drive path: ${path}"
  [[ "$path" != *\\* ]] || die "Unsafe ${kind} path: backslash is not allowed: ${path}"

  if printf '%s' "$path" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    die "Unsafe ${kind} path: control character is not allowed"
  fi

  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    [[ "$part" != ".." ]] || die "Unsafe ${kind} path: parent traversal: ${path}"
    [[ -n "$part" ]] || die "Unsafe ${kind} path: empty path segment: ${path}"
  done

  case "$path" in
    world|world/*|saves|saves/*|logs|logs/*|.minecraft|.minecraft/*|\
    .server-install.json|.modpack-install.json|server.properties|eula.txt|ops.json|whitelist.json)
      die "Unsafe ${kind} path: reserved path: ${path}"
      ;;
  esac

  case "$path" in
    mods/*|config/*|defaultconfigs/*|datapacks/*|resourcepacks/*)
      return 0
      ;;
    *)
      die "Unsafe ${kind} path: outside allowed modpack paths: ${path}"
      ;;
  esac
}

select_modrinth_server_files() {
  local index="$1"
  local file path

  [[ -f "$index" ]] || die "Modrinth index not found: ${index}"

  jq -c '.files[] | select((.env.server? // "required") == "required")' "$index" |
    while IFS= read -r file; do
      path="$(jq -er '.path' <<< "$file")" || die "Selected Modrinth file is missing path"
      safe_modpack_path "$path" file
      printf '%s\n' "$file"
    done
}

modpack_install_marker() {
  printf '%s/.modpack-install.json' "${DATA_DIR}"
}

modpack_file_hash_matches() {
  local file="$1"
  local sha1="$2"
  local sha512="$3"

  [[ -f "$file" ]] || return 1
  echo "${sha512}  ${file}" | sha512sum -c - >/dev/null 2>&1 || return 1
  echo "${sha1}  ${file}" | sha1sum -c - >/dev/null 2>&1 || return 1
}

modpack_marker_has_file() {
  local relpath="$1"
  local marker
  marker="$(modpack_install_marker)"

  [[ -f "$marker" ]] || return 1
  jq -e 'type == "object" and .schemaVersion == 1 and (.files | type == "array")' "$marker" >/dev/null \
    || die "Invalid modpack install marker: ${marker}"
  jq -e --arg path "$relpath" '.files[]? | select(.path == $path)' "$marker" >/dev/null
}

download_modpack_file() {
  local url="$1"
  local out="$2"
  local label="$3"
  local src

  case "$url" in
    file://*)
      is_true "${MODPACK_ALLOW_FILE_URL:-false}" || die "file:// modpack downloads require MODPACK_ALLOW_FILE_URL=true"
      src="${url#file://}"
      [[ -f "$src" ]] || die "Local modpack source not found for ${label}"
      if ! cp "$src" "$out"; then
        safe_rm_f "$out"
        die "Failed to copy local modpack source for ${label}"
      fi
      ;;
    https://*)
      command -v curl >/dev/null 2>&1 || die "curl is required for HTTPS modpack downloads"
      if ! curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --proto '=https' \
        --proto-redir '=https' \
        --retry 3 \
        --retry-delay 1 \
        --retry-all-errors \
        --connect-timeout 15 \
        --max-time 300 \
        --output "$out" \
        -- "$url"; then
        safe_rm_f "$out"
        die "Failed to download modpack file: ${label}"
      fi
      ;;
    *)
      die "Unsupported modpack download URL for ${label}"
      ;;
  esac

  if [[ ! -s "$out" ]]; then
    safe_rm_f "$out"
    die "Downloaded modpack file is empty for ${label}"
  fi
}

verify_modpack_file() {
  local file="$1"
  local sha1="$2"
  local sha512="$3"
  local label="$4"

  echo "${sha512}  ${file}" | sha512sum -c - >/dev/null || die "SHA512 mismatch for modpack file: ${label}"
  echo "${sha1}  ${file}" | sha1sum -c - >/dev/null || die "SHA1 mismatch for modpack file: ${label}"
}

install_modpack_file() {
  local relpath="$1"
  local src="$2"
  local sha1="$3"
  local sha512="$4"
  local target parent tmp

  safe_modpack_path "$relpath" file
  target="${DATA_DIR}/${relpath}"
  parent="$(dirname "$target")"

  case "$target" in
    "${DATA_DIR}"/*) ;;
    *) die "Refusing to install modpack file outside DATA_DIR: ${relpath}" ;;
  esac

  if [[ -e "$target" ]]; then
    if modpack_file_hash_matches "$target" "$sha1" "$sha512"; then
      log INFO "Modpack file already present with expected hash: ${relpath}"
      return 0
    fi

    if modpack_marker_has_file "$relpath"; then
      log INFO "Replacing previously managed modpack file: ${relpath}"
    elif [[ "$relpath" == *.jar ]]; then
      die "Refusing to overwrite user-owned jar from modpack: ${relpath}"
    else
      log INFO "Skipping existing user-owned modpack seed file: ${relpath}"
      return 2
    fi
  fi

  mkdir -p "$parent"
  tmp="$(mktemp "${parent}/.$(basename "$target").tmp.XXXXXX")"
  cp "$src" "$tmp" || {
    safe_rm_f "$tmp"
    die "Failed to stage modpack file: ${relpath}"
  }
  if ! safe_mv_f "$tmp" "$target"; then
    safe_rm_f "$tmp"
    return 1
  fi
  set_readable_file_permissions "$target"
}

write_modpack_marker() {
  local marker="$1"
  local tmp_files="$2"
  local source_url="$3"
  local version_id="$4"
  local index_sha512="$5"
  local tmp

  tmp="$(mktemp "${marker}.tmp.XXXXXX")"
  if ! jq -n \
    --arg sourceUrl "$source_url" \
    --arg versionId "$version_id" \
    --arg indexSha512 "$index_sha512" \
    --arg installedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --slurpfile files "$tmp_files" \
    '{
      schemaVersion: 1,
      format: "mrpack",
      sourceUrl: $sourceUrl,
      versionId: $versionId,
      indexSha512: $indexSha512,
      installMode: "server",
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
  local relpath sha1 sha512

  [[ -f "$marker" ]] || return 1
  jq -e 'type == "object" and .schemaVersion == 1 and (.files | type == "array")' "$marker" >/dev/null \
    || die "Invalid modpack install marker: ${marker}"

  jq -e \
    --arg sourceUrl "$source_url" \
    --arg versionId "$version_id" \
    --arg indexSha512 "$index_sha512" \
    '.format == "mrpack"
      and .sourceUrl == $sourceUrl
      and .versionId == $versionId
      and .indexSha512 == $indexSha512
      and .installMode == "server"' "$marker" >/dev/null || return 1

  while IFS=$'\t' read -r relpath sha1 sha512; do
    [[ -n "$relpath" ]] || continue
    safe_modpack_path "$relpath" file
    modpack_file_hash_matches "${DATA_DIR}/${relpath}" "$sha1" "$sha512" || return 1
  done < <(jq -r '.files[] | [.path, .sha1, .sha512] | @tsv' "$marker")
}

install_modrinth_mrpack() {
  local archive="$1"
  local source_url="$2"
  local tmpdir index selected tmp_files marker version_id index_sha512
  local file relpath url sha1 sha512 downloaded

  tmpdir="$(mktemp -d)"
  index="${tmpdir}/modrinth.index.json"
  selected="${tmpdir}/selected.jsonl"
  tmp_files="${tmpdir}/files.json"
  marker="$(modpack_install_marker)"

  extract_mrpack_index "$archive" "$index"
  validate_modrinth_index "$index"
  version_id="$(jq -er '.versionId' "$index")"
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
      local status=$?
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
  if ! write_modpack_marker "$marker" "${tmp_files}.array" "$source_url" "$version_id" "$index_sha512"; then
    safe_rm_rf "$tmpdir"
    return 1
  fi
  safe_rm_rf "$tmpdir"
  log INFO "Modpack install completed: ${version_id}"
}

install_modpack() {
  local format tmpdir archive source

  [[ -n "${MODPACK_URL:-}" ]] || return 0

  [[ "${MODPACK_INSTALL_MODE}" == "server" ]] || die "Only MODPACK_INSTALL_MODE=server is supported in this phase"
  [[ "${MODPACK_FORMAT}" == "auto" || "${MODPACK_FORMAT}" == "mrpack" ]] || die "Only MODPACK_FORMAT=auto or mrpack is supported"
  is_true "${MODPACK_REMOVE_EXTRA:-false}" && die "MODPACK_REMOVE_EXTRA=true is not supported in this phase"
  is_true "${MODPACK_INCLUDE_OPTIONAL:-false}" && die "MODPACK_INCLUDE_OPTIONAL=true is not supported in this phase"

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
  source="${MODPACK_URL}"

  log INFO "Installing Modrinth mrpack"
  download_modpack_file "$source" "$archive" "mrpack archive"
  if ! install_modrinth_mrpack "$archive" "$source"; then
    safe_rm_rf "$tmpdir"
    return 1
  fi
  safe_rm_rf "$tmpdir"
}

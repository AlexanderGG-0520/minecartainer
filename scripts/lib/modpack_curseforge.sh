# shellcheck shell=bash

curseforge_modpack_format_enabled() {
  [[ "${MODPACK_FORMAT:-auto}" == "curseforge" ]]
}

resolve_modpack_install_format() {
  local requested="${MODPACK_FORMAT:-auto}"

  case "$requested" in
    mrpack|curseforge)
      printf '%s\n' "$requested"
      ;;
    auto)
      case "${MODPACK_URL:-}" in
        *.mrpack|*.mrpack\?*) printf '%s\n' mrpack ;;
        *.zip|*.zip\?*)
          die "MODPACK_FORMAT=auto does not guess generic .zip files; set MODPACK_FORMAT=curseforge explicitly for a CurseForge export"
          return 1
          ;;
        *)
          die "MODPACK_FORMAT=auto only recognizes Modrinth .mrpack URLs; set MODPACK_FORMAT explicitly for other formats"
          return 1
          ;;
      esac
      ;;
    *)
      die "Unsupported MODPACK_FORMAT=${requested}; supported values are auto, mrpack, and curseforge"
      return 1
      ;;
  esac
}

extract_curseforge_manifest() {
  local archive="$1"
  local out="$2"

  [[ -f "$archive" ]] || { die "CurseForge archive not found: ${archive}"; return 1; }
  case "$out" in
    "${DATA_DIR}"|"${DATA_DIR}"/*)
      die "Refusing to write CurseForge manifest under DATA_DIR: ${out}"
      return 1
      ;;
  esac

  command -v unzip >/dev/null 2>&1 || { die "unzip is required to read CurseForge modpack archives"; return 1; }
  if ! unzip -p "$archive" manifest.json > "$out"; then
    die "manifest.json not found in CurseForge archive: ${archive}"
    return 1
  fi
  [[ -s "$out" ]] || { die "manifest.json is empty in CurseForge archive: ${archive}"; return 1; }
  jq -e . "$out" >/dev/null || { die "manifest.json is not valid JSON in CurseForge archive: ${archive}"; return 1; }
}

validate_curseforge_manifest() {
  local manifest="$1"

  [[ -f "$manifest" ]] || { die "CurseForge manifest not found: ${manifest}"; return 1; }

  jq -e '
    type == "object"
    and .manifestType == "minecraftModpack"
    and .manifestVersion == 1
    and (.name | type == "string" and length > 0)
    and (.version | type == "string" and length > 0)
    and (.minecraft | type == "object")
    and (.minecraft.version | type == "string" and length > 0)
    and (.minecraft.modLoaders | type == "array" and length > 0)
    and (.minecraft.modLoaders | all(.[];
      type == "object"
      and (.id | type == "string" and length > 0)
      and (.primary | type == "boolean")
    ))
    and ([.minecraft.modLoaders[] | select(.primary == true)] | length == 1)
    and (.files | type == "array")
    and (.files | all(.[];
      type == "object"
      and (.projectID | type == "number" and floor == . and . > 0)
      and (.fileID | type == "number" and floor == . and . > 0)
      and (.required | type == "boolean")
    ))
    and ((has("overrides") | not) or .overrides == "overrides")
  ' "$manifest" >/dev/null || {
    die "Invalid or unsupported CurseForge manifest schema: ${manifest}"
    return 1
  }
}

curseforge_primary_loader() {
  local manifest="$1"
  local loader_id loader_type loader_version

  loader_id="$(jq -er '[.minecraft.modLoaders[] | select(.primary == true)][0].id' "$manifest")" || {
    die "CurseForge manifest is missing a primary mod loader"
    return 1
  }

  case "$loader_id" in
    forge-*) loader_type=forge; loader_version="${loader_id#forge-}" ;;
    fabric-*) loader_type=fabric; loader_version="${loader_id#fabric-}" ;;
    neoforge-*) loader_type=neoforge; loader_version="${loader_id#neoforge-}" ;;
    quilt-*) loader_type=quilt; loader_version="${loader_id#quilt-}" ;;
    *)
      die "Unsupported CurseForge primary mod loader: ${loader_id}"
      return 1
      ;;
  esac

  [[ -n "$loader_version" ]] || {
    die "CurseForge primary mod loader has no version: ${loader_id}"
    return 1
  }
  printf '%s\t%s\t%s\n' "$loader_type" "$loader_version" "$loader_id"
}

validate_curseforge_runtime() {
  local manifest="$1"
  local pack_minecraft runtime_version runtime_type loader_type loader_version loader_id runtime_loader_version

  pack_minecraft="$(jq -er '.minecraft.version' "$manifest")" || return 1
  runtime_version="$(mrpack_runtime_version)"
  [[ -n "$runtime_version" ]] || {
    die "Cannot validate CurseForge Minecraft version without configured VERSION or server install marker"
    return 1
  }
  [[ "$runtime_version" == "$pack_minecraft" ]] || {
    die "CurseForge Minecraft version mismatch: pack=${pack_minecraft} server=${runtime_version}"
    return 1
  }

  IFS=$'\t' read -r loader_type loader_version loader_id < <(curseforge_primary_loader "$manifest") || return 1
  runtime_type="$(mrpack_runtime_type)"
  [[ -n "$runtime_type" ]] || {
    die "Cannot validate CurseForge loader without configured TYPE or server install marker"
    return 1
  }
  [[ "$runtime_type" == "$loader_type" ]] || {
    die "CurseForge loader mismatch: pack requires ${loader_id} but server TYPE=${runtime_type}"
    return 1
  }

  runtime_loader_version="$(mrpack_runtime_loader_version "$runtime_type" 2>/dev/null || true)"
  if [[ -n "$runtime_loader_version" ]]; then
    [[ "$runtime_loader_version" == "$loader_version" ]] || {
      die "CurseForge loader version mismatch: pack ${loader_id} server=${runtime_loader_version}"
      return 1
    }
  else
    log WARN "Could not verify exact CurseForge loader version ${loader_id}; server TYPE=${runtime_type} matches"
  fi
}

curseforge_api_get() {
  local api_path="$1"
  local out="$2"
  local label="$3"
  local api_key="${CURSEFORGE_API_KEY:-}"

  [[ -n "$api_key" ]] || {
    die "CURSEFORGE_API_KEY is required to resolve CurseForge manifest files"
    return 1
  }
  command -v curl >/dev/null 2>&1 || { die "curl is required for CurseForge API access"; return 1; }
  [[ "$api_path" == /v1/* ]] || { die "Refusing unexpected CurseForge API path for ${label}"; return 1; }

  # Do not follow redirects here. The API key is only ever sent to the fixed
  # CurseForge API origin and is never forwarded to a download/CDN host.
  if ! curl \
    --fail \
    --silent \
    --show-error \
    --proto '=https' \
    --retry 3 \
    --retry-delay 1 \
    --retry-all-errors \
    --connect-timeout 15 \
    --max-time 60 \
    --header 'Accept: application/json' \
    --header "x-api-key: ${api_key}" \
    --output "$out" \
    -- "https://api.curseforge.com${api_path}"; then
    safe_rm_f "$out"
    die "CurseForge API request failed for ${label}"
    return 1
  fi

  [[ -s "$out" ]] || {
    safe_rm_f "$out"
    die "CurseForge API returned an empty response for ${label}"
    return 1
  }
  jq -e . "$out" >/dev/null || {
    safe_rm_f "$out"
    die "CurseForge API returned invalid JSON for ${label}"
    return 1
  }
}

curseforge_file_metadata() {
  local project_id="$1"
  local file_id="$2"
  local out="$3"
  local file_name sha1

  curseforge_api_get "/v1/mods/${project_id}/files/${file_id}" "$out" "project ${project_id} file ${file_id}" || return 1
  jq -e \
    --argjson projectId "$project_id" \
    --argjson fileId "$file_id" '
      .data | type == "object"
      and .modId == $projectId
      and .id == $fileId
      and (.isAvailable != false)
      and (.fileName | type == "string" and length > 0)
      and (.hashes | type == "array")
      and ([.hashes[] | select(.algo == 1 and (.value | type == "string" and length > 0))] | length >= 1)
    ' "$out" >/dev/null || {
      die "CurseForge file metadata is unavailable, mismatched, or lacks SHA-1 for project ${project_id} file ${file_id}"
      return 1
    }

  file_name="$(jq -er '.data.fileName' "$out")" || return 1
  [[ "$file_name" != */* && "$file_name" != *\\* && "$file_name" != "." && "$file_name" != ".." ]] || {
    die "Unsafe CurseForge file name for project ${project_id} file ${file_id}: ${file_name}"
    return 1
  }

  sha1="$(jq -er '[.data.hashes[] | select(.algo == 1)][0].value | ascii_downcase' "$out")" || return 1
  [[ "$sha1" =~ ^[0-9a-f]{40}$ ]] || {
    die "Invalid CurseForge SHA-1 for project ${project_id} file ${file_id}"
    return 1
  }

  printf '%s\t%s\n' "$file_name" "$sha1"
}

curseforge_file_download_url() {
  local project_id="$1"
  local file_id="$2"
  local out="$3"
  local url

  curseforge_api_get "/v1/mods/${project_id}/files/${file_id}/download-url" "$out" "download URL for project ${project_id} file ${file_id}" || return 1
  url="$(jq -er '.data | select(type == "string" and length > 0)' "$out")" || {
    die "CurseForge did not provide a download URL for project ${project_id} file ${file_id}; distribution may be restricted"
    return 1
  }
  case "$url" in
    https://*) printf '%s\n' "$url" ;;
    *)
      die "CurseForge returned a non-HTTPS download URL for project ${project_id} file ${file_id}"
      return 1
      ;;
  esac
}

select_curseforge_manifest_files() {
  local manifest="$1"
  local include_optional=false

  if modpack_include_optional_enabled; then
    include_optional=true
  fi

  jq -c --argjson includeOptional "$include_optional" '
    .files[]
    | select(.required == true or $includeOptional)
  ' "$manifest"
}

write_curseforge_marker() {
  local marker="$1"
  local files_array="$2"
  local source_url="$3"
  local manifest="$4"
  local manifest_sha512="$5"
  local pack_name pack_version minecraft loader_id include_optional=false tmp

  pack_name="$(jq -er '.name' "$manifest")" || return 1
  pack_version="$(jq -er '.version' "$manifest")" || return 1
  minecraft="$(jq -er '.minecraft.version' "$manifest")" || return 1
  loader_id="$(jq -er '[.minecraft.modLoaders[] | select(.primary == true)][0].id' "$manifest")" || return 1
  if modpack_include_optional_enabled; then
    include_optional=true
  fi

  tmp="$(mktemp "${marker}.tmp.XXXXXX")"
  if ! jq -n \
    --arg sourceUrl "$source_url" \
    --arg name "$pack_name" \
    --arg versionId "$pack_version" \
    --arg manifestSha512 "$manifest_sha512" \
    --arg installedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg minecraft "$minecraft" \
    --arg loader "$loader_id" \
    --argjson includeOptional "$include_optional" \
    --slurpfile files "$files_array" \
    '{
      schemaVersion: 1,
      format: "curseforge",
      sourceUrl: $sourceUrl,
      name: $name,
      versionId: $versionId,
      manifestSha512: $manifestSha512,
      installMode: "server",
      includeOptional: $includeOptional,
      dependencies: {minecraft:$minecraft, loader:$loader},
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

curseforge_marker_matches() {
  local marker="$1"
  local source_url="$2"
  local manifest="$3"
  local manifest_sha512="$4"
  local pack_version include_optional=false relpath sha1 sha512

  [[ -f "$marker" ]] || return 1
  pack_version="$(jq -er '.version' "$manifest")" || return 1
  if modpack_include_optional_enabled; then
    include_optional=true
  fi

  jq -e '
    type == "object"
    and .schemaVersion == 1
    and (.files | type == "array")
    and (((.overrides // []) | type) == "array")
  ' "$marker" >/dev/null || { die "Invalid modpack install marker: ${marker}"; return 1; }
  jq -e \
    --arg sourceUrl "$source_url" \
    --arg versionId "$pack_version" \
    --arg manifestSha512 "$manifest_sha512" \
    --argjson includeOptional "$include_optional" '
      .format == "curseforge"
      and .sourceUrl == $sourceUrl
      and .versionId == $versionId
      and .manifestSha512 == $manifestSha512
      and .installMode == "server"
      and ((.includeOptional // false) == $includeOptional)
    ' "$marker" >/dev/null || return 1

  while IFS=$'\t' read -r relpath sha1 sha512; do
    [[ -n "$relpath" ]] || continue
    safe_modpack_path "$relpath" file || return 1
    modpack_file_hash_matches "${DATA_DIR}/${relpath}" "$sha1" "$sha512" || return 1
  done < <(jq -r '.files[] | [.path, .sha1, .sha512] | @tsv' "$marker")

  while IFS=$'\t' read -r relpath sha512; do
    [[ -n "$relpath" ]] || continue
    safe_modpack_path "$relpath" override || return 1
    modpack_override_hash_matches "${DATA_DIR}/${relpath}" "$sha512" || return 1
  done < <(jq -r '.overrides[]? | select(.action == "seeded") | [.path, .sha512] | @tsv' "$marker")
}

apply_curseforge_overrides() {
  local archive="$1"
  local manifest="$2"
  local previous_marker="$3"
  local marker="$4"
  local tmpdir="$5"
  local override_dir listing entries current_seeded records

  override_dir="$(jq -r '.overrides // empty' "$manifest")"
  records="${tmpdir}/curseforge-override-records.jsonl"
  : > "$records"
  if [[ -z "$override_dir" ]]; then
    write_modpack_overrides_to_marker "$marker" "$records" "$tmpdir"
    return
  fi
  [[ "$override_dir" == "overrides" ]] || {
    die "Only the standard CurseForge overrides directory is supported"
    return 1
  }

  listing="${tmpdir}/curseforge-archive-entries.txt"
  entries="${tmpdir}/curseforge-overrides.tsv"
  current_seeded="${tmpdir}/curseforge-current-seeded.txt"

  command -v unzip >/dev/null 2>&1 || { die "unzip is required to apply CurseForge overrides"; return 1; }
  unzip -Z1 "$archive" > "$listing" || { die "Failed to list CurseForge archive entries"; return 1; }
  collect_modpack_override_entries "$listing" "$override_dir" "$entries" || return 1
  : > "$current_seeded"

  apply_modpack_override_layer \
    "$archive" "$entries" curseforge-overrides "$previous_marker" \
    "$current_seeded" "$records" "$tmpdir" || return 1
  write_modpack_overrides_to_marker "$marker" "$records" "$tmpdir"
}

install_curseforge_modpack() {
  local archive="$1"
  local source_url="$2"
  local previous_marker="$3"
  local tmpdir manifest selected files_json marker manifest_sha512
  local entry project_id file_id metadata download_meta file_name sha1 relpath download_url downloaded sha512 status
  declare -A seen_paths=()

  tmpdir="$(mktemp -d)"
  manifest="${tmpdir}/manifest.json"
  selected="${tmpdir}/selected.jsonl"
  files_json="${tmpdir}/files.jsonl"
  marker="$(modpack_install_marker)"

  extract_curseforge_manifest "$archive" "$manifest" || { safe_rm_rf "$tmpdir"; return 1; }
  validate_curseforge_manifest "$manifest" || { safe_rm_rf "$tmpdir"; return 1; }
  validate_curseforge_runtime "$manifest" || { safe_rm_rf "$tmpdir"; return 1; }
  manifest_sha512="$(sha512sum "$manifest")"
  manifest_sha512="${manifest_sha512%% *}"

  if ! is_true "${MODPACK_FORCE_REINSTALL:-false}" \
    && curseforge_marker_matches "$marker" "$source_url" "$manifest" "$manifest_sha512"; then
    log INFO "CurseForge modpack marker matches; skipping file downloads"
    safe_rm_rf "$tmpdir"
    return 0
  fi

  select_curseforge_manifest_files "$manifest" > "$selected" || { safe_rm_rf "$tmpdir"; return 1; }
  : > "$files_json"

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    project_id="$(jq -er '.projectID' <<< "$entry")" || { safe_rm_rf "$tmpdir"; return 1; }
    file_id="$(jq -er '.fileID' <<< "$entry")" || { safe_rm_rf "$tmpdir"; return 1; }
    metadata="${tmpdir}/metadata-${project_id}-${file_id}.json"
    download_meta="${tmpdir}/download-url-${project_id}-${file_id}.json"

    IFS=$'\t' read -r file_name sha1 < <(curseforge_file_metadata "$project_id" "$file_id" "$metadata") || {
      safe_rm_rf "$tmpdir"
      return 1
    }
    relpath="mods/${file_name}"
    safe_modpack_path "$relpath" file || { safe_rm_rf "$tmpdir"; return 1; }
    if [[ -n "${seen_paths[$relpath]+x}" ]]; then
      safe_rm_rf "$tmpdir"
      die "CurseForge manifest resolves multiple files to the same target: ${relpath}"
      return 1
    fi
    seen_paths["$relpath"]=1

    download_url="$(curseforge_file_download_url "$project_id" "$file_id" "$download_meta")" || {
      safe_rm_rf "$tmpdir"
      return 1
    }
    downloaded="$(mktemp "${tmpdir}/downloaded-${file_id}.XXXXXX")"
    download_modpack_file "$download_url" "$downloaded" "$relpath" || { safe_rm_rf "$tmpdir"; return 1; }
    echo "${sha1}  ${downloaded}" | sha1sum -c - >/dev/null || {
      safe_rm_rf "$tmpdir"
      die "SHA1 mismatch for CurseForge file: ${relpath}"
      return 1
    }
    sha512="$(sha512sum "$downloaded")"
    sha512="${sha512%% *}"

    if install_modpack_file "$relpath" "$downloaded" "$sha1" "$sha512"; then
      jq -nc \
        --arg path "$relpath" \
        --arg sha1 "$sha1" \
        --arg sha512 "$sha512" \
        --argjson projectId "$project_id" \
        --argjson fileId "$file_id" \
        '{path:$path,sha1:$sha1,sha512:$sha512,projectId:$projectId,fileId:$fileId}' >> "$files_json"
    else
      status=$?
      if [[ "$status" -ne 2 ]]; then
        safe_rm_rf "$tmpdir"
        return "$status"
      fi
    fi
  done < "$selected"

  jq -s '.' "$files_json" > "${files_json}.array" || { safe_rm_rf "$tmpdir"; return 1; }
  write_curseforge_marker "$marker" "${files_json}.array" "$source_url" "$manifest" "$manifest_sha512" \
    || { safe_rm_rf "$tmpdir"; return 1; }
  apply_curseforge_overrides "$archive" "$manifest" "$previous_marker" "$marker" "$tmpdir" \
    || { safe_rm_rf "$tmpdir"; return 1; }

  safe_rm_rf "$tmpdir"
  log INFO "CurseForge modpack install completed"
}

install_curseforge_modpack_with_overrides() {
  local tmpdir archive source marker previous_marker

  modpack_remove_extra_enabled && {
    die "MODPACK_REMOVE_EXTRA=true is not yet supported for CurseForge packs"
    return 1
  }
  modpack_runtime_inference_enabled && {
    die "MODPACK_INFER_RUNTIME=true currently supports Modrinth mrpack only; configure TYPE and VERSION explicitly for CurseForge"
    return 1
  }

  tmpdir="$(mktemp -d)"
  archive="${tmpdir}/pack.zip"
  previous_marker="${tmpdir}/previous-marker.json"
  source="${MODPACK_URL}"
  marker="$(modpack_install_marker)"

  if [[ -f "$marker" ]]; then
    cp "$marker" "$previous_marker" || {
      safe_rm_rf "$tmpdir"
      die "Failed to preserve previous modpack marker"
      return 1
    }
  fi

  log INFO "Installing CurseForge modpack export"
  if modpack_include_optional_enabled; then
    log INFO "Including CurseForge manifest entries marked required=false"
  fi
  download_modpack_file "$source" "$archive" "CurseForge modpack archive" || { safe_rm_rf "$tmpdir"; return 1; }
  install_curseforge_modpack "$archive" "$source" "$previous_marker" || { safe_rm_rf "$tmpdir"; return 1; }
  safe_rm_rf "$tmpdir"
}

install_modpack_dispatch() {
  local format

  [[ -n "${MODPACK_URL:-}" ]] || return 0
  [[ "${MODPACK_INSTALL_MODE:-server}" == "server" ]] || {
    die "Only MODPACK_INSTALL_MODE=server is supported"
    return 1
  }

  format="$(resolve_modpack_install_format)" || return 1
  case "$format" in
    mrpack)
      install_modpack_with_overrides
      ;;
    curseforge)
      install_curseforge_modpack_with_overrides
      ;;
    *)
      die "Internal error: unsupported resolved modpack format ${format}"
      return 1
      ;;
  esac
}

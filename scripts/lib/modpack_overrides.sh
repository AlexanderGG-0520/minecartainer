# shellcheck shell=bash

modpack_override_hash_matches() {
  local file="$1"
  local sha512="$2"

  [[ -f "$file" ]] || return 1
  echo "${sha512}  ${file}" | sha512sum -c - >/dev/null 2>&1
}

modpack_previous_override_is_managed() {
  local marker="$1"
  local relpath="$2"
  local target="$3"
  local sha512

  [[ -f "$marker" ]] || return 1

  jq -e '
    type == "object"
    and ((.overrides // []) | type == "array")
    and ((.overrides // []) | all(.[];
      type == "object"
      and (.path | type == "string")
      and (.action == "seeded" or .action == "skipped")
      and (if .action == "seeded" then (.sha512 | type == "string") else true end)
    ))
  ' "$marker" >/dev/null || die "Invalid modpack override marker: ${marker}"

  sha512="$(jq -er --arg path "$relpath" '
    [.overrides[]? | select(.path == $path and .action == "seeded")]
    | if length == 1 then .[0].sha512 else empty end
  ' "$marker")" || return 1

  modpack_override_hash_matches "$target" "$sha512"
}

modpack_override_target_path() {
  local relpath="$1"
  local data_real target target_real

  safe_modpack_path "$relpath" override
  command -v realpath >/dev/null 2>&1 || die "realpath is required for modpack override safety"

  data_real="$(realpath -e -- "${DATA_DIR}")" \
    || die "Failed to resolve DATA_DIR for modpack override safety: ${DATA_DIR}"
  target="${DATA_DIR}/${relpath}"
  target_real="$(realpath -m -- "$target")" \
    || die "Failed to resolve modpack override target: ${relpath}"

  case "$target_real" in
    "${data_real}"/*)
      printf '%s\n' "$target"
      ;;
    *)
      die "Refusing modpack override target outside DATA_DIR: ${relpath}"
      ;;
  esac
}

collect_modpack_override_entries() {
  local listing="$1"
  local prefix="$2"
  local out="$3"
  local entry relpath
  declare -A seen=()

  : > "$out"
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    case "$entry" in
      "${prefix}"/*) ;;
      *) continue ;;
    esac

    [[ "$entry" == */ ]] && continue
    relpath="${entry#"${prefix}"/}"
    safe_modpack_path "$relpath" override

    if [[ -n "${seen[$relpath]+x}" ]]; then
      die "Duplicate ${prefix} entry in mrpack: ${relpath}"
    fi
    seen["$relpath"]=1
    printf '%s\t%s\n' "$relpath" "$entry" >> "$out"
  done < "$listing"
}

modpack_current_seeded_has_path() {
  local seeded="$1"
  local relpath="$2"

  [[ -f "$seeded" ]] || return 1
  grep -Fx -- "$relpath" "$seeded" >/dev/null
}

record_modpack_override() {
  local records="$1"
  local relpath="$2"
  local layer="$3"
  local action="$4"
  local sha512="${5:-}"

  if [[ "$action" == "seeded" ]]; then
    jq -nc \
      --arg path "$relpath" \
      --arg layer "$layer" \
      --arg action "$action" \
      --arg sha512 "$sha512" \
      '{path:$path,layer:$layer,action:$action,sha512:$sha512}' >> "$records"
  else
    jq -nc \
      --arg path "$relpath" \
      --arg layer "$layer" \
      --arg action "$action" \
      '{path:$path,layer:$layer,action:$action}' >> "$records"
  fi
}

install_modpack_override_entry() {
  local archive="$1"
  local archive_entry="$2"
  local relpath="$3"
  local layer="$4"
  local previous_marker="$5"
  local current_seeded="$6"
  local records="$7"
  local tmpdir="$8"
  local target parent staged tmp sha512 allow_replace=false

  if modpack_marker_has_file "$relpath"; then
    die "Modpack override collides with indexed pack file: ${relpath}"
  fi

  if ! target="$(modpack_override_target_path "$relpath")"; then
    return 1
  fi
  parent="$(dirname "$target")"
  staged="$(mktemp "${tmpdir}/override.XXXXXX")"

  if ! unzip -p "$archive" "$archive_entry" > "$staged"; then
    safe_rm_f "$staged"
    die "Failed to extract ${layer} entry from mrpack: ${relpath}"
  fi
  sha512="$(sha512sum "$staged")"
  sha512="${sha512%% *}"

  if [[ -e "$target" || -L "$target" ]]; then
    if modpack_current_seeded_has_path "$current_seeded" "$relpath"; then
      allow_replace=true
      log INFO "Applying higher-priority ${layer} entry: ${relpath}"
    elif modpack_previous_override_is_managed "$previous_marker" "$relpath" "$target"; then
      allow_replace=true
      log INFO "Updating previously managed modpack override: ${relpath}"
    else
      log INFO "Skipping existing user-owned modpack override target: ${relpath}"
      record_modpack_override "$records" "$relpath" "$layer" skipped
      safe_rm_f "$staged"
      return 0
    fi
  fi

  mkdir -p "$parent"
  tmp="$(mktemp "${parent}/.$(basename "$target").tmp.XXXXXX")"
  if ! cp "$staged" "$tmp"; then
    safe_rm_f "$tmp"
    safe_rm_f "$staged"
    die "Failed to stage modpack override: ${relpath}"
  fi
  safe_rm_f "$staged"

  if [[ "$allow_replace" == true ]]; then
    log INFO "Replacing managed modpack override: ${relpath}"
  else
    log INFO "Seeding modpack override: ${relpath}"
  fi

  if ! safe_mv_f "$tmp" "$target"; then
    safe_rm_f "$tmp"
    return 1
  fi
  set_readable_file_permissions "$target"
  printf '%s\n' "$relpath" >> "$current_seeded"
  record_modpack_override "$records" "$relpath" "$layer" seeded "$sha512"
}

apply_modpack_override_layer() {
  local archive="$1"
  local entries="$2"
  local layer="$3"
  local previous_marker="$4"
  local current_seeded="$5"
  local records="$6"
  local tmpdir="$7"
  local relpath archive_entry

  while IFS=$'\t' read -r relpath archive_entry; do
    [[ -n "$relpath" ]] || continue
    if ! install_modpack_override_entry \
      "$archive" "$archive_entry" "$relpath" "$layer" \
      "$previous_marker" "$current_seeded" "$records" "$tmpdir"; then
      return 1
    fi
  done < "$entries"
}

write_modpack_overrides_to_marker() {
  local marker="$1"
  local records="$2"
  local tmpdir="$3"
  local overrides tmp

  [[ -f "$marker" ]] || die "Modpack install marker missing before override update: ${marker}"
  overrides="${tmpdir}/overrides.json"
  tmp="$(mktemp "${marker}.tmp.XXXXXX")"

  if ! jq -s '
    reduce .[] as $item ({}; .[$item.path] = $item)
    | to_entries
    | map(.value)
  ' "$records" > "$overrides"; then
    safe_rm_f "$tmp"
    return 1
  fi

  if ! jq --slurpfile overrides "$overrides" '.overrides = $overrides[0]' "$marker" > "$tmp"; then
    safe_rm_f "$tmp"
    return 1
  fi
  if ! safe_mv_f "$tmp" "$marker"; then
    safe_rm_f "$tmp"
    return 1
  fi
  set_readable_file_permissions "$marker"
}

apply_modpack_overrides() {
  local archive="$1"
  local previous_marker="$2"
  local marker="$3"
  local tmpdir="$4"
  local listing base_entries server_entries current_seeded records

  listing="${tmpdir}/archive-entries.txt"
  base_entries="${tmpdir}/overrides.tsv"
  server_entries="${tmpdir}/server-overrides.tsv"
  current_seeded="${tmpdir}/current-seeded.txt"
  records="${tmpdir}/override-records.jsonl"

  command -v unzip >/dev/null 2>&1 || die "unzip is required to apply mrpack overrides"
  if ! unzip -Z1 "$archive" > "$listing"; then
    die "Failed to list mrpack archive entries"
  fi

  collect_modpack_override_entries "$listing" overrides "$base_entries"
  collect_modpack_override_entries "$listing" server-overrides "$server_entries"
  : > "$current_seeded"
  : > "$records"

  if ! apply_modpack_override_layer \
    "$archive" "$base_entries" overrides "$previous_marker" \
    "$current_seeded" "$records" "$tmpdir"; then
    return 1
  fi
  if ! apply_modpack_override_layer \
    "$archive" "$server_entries" server-overrides "$previous_marker" \
    "$current_seeded" "$records" "$tmpdir"; then
    return 1
  fi

  write_modpack_overrides_to_marker "$marker" "$records" "$tmpdir"
}

# Extends the base mrpack workflow without re-downloading the archive. The
# original file/index installer remains in mods.sh; this wrapper adds the
# server-safe override layers before deleting the downloaded mrpack archive.
install_modpack_with_overrides() {
  local format tmpdir archive source marker previous_marker

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
  previous_marker="${tmpdir}/previous-marker.json"
  source="${MODPACK_URL}"
  marker="$(modpack_install_marker)"

  if [[ -f "$marker" ]]; then
    cp "$marker" "$previous_marker" \
      || { safe_rm_rf "$tmpdir"; die "Failed to preserve previous modpack marker"; }
  fi

  log INFO "Installing Modrinth mrpack"
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

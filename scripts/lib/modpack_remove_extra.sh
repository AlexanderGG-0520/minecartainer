# shellcheck shell=bash

modpack_remove_extra_enabled() {
  is_true "${MODPACK_REMOVE_EXTRA:-false}"
}

validate_modpack_cleanup_marker() {
  local marker="$1"

  [[ -f "$marker" ]] || return 0
  jq -e '
    type == "object"
    and .schemaVersion == 1
    and (.files | type == "array")
    and (.files | all(.[];
      type == "object"
      and (.path | type == "string")
      and (.sha512 | type == "string" and length > 0)
    ))
    and (((.overrides // []) | type) == "array")
    and ((.overrides // []) | all(.[];
      type == "object"
      and (.path | type == "string")
      and (.action == "seeded" or .action == "skipped")
      and (if .action == "seeded" then (.sha512 | type == "string" and length > 0) else true end)
    ))
    and (((.retainedManaged // []) | type) == "array")
    and ((.retainedManaged // []) | all(.[];
      type == "object"
      and (.path | type == "string")
      and (.sha512 | type == "string" and length > 0)
      and ((has("origin") | not) or (.origin | type == "string"))
    ))
  ' "$marker" >/dev/null || die "Invalid modpack marker for remove-extra reconciliation: ${marker}"
}

collect_previous_modpack_managed_entries() {
  local marker="$1"
  local out="$2"

  : > "$out"
  [[ -f "$marker" ]] || return 0
  validate_modpack_cleanup_marker "$marker"

  jq -c '
    [
      ((.retainedManaged // [])[] | {
        path: .path,
        sha512: .sha512,
        origin: (.origin // "retained")
      }),
      (.files[]? | {
        path: .path,
        sha512: .sha512,
        origin: "indexed"
      }),
      (.overrides[]? | select(.action == "seeded") | {
        path: .path,
        sha512: .sha512,
        origin: "override"
      })
    ]
    | reduce .[] as $item ({}; .[$item.path] = $item)
    | to_entries
    | map(.value)
    | sort_by(.path)
    | .[]
  ' "$marker" > "$out"
}

collect_current_modpack_paths() {
  local archive="$1"
  local out="$2"
  local tmpdir="$3"
  local index selected listing base_entries server_entries

  index="${tmpdir}/remove-extra-index.json"
  selected="${tmpdir}/remove-extra-selected.jsonl"
  listing="${tmpdir}/remove-extra-archive-entries.txt"
  base_entries="${tmpdir}/remove-extra-overrides.tsv"
  server_entries="${tmpdir}/remove-extra-server-overrides.tsv"

  extract_mrpack_index "$archive" "$index"
  validate_modrinth_index "$index"
  if ! select_modrinth_server_files "$index" > "$selected"; then
    return 1
  fi
  if ! jq -r '.path' "$selected" > "$out"; then
    return 1
  fi

  command -v unzip >/dev/null 2>&1 || die "unzip is required for mrpack remove-extra safety"
  if ! unzip -Z1 "$archive" > "$listing"; then
    die "Failed to list mrpack archive entries for remove-extra reconciliation"
  fi
  collect_modpack_override_entries "$listing" overrides "$base_entries"
  collect_modpack_override_entries "$listing" server-overrides "$server_entries"

  cut -f1 "$base_entries" >> "$out"
  cut -f1 "$server_entries" >> "$out"
  LC_ALL=C sort -u -o "$out" "$out"
}

modpack_cleanup_target_path() {
  local relpath="$1"
  local data_real target target_real

  safe_modpack_path "$relpath" managed-file
  command -v realpath >/dev/null 2>&1 || die "realpath is required for mrpack remove-extra safety"

  data_real="$(realpath -e -- "${DATA_DIR}")" \
    || die "Failed to resolve DATA_DIR for mrpack remove-extra safety: ${DATA_DIR}"
  target="${DATA_DIR}/${relpath}"
  target_real="$(realpath -m -- "$target")" \
    || die "Failed to resolve managed modpack target: ${relpath}"

  case "$target_real" in
    "${data_real}"/*)
      printf '%s\n' "$target"
      ;;
    *)
      die "Refusing mrpack remove-extra target outside DATA_DIR: ${relpath}"
      ;;
  esac
}

modpack_managed_sha512_matches() {
  local target="$1"
  local sha512="$2"

  [[ -f "$target" && ! -L "$target" ]] || return 1
  echo "${sha512}  ${target}" | sha512sum -c - >/dev/null 2>&1
}

record_retained_modpack_managed_entry() {
  local records="$1"
  local relpath="$2"
  local sha512="$3"
  local origin="$4"

  jq -nc \
    --arg path "$relpath" \
    --arg sha512 "$sha512" \
    --arg origin "$origin" \
    '{path:$path,sha512:$sha512,origin:$origin}' >> "$records"
}

write_retained_modpack_managed_entries() {
  local marker="$1"
  local records="$2"
  local tmpdir="$3"
  local retained tmp

  [[ -f "$marker" ]] || die "Modpack install marker missing before remove-extra reconciliation: ${marker}"
  retained="${tmpdir}/retained-managed.json"
  tmp="$(mktemp "${marker}.tmp.XXXXXX")"

  if ! jq -s '
    reduce .[] as $item ({}; .[$item.path] = $item)
    | to_entries
    | map(.value)
    | sort_by(.path)
  ' "$records" > "$retained"; then
    safe_rm_f "$tmp"
    return 1
  fi

  if ! jq --slurpfile retained "$retained" '.retainedManaged = $retained[0]' "$marker" > "$tmp"; then
    safe_rm_f "$tmp"
    return 1
  fi
  if ! safe_mv_f "$tmp" "$marker"; then
    safe_rm_f "$tmp"
    return 1
  fi
  set_readable_file_permissions "$marker"
}

reconcile_modpack_managed_extras() {
  local archive="$1"
  local previous_marker="$2"
  local marker="$3"
  local tmpdir="$4"
  local current_paths candidates retained
  local entry relpath sha512 origin target

  current_paths="${tmpdir}/current-modpack-paths.txt"
  candidates="${tmpdir}/previous-managed.jsonl"
  retained="${tmpdir}/retained-managed.jsonl"

  if ! collect_current_modpack_paths "$archive" "$current_paths" "$tmpdir"; then
    return 1
  fi
  collect_previous_modpack_managed_entries "$previous_marker" "$candidates"
  : > "$retained"

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    relpath="$(jq -er '.path' <<< "$entry")"
    sha512="$(jq -er '.sha512' <<< "$entry")"
    origin="$(jq -er '.origin' <<< "$entry")"
    safe_modpack_path "$relpath" managed-file

    if grep -Fx -- "$relpath" "$current_paths" >/dev/null; then
      continue
    fi

    target="${DATA_DIR}/${relpath}"
    if [[ -L "$target" ]]; then
      log INFO "Preserving modified former modpack file (symlink): ${relpath}"
      continue
    fi
    if [[ ! -e "$target" ]]; then
      continue
    fi
    if ! target="$(modpack_cleanup_target_path "$relpath")"; then
      return 1
    fi

    if ! modpack_managed_sha512_matches "$target" "$sha512"; then
      log INFO "Preserving modified former modpack file and relinquishing ownership: ${relpath}"
      continue
    fi

    if modpack_remove_extra_enabled; then
      log INFO "Removing stale managed modpack file: ${relpath}"
      if ! safe_rm_f "$target"; then
        return 1
      fi
    else
      record_retained_modpack_managed_entry "$retained" "$relpath" "$sha512" "$origin"
    fi
  done < "$candidates"

  write_retained_modpack_managed_entries "$marker" "$retained" "$tmpdir"
}

# Overrides the policy-layer wrapper after modpack_policy.sh is sourced. Safe
# remove-extra is intentionally marker-based: only files Minecartainer can
# prove it previously installed, and which still match their recorded SHA-512,
# are eligible for deletion.
install_modpack_with_overrides() {
  local format tmpdir archive source marker previous_marker

  [[ -n "${MODPACK_URL:-}" ]] || return 0

  [[ "${MODPACK_INSTALL_MODE}" == "server" ]] || die "Only MODPACK_INSTALL_MODE=server is supported in this phase"
  [[ "${MODPACK_FORMAT}" == "auto" || "${MODPACK_FORMAT}" == "mrpack" ]] || die "Only MODPACK_FORMAT=auto or mrpack is supported"

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

  if modpack_remove_extra_enabled && [[ ! -f "$marker" ]]; then
    safe_rm_rf "$tmpdir"
    die "MODPACK_REMOVE_EXTRA=true is not supported in this phase without an existing modpack marker; install the pack once before enabling managed cleanup"
  fi

  if [[ -f "$marker" ]]; then
    cp "$marker" "$previous_marker" \
      || { safe_rm_rf "$tmpdir"; die "Failed to preserve previous modpack marker"; }
  fi

  log INFO "Installing Modrinth mrpack"
  if modpack_include_optional_enabled; then
    log INFO "Including Modrinth files marked env.server=optional"
  fi
  if modpack_remove_extra_enabled; then
    log INFO "Removing stale files only when prior Minecartainer ownership and SHA-512 still match"
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
  if ! reconcile_modpack_managed_extras "$archive" "$previous_marker" "$marker" "$tmpdir"; then
    safe_rm_rf "$tmpdir"
    return 1
  fi
  safe_rm_rf "$tmpdir"
}

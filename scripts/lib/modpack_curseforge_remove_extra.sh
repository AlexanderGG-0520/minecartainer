# shellcheck shell=bash

collect_current_curseforge_managed_paths() {
  local marker="$1"
  local out="$2"

  [[ -f "$marker" ]] || {
    die "CurseForge install marker missing before remove-extra reconciliation: ${marker}"
    return 1
  }

  jq -e '
    type == "object"
    and .schemaVersion == 1
    and .format == "curseforge"
    and (.files | type == "array")
    and (((.overrides // []) | type) == "array")
  ' "$marker" >/dev/null || {
    die "Invalid CurseForge marker for remove-extra reconciliation: ${marker}"
    return 1
  }

  if ! jq -r '
    [
      .files[]?.path,
      (.overrides[]? | .path)
    ]
    | map(select(type == "string" and length > 0))
    | unique
    | .[]
  ' "$marker" > "$out"; then
    return 1
  fi
}

reconcile_curseforge_managed_extras() {
  local previous_marker="$1"
  local marker="$2"
  local tmpdir="$3"
  local current_paths candidates retained
  local entry relpath sha512 origin target

  current_paths="${tmpdir}/current-curseforge-paths.txt"
  candidates="${tmpdir}/previous-curseforge-managed.jsonl"
  retained="${tmpdir}/retained-curseforge-managed.jsonl"

  collect_current_curseforge_managed_paths "$marker" "$current_paths" || return 1
  collect_previous_modpack_managed_entries "$previous_marker" "$candidates" || return 1
  : > "$retained"

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    relpath="$(jq -er '.path' <<< "$entry")" || return 1
    sha512="$(jq -er '.sha512' <<< "$entry")" || return 1
    origin="$(jq -er '.origin' <<< "$entry")" || return 1
    safe_modpack_path "$relpath" managed-file || return 1

    if grep -Fx -- "$relpath" "$current_paths" >/dev/null; then
      continue
    fi

    target="${DATA_DIR}/${relpath}"
    if [[ -L "$target" ]]; then
      log INFO "Preserving modified former CurseForge file (symlink): ${relpath}"
      continue
    fi
    if [[ ! -e "$target" ]]; then
      continue
    fi
    if ! target="$(modpack_cleanup_target_path "$relpath")"; then
      return 1
    fi

    if ! modpack_managed_sha512_matches "$target" "$sha512"; then
      log INFO "Preserving modified former CurseForge file and relinquishing ownership: ${relpath}"
      continue
    fi

    if modpack_remove_extra_enabled; then
      log INFO "Removing stale managed CurseForge file: ${relpath}"
      safe_rm_f "$target" || return 1
    else
      record_retained_modpack_managed_entry "$retained" "$relpath" "$sha512" "$origin" || return 1
    fi
  done < "$candidates"

  write_retained_modpack_managed_entries "$marker" "$retained" "$tmpdir"
}

curseforge_cleanup_baseline_is_compatible() {
  local marker="$1"

  [[ -f "$marker" ]] || return 1
  jq -e '
    type == "object"
    and .schemaVersion == 1
    and .format == "curseforge"
  ' "$marker" >/dev/null
}

# Extends the runtime-aware CurseForge wrapper with marker-backed cleanup.
# Cleanup never scans the whole mods/config tree. It only considers paths from
# a previous CurseForge marker and only removes unchanged regular files whose
# SHA-512 still proves Minecartainer ownership.
install_curseforge_modpack_with_overrides() {
  local tmpdir archive source marker previous_marker cleanup_previous_marker

  tmpdir="$(mktemp -d)"
  archive="${tmpdir}/pack.zip"
  previous_marker="${tmpdir}/previous-marker.json"
  cleanup_previous_marker="${tmpdir}/cleanup-previous-marker.json"
  source="${MODPACK_URL}"
  marker="$(modpack_install_marker)"

  if modpack_remove_extra_enabled; then
    if [[ ! -f "$marker" ]]; then
      safe_rm_rf "$tmpdir"
      die "MODPACK_REMOVE_EXTRA=true requires an existing CurseForge modpack marker; install the pack once before enabling managed cleanup"
      return 1
    fi
    if ! curseforge_cleanup_baseline_is_compatible "$marker"; then
      safe_rm_rf "$tmpdir"
      die "MODPACK_REMOVE_EXTRA=true requires an existing CurseForge-format ownership marker; refusing cross-format cleanup"
      return 1
    fi
  fi

  if [[ -f "$marker" ]]; then
    cp "$marker" "$previous_marker" || {
      safe_rm_rf "$tmpdir"
      die "Failed to preserve previous modpack marker"
      return 1
    }
    if curseforge_cleanup_baseline_is_compatible "$marker"; then
      cp "$marker" "$cleanup_previous_marker" || {
        safe_rm_rf "$tmpdir"
        die "Failed to preserve previous CurseForge cleanup marker"
        return 1
      }
    fi
  fi

  log INFO "Installing CurseForge modpack export"
  if modpack_include_optional_enabled; then
    log INFO "Including CurseForge manifest entries marked required=false"
  fi
  if modpack_remove_extra_enabled; then
    log INFO "Removing stale CurseForge files only when prior Minecartainer ownership and SHA-512 still match"
  fi

  if declare -F acquire_curseforge_modpack_archive >/dev/null; then
    acquire_curseforge_modpack_archive "$source" "$archive" || {
      safe_rm_rf "$tmpdir"
      return 1
    }
  else
    download_modpack_file "$source" "$archive" "CurseForge modpack archive" || {
      safe_rm_rf "$tmpdir"
      return 1
    }
  fi

  install_curseforge_modpack "$archive" "$source" "$previous_marker" || {
    safe_rm_rf "$tmpdir"
    return 1
  }

  if [[ -f "$cleanup_previous_marker" ]]; then
    reconcile_curseforge_managed_extras "$cleanup_previous_marker" "$marker" "$tmpdir" || {
      safe_rm_rf "$tmpdir"
      return 1
    }
  else
    # First CurseForge install or a deliberate format switch starts a fresh
    # cleanup baseline and never inherits deletion authority from another
    # modpack format.
    : > "${tmpdir}/empty-retained.jsonl"
    write_retained_modpack_managed_entries "$marker" "${tmpdir}/empty-retained.jsonl" "$tmpdir" || {
      safe_rm_rf "$tmpdir"
      return 1
    }
  fi

  safe_rm_rf "$tmpdir"
}

# shellcheck shell=bash

# Modpack world content is deliberately not part of the normal managed-content
# allowlist. A world mutates immediately after Minecraft starts, so it cannot
# safely participate in hash-backed replacement or remove-extra ownership.
# This module therefore treats a pack-provided world as a one-time seed only.

modpack_world_install_enabled() {
  is_true "${MODPACK_INSTALL_WORLD:-false}"
}

modpack_world_relpath_is_seed() {
  local relpath="$1"
  local world_name

  world_name="$(minecraft_world_name)" || return 1
  [[ "$relpath" == "${world_name}/"* ]]
}

validate_modpack_world_entry_path() {
  local relpath="$1"

  modpack_path_validate_shape "$relpath" "modpack world entry" || return 1

  # unzip file arguments are patterns. Reject pattern metacharacters so the
  # exact archive member selected from the listing is the only member emitted
  # by `unzip -p` below.
  case "$relpath" in
    *'*'*|*'?'*|*'['*|*']'*)
      die "Unsafe modpack world entry path: archive pattern character is not allowed: ${relpath}"
      return 1
      ;;
  esac

  return 0
}

collect_modpack_world_layer_entries() {
  local listing="$1"
  local layer="$2"
  local world_name="$3"
  local out="$4"
  local prefix entry relpath
  declare -A seen=()

  prefix="${layer}/${world_name}"
  : > "$out"

  while IFS= read -r entry || [[ -n "$entry" ]]; do
    case "$entry" in
      "${prefix}"/*) ;;
      *) continue ;;
    esac

    [[ "$entry" == */ ]] && continue
    relpath="${entry#"${prefix}"/}"
    validate_modpack_world_entry_path "$relpath" || return 1

    if [[ -n "${seen[$relpath]+x}" ]]; then
      die "Duplicate ${layer} world entry in modpack: ${relpath}"
      return 1
    fi
    seen["$relpath"]=1
    printf '%s\t%s\n' "$relpath" "$entry" >> "$out"
  done < "$listing"
}

extract_modpack_world_layer() {
  local archive="$1"
  local entries="$2"
  local stage="$3"
  local layer="$4"
  local relpath archive_entry target parent tmp

  while IFS=$'\t' read -r relpath archive_entry; do
    [[ -n "$relpath" ]] || continue
    target="${stage}/${relpath}"
    parent="$(dirname "$target")"
    mkdir -p "$parent" || return 1
    tmp="$(mktemp "${parent}/.$(basename "$target").tmp.XXXXXX")" || return 1

    if ! unzip -p "$archive" "$archive_entry" > "$tmp"; then
      safe_rm_f "$tmp"
      die "Failed to extract ${layer} modpack world entry: ${relpath}"
      return 1
    fi
    if ! safe_mv_f "$tmp" "$target"; then
      safe_rm_f "$tmp"
      return 1
    fi
  done < "$entries"
}

write_modpack_world_marker() {
  local marker="$1"
  local world_name="$2"
  local action="$3"
  local source_layer="${4:-}"
  local tmp

  [[ -f "$marker" ]] || {
    die "Modpack install marker missing before world seed metadata update: ${marker}"
    return 1
  }
  jq -e 'type == "object" and .schemaVersion == 1' "$marker" >/dev/null || {
    die "Invalid modpack marker before world seed metadata update: ${marker}"
    return 1
  }

  tmp="$(mktemp "${marker}.tmp.XXXXXX")" || return 1
  if ! jq \
    --arg path "$world_name" \
    --arg action "$action" \
    --arg sourceLayer "$source_layer" '
      .world = (
        {
          path: $path,
          action: $action,
          ownership: "seed-only"
        }
        + (if $sourceLayer == "" then {} else {sourceLayer:$sourceLayer} end)
      )
    ' "$marker" > "$tmp"; then
    safe_rm_f "$tmp"
    return 1
  fi
  if ! safe_mv_f "$tmp" "$marker"; then
    safe_rm_f "$tmp"
    return 1
  fi
  set_readable_file_permissions "$marker"
}

install_modpack_world_from_archive() {
  local archive="$1"
  local format="$2"
  local marker="$3"
  local tmpdir="$4"
  local world_name world_dir listing stage
  local base_entries server_entries base_count=0 server_count=0 source_layer=""

  modpack_world_install_enabled || return 0

  world_name="$(minecraft_world_name)" || return 1
  world_dir="$(minecraft_world_dir)" || return 1
  # Reuse the generic shape checks for the archive-facing world root without
  # weakening safe_modpack_path(), which must continue to reject world data.
  modpack_path_validate_shape "${world_name}/level.dat" "modpack world root" || return 1
  validate_world_install_paths "${DATA_DIR:-}" "$world_dir" || return 1

  if [[ -L "$world_dir" ]]; then
    die "Refusing modpack world seed into symlink target: ${world_name}"
    return 1
  fi

  if [[ -f "${world_dir}/level.dat" ]]; then
    log INFO "Existing world detected; preserving it instead of applying modpack world seed: ${world_name}"
    write_modpack_world_marker "$marker" "$world_name" preserved-existing
    return
  fi

  if [[ -e "$world_dir" && ! -d "$world_dir" ]]; then
    die "Refusing modpack world seed because world target is not a directory: ${world_name}"
    return 1
  fi
  if [[ -d "$world_dir" ]] && find "$world_dir" -mindepth 1 -print -quit | grep -q .; then
    die "Refusing modpack world seed into non-empty world directory without level.dat: ${world_name}"
    return 1
  fi

  listing="${tmpdir}/modpack-world-archive-entries.txt"
  base_entries="${tmpdir}/modpack-world-overrides.tsv"
  server_entries="${tmpdir}/modpack-world-server-overrides.tsv"
  stage="$(mktemp -d "${tmpdir}/modpack-world-stage.XXXXXX")" || return 1

  command -v unzip >/dev/null 2>&1 || {
    safe_rm_rf "$stage"
    die "unzip is required for modpack world seeding"
    return 1
  }
  if ! unzip -Z1 "$archive" > "$listing"; then
    safe_rm_rf "$stage"
    die "Failed to list modpack archive entries for world seeding"
    return 1
  fi

  case "$format" in
    mrpack)
      collect_modpack_world_layer_entries "$listing" overrides "$world_name" "$base_entries" || {
        safe_rm_rf "$stage"
        return 1
      }
      collect_modpack_world_layer_entries "$listing" server-overrides "$world_name" "$server_entries" || {
        safe_rm_rf "$stage"
        return 1
      }
      ;;
    curseforge)
      collect_modpack_world_layer_entries "$listing" overrides "$world_name" "$base_entries" || {
        safe_rm_rf "$stage"
        return 1
      }
      : > "$server_entries"
      ;;
    *)
      safe_rm_rf "$stage"
      die "Internal error: unsupported modpack world seed format ${format}"
      return 1
      ;;
  esac

  base_count="$(wc -l < "$base_entries")"
  server_count="$(wc -l < "$server_entries")"
  if [[ "$base_count" -eq 0 && "$server_count" -eq 0 ]]; then
    safe_rm_rf "$stage"
    die "MODPACK_INSTALL_WORLD=true but the modpack contains no ${world_name}/ world seed under supported override layers"
    return 1
  fi

  extract_modpack_world_layer "$archive" "$base_entries" "$stage" overrides || {
    safe_rm_rf "$stage"
    return 1
  }
  extract_modpack_world_layer "$archive" "$server_entries" "$stage" server-overrides || {
    safe_rm_rf "$stage"
    return 1
  }

  [[ -s "${stage}/level.dat" ]] || {
    safe_rm_rf "$stage"
    die "Modpack world seed is missing a non-empty top-level level.dat for ${world_name}"
    return 1
  }

  chmod -R u+rwX,go+rX -- "$stage" || {
    safe_rm_rf "$stage"
    die "Failed to set readable permissions on staged modpack world"
    return 1
  }

  # install_dirs creates the target world directory early. Only remove that
  # directory when it is still empty; never replace partially populated state.
  validate_world_install_paths "${DATA_DIR:-}" "$world_dir" || {
    safe_rm_rf "$stage"
    return 1
  }
  if [[ -d "$world_dir" ]]; then
    if ! rmdir -- "$world_dir"; then
      safe_rm_rf "$stage"
      die "World target became non-empty before modpack world seed activation: ${world_name}"
      return 1
    fi
  fi
  validate_world_install_paths "${DATA_DIR:-}" "$world_dir" || {
    safe_rm_rf "$stage"
    return 1
  }
  if ! safe_mv "$stage" "$world_dir"; then
    safe_rm_rf "$stage"
    return 1
  fi

  if [[ "$base_count" -gt 0 && "$server_count" -gt 0 ]]; then
    source_layer="overrides+server-overrides"
  elif [[ "$server_count" -gt 0 ]]; then
    source_layer="server-overrides"
  else
    source_layer="overrides"
  fi

  write_modpack_world_marker "$marker" "$world_name" seeded "$source_layer" || return 1
  log INFO "Modpack world seeded successfully: ${world_name} (${source_layer})"
}

# Final override collector: when world seeding is explicitly enabled, remove
# the configured world subtree from normal override ownership. When it is not
# enabled, safe_modpack_path() still rejects the same subtree as reserved.
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

    if modpack_world_install_enabled && modpack_world_relpath_is_seed "$relpath"; then
      continue
    fi

    safe_modpack_path "$relpath" override || return 1

    if [[ -n "${seen[$relpath]+x}" ]]; then
      die "Duplicate ${prefix} entry in modpack: ${relpath}"
      return 1
    fi
    seen["$relpath"]=1
    printf '%s\t%s\n' "$relpath" "$entry" >> "$out"
  done < "$listing"
}

# Final Modrinth override wrapper: preserve the existing operator-ownership
# semantics, then seed the world through the separate one-time path above.
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
    return 1
  fi

  collect_modpack_override_entries "$listing" overrides "$base_entries" || return 1
  collect_modpack_override_entries "$listing" server-overrides "$server_entries" || return 1
  : > "$current_seeded"
  : > "$records"

  apply_modpack_override_layer \
    "$archive" "$base_entries" overrides "$previous_marker" \
    "$current_seeded" "$records" "$tmpdir" || return 1
  apply_modpack_override_layer \
    "$archive" "$server_entries" server-overrides "$previous_marker" \
    "$current_seeded" "$records" "$tmpdir" || return 1

  write_modpack_overrides_to_marker "$marker" "$records" "$tmpdir" || return 1
  install_modpack_world_from_archive "$archive" mrpack "$marker" "$tmpdir"
}

# Final CurseForge override wrapper with the same one-time world seed boundary.
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
    write_modpack_overrides_to_marker "$marker" "$records" "$tmpdir" || return 1
    install_modpack_world_from_archive "$archive" curseforge "$marker" "$tmpdir"
    return
  fi
  [[ "$override_dir" == "overrides" ]] || {
    die "Only the standard CurseForge overrides directory is supported"
    return 1
  }

  listing="${tmpdir}/curseforge-archive-entries.txt"
  entries="${tmpdir}/curseforge-overrides.tsv"
  current_seeded="${tmpdir}/curseforge-current-seeded.txt"

  command -v unzip >/dev/null 2>&1 || {
    die "unzip is required to apply CurseForge overrides"
    return 1
  }
  unzip -Z1 "$archive" > "$listing" || {
    die "Failed to list CurseForge archive entries"
    return 1
  }
  collect_modpack_override_entries "$listing" "$override_dir" "$entries" || return 1
  : > "$current_seeded"

  apply_modpack_override_layer \
    "$archive" "$entries" curseforge-overrides "$previous_marker" \
    "$current_seeded" "$records" "$tmpdir" || return 1
  write_modpack_overrides_to_marker "$marker" "$records" "$tmpdir" || return 1
  install_modpack_world_from_archive "$archive" curseforge "$marker" "$tmpdir"
}

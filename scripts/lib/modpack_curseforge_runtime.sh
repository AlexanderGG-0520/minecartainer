# shellcheck shell=bash

# Extends the phase-1 CurseForge wrapper after modpack_curseforge.sh is sourced.
# Runtime inference prefetches and validates the export before server
# installation; this wrapper consumes exactly those bytes instead of
# downloading the pack a second time.
install_curseforge_modpack_with_overrides() {
  local tmpdir archive source marker previous_marker

  modpack_remove_extra_enabled && {
    die "MODPACK_REMOVE_EXTRA=true is not yet supported for CurseForge packs"
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
  safe_rm_rf "$tmpdir"
}

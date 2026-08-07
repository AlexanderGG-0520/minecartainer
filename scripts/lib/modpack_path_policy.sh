# shellcheck shell=bash

# Authoritative path policy for modpack-managed content. The extension modules
# source the base mods.sh implementation as a dependency, so install_phase.sh
# intentionally sources this module last before modpack execution. Indexed
# files, overrides, and remove-extra therefore share this final classifier.

modpack_path_top_level() {
  local path="$1"
  printf '%s\n' "${path%%/*}"
}

modpack_path_reject() {
  die "$1"
  return 1
}

modpack_path_validate_shape() {
  local path="$1"
  local kind="${2:-file}"
  local part
  local -a parts

  if [[ -z "$path" ]]; then
    modpack_path_reject "Unsafe ${kind} path: empty"
    return 1
  fi
  if [[ "$path" == /* ]]; then
    modpack_path_reject "Unsafe ${kind} path: absolute path: ${path}"
    return 1
  fi
  if [[ "$path" =~ ^[A-Za-z]: ]]; then
    modpack_path_reject "Unsafe ${kind} path: Windows drive path: ${path}"
    return 1
  fi
  if [[ "$path" == *\\* ]]; then
    modpack_path_reject "Unsafe ${kind} path: backslash is not allowed: ${path}"
    return 1
  fi
  if [[ "$path" == *//* || "$path" == */ ]]; then
    modpack_path_reject "Unsafe ${kind} path: empty path segment: ${path}"
    return 1
  fi

  if printf '%s' "$path" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    modpack_path_reject "Unsafe ${kind} path: control character is not allowed"
    return 1
  fi

  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    if [[ "$part" == ".." ]]; then
      modpack_path_reject "Unsafe ${kind} path: parent traversal: ${path}"
      return 1
    fi
    if [[ "$part" == "." ]]; then
      modpack_path_reject "Unsafe ${kind} path: dot path segment: ${path}"
      return 1
    fi
    if [[ -z "$part" ]]; then
      modpack_path_reject "Unsafe ${kind} path: empty path segment: ${path}"
      return 1
    fi
  done

  return 0
}

modpack_path_is_reserved() {
  local path="$1"
  local root world_name=""

  root="$(modpack_path_top_level "$path")"

  # Never allow a modpack to write hidden top-level state. Minecartainer and
  # loaders use several dot-prefixed directories and markers under DATA_DIR.
  [[ "$root" == .* ]] && return 0

  case "$root" in
    world|saves|logs|backups|plugins|libraries|versions|crash-reports)
      return 0
      ;;
  esac

  case "$path" in
    server.properties|eula.txt|ops.json|whitelist.json|jvm.args|reset-world.flag|\
    server.jar|fabric-server-launch.jar|velocity.jar|run.sh|run.bat|\
    unix_args.txt|win_args.txt|user_jvm_args.txt)
      return 0
      ;;
  esac

  # Respect a configured non-default level name too. A modpack content layer
  # must never become an implicit world installer.
  if declare -F minecraft_world_name >/dev/null 2>&1; then
    world_name="$(minecraft_world_name 2>/dev/null || true)"
    if [[ -n "$world_name" ]]; then
      case "$root" in
        "$world_name"|"${world_name}_nether"|"${world_name}_the_end")
          return 0
          ;;
      esac
    fi
  fi

  return 1
}

modpack_path_is_managed_content_root() {
  local path="$1"
  local root
  root="$(modpack_path_top_level "$path")"

  # Core Modrinth/server content roots plus a conservative set of common
  # modpack-authored server-content roots. Every root remains subject to the
  # same ownership, hash, canonical-path, and remove-extra protections.
  case "$root" in
    mods|config|defaultconfigs|datapacks|resourcepacks|\
    kubejs|scripts|global_packs|openloader|patchouli_books)
      [[ "$path" == */* ]]
      ;;
    *)
      return 1
      ;;
  esac
}

modpack_path_classify() {
  local path="$1"
  local kind="${2:-file}"

  modpack_path_validate_shape "$path" "$kind" || return 1

  if modpack_path_is_reserved "$path"; then
    printf '%s\n' reserved
    return 0
  fi

  if modpack_path_is_managed_content_root "$path"; then
    printf '%s\n' managed-content
    return 0
  fi

  printf '%s\n' unsupported
}

safe_modpack_path() {
  local path="$1"
  local kind="${2:-file}"
  local class

  class="$(modpack_path_classify "$path" "$kind")" || return 1
  case "$class" in
    managed-content)
      return 0
      ;;
    reserved)
      modpack_path_reject "Unsafe ${kind} path: reserved path: ${path}"
      return 1
      ;;
    unsupported)
      modpack_path_reject "Unsafe ${kind} path: outside allowed modpack paths: ${path}"
      return 1
      ;;
    *)
      modpack_path_reject "Unsafe ${kind} path: unknown path classification for ${path}"
      return 1
      ;;
  esac
}

modpack_managed_target_path() {
  local relpath="$1"
  local kind="${2:-file}"
  local data_real target target_real

  safe_modpack_path "$relpath" "$kind" || return 1
  command -v realpath >/dev/null 2>&1 || {
    modpack_path_reject "realpath is required for modpack path safety"
    return 1
  }
  data_real="$(realpath -e -- "${DATA_DIR}")" || {
    modpack_path_reject "Failed to resolve DATA_DIR for modpack path safety: ${DATA_DIR}"
    return 1
  }
  target="${DATA_DIR}/${relpath}"
  target_real="$(realpath -m -- "$target")" || {
    modpack_path_reject "Failed to resolve modpack target: ${relpath}"
    return 1
  }

  case "$target_real" in
    "${data_real}"/*)
      printf '%s\n' "$target"
      ;;
    *)
      modpack_path_reject "Refusing modpack target outside DATA_DIR: ${relpath}"
      return 1
      ;;
  esac
}

# Override the base installer after mods.sh has been sourced so indexed files
# receive the same canonical DATA_DIR boundary already used by overrides and
# remove-extra reconciliation.
install_modpack_file() {
  local relpath="$1"
  local src="$2"
  local sha1="$3"
  local sha512="$4"
  local target parent tmp

  target="$(modpack_managed_target_path "$relpath" file)" || return 1
  parent="$(dirname "$target")"

  if [[ -e "$target" || -L "$target" ]]; then
    if [[ ! -L "$target" ]] && modpack_file_hash_matches "$target" "$sha1" "$sha512"; then
      log INFO "Modpack file already present with expected hash: ${relpath}"
      return 0
    fi

    if modpack_marker_has_file "$relpath"; then
      log INFO "Replacing previously managed modpack file: ${relpath}"
    elif [[ "$relpath" == *.jar ]]; then
      die "Refusing to overwrite user-owned jar from modpack: ${relpath}"
      return 1
    else
      log INFO "Skipping existing user-owned modpack seed file: ${relpath}"
      return 2
    fi
  fi

  mkdir -p "$parent"
  target="$(modpack_managed_target_path "$relpath" file)" || return 1
  parent="$(dirname "$target")"
  tmp="$(mktemp "${parent}/.$(basename "$target").tmp.XXXXXX")"
  cp "$src" "$tmp" || {
    safe_rm_f "$tmp"
    die "Failed to stage modpack file: ${relpath}"
    return 1
  }
  if ! safe_mv_f "$tmp" "$target"; then
    safe_rm_f "$tmp"
    return 1
  fi
  set_readable_file_permissions "$target"
}

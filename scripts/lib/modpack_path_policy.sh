# shellcheck shell=bash

# Authoritative path policy for modpack-managed content. The base mrpack
# implementation in mods.sh predates this policy layer; install_phase sources
# this module before any modpack extension executes so all indexed-file,
# override, and remove-extra paths share the same classifier.

modpack_path_top_level() {
  local path="$1"
  printf '%s\n' "${path%%/*}"
}

modpack_path_validate_shape() {
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
    [[ "$part" != "." ]] || die "Unsafe ${kind} path: dot path segment: ${path}"
    [[ -n "$part" ]] || die "Unsafe ${kind} path: empty path segment: ${path}"
  done
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

  case "$root" in
    # Core Modrinth/server content roots.
    mods|config|defaultconfigs|datapacks|resourcepacks|\
    # Common modpack-authored server content. These remain under the same
    # ownership/hash/path protections as the core roots.
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

  modpack_path_validate_shape "$path" "$kind"

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
      die "Unsafe ${kind} path: reserved path: ${path}"
      ;;
    unsupported)
      die "Unsafe ${kind} path: outside allowed modpack paths: ${path}"
      ;;
    *)
      die "Unsafe ${kind} path: unknown path classification for ${path}"
      ;;
  esac
}

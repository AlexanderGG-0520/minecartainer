# shellcheck shell=bash

minecraft_world_name() {
  local world_name="${LEVEL_NAME:-${LEVEL:-world}}"

  if [[ -z "${world_name}" ||
    "${world_name}" == "." ||
    "${world_name}" == ".." ||
    "${world_name}" == */* ]]; then
    log ERROR "Invalid level-name for world path"
    return 1
  fi

  # Never treat runtime-owned directories or hidden metadata as a world.
  case "${world_name}" in
    .*|backups|mods|plugins|config|logs|libraries|versions|resourcepacks|datapacks|crash-reports)
      log ERROR "Invalid level-name: conflicts with a managed server path"
      return 1
      ;;
  esac

  printf '%s\n' "${world_name}"
}

minecraft_world_dir() {
  local data_dir="${1:-${DATA_DIR:-}}"
  local world_name

  world_name="$(minecraft_world_name)" || return 1
  printf '%s/%s\n' "${data_dir}" "${world_name}"
}

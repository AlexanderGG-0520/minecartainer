#!/usr/bin/env bash
set -Eeuo pipefail

ENTRYPOINT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/logging.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/logging.sh"
# shellcheck source=scripts/lib/filesystem.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/filesystem.sh"
# shellcheck source=scripts/lib/numeric_validation.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/numeric_validation.sh"
# shellcheck source=scripts/lib/runtime.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/runtime.sh"
# shellcheck source=scripts/lib/preflight.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/preflight.sh"
# shellcheck source=scripts/lib/runtime_env.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/runtime_env.sh"
# shellcheck source=scripts/lib/c2me.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/c2me.sh"
# shellcheck source=scripts/lib/jvm_args.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/jvm_args.sh"
# shellcheck source=scripts/lib/player_lists.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/player_lists.sh"
# shellcheck source=scripts/lib/paper_config.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/paper_config.sh"
# shellcheck source=scripts/lib/world_paths.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/world_paths.sh"
# shellcheck source=scripts/lib/bootstrap_files.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/bootstrap_files.sh"
# shellcheck source=scripts/lib/lifecycle.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/lifecycle.sh"
# shellcheck source=scripts/lib/rcon.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/rcon.sh"
# shellcheck source=scripts/lib/shutdown.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/shutdown.sh"
# shellcheck source=scripts/lib/s3_client.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/s3_client.sh"
# shellcheck source=scripts/lib/content_assets.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/content_assets.sh"
# shellcheck source=scripts/lib/mods.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/mods.sh"
# shellcheck source=scripts/lib/velocity_config.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/velocity_config.sh"
# shellcheck source=scripts/lib/server_install.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/server_install.sh"
# shellcheck source=scripts/lib/runtime_launch.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/runtime_launch.sh"
# shellcheck source=scripts/lib/world_install.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/world_install.sh"
# shellcheck source=scripts/lib/world_reset.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/world_reset.sh"
# shellcheck source=scripts/lib/server_properties.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/server_properties.sh"
# shellcheck source=scripts/lib/install_phase.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/install_phase.sh"
# shellcheck source=scripts/lib/command_mode.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/command_mode.sh"
# shellcheck source=scripts/lib/runtime_phase.sh
source "${ENTRYPOINT_DIR%/}/scripts/lib/runtime_phase.sh"

# shellcheck disable=SC2034  # Reserved global for PID-oriented lifecycle handling.
MC_PID=""

# ================================
# Force IPv4 (IMPORTANT)
# ================================
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} \
-Djava.net.preferIPv4Stack=true \
-Djava.net.preferIPv4Addresses=true \
-Duser.timezone=${LOG_TZ}"

log INFO "JAVA_TOOL_OPTIONS=${JAVA_TOOL_OPTIONS}"

# ============================================================
# Environment defaults (non server.properties)
# ============================================================

# Java
: "${JAVA_MAJOR:=unknown}"
: "${JAVA_VERSION_RAW:=unknown}"
: "${JAVA_VENDOR:=unknown}"

: "${RUNTIME_ARCH_NORM:=unknown}"
: "${RUNTIME_CONTAINER:=unknown}"
: "${RUNTIME_GPU:=none}"

# Global Paths
: "${DATA_DIR:=/data}"
: "${JVM_ARGS_FILE:=${DATA_DIR}/jvm.args}"

# UID/GID
: "${UID:=1000}"
: "${GID:=1000}"

# Runtime
: "${TYPE:=vanilla}"
: "${READY_DELAY:=5}"
: "${HOOKS_ENABLED:=false}"
: "${HOOKS_DIR:=/hooks}"
: "${HOOKS_STRICT:=true}"
: "${HOOKS_TIMEOUT_SEC:=0}"
: "${INSTALL_ONLY:=false}"

# JVM
: "${JVM_XMS:=512M}"
: "${JVM_XMX:=512M}"
: "${JVM_GC:=G1}"
: "${JVM_USE_CONTAINER_SUPPORT:=true}"
: "${JVM_EXTRA_ARGS:=}"

# Mods
: "${MODS_ENABLED:=true}"
: "${MODS_S3_PREFIX:=mods/latest}"
: "${MODS_SYNC_ONCE:=true}"
: "${MODS_REMOVE_EXTRA:=false}"

# Plugins
: "${PLUGINS_ENABLED:=true}"
: "${PLUGINS_S3_PREFIX:=plugins/latest}"
: "${PLUGINS_SYNC_ONCE:=true}"
: "${PLUGINS_REMOVE_EXTRA:=false}"

# Configs
: "${CONFIGS_ENABLED:=true}"
: "${CONFIGS_S3_PREFIX:=configs/latest}"
: "${CONFIGS_SYNC_ONCE:=true}"
: "${CONFIGS_REMOVE_EXTRA:=false}"

# Datapacks
: "${DATAPACKS_ENABLED:=true}"
: "${DATAPACKS_S3_PREFIX:=datapacks/latest}"
: "${DATAPACKS_SYNC_ONCE:=true}"
: "${DATAPACKS_REMOVE_EXTRA:=false}"

# Resourcepacks
: "${RESOURCEPACKS_ENABLED:=true}"
: "${RESOURCEPACKS_S3_PREFIX:=resourcepacks/latest}"
: "${RESOURCEPACKS_SYNC_ONCE:=true}"
: "${RESOURCEPACKS_REMOVE_EXTRA:=false}"
: "${RESOURCEPACKS_AUTO_SET_RESOURCE_PACK:=false}"

# Modpacks (experimental)
: "${MODPACK_URL:=}"
: "${MODPACK_FORMAT:=auto}"
: "${MODPACK_INSTALL_MODE:=server}"
: "${MODPACK_FORCE_REINSTALL:=false}"
: "${MODPACK_REMOVE_EXTRA:=false}"
: "${MODPACK_INCLUDE_OPTIONAL:=false}"
: "${MODPACK_ALLOW_FILE_URL:=false}"

# F-3: C2ME (EXPERIMENTAL)
: "${ENABLE_C2ME:=false}"
: "${ENABLE_C2ME_HARDWARE_ACCELERATION:=false}"
: "${I_KNOW_C2ME_IS_EXPERIMENTAL:=false}"

# RCON
: "${ENABLE_RCON:=false}"
: "${RCON_HOST:=127.0.0.1}"
: "${RCON_PORT:=25575}"
: "${RCON_PASSWORD:=}"
: "${RCON_CMDS_STARTUP:=}"


# ============================================================
# Input directories (external / immutable)
# ============================================================
for input_variable in INPUT_MODS_DIR INPUT_PLUGINS_DIR INPUT_CONFIG_DIR INPUT_DATAPACKS_DIR INPUT_RESOURCEPACKS_DIR; do
  if [[ -v "${input_variable}" ]]; then
    printf -v "${input_variable}_CONFIGURED" '%s' true
  else
    printf -v "${input_variable}_CONFIGURED" '%s' false
  fi
done
unset input_variable
: "${INPUT_MODS_DIR:=/mods}"
: "${INPUT_PLUGINS_DIR:=/plugins}"
: "${INPUT_CONFIG_DIR:=/config}"
: "${INPUT_DATAPACKS_DIR:=/datapacks}"
: "${INPUT_RESOURCEPACKS_DIR:=/resourcepacks}"
# ============================================================

# RCON (runtime control)
: "${STOP_SERVER_ANNOUNCE_DELAY:=0}"
# ============================================================
# Server Icon
: "${SERVER_ICON_URL:=}"
# ============================================================

clear_fabric_cache() {
# -----------------------------
# Clean Fabric mapping cache
# -----------------------------
case "${TYPE}" in
  fabric|taiyitist|quilt)
    log INFO "Cleaning Fabric mapping/cache directories (TYPE=${TYPE})"
    safe_rm_rf "${DATA_DIR}/.fabric"
    safe_rm_rf "${DATA_DIR}/.cache"
    safe_rm_rf "${DATA_DIR}/.mappings"
    log INFO "Fabric mapping/cache directories cleaned"
    ;;
esac
}

normalize_toml_key() {
  printf '%s\n' "${1//[^a-zA-Z0-9_]/_}"
}

declare -A VELOCITY_SERVER_KEYS

IFS=',' read -ra ENTRIES <<< "${VELOCITY_SERVERS:-}"
for entry in "${ENTRIES[@]}"; do
  raw_key="${entry%%=*}"
  key="$(normalize_toml_key "${raw_key}")"
  VELOCITY_SERVER_KEYS["${key}"]=1
done

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

# Add to appropriate location if missing (bash assumed)
trim_ws() {
  local s="$1"
  # leading
  s="${s#"${s%%[![:space:]]*}"}"
  # trailing
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# shellcheck disable=SC2034  # Reserved managed-path anchor for optimize-mods handling.
OPT_MANAGED_DIR="${DATA_DIR}/.managed/optimize-mods"
OPT_LINK_PREFIX="zz-opt-"

opt_bool() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

opt_type_family() {
  # TYPE is assumed already set (fabric|quilt|forge|neoforge|...)
  case "${TYPE:-}" in
    fabric|quilt) echo "fabric" ;;
    forge|neoforge) echo "forge" ;;
    *) echo "unknown" ;;
  esac
}

opt_required_any_enabled() {
  local fam="$1"
  if [[ "$fam" == "fabric" ]]; then
    opt_bool "$OPTIMIZE_LITHIUM" && return 0
    opt_bool "$OPTIMIZE_FERRITECORE" && return 0
    return 1
  elif [[ "$fam" == "forge" ]]; then
    opt_bool "$OPTIMIZE_FERRITECORE" && return 0
    opt_bool "$OPTIMIZE_MODERNFIX" && return 0
    return 1
  fi
  return 1
}

opt_configure_s3_client() {
  configure_s3_client "optimize mods"
}

opt_mirror_from_s3() {
  local src="$1"  # like: s3/bucket/prefix/type
  local dst="$2"

  mkdir -p "$dst"

  # IMPORTANT: no --remove here (rule!)
  # We allow overwrite so updates propagate.
  s3_sync "$src" "$dst"
}

opt_install_links() {
  local cache_dir="$1"
  local mods_dir="$2"

  mkdir -p "$mods_dir"

  # Remove stale symlinks we previously created (safe: only symlink + prefix)
  find "$mods_dir" -maxdepth 1 -type l -name "${OPT_LINK_PREFIX}*.jar" -print0 2>/dev/null \
    | while IFS= read -r -d '' link; do
        local target
        target="$(readlink "$link" || true)"
        if [[ -z "$target" || ! -e "$mods_dir/$target" && ! -e "$target" ]]; then
          safe_rm_f "$link"
        fi
      done

  # Create/refresh symlinks for jars in cache
  local found=0
  shopt -s nullglob
  for jar in "$cache_dir"/*.jar; do
    found=1
    local base
    base="$(basename "$jar")"
    local link="${mods_dir}/${OPT_LINK_PREFIX}${base}"

    # If a non-symlink file exists with same name, don't touch it.
    if [[ -e "$link" && ! -L "$link" ]]; then
      log WARN "Optimize link name conflict (not a symlink), skipping: $link"
      continue
    fi

    ln -sf "$jar" "$link"
  done
  shopt -u nullglob

  [[ $found -eq 1 ]] && return 0 || return 1
}

is_world_generated() {
  [[ -f "${DATA_DIR}/world/level.dat" ]]
}

wait_for_worldgen() {
  log INFO "Waiting for world generation to complete"
  while ! is_world_generated; do
    sleep 1
  done
  log INFO "World generation confirmed (level.dat found)"
}

: "${RCON_RETRIES:=5}"
: "${RCON_RETRY_DELAY:=1}"
: "${RCON_TIMEOUT:=5}"
: "${SHUTDOWN_WAIT_TIMEOUT:=90}"
: "${SHUTDOWN_TERM_WAIT:=10}"
: "${SHUTDOWN_SAVE_WAIT_SECONDS:=3}"
: "${RCON_STOP_LOCK_WAIT_TIMEOUT:=30}"

json_escape() {
  local s="$*"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# Put the lock on ephemeral filesystem (NOT on /data / PVC)
RCON_STOP_RESULT=1
RCON_STOP_LOCK="${RCON_STOP_LOCK:-/tmp/.rcon-stop.lockdir}"
RCON_STOP_IN_PROGRESS=0
SERVER_PID=""

# Single source of truth for signals (make sure there is only ONE trap)
trap 'graceful_shutdown' TERM INT QUIT

handle_command_mode "$@"
if (( COMMAND_MODE_SHIFT > 0 )); then
  shift "${COMMAND_MODE_SHIFT}" || true
fi

main() {
  log INFO "Minecraft Runtime Booting..."
  preflight
  resolve_type_auto
  detect_runtime_env
  run_runtime_phase
}

if [[ "${__SOURCED:-0}" != "1" ]]; then
  main "$@"
  exit $?
fi

eval "return 0" 2>/dev/null || true

# __VELOCITY_RUNTIME_EXEC_FOOTER__
# Fail-safe: Kubernetes requires PID 1 to stay alive.
# If the script reaches here with TYPE=velocity, start Velocity in the foreground.
if [[ "${TYPE:-}" == "velocity" ]]; then
  : "${DATA_DIR:?DATA_DIR is required}"
  if [[ ! -f "${DATA_DIR}/velocity.jar" ]]; then
    die "velocity.jar not found at ${DATA_DIR}/velocity.jar"
  fi
  log INFO "Launching Velocity (foreground, PID 1)"
  cd "${DATA_DIR}"
  exec java -jar "${DATA_DIR}/velocity.jar"
fi

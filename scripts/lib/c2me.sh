# shellcheck shell=bash

_c2me_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/fabric_mod_metadata.sh
source "${_c2me_lib_dir}/fabric_mod_metadata.sh"
# shellcheck source=scripts/lib/c2me_opencl.sh
source "${_c2me_lib_dir}/c2me_opencl.sh"
unset _c2me_lib_dir

should_enable_c2me() {
  c2me_opencl_requested || return 1

  # ---- Explicit user consent ----
  [[ "${ENABLE_C2ME:-false}" == "true" ]] || return 1
  [[ "${I_KNOW_C2ME_IS_EXPERIMENTAL:-false}" == "true" ]] || return 1

  # ---- Java / loader guard ----
  [[ "${JAVA_MAJOR:-unknown}" == "25" ]] || return 1
  [[ "${TYPE:-}" == "fabric" ]] || return 1

  # ---- Runtime guard ----
  [[ "${RUNTIME_ARCH_NORM:-unknown}" == "x86_64" ]] || return 1
  [[ "${RUNTIME_CONTAINER:-unknown}" == "true" ]] || return 1
  [[ "${RUNTIME_GPU:-none}" != "none" ]] || return 1

  # ---- Device guard ----
  [[ -d /dev/dri || -e /dev/nvidia0 || -e /dev/dxg ]] || return 1

  return 0
}

# Backward-compatible helper retained for existing internal callers. Detection is
# metadata-based now; the argument is interpreted as an exact Fabric mod id.
detect_optimize_mod() {
  local mod_id="$1"
  has_fabric_mod_id "$mod_id"
}

has_c2me_mod() {
  has_c2me_base_mod
}

install_c2me_jvm_args() {
  c2me_opencl_requested || return 0

  if c2me_opencl_uses_legacy_env; then
    log WARN "ENABLE_C2ME_HARDWARE_ACCELERATION is deprecated; use ENABLE_C2ME_OPENCL=true"
  fi

  validate_c2me_opencl_policy

  if ! has_c2me_mod; then
    log INFO "C2ME base mod not found in mods/, skipping OpenCL config"
    return 0
  fi

  if ! has_c2me_opencl_mod; then
    log INFO "C2ME OpenCL addon not found in mods/, skipping OpenCL config"
    return 0
  fi

  if ! detect_gpu; then
    log INFO "OpenCL GPU environment not detected, skipping C2ME OpenCL config"
    return 0
  fi

  if should_enable_c2me; then
    log WARN "C2ME OpenCL Acceleration ENABLED (EXPERIMENTAL)"
    log WARN "This may cause instability or data corruption"

    {
      echo ""
      echo "# --- C2ME OpenCL Acceleration (EXPERIMENTAL) ---"
      c2me_opencl_jvm_arg
    } >> "${JVM_ARGS_FILE}"
  else
    log INFO "C2ME OpenCL components present, but runtime guard conditions not met"
  fi
}

detect_gpu() {
  log INFO "Detecting OpenCL GPU availability..."

  # ------------------------------------------------------------
  # 1. GPU device (Docker / WSL compatible)
  # ------------------------------------------------------------
  if [ ! -e /dev/nvidia0 ] && [ ! -e /dev/dxg ]; then
    log INFO "No NVIDIA GPU device found (/dev/nvidia* or /dev/dxg)"
    return 1
  fi
  log INFO "GPU device node found"

  # ------------------------------------------------------------
  # 2. OpenCL loader (path-based, not ldconfig)
  # ------------------------------------------------------------
  if ! find /usr/lib /usr/local/lib -path '*libOpenCL.so*' -print -quit 2>/dev/null | grep -q .; then
    log WARN "OpenCL loader (libOpenCL.so) not found"
    return 1
  fi
  log INFO "OpenCL loader present"

  # ------------------------------------------------------------
  # 3. clinfo is diagnostic only; containerized OpenCL can work
  #    even when clinfo is missing or unreliable.
  # ------------------------------------------------------------
  if ! command -v clinfo >/dev/null 2>&1; then
    log WARN "clinfo not available; continuing with device + loader detection"
    return 0
  fi

  if ! clinfo --raw 2>/dev/null | grep -qi "NVIDIA"; then
    log WARN "clinfo did not report NVIDIA; continuing because clinfo is not authoritative"
    return 0
  fi

  log INFO "OpenCL GPU detected"
  return 0
}

configure_c2me_opencl() {
  if ! c2me_opencl_requested; then
    export C2ME_OPENCL_ENABLED=false
    return
  fi

  validate_c2me_opencl_policy

  if ! has_c2me_mod || ! has_c2me_opencl_mod; then
    export C2ME_OPENCL_ENABLED=false
    log INFO "C2ME OpenCL disabled because required mod components are not both present"
    return
  fi

  if [[ "${C2ME_OPENCL_FORCE:-auto}" == "true" ]]; then
    log WARN "C2ME OpenCL runtime probe FORCE ENABLED"
    export C2ME_OPENCL_ENABLED=true
    return
  fi

  if detect_gpu; then
    export C2ME_OPENCL_ENABLED=true
    log INFO "C2ME OpenCL enabled (GPU mode)"
  else
    export C2ME_OPENCL_ENABLED=false
    log INFO "C2ME OpenCL disabled (CPU-safe mode)"
  fi
}

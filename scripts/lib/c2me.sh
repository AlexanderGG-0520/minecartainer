# shellcheck shell=bash

_c2me_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/fabric_mod_metadata.sh
source "${_c2me_lib_dir}/fabric_mod_metadata.sh"
# shellcheck source=scripts/lib/modrinth_api.sh
source "${_c2me_lib_dir}/modrinth_api.sh"
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

remove_managed_c2me_jvm_args() {
  local tmp

  [[ -f "${JVM_ARGS_FILE}" ]] || return 0

  tmp="$(mktemp "${JVM_ARGS_FILE}.c2me-clean.XXXXXX")"
  if ! awk '
    $0 == "# --- Minecartainer C2ME OpenCL BEGIN ---" { managed = 1; next }
    $0 == "# --- Minecartainer C2ME OpenCL END ---" { managed = 0; next }
    managed { next }

    # Clean the legacy Minecartainer-managed block from pre-split C2ME support.
    $0 == "# --- C2ME Hardware Acceleration (EXPERIMENTAL) ---" { next }
    $0 == "-Dc2me.experimental.hardwareAcceleration=true" { next }
    $0 == "-Dc2me.experimental.opencl=true" { next }
    $0 == "-Dc2me.experimental.unsafe=true" { next }

    { print }
  ' "${JVM_ARGS_FILE}" > "$tmp"; then
    safe_rm_f "$tmp"
    die "Failed to reconcile C2ME JVM arguments"
  fi

  if ! cat "$tmp" > "${JVM_ARGS_FILE}"; then
    safe_rm_f "$tmp"
    die "Failed to update C2ME JVM arguments"
  fi
  safe_rm_f "$tmp"
}

install_c2me_jvm_args() {
  # This function runs on every install phase. Remove only blocks that
  # Minecartainer owns so disabling the env flag actually disables OpenCL on
  # the next start, while preserving operator-authored JVM arguments.
  remove_managed_c2me_jvm_args

  c2me_opencl_requested || return 0
  validate_c2me_opencl_policy

  if ! has_c2me_mod; then
    log INFO "C2ME base mod not found in mods/, skipping OpenCL config"
    return 0
  fi

  if ! has_c2me_opencl_mod; then
    log INFO "C2ME OpenCL addon not found in mods/, skipping OpenCL config"
    return 0
  fi

  if [[ "${C2ME_OPENCL_FORCE:-auto}" != "true" ]] && ! detect_gpu; then
    die "C2ME OpenCL requested, but a usable OpenCL GPU runtime was not detected"
  fi

  if should_enable_c2me || [[ "${C2ME_OPENCL_FORCE:-auto}" == "true" ]]; then
    log WARN "C2ME OpenCL Acceleration ENABLED (EXPERIMENTAL)"
    log WARN "This may cause instability or data corruption"

    {
      echo ""
      echo "# --- Minecartainer C2ME OpenCL BEGIN ---"
      c2me_opencl_jvm_arg
      echo "# --- Minecartainer C2ME OpenCL END ---"
    } >> "${JVM_ARGS_FILE}"
  else
    die "C2ME OpenCL components are present, but runtime guard conditions are not met"
  fi
}

detect_opencl_gpu() {
  log INFO "Detecting OpenCL GPU availability..."

  # Device access exposed by Docker/Kubernetes/WSL. /dev/dri covers DRM render
  # nodes used by Intel/AMD and some other OpenCL implementations.
  if [[ ! -d /dev/dri && ! -e /dev/nvidia0 && ! -e /dev/dxg ]]; then
    log INFO "No GPU device node found (/dev/dri, /dev/nvidia0, or /dev/dxg)"
    return 1
  fi
  log INFO "GPU device node found"

  # OpenCL ICD loader. Path-based detection works in minimal containers where
  # ldconfig may be unavailable or incomplete.
  if ! find /usr/lib /usr/local/lib -path '*libOpenCL.so*' -print -quit 2>/dev/null | grep -q .; then
    log WARN "OpenCL loader (libOpenCL.so) not found"
    return 1
  fi
  log INFO "OpenCL loader present"

  # clinfo remains diagnostic rather than authoritative: containerized OpenCL
  # can work even when clinfo is missing or unable to enumerate a platform.
  if ! command -v clinfo >/dev/null 2>&1; then
    log WARN "clinfo not available; continuing with device + loader detection"
    return 0
  fi

  if ! clinfo --raw 2>/dev/null | grep -q .; then
    log WARN "clinfo did not enumerate an OpenCL platform; continuing because clinfo is diagnostic only"
    return 0
  fi

  log INFO "OpenCL platform detected"
  return 0
}

# Compatibility name retained for existing callers/tests.
detect_gpu() {
  detect_opencl_gpu
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
    log ERROR "C2ME OpenCL requested but OpenCL GPU runtime is unavailable"
    return 1
  fi
}

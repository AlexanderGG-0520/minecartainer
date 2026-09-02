# shellcheck shell=bash

C2ME_BASE_MOD_ID="c2me"
C2ME_OPENCL_MOD_ID="c2me-opts-accel-opencl"
C2ME_OPENCL_CONFIG_PROPERTY="c2me.base.config.override.openclAccel.enabled"

has_c2me_base_mod() {
  has_fabric_mod_id "$C2ME_BASE_MOD_ID"
}

has_c2me_opencl_mod() {
  has_fabric_mod_id "$C2ME_OPENCL_MOD_ID"
}

c2me_opencl_requested() {
  local value

  if [[ -n "${ENABLE_C2ME_OPENCL+x}" ]]; then
    value="${ENABLE_C2ME_OPENCL}"
  else
    value="${ENABLE_C2ME_HARDWARE_ACCELERATION:-false}"
  fi

  case "${value,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

c2me_opencl_uses_legacy_env() {
  [[ -z "${ENABLE_C2ME_OPENCL+x}" ]] \
    && [[ -n "${ENABLE_C2ME_HARDWARE_ACCELERATION+x}" ]]
}

validate_c2me_opencl_policy() {
  c2me_opencl_requested || return 0

  case "${ENABLE_C2ME:-false}" in
    true) ;;
    *) die "ENABLE_C2ME_OPENCL=true requires ENABLE_C2ME=true" ;;
  esac

  case "${I_KNOW_C2ME_IS_EXPERIMENTAL:-false}" in
    true) ;;
    *) die "ENABLE_C2ME_OPENCL=true requires I_KNOW_C2ME_IS_EXPERIMENTAL=true" ;;
  esac

  [[ "${TYPE:-}" == "fabric" ]] \
    || die "C2ME OpenCL automatic integration currently supports TYPE=fabric only (current: ${TYPE:-unset})"

  [[ "${JAVA_MAJOR:-unknown}" == "25" ]] \
    || die "C2ME OpenCL requires Java 25 (current: ${JAVA_MAJOR:-unknown})"
}

c2me_opencl_jvm_arg() {
  printf '%s\n' "-D${C2ME_OPENCL_CONFIG_PROPERTY}=true"
}

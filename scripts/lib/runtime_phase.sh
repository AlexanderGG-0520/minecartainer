# shellcheck shell=bash

run_runtime_phase() {
  if is_true "${MODPACK_INFER_RUNTIME:-false}" \
    && declare -F cleanup_modpack_prefetch >/dev/null; then
    # Runtime inference happens before server installation. If any later install
    # step exits early, remove the prefetched archive instead of leaving it in
    # the container writable layer. The normal modpack install consumes and
    # clears this state first, making the EXIT cleanup a no-op on success.
    trap 'cleanup_modpack_prefetch' EXIT
  fi


  install

  if is_true "${INSTALL_ONLY:-false}"; then
    log WARN "INSTALL_ONLY=true, skipping runtime launch and exiting"
    exit 0
  fi

  runtime
}

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT_DIR}"

calls=""

record_call() {
  if [[ -n "$calls" ]]; then
    calls="${calls} $1"
  else
    calls="$1"
  fi
}

log() {
  record_call "log:$1:$2"
}

run_phase_hooks() {
  record_call "hook:$1"
}

install_dirs() { record_call "${FUNCNAME[0]}"; }
install_eula() { record_call "${FUNCNAME[0]}"; }
install_server() { record_call "${FUNCNAME[0]}"; }
clear_fabric_cache() { record_call "${FUNCNAME[0]}"; }
setup_server_icon() { record_call "${FUNCNAME[0]}"; }
configure_paper_configs() { record_call "${FUNCNAME[0]}"; }
generate_velocity_toml() { record_call "${FUNCNAME[0]}"; }
ensure_server_properties() { record_call "${FUNCNAME[0]}"; }
handle_reset_world_flag() { record_call "${FUNCNAME[0]}"; }
install_world() { record_call "${FUNCNAME[0]}"; }
install_server_properties() { record_call "${FUNCNAME[0]}"; }
install_mods() { record_call "${FUNCNAME[0]}"; }
activate_mods() { record_call "${FUNCNAME[0]}"; }
install_datapacks() { record_call "${FUNCNAME[0]}"; }
activate_datapacks() { record_call "${FUNCNAME[0]}"; }
install_jvm_args() { record_call "${FUNCNAME[0]}"; }
install_configs() { record_call "${FUNCNAME[0]}"; }
activate_configs() { record_call "${FUNCNAME[0]}"; }
apply_paper_global_from_env() { record_call "${FUNCNAME[0]}"; }
install_plugins() { record_call "${FUNCNAME[0]}"; }
activate_plugins() { record_call "${FUNCNAME[0]}"; }
install_resourcepacks() { record_call "${FUNCNAME[0]}"; }
reconcile_c2me_opencl() { record_call "${FUNCNAME[0]}"; }
install_c2me_jvm_args() { record_call "${FUNCNAME[0]}"; }
install_whitelist() { record_call "${FUNCNAME[0]}"; }
install_ops() { record_call "${FUNCNAME[0]}"; }
configure_c2me_opencl() { record_call "${FUNCNAME[0]}"; }

source ./scripts/lib/install_phase.sh

install_modpack_dispatch() { record_call "${FUNCNAME[0]}"; }

expected_common_prefix="log:INFO:Install phase start hook:pre-install install_dirs install_eula install_server clear_fabric_cache setup_server_icon configure_paper_configs generate_velocity_toml handle_reset_world_flag install_world install_server_properties install_mods activate_mods install_datapacks activate_datapacks install_jvm_args install_configs activate_configs apply_paper_global_from_env install_plugins activate_plugins"
expected_common_suffix="install_modpack_dispatch reconcile_c2me_opencl install_c2me_jvm_args install_whitelist install_ops configure_c2me_opencl hook:post-install log:INFO:Install phase completed"

TYPE=paper
calls=""
install
expected_paper="${expected_common_prefix} install_resourcepacks ${expected_common_suffix}"
if [[ "$calls" != "$expected_paper" ]]; then
  echo "FAIL: unexpected paper install phase order" >&2
  printf 'expected: %s\nactual:   %s\n' "$expected_paper" "$calls" >&2
  exit 1
fi

TYPE=velocity
calls=""
install
expected_velocity="${expected_common_prefix} ${expected_common_suffix}"
if [[ "$calls" != "$expected_velocity" ]]; then
  echo "FAIL: unexpected velocity install phase order" >&2
  printf 'expected: %s\nactual:   %s\n' "$expected_velocity" "$calls" >&2
  exit 1
fi

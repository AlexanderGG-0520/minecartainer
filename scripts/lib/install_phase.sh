# shellcheck shell=bash

# shellcheck source=scripts/lib/modpack_overrides.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/modpack_overrides.sh"
# shellcheck source=scripts/lib/modpack_policy.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/modpack_policy.sh"
# shellcheck source=scripts/lib/modpack_remove_extra.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/modpack_remove_extra.sh"
# shellcheck source=scripts/lib/modpack_runtime_inference.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/modpack_runtime_inference.sh"
# shellcheck source=scripts/lib/modpack_curseforge.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/modpack_curseforge.sh"
# shellcheck source=scripts/lib/modpack_curseforge_runtime.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/modpack_curseforge_runtime.sh"
# shellcheck source=scripts/lib/modpack_curseforge_remove_extra.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/modpack_curseforge_remove_extra.sh"
# shellcheck source=scripts/lib/modpack_world.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/modpack_world.sh"
# Source the authoritative path policy last because the extension modules above
# source the base mods.sh implementation as part of their dependency chain.
# shellcheck source=scripts/lib/modpack_path_policy.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/modpack_path_policy.sh"

install() {
  log INFO "Install phase start"
  run_phase_hooks "pre-install"

  install_dirs
  install_eula
  install_server        # server jar
  clear_fabric_cache
  setup_server_icon

  configure_paper_configs
  generate_velocity_toml

  handle_reset_world_flag
  install_world

  install_server_properties
  install_mods          # mods (most important)
  activate_mods         # activate mods
  install_datapacks     # datapacks
  activate_datapacks    # activate datapacks
  install_jvm_args
  install_configs
  activate_configs
  if declare -F activate_config_templates >/dev/null; then
    activate_config_templates
  fi
  apply_paper_global_from_env
  install_plugins
  activate_plugins
  if [[ ! "${TYPE}" == "velocity" ]]; then
    install_resourcepacks
  fi
  install_modpack_dispatch
  reconcile_c2me_opencl
  install_c2me_jvm_args
  install_whitelist
  install_ops
  configure_c2me_opencl
  run_phase_hooks "post-install"

  log INFO "Install phase completed"
}

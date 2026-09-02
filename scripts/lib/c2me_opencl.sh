# shellcheck shell=bash

# Split C2ME OpenCL support is implemented here incrementally.
# This file intentionally starts with identity helpers only; resolver/install
# behavior is added in follow-up commits on the same feature branch.

C2ME_BASE_MOD_ID="c2me"
C2ME_OPENCL_MOD_ID="c2me-opts-accel-opencl"

has_c2me_base_mod() {
  has_fabric_mod_id "$C2ME_BASE_MOD_ID"
}

has_c2me_opencl_mod() {
  has_fabric_mod_id "$C2ME_OPENCL_MOD_ID"
}

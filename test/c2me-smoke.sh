#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

DATA_DIR="$tmp/data"
JVM_ARGS_FILE="$tmp/custom/custom.jvm.args"
__SOURCED=1

source ./entrypoint.sh >/dev/null

mkdir -p "$DATA_DIR/mods"

make_fabric_mod_jar() {
  local jar="$1"
  local mod_id="$2"
  local version="$3"
  local metadata="$tmp/fabric.mod.json"

  cat > "$metadata" <<JSON
{"schemaVersion":1,"id":"${mod_id}","version":"${version}"}
JSON
  python3 - "$jar" "$metadata" <<'PY'
import sys
import zipfile

jar, metadata = sys.argv[1:]
with zipfile.ZipFile(jar, "w") as zf:
    zf.write(metadata, "fabric.mod.json")
PY
}

if has_c2me_mod; then
  echo "FAIL: C2ME mod detected when mods directory is empty" >&2
  exit 1
fi

# Filenames are intentionally unrelated to C2ME: identity must come from
# fabric.mod.json rather than a c2me*.jar filename heuristic.
make_fabric_mod_jar "$DATA_DIR/mods/renamed-base-mod.jar" c2me test
make_fabric_mod_jar "$DATA_DIR/mods/renamed-opencl-addon.jar" c2me-opts-accel-opencl test
has_c2me_mod
has_c2me_opencl_mod

ENABLE_C2ME=true
ENABLE_C2ME_OPENCL=true
unset ENABLE_C2ME_HARDWARE_ACCELERATION
I_KNOW_C2ME_IS_EXPERIMENTAL=true
TYPE=fabric
JAVA_MAJOR=25
RUNTIME_ARCH_NORM=x86_64
RUNTIME_CONTAINER=true
RUNTIME_GPU=none

if should_enable_c2me; then
  echo "FAIL: C2ME policy enabled without runtime GPU detection" >&2
  exit 1
fi

C2ME_OPENCL_FORCE=true
unset C2ME_OPENCL_ENABLED
configure_c2me_opencl >/dev/null
test "$C2ME_OPENCL_ENABLED" = "true"

C2ME_OPENCL_FORCE=auto
detect_gpu() {
  return 1
}
configure_c2me_opencl >/dev/null || true
test "$C2ME_OPENCL_ENABLED" = "false"

mkdir -p "$(dirname "$JVM_ARGS_FILE")"
install_jvm_args >/dev/null

# Simulate a file produced by the legacy C2ME integration. The new reconciler
# must remove only those old Minecartainer-owned flags.
cat >> "$JVM_ARGS_FILE" <<'EOF'
# --- C2ME Hardware Acceleration (EXPERIMENTAL) ---
-Dc2me.experimental.hardwareAcceleration=true
-Dc2me.experimental.opencl=true
-Dc2me.experimental.unsafe=true
-Doperator.custom=true
EOF

test -f "$JVM_ARGS_FILE"
grep -F -- "-Xms512M" "$JVM_ARGS_FILE" >/dev/null
grep -F -- "-Xmx512M" "$JVM_ARGS_FILE" >/dev/null
grep -F -- "-XX:+UseG1GC" "$JVM_ARGS_FILE" >/dev/null
test ! -e "$DATA_DIR/jvm.args"

detect_gpu() {
  return 0
}

RUNTIME_GPU=nvidia
should_enable_c2me() {
  return 0
}

install_c2me_jvm_args >/dev/null

grep -F -- "# --- Minecartainer C2ME OpenCL BEGIN ---" "$JVM_ARGS_FILE" >/dev/null
grep -F -- "# --- Minecartainer C2ME OpenCL END ---" "$JVM_ARGS_FILE" >/dev/null
grep -F -- "-Dc2me.base.config.override.openclAccel.enabled=true" "$JVM_ARGS_FILE" >/dev/null
if grep -Fq -- "-Dc2me.experimental.hardwareAcceleration=true" "$JVM_ARGS_FILE"; then
  echo "FAIL: legacy hardwareAcceleration flag remained" >&2
  exit 1
fi
if grep -Fq -- "-Dc2me.experimental.opencl=true" "$JVM_ARGS_FILE"; then
  echo "FAIL: legacy opencl flag remained" >&2
  exit 1
fi
if grep -Fq -- "-Dc2me.experimental.unsafe=true" "$JVM_ARGS_FILE"; then
  echo "FAIL: legacy unsafe flag remained" >&2
  exit 1
fi
grep -F -- "-Doperator.custom=true" "$JVM_ARGS_FILE" >/dev/null

# Re-running the install phase must not duplicate the managed block.
install_c2me_jvm_args >/dev/null
test "$(grep -Fc -- "# --- Minecartainer C2ME OpenCL BEGIN ---" "$JVM_ARGS_FILE")" -eq 1
test "$(grep -Fc -- "-Dc2me.base.config.override.openclAccel.enabled=true" "$JVM_ARGS_FILE")" -eq 1

# Disabling the canonical env must remove the managed flag on the next install
# while leaving operator-authored arguments intact.
ENABLE_C2ME_OPENCL=false
install_c2me_jvm_args >/dev/null
if grep -Fq -- "# --- Minecartainer C2ME OpenCL BEGIN ---" "$JVM_ARGS_FILE"; then
  echo "FAIL: managed C2ME OpenCL block remained after disable" >&2
  exit 1
fi
if grep -Fq -- "-Dc2me.base.config.override.openclAccel.enabled=true" "$JVM_ARGS_FILE"; then
  echo "FAIL: managed C2ME OpenCL flag remained after disable" >&2
  exit 1
fi
grep -F -- "-Doperator.custom=true" "$JVM_ARGS_FILE" >/dev/null
test ! -e "$DATA_DIR/jvm.args"

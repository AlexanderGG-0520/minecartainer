# Examples

This directory contains runnable Docker Compose and Kubernetes examples.

Start with:

- `docker/fabric/compose.yml` for a small local Fabric server.
- `docker/fabric-c2me-gpu-accelerated/compose.yml` for Fabric + split C2ME OpenCL acceleration.
- `kubernetes/fabric-basic.yaml` for a minimal Kubernetes deployment.
- `kubernetes/fabric-hardcore-smp-gpu-c2me.yaml` for the Kubernetes GPU/OpenCL example.
- `kubernetes/paper-pvc/` for a minimal Kubernetes Paper server with a PVC and RCON shutdown.
- `kubernetes/paper-minio-assets/` for a Paper server with PVC storage and S3-compatible plugin/config sync.
- `kubernetes/install-only-job.example.yaml` for pre-warming a volume without launching runtime.
- `kubernetes/rcon-secret.example.yaml` for non-default RCON shutdown credentials.

## Split C2ME OpenCL support

Modern C2ME distributes OpenCL acceleration as a separate Modrinth project rather than bundling the OpenCL module in the base C2ME JAR.

Minecartainer treats those components differently:

- **Base C2ME is user-owned.** Supply it through the normal mods path, S3 sync, or a modpack.
- **The split C2ME OpenCL addon can be Minecartainer-managed.** When explicitly enabled and no unmanaged addon is already present, Minecartainer resolves it from the official Modrinth project and installs it into `/data/mods`.
- **The addon is version-locked to the installed C2ME base version.** This is required because the OpenCL module depends on C2ME internal modules of the same version.
- **Managed downloads are SHA-512 verified and pinned.** The resolved version and file hash are recorded under `/data/.minecartainer/managed-mods/c2me-opencl.json`.
- **Unmanaged addons remain user-owned.** If an existing OpenCL addon is present, Minecartainer validates that its Fabric mod version matches base C2ME and does not take ownership of it.
- **The All-Rights-Reserved addon is never bundled in the container image.** It is downloaded directly from the official Modrinth CDN only when requested.

The canonical opt-in is:

```yaml
ENABLE_C2ME: "true"
ENABLE_C2ME_OPENCL: "true"
I_KNOW_C2ME_IS_EXPERIMENTAL: "true"
```

`ENABLE_C2ME_HARDWARE_ACCELERATION=true` remains a deprecated compatibility alias when `ENABLE_C2ME_OPENCL` is not explicitly set.

### Resolution behavior

With `ENABLE_C2ME_OPENCL=true`, installation occurs after normal mods and modpack processing:

1. Detect base C2ME from `fabric.mod.json` using the exact Fabric mod ID `c2me`.
2. Read the installed base C2ME version.
3. Reuse a valid Minecartainer-managed OpenCL addon if its marker, hash, Minecraft version, and C2ME version still match.
4. Otherwise respect one existing unmanaged addon if its Fabric mod ID is `c2me-opts-accel-opencl` and its version exactly matches base C2ME.
5. If no addon exists, query Modrinth for the current Minecraft version and Fabric loader, resolve the OpenCL release whose `version_number` exactly matches base C2ME, download its primary JAR, and verify SHA-512.
6. Enable the current C2ME config override:

```text
-Dc2me.base.config.override.openclAccel.enabled=true
```

If base C2ME is updated, the managed marker no longer matches and the addon is reconciled to the new matching C2ME version on the next start.

`C2ME_OPENCL_VERSION` defaults to `match-c2me`. An explicit Modrinth version ID or version number may be supplied for controlled resolution, but Minecartainer still rejects a result whose C2ME/OpenCL version does not match the installed base C2ME.

`C2ME_OPENCL_UPDATE=true` forces the managed addon to be re-resolved and reinstalled while preserving the same-version compatibility rule.

## Runtime requirements

Automatic C2ME OpenCL integration currently requires:

- `TYPE=fabric`
- Java 25
- base C2ME already installed
- a GPU device exposed to the container (`/dev/dri`, `/dev/nvidia0`, or `/dev/dxg`)
- an OpenCL ICD loader (`libOpenCL.so`)

The GPU image provides Java 25, the OpenCL loader, and diagnostic tooling, but it does **not** automatically enable C2ME OpenCL. The feature remains explicit opt-in.

For NVIDIA containers, the host still supplies the NVIDIA driver and GPU device access. The examples use the NVIDIA container runtime and expose the required driver capabilities.

## About `clinfo`

`clinfo` is diagnostic, not authoritative. In some container/runtime combinations it can fail to enumerate a platform even when Minecraft/LWJGL can initialize OpenCL correctly. Minecartainer therefore uses device-node plus OpenCL-loader checks as its preflight boundary and treats `clinfo` output as additional evidence rather than the sole success criterion.

The final runtime confirmation should come from Minecraft/C2ME logs showing OpenCL platform/device enumeration and OpenCL world-generation compilation.

## ScalableLux

The C2ME OpenCL module recommends ScalableLux because lighting can become the next world-generation bottleneck once OpenCL acceleration is active. Minecartainer does not install ScalableLux implicitly; if its Fabric mod ID (`scalablelux`) is absent, startup emits a warning and leaves ownership to the operator.

## Docker Compose example

`docker/fabric-c2me-gpu-accelerated/compose.yml` demonstrates the NVIDIA Docker path. Base C2ME must still be supplied through your normal mods source.

The relevant environment variables are:

```yaml
ENABLE_C2ME: "true"
ENABLE_C2ME_OPENCL: "true"
I_KNOW_C2ME_IS_EXPERIMENTAL: "true"
NVIDIA_VISIBLE_DEVICES: "all"
NVIDIA_DRIVER_CAPABILITIES: "compute,utility"
```

and the service uses:

```yaml
gpus: all
```

## Kubernetes example

`kubernetes/fabric-hardcore-smp-gpu-c2me.yaml` demonstrates the NVIDIA Kubernetes path. It uses:

```yaml
runtimeClassName: nvidia
```

and requests an NVIDIA GPU resource. The example also mounts the host OpenCL vendor ICD directory for NVIDIA OpenCL discovery.

Treat CUDA/runtime changes as compatibility-sensitive changes. Pin known-good runtime versions and validate Minecraft/C2ME logs after upgrades rather than assuming a newer CUDA runtime is automatically safer.

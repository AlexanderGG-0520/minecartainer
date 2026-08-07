# Minecartainer

**Minecraft Java Server Container Image**

![Docker Build](https://img.shields.io/github/actions/workflow/status/AlexanderGG-0520/minecartainer/publish.yml?branch=main)
[![Docker Pulls](https://img.shields.io/docker/pulls/alecjp02/minecraft-server.svg?logo=docker)](https://hub.docker.com/r/alecjp02/minecraft-server/)
<a href="https://github.com/users/alexandergg-0520/packages/container/package/minecraft-server"><img alt="GHCR Pulls" src="https://ghcr-badge.elias.eu.org/shield/alexandergg-0520/minecraft-server" height="20"></a>
[![Docker Stars](https://img.shields.io/docker/stars/alecjp02/minecraft-server.svg?logo=docker)](https://hub.docker.com/r/alecjp02/minecraft-server/)
[![GitHub Issues](https://img.shields.io/github/issues-raw/alexandergg-0520/minecartainer.svg)](https://github.com/alexandergg-0520/minecartainer/issues)
![GHCR](https://img.shields.io/badge/GHCR-ghcr.io%2Falexandergg--0520%2Fminecraft--server-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Java](https://img.shields.io/badge/java-8%20%7C%2011%20%7C%2017%20%7C%2021%20%7C%2025%20%7C%2025--gpu-orange)
![Kubernetes](https://img.shields.io/badge/kubernetes-ready-blue)

A predictable, fail-fast Minecraft Java server container image built for Kubernetes, GitOps, persistent volumes, and S3-compatible asset delivery.

```bash
docker pull ghcr.io/alexandergg-0520/minecraft-server:runtime-jre21
```

Stable published image locations:

```text
GHCR:
ghcr.io/alexandergg-0520/minecraft-server

Docker Hub:
alecjp02/minecraft-server
```

The GitHub project is Minecartainer; these published image paths intentionally remain unchanged for existing deployments.

## Core capabilities

* Conservative persistent-volume handling and fail-fast validation before unsafe mutations.
* Explicit install and runtime lifecycle separation, with managed and bring-your-own server artifacts.
* Minecraft-aware graceful shutdown through RCON.
* Local and S3-compatible delivery of mods, plugins, configs, datapacks, resource packs, and world archives.
* Kubernetes and GitOps-oriented operation, including install-only volume pre-warming.
* Java 8, 11, 17, 21, and 25 runtime images, plus a GPU-enabled Java 25 image where applicable.

Minecartainer is an advanced alternative for operators who prefer explicit behavior over broad automatic configuration; it is not a universal replacement for every Minecraft server image.

## Docker Compose Quick Start

Start with a maintained local example:

* **[Paper Compose Quick Start](examples/docker/paper/)** — the recommended plugin-server path.
* **[Fabric Compose Quick Start](examples/docker/fabric/)** — a modded-server starting point.

Both examples use explicit runtime tags, a named `/data` volume, local-only port binding, conservative JVM defaults, and a 240-second Compose stop grace period.

## Kubernetes

Use the [Paper PVC example](examples/kubernetes/paper-pvc/) for a minimal single-writer world volume, or the [Paper S3-compatible assets example](examples/kubernetes/paper-minio-assets/) for plugins and configs from object storage. See [all examples](examples/README.md) for Fabric, GPU, RCON-secret, and install-only patterns.

## Supported server types

Managed and bring-your-own workflows support Vanilla, Paper, Purpur, Fabric, Forge, NeoForge, Velocity, and existing Spigot artifacts. Prefer explicit `TYPE` and `VERSION`; see [server installation and reinstall policy](docs/server-install-reinstall-policy.md) for artifact rules and safeguards.

## Supported Java runtimes

Published runtime targets are `runtime-jre8`, `runtime-jre11`, `runtime-jre17`, `runtime-jre21`, `runtime-jre25`, and `runtime-jre25-gpu`. Select the Java version required by your server software and mods; GPU support is workload- and host-runtime-specific.

## Safety model

Existing worlds and persistent volumes are treated as important state. The image separates installation from runtime, rejects unsafe or mismatched state before mutation, uses an explicit RCON shutdown path, and makes destructive S3 mirroring opt-in. Keep backups and verify new storage prefixes before enabling removal.

## Examples

* [Docker Compose examples](examples/README.md#start-with)
* [Kubernetes Paper with a PVC](examples/kubernetes/paper-pvc/)
* [Kubernetes Paper with S3-compatible assets](examples/kubernetes/paper-minio-assets/)
* [Install-only Kubernetes job](examples/kubernetes/install-only-job.example.yaml)

## CI and smoke coverage

CI is split by responsibility:

* **Lint and Static Smoke** runs `bash -n entrypoint.sh` and `shellcheck -x -s bash entrypoint.sh`.
* **Runtime Smoke CI** builds `runtime-jre21`, checks `/entrypoint.sh` inside the image, and runs
  runtime behavior regressions for install-only, RCON safety, `TYPE=auto`, Spigot bring-your-own
  artifacts, and install marker mismatch handling.

---

## Experimental Modrinth `.mrpack`

Modrinth `.mrpack` server-mode install support is being introduced in phases. `MODPACK_URL`
accepts HTTPS `.mrpack` URLs. HTTPS downloads are restricted to HTTPS redirects, use bounded
retries and timeouts, and every pack-declared file is verified with SHA-512 and SHA-1 before
installation. Local `file://` downloads remain available only when
`MODPACK_ALLOW_FILE_URL=true` is explicitly set and are intended for tests and local fixtures.

Server-side filtering follows the `.mrpack` `files[].env.server` metadata. Files where
`env.server` is missing or `required` are eligible for installation. Files marked
`env.server=unsupported` are client-only and are excluded from the server. Files marked
`env.server=optional` are also skipped while optional-file installation is unsupported;
`MODPACK_INCLUDE_OPTIONAL=true` currently fails fast instead of silently changing that policy.

Server installs also support the `.mrpack` `overrides/` and `server-overrides/` layers. Minecartainer
applies `overrides/` first and `server-overrides/` second, matching Modrinth's server-layer semantics.
Existing operator-owned targets are not overwritten. A previously seeded override remains managed only
while its current SHA-512 still matches the marker; if an operator edits it, later installs preserve the
operator's version instead of taking ownership again. `client-overrides/` is intentionally ignored by
server installs.

Override paths retain the conservative modpack allowlist and safety checks. World data,
`server.properties`, `eula.txt`, `ops.json`, `whitelist.json`, duplicate layer entries, indexed-file
collisions, traversal paths, and symlink-resolved targets outside `/data` are rejected.

`MODPACK_REMOVE_EXTRA=true`, CurseForge packs, direct zip packs, world installs, and TYPE/VERSION
inference are not supported yet.

---

## Kubernetes shutdown recommendations

For reliable shutdown behavior (including Citizens save), we recommend:

* Set `terminationGracePeriodSeconds` to **240s or higher** for the default timings.
* Set `ENABLE_RCON=true` and provide a non-default `RCON_PASSWORD` so shutdown commands can run.

`ENABLE_RCON` defaults to `false`. The image refuses an empty RCON password and also refuses
`RCON_PASSWORD=changeme`.

Shutdown timing values are validated during preflight. `STOP_SERVER_ANNOUNCE_DELAY`,
`SHUTDOWN_SAVE_WAIT_SECONDS`, `RCON_RETRY_DELAY`, `SHUTDOWN_WAIT_TIMEOUT`,
`SHUTDOWN_TERM_WAIT`, `RCON_STOP_LOCK_WAIT_TIMEOUT`, and `READY_DELAY` are non-negative integer
seconds. `RCON_RETRIES` and `RCON_TIMEOUT` are positive integers (`RCON_TIMEOUT` is in seconds).
Invalid, fractional, negative, whitespace-padded, or suffixed values fail before installation or
Minecraft startup. Values greater than `2147483647` are also rejected.

The modeled bounded default shutdown path is 219 seconds:
`max(RCON_STOP_LOCK_WAIT_TIMEOUT, announcement + 4 * command_retry_budget + SHUTDOWN_SAVE_WAIT_SECONDS) + SHUTDOWN_WAIT_TIMEOUT + SHUTDOWN_TERM_WAIT`, where
`command_retry_budget = RCON_RETRIES * RCON_TIMEOUT + (RCON_RETRIES - 1) * RCON_RETRY_DELAY`.
The four command budgets cover Citizens save, flush, fallback save, and stop; the announcement adds
two command budgets only when enabled because its `say` fallback may run. Maintained examples use 240
seconds, providing a 21-second shell/process-transition safety margin. Successful shutdowns normally
finish much sooner. Recalculate the formula and increase the grace period when overriding any retry,
timeout, announcement, save-wait, process-wait, or TERM-wait value.

Kubernetes counts `preStop` time against `terminationGracePeriodSeconds`. The maintained examples do
not run `rcon-stop` in `preStop`: `tini` forwards TERM to the entrypoint, whose TERM trap performs the
single Minecraft-aware shutdown sequence and shares its RCON lock. Docker's default stop timeout can be
too short for this path; use `docker stop --time 240` or a Compose `stop_grace_period: 240s` for defaults.
SIGKILL or host failure can still interrupt saving.

Minimal Kubernetes pattern:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: minecraft-rcon
type: Opaque
stringData:
  password: replace-with-a-strong-password
---
containers:
  - name: minecraft
    env:
      - name: ENABLE_RCON
        value: "true"
      - name: RCON_PASSWORD
        valueFrom:
          secretKeyRef:
            name: minecraft-rcon
            key: password
    readinessProbe:
      exec:
        command: ["test", "-f", "/data/.ready"]
      periodSeconds: 10
      failureThreshold: 3
    volumeMounts:
      - name: data
        mountPath: /data
terminationGracePeriodSeconds: 240
```

The `.ready` file is created only after the runtime survives `READY_DELAY` and is removed during
shutdown. Keep world data on a single-writer PVC and prefer `strategy.type: Recreate` for
Deployments that mount the same world volume.

## Startup hooks (new)

You can run custom scripts at controlled lifecycle points.

Environment variables:

* `HOOKS_ENABLED` (`false` by default)
* `HOOKS_DIR` (`/hooks` by default)
* `HOOKS_STRICT` (`true` by default; if false, failed hooks only log warnings)
* `HOOKS_TIMEOUT_SEC` (`0` by default; if > 0, each hook is terminated after timeout)

Supported hook phases (directory names under `HOOKS_DIR`):

* `pre-install.d` — before install phase starts
* `post-install.d` — after install phase completes
* `pre-runtime.d` — right before launching the server runtime

Only executable files are run.

## Install-only mode (new)

If you only want to execute the install phase and then stop (for pre-warming volumes or CI checks),
set:

* `INSTALL_ONLY=true`

Behavior:

* Runs normal preflight + install
* Skips runtime server launch
* Exits with code `0` when install succeeds

## Server type and flavor notes

Prefer an explicit `TYPE` for new installs. `TYPE=auto` is intended for existing `/data` volumes: it
uses `/data/.server-install.json` when a managed install marker and its artifact are present. Without a
usable marker, it checks for `velocity.jar`, `fabric-server-launch.jar`, Forge/NeoForge `run.sh`, then
`server.jar`, and falls back to `vanilla` when no known artifact is present. It does not infer the
Minecraft `VERSION`.

Set `VERSION` for install and install-only workflows. The runtime fails fast when it cannot safely
match the requested server artifact to the requested `TYPE` and `VERSION`.

Managed install artifact expectations:

* `vanilla`, `paper`, and `purpur` use `/data/server.jar`.
* `fabric` uses `/data/fabric-server-launch.jar`.
* `forge` and `neoforge` install and run through `/data/run.sh`.
* `velocity` uses `/data/velocity.jar` and does not use `server.properties`.

`TYPE=spigot` can run an existing `/data/server.jar`, but the entrypoint does not currently provide a
managed Spigot installer. It fails fast if `TYPE=spigot` is selected without an existing artifact.

The installer writes `/data/.server-install.json` for managed artifacts. If an existing artifact has a
marker for a different `TYPE`, `VERSION`, or artifact name, the entrypoint refuses to replace it
automatically. Existing artifacts without a marker are left in place with a warning, so verify legacy
volumes before changing `TYPE` or `VERSION`. See the
[server reinstall policy](docs/server-install-reinstall-policy.md) for `FORCE_REINSTALL=true` behavior.

## `server.properties` environment overrides

When `APPLY_SERVER_PROPERTIES_DIFF=true` (the default), known `server.properties` keys can be set with
environment variables by uppercasing the key and replacing `-` and `.` with `_`.

Examples:

* `online-mode` -> `ONLINE_MODE`
* `enforce-secure-profile` -> `ENFORCE_SECURE_PROFILE`
* `server-port` -> `SERVER_PORT`
* `query.port` -> `QUERY_PORT`
* `rcon.port` -> `RCON_PORT`
* `require-resource-pack` -> `REQUIRE_RESOURCE_PACK`
* `resource-pack` -> `RESOURCE_PACK`
* `view-distance` -> `VIEW_DISTANCE`
* `simulation-distance` -> `SIMULATION_DISTANCE`

For server resource packs, `RESOURCE_PACK` must be a client-accessible `http://` or `https://`
URL. S3 sync paths such as `s3/bucket/resourcepacks` are internal asset sources and are not
valid `resource-pack` values for Minecraft clients.

The image can also generate `resource-pack` from resourcepack object-storage settings when
`RESOURCEPACKS_AUTO_SET_RESOURCE_PACK=true` and `RESOURCE_PACK` is not explicitly set. Use
`RESOURCEPACKS_PUBLIC_BASE_URL` as the public HTTP/HTTPS URL for the bucket root, not for the
resourcepack prefix itself. The entrypoint appends `RESOURCEPACKS_S3_PREFIX` and
`RESOURCEPACKS_FILE` to that base URL.

Example:

```yaml
env:
  - name: APPLY_SERVER_PROPERTIES_DIFF
    value: "true"
  - name: RESOURCEPACKS_AUTO_SET_RESOURCE_PACK
    value: "true"
  - name: RESOURCEPACKS_PUBLIC_BASE_URL
    value: "https://assets.example.com"
  - name: RESOURCEPACKS_S3_PREFIX
    value: "fabric/prison/resourcepacks"
  - name: RESOURCEPACKS_FILE
    value: "pack.zip"
  - name: REQUIRE_RESOURCE_PACK
    value: "true"
  - name: RESOURCE_PACK_PROMPT
    value: "Please accept the server resource pack."
```

This generates:

```properties
resource-pack=https://assets.example.com/fabric/prison/resourcepacks/pack.zip
```

Only environment variables that are explicitly set are applied. If a variable is set to an empty
string, the corresponding line is written as `key=`. Existing keys are replaced, missing keys are
appended, and comments or unrelated keys are preserved where possible.

Minecraft versions differ in which `server.properties` keys they support. This image keeps mappings for
both old and new keys; unsupported keys are not added unless you explicitly set the matching
environment variable.

## UUID cache safety notes

`OPS_USERS` and `WHITELIST_USERS` accept comma-separated Minecraft player names and use
`/data/uuid_cache.json` to cache Mojang UUID lookups.
The cache must be a JSON object. If the file is corrupted or contains another JSON type, startup fails
fast with the cache path and does not print the file contents. Fix the JSON manually or remove the cache
file to let it be regenerated; the entrypoint does not auto-repair it.

## S3 sync safety notes

The image uses `aws-cli` for S3-backed mods, plugins, configs, datapacks, resourcepacks, and world
archives. S3-compatible endpoints are supported with `S3_ENDPOINT_URL` or the legacy-compatible
`S3_ENDPOINT`; when either is set, the entrypoint passes `--endpoint-url` to AWS CLI calls.

Credential variables are AWS-compatible. Set `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` directly
when possible. Existing project-specific variables are still accepted: `S3_ACCESS_KEY_ID` or
`S3_ACCESS_KEY` map to `AWS_ACCESS_KEY_ID`, and `S3_SECRET_ACCESS_KEY` or `S3_SECRET_KEY` map to
`AWS_SECRET_ACCESS_KEY` inside the runtime process. `AWS_REGION`, `AWS_DEFAULT_REGION`, or `S3_REGION`
can set the region; otherwise the image defaults to `us-east-1` for S3-compatible storage. Secrets are
not logged.

Resourcepacks synced from S3-compatible storage are stored as local files for operator-managed distribution
workflows. Minecraft clients are not served files from `/data/resourcepacks` automatically; set
`RESOURCE_PACK` to the HTTP/HTTPS URL that clients can fetch. The install phase does not activate
resourcepacks into `/data/resourcepacks`; local sync is retained for object validation, optional local
inspection, and future local serving workflows.

If your object-storage bucket is exposed through cloudflared, nginx, Kubernetes Ingress, or a CDN, set
`RESOURCEPACKS_PUBLIC_BASE_URL` to that public bucket-root URL. Do not set `resource-pack` to
internal values such as `s3://...`, `s3/...`, `/resourcepacks/...`, `/data/resourcepacks/...`, or an
internal-only object-storage endpoint.

For asset syncs, `*_REMOVE_EXTRA=false` is the safer default. Enabling `*_REMOVE_EXTRA=true` treats the
selected remote S3 prefix as authoritative: local files that are not present under that prefix may
be removed. Before running a remove sync, the entrypoint lists the remote source and fails fast if it is
empty, which helps catch bucket or prefix mistakes before local content is pruned.

Keep S3 prefixes stable for a given world. Before enabling remove-extra, verify the bucket and prefix
contain the expected files and do not commit S3 credentials or other secrets. `*_SYNC_ONCE=true` skips a
sync when the local target already has content and remove-extra is not enabled; enabling remove-extra
always performs the sync safety check and mirror operation.

### Datapack source policy

Datapacks may come from the local datapack input directory (`INPUT_DATAPACKS_DIR`, default
`/datapacks`) or from `DATAPACKS_S3_BUCKET` plus `DATAPACKS_S3_PREFIX`, but not both at once. The image
stages S3 datapacks before touching `<world>/datapacks`. If both prepared sources contain files, startup
fails before changing the world destination; configure only one source. Empty directories do not count
as populated, and existing files in the world datapack directory are destination state, not an input.

To use local input, mount or provide files under the local datapack input directory. To use S3 input,
set the bucket and prefix and leave the local input empty. Before changing either source, back up and
verify the world: a world directory or named volume is not a backup.

### Local content input directories

Local activation reads these directories by default: `INPUT_MODS_DIR=/mods`,
`INPUT_PLUGINS_DIR=/plugins`, `INPUT_CONFIG_DIR=/config`,
`INPUT_DATAPACKS_DIR=/datapacks`, and `INPUT_RESOURCEPACKS_DIR=/resourcepacks`.
Set an `INPUT_*_DIR` value to use that exact local source instead; it controls activation as well as
S3 staging. For mods, plugins, config, and datapacks, an explicitly configured activation path must
exist and be a readable directory. An empty configured directory is a valid source and does not fall
back to the image default or remove the active destination.

An activated input source must not overlap its active destination under `/data`; a source equal to its
destination is treated as already active and is left untouched. Quote paths containing spaces in Compose
or YAML, for example:

```yaml
volumes:
  - "./server inputs/mods:/custom mods:ro"
environment:
  INPUT_MODS_DIR: "/custom mods"
```

Datapacks retain the separate local-versus-S3 exclusivity rule above. The other content types preserve
their existing S3 ordering and source behavior.

## Documentation

This project has detailed guidance in the [documentation index](docs/index.md) and GitHub Wiki.

The Wiki explains not only *how* to run the server, but *why* it is designed this way:
including lifecycle separation, persistent storage strategy, and world safety guarantees.

### Start here

[Wiki Home](https://github.com/AlexanderGG-0520/minecartainer/wiki)

### Recommended reading order

1. **Getting Started / Quick Start**  
   Fastest way to run the server safely

2. **Lifecycle Design (Install Phase / Runtime Phase)**  
   Core design philosophy and safety guarantees

3. **Environment Variables**  
   How configuration is classified and applied

4. **World Reset Mechanism**  
   How destructive changes are made explicit and safe

5. **Storage & Persistence**  
   PVC, volume strategy, and migration

6. **FAQ**  
   Differences vs itzg/minecraft-server and common pitfalls

The lifecycle documentation is recommended reading before changing install or runtime environment
variables, because some variables are intentionally scoped to only one phase.

### Install-only mode

Run `entrypoint.sh install-only` to execute the install phase and exit without starting the server.
This is intended for explicit init workflows such as Kubernetes init containers.

---

## Repository Rename

This project was previously hosted at `AlexanderGG-0520/minecraft-server`.

The GitHub repository is now `AlexanderGG-0520/minecartainer`. GitHub redirects the old repository URL to the new location.

The published container image paths have not changed:

* `ghcr.io/alexandergg-0520/minecraft-server`
* `alecjp02/minecraft-server`

Existing Docker Compose files, Kubernetes manifests, image tags, and digest-pinned deployments remain compatible.

## Credits

This project is inspired by existing Minecraft server images, including [itzg/docker-minecraft-server](https://github.com/itzg/docker-minecraft-server), and the broader container ecosystem.

It exists to provide another option for explicit lifecycle boundaries, Kubernetes-oriented behavior, conservative persistent storage, predictable failures, and S3-compatible asset workflows—not to replace other projects.

# s3_client.sh temporary-file cleanup boundary

This note defines the boundary for the completed behavior-preserving cleanup of
temporary-file handling in `scripts/lib/s3_client.sh`, especially
`ensure_s3_source_nonempty_for_remove`.

This note was added before the implementation PR and documents the behavior
boundary for that cleanup.

Implementation status: completed for the focused
`ensure_s3_source_nonempty_for_remove` temporary-file cleanup pass.

## Current behavior to preserve after AWS CLI migration

`s3_client.sh` owns the shared AWS CLI helpers used by S3-backed sync flows.

- `S3_ENDPOINT_URL` is used for S3-compatible endpoints when set.
- Legacy `S3_ENDPOINT` remains accepted as an endpoint alias.
- When a custom S3-compatible endpoint is configured, Minecartainer defaults
  `AWS_REQUEST_CHECKSUM_CALCULATION` and `AWS_RESPONSE_CHECKSUM_VALIDATION` to
  `when_required`. This avoids AWS CLI checksum/signing behavior that is not
  consistently implemented by S3-compatible servers while retaining required
  checksums.
- Explicit operator values for `AWS_REQUEST_CHECKSUM_CALCULATION` and
  `AWS_RESPONSE_CHECKSUM_VALIDATION` are preserved and never overwritten.
- Native AWS S3 usage without a custom endpoint leaves AWS CLI checksum defaults
  untouched.
- AWS-compatible credentials are used directly when present:
  - `AWS_ACCESS_KEY_ID`
  - `AWS_SECRET_ACCESS_KEY`
  - `AWS_DEFAULT_REGION`
  - `AWS_REGION`
- Project-specific credentials are mapped inside the runtime process when set:
  - `S3_ACCESS_KEY_ID` or `S3_ACCESS_KEY`
  - `S3_SECRET_ACCESS_KEY` or `S3_SECRET_KEY`
  - `S3_REGION`
- The default region is `us-east-1` when no AWS or project-specific region is
  configured.
- `ensure_s3_source_nonempty_for_remove` receives a source path and feature
  name, writes AWS CLI object listing output to a temporary file, and fails
  before deletion-capable sync if listing fails or the source is empty.
- The helper currently removes its temporary file on the explicit success and
  failure branches.

Future cleanup must preserve:

- S3-compatible storage support as a first-class project assumption.
- Existing S3 environment variable names and AWS-compatible names.
- The custom-endpoint checksum compatibility defaults and explicit operator
  override behavior.
- Existing internal source path shape such as `s3/bucket/prefix`, converted to
  `s3://bucket/prefix` at the AWS CLI boundary.
- Existing fail-fast behavior before remove sync.
- Existing log and error message meaning unless a dedicated PR intentionally
  changes that behavior.
- Existing callers from mods, configs, datapacks, resourcepacks, and any future
  S3-backed helpers.
- CI smoke tests should not contact real object storage unless a dedicated test
  environment explicitly provides mocked or disposable endpoints.

## Implementation boundary

A future implementation PR may:

- Keep the cleanup scoped to `scripts/lib/s3_client.sh`.
- Use `mktemp` for temporary file creation.
- Add a local cleanup trap or a carefully scoped cleanup helper.
- Ensure temporary files are removed on success, listing failure, empty-source
  failure, and unexpected function exit.
- Avoid leaking temporary files if AWS CLI, shell redirection, or validation
  commands fail.
- Keep cleanup local to `ensure_s3_source_nonempty_for_remove` where possible.

A future implementation PR must not:

- Remove existing S3 environment variable compatibility.
- Remove S3-compatible endpoint support.
- Change bucket, prefix, or key semantics.
- Change remove-extra safety behavior.
- Change world install/reset behavior.
- Change install, runtime launch, shutdown, RCON, or server artifact behavior.
- Combine with world path-safety or `rm -rf` cleanup.

## Staged plan

1. Docs-only temp cleanup boundary.
   This PR.

2. Behavior-preserving temp-file cleanup in `s3_client.sh` only.
   Use `mktemp`, scoped cleanup, unchanged command semantics, and mocked smoke
   coverage where practical.

3. Separate object-storage dependency remediation PRs when needed.
   Keep S3-compatible endpoint support and avoid unrelated refactors.

4. Separate world install/reset path-safety PRs.
   Do not mix destructive path hardening with S3 temp cleanup.

## Smoke guidance

Future implementation smoke tests should:

- Source `scripts/lib/s3_client.sh` under `set -euo pipefail`.
- Mock `aws` in `PATH` to avoid real object-storage network calls.
- Use temporary directories for mock state and temp-file assertions.
- Verify temp files are cleaned up after successful listing.
- Verify temp files are cleaned up after AWS CLI listing failure.
- Verify temp files are cleaned up after an empty-source failure.
- Verify existing S3 env var names remain compatible.
- Verify custom endpoints default checksum calculation and validation to
  `when_required` while explicit operator values remain authoritative.
- Verify native AWS S3 mode does not inject checksum compatibility overrides.
- Avoid real S3 credentials.
- Avoid contacting real object-storage endpoints.
- Avoid destructive world reset or world install paths.

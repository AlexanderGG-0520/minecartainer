#!/usr/bin/env python3
"""Static invariants for the exact-SHA release workflow."""

from pathlib import Path
import re

try:
    import yaml
except ImportError as error:
    raise SystemExit(f"PyYAML is required for this smoke test: {error}")


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/publish.yml"
VARIANTS = {
    "runtime-jre8": {"target": "runtime", "java": "8"},
    "runtime-jre11": {"target": "runtime", "java": "11"},
    "runtime-jre17": {"target": "runtime", "java": "17"},
    "runtime-jre21": {"target": "runtime", "java": "21"},
    "runtime-jre25": {"target": "runtime", "java": "25"},
    "runtime-jre25-gpu": {"target": "runtime-gpu", "java": "25"},
}


def fail(message: str) -> None:
    raise SystemExit(f"release workflow smoke test failed: {message}")


workflow_text = WORKFLOW.read_text(encoding="utf-8")
workflow = yaml.load(workflow_text, Loader=yaml.BaseLoader)
jobs = workflow.get("jobs", {})
required_jobs = {"resolve-source", "validate-shell", "validate-target", "publish-immutable", "promote-aliases"}
if set(jobs) != required_jobs:
    fail(f"unexpected release job set: {sorted(jobs)}")

variants_match = re.search(r"variants='(\[[^']+\])'", workflow_text)
if not variants_match:
    fail("authoritative variant JSON is missing")
variant_entries = yaml.load(variants_match.group(1), Loader=yaml.BaseLoader)
variants = {
    entry["name"]: {"target": entry["target"], "java": entry["java"]}
    for entry in variant_entries
}
if variants != VARIANTS:
    fail(f"authoritative variant matrix is {variants}, expected {VARIANTS}")

for job_name in ("validate-target", "publish-immutable", "promote-aliases"):
    matrix = jobs[job_name].get("strategy", {}).get("matrix", {}).get("variant", "")
    if "needs.resolve-source.outputs.variants" not in matrix:
        fail(f"{job_name} does not consume the authoritative variant matrix")

for job_name in ("validate-shell", "validate-target", "publish-immutable"):
    steps = jobs[job_name].get("steps", [])
    checkout = next((step for step in steps if step.get("name") == "Checkout resolved source"), None)
    if not checkout or "needs.resolve-source.outputs.source_sha" not in checkout.get("with", {}).get("ref", ""):
        fail(f"{job_name} does not check out the resolved SHA")
    assertion = next((step for step in steps if step.get("name") == "Assert resolved source"), None)
    if not assertion or "git rev-parse HEAD" not in assertion.get("run", ""):
        fail(f"{job_name} does not assert the checked out SHA")

publish_needs = set(jobs["publish-immutable"].get("needs", []))
if not {"resolve-source", "validate-shell", "validate-target"}.issubset(publish_needs):
    fail("production immutable publishing is not downstream of the complete validation gate")
promote_needs = set(jobs["promote-aliases"].get("needs", []))
if not {"resolve-source", "publish-immutable"}.issubset(promote_needs):
    fail("alias promotion is not downstream of immutable publishing")

for job_name in ("validate-shell", "validate-target"):
    start = workflow_text.find(f"    {job_name}:")
    end = workflow_text.find("\n    ", start + 5)
    if "push: true" in workflow_text[start:end]:
        fail(f"validation job {job_name} has a production push")

for job_name in ("validate-target", "publish-immutable"):
    steps = jobs[job_name]["steps"]
    target_step = next((step for step in steps if step.get("name") == "Resolve Docker build target"), None)
    if not target_step:
        fail(f"{job_name} does not resolve a source-compatible Docker target")
    if target_step.get("id") != "build_target":
        fail(f"{job_name} target resolver does not expose the build_target step id")
    target_env = target_step.get("env", {})
    if target_env.get("INTERNAL_TARGET") != "${{ matrix.variant.target }}":
        fail(f"{job_name} target resolver does not receive the internal target")
    if target_env.get("LEGACY_TARGET") != "${{ matrix.variant.name }}":
        fail(f"{job_name} target resolver does not receive the legacy public target")
    target_run = target_step.get("run", "")
    for required in (
        "${INTERNAL_TARGET}",
        "${LEGACY_TARGET}",
        'target="${INTERNAL_TARGET}"',
        'target="${LEGACY_TARGET}"',
        "No compatible Docker target found",
    ):
        if required not in target_run:
            fail(f"{job_name} target resolver is missing backfill compatibility logic: {required}")

validate_build = next(
    step
    for step in jobs["validate-target"]["steps"]
    if step.get("name") == "Build validation image without publishing"
)
validate_with = validate_build.get("with", {})
if validate_with.get("push") != "false":
    fail("target validation build must use push: false")
if validate_with.get("target") != "${{ steps.build_target.outputs.target }}":
    fail("target validation build does not use the source-compatible resolved target")
if "JAVA_VERSION=${{ matrix.variant.java }}" not in validate_with.get("build-args", ""):
    fail("target validation build does not pass the Java version")
if "matrix.variant.name" not in validate_with.get("tags", ""):
    fail("target validation image tag does not use the public variant name")

publish_build = next(
    step
    for step in jobs["publish-immutable"]["steps"]
    if step.get("name") == "Publish immutable image"
)
publish_with = publish_build.get("with", {})
if publish_with.get("target") != "${{ steps.build_target.outputs.target }}":
    fail("immutable publication does not use the source-compatible resolved target")
if "JAVA_VERSION=${{ matrix.variant.java }}" not in publish_with.get("build-args", ""):
    fail("immutable publication does not pass the Java version")
if "matrix.variant.name" not in publish_with.get("tags", ""):
    fail("immutable publication tags do not use the public variant name")

runtime_check = next(
    step
    for step in jobs["validate-target"]["steps"]
    if step.get("name") == "Check published runtime dependencies"
)
runtime_check_text = runtime_check.get("run", "")
if "grep -F Zulu" not in runtime_check_text:
    fail("runtime validation does not assert the Azul Zulu JVM vendor")
if "steps.build_target.outputs.modern" not in runtime_check_text:
    fail("Zulu vendor validation is not gated for historical pre-migration backfills")

resolver = ROOT / "scripts/release/resolve-source.sh"
resolver_text = resolver.read_text(encoding="utf-8")
if "refs/tags/${release_tag}:refs/tags/${release_tag}" not in resolver_text or "refs/tags/${release_tag}^{commit}" not in resolver_text:
    fail("manual tag resolution must fetch refs/tags and peel to a commit")
if "release_tag_is_valid" not in resolver_text or re.search(r"\beval\b", resolver_text):
    fail("manual tag validation is missing or unsafe")
resolver_call = 'source_sha="$(bash scripts/release/resolve-source.sh "$PWD" "${release_tag}")"'
if workflow_text.count(resolver_call) != 2:
    fail("tag pushes and manual backfills must invoke the resolver through Bash")
if 'source_sha="$(scripts/release/resolve-source.sh' in workflow_text:
    fail("release resolver must not be invoked directly")
if '[[ "${GITHUB_REF_TYPE}" == "tag" ]]' not in workflow_text or "workflow_dispatch)" not in workflow_text:
    fail("tag pushes and manual backfills must resolve through the same resolver")

if '"${CHANNEL}" == "main"' not in workflow_text:
    fail("main-only mutable runtime alias policy is missing")
if "${RELEASE_TAG}-${VARIANT}" not in workflow_text:
    fail("versioned release alias promotion is missing")
if "-sha-${{ needs.resolve-source.outputs.source_sha }}" not in workflow_text:
    fail("immutable SHA image tag is missing")
if "org.opencontainers.image.revision=${{ needs.resolve-source.outputs.source_sha }}" not in workflow_text:
    fail("OCI revision label must use resolved source SHA")
if "cancel-in-progress: false" not in workflow_text:
    fail("release concurrency must not cancel an in-progress publication")
if "{{.Digest}}" in workflow_text:
    fail("immutable digest recording uses unsupported top-level Digest template field")
if workflow_text.count("docker buildx imagetools inspect") != 2:
    fail("immutable publication must inspect both registry manifests")
if workflow_text.count("--format '{{json .Manifest}}'") != 2:
    fail("immutable digest recording must inspect JSON manifests for both registries")
if workflow_text.count("jq -er '.digest | select(test(\"^sha256:[0-9a-f]{64}$\"))'") != 2:
    fail("immutable digest recording must validate both extracted manifest digests")
if (
    "test \"${ghcr_digest}\" = \"${DIGEST}\"" not in workflow_text
    or "test \"${dockerhub_digest}\" = \"${DIGEST}\"" not in workflow_text
):
    fail("immutable publication must compare both registry digests with the build digest")

for job_name in ("resolve-source", "validate-shell", "validate-target"):
    permissions = jobs[job_name].get("permissions", {})
    if permissions and permissions.get("packages") == "write":
        fail(f"validation job {job_name} has package write permission")

lint_workflow = ROOT / ".github/workflows/lint-and-smoke.yml"
lint_text = lint_workflow.read_text(encoding="utf-8")
for workflow_name, candidate_text in (("lint", lint_text), ("release validation", workflow_text)):
    if "python3 test/ci-test-inventory-smoke.py" not in candidate_text:
        fail(f"{workflow_name} does not run the smoke-test inventory checker")
    if "scripts/ci/run-test-manifest.sh" not in candidate_text:
        fail(f"{workflow_name} does not run the authoritative smoke-test manifest")

if "for test_file in test/*.sh" in workflow_text:
    fail("release validation retains an independent shell-test list")
if "test/filesystem-safety-smoke.sh" in lint_text:
    fail("lint workflow retains individually maintained standalone smoke-test steps")

print("release workflow smoke test passed")

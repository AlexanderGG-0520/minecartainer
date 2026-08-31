#!/usr/bin/env python3
"""Static invariants for Java runtime construction in the Dockerfile."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
DOCKERFILE = ROOT / "Dockerfile"
TEXT = DOCKERFILE.read_text(encoding="utf-8")


def fail(message: str) -> None:
    raise SystemExit(f"dockerfile Java runtime smoke test failed: {message}")


if "eclipse-temurin" in TEXT:
    fail("legacy Eclipse Temurin reference remains")

for required in (
    "https://repos.azul.com/azul-repo.key",
    "https://repos.azul.com/zulu/deb stable main",
    "AS runtime-common",
    "AS runtime",
    "ARG JAVA_VERSION=25",
    'apt-get install -y --no-install-recommends "zulu${JAVA_VERSION}-jre"',
    'readlink -f "$(command -v java)"',
    "ENV JAVA_HOME=/opt/java/openjdk",
    "AS runtime-gpu",
    "FROM runtime-gpu AS runtime-jre25-gpu",
):
    if required not in TEXT:
        fail(f"missing required Dockerfile invariant: {required}")

if TEXT.count("ENV JAVA_HOME=/opt/java/openjdk") != 7:
    fail("every CPU runtime and the GPU runtime must expose the stable /opt/java/openjdk JAVA_HOME")

if not re.search(r'case "\$\{JAVA_VERSION\}" in\s+\\\n\s+8\|11\|17\|21\|25\)', TEXT):
    fail("parameterized runtime does not explicitly allow exactly Java 8/11/17/21/25")

for version in (8, 11, 17, 21, 25):
    marker = f"FROM runtime-common AS runtime-jre{version}"
    start = TEXT.find(marker)
    if start < 0:
        fail(f"missing backward-compatible target runtime-jre{version}")
    next_stage = TEXT.find("\nFROM ", start + len(marker))
    section = TEXT[start:] if next_stage < 0 else TEXT[start:next_stage]
    if f"zulu{version}-jre" not in section:
        fail(f"runtime-jre{version} does not install Zulu {version}")
    if "ENV JAVA_HOME=/opt/java/openjdk" not in section:
        fail(f"runtime-jre{version} does not expose the stable JAVA_HOME")

runtime_gpu = TEXT[TEXT.find("FROM nvidia/cuda:13.3.1-runtime-ubuntu24.04 AS runtime-gpu"):]
if 'test "${JAVA_VERSION}" = "25"' not in runtime_gpu:
    fail("GPU runtime does not reject non-Java-25 build arguments")
if '"zulu${JAVA_VERSION}-jre"' not in runtime_gpu:
    fail("GPU runtime does not install Zulu through the shared JAVA_VERSION build argument")

print("dockerfile Java runtime smoke test passed")

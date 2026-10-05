#!/usr/bin/env python3
from pathlib import Path
import re


dockerfile = Path("Dockerfile").read_text(encoding="utf-8")
gpu_stage_match = re.search(
    r"(?m)^FROM\s+nvidia/cuda:\S+\s+AS\s+runtime-gpu\s*$",
    dockerfile,
)
if gpu_stage_match is None:
    raise SystemExit("GPU runtime stage not found")
if "FROM runtime-gpu AS runtime-jre25-gpu" not in dockerfile:
    raise SystemExit("backward-compatible GPU target alias not found")

gpu_stage = dockerfile[gpu_stage_match.end():]

required = (
    "ARG AWS_CLI_VERSION=2.23.6",
    'awscli-exe-linux-${aws_arch}-${AWS_CLI_VERSION}.zip',
    'aws-cli/${AWS_CLI_VERSION}',
)
for needle in required:
    if needle not in gpu_stage:
        raise SystemExit(f"GPU AWS CLI pin guard missing: {needle}")

if 'awscli-exe-linux-${aws_arch}.zip' in gpu_stage:
    raise SystemExit("GPU runtime must not download the unversioned latest AWS CLI installer")

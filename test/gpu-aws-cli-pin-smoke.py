#!/usr/bin/env python3
from pathlib import Path


dockerfile = Path("Dockerfile").read_text(encoding="utf-8")
marker = "FROM nvidia/cuda:13.3.1-runtime-ubuntu24.04 AS runtime-jre25-gpu"
if marker not in dockerfile:
    raise SystemExit("GPU runtime stage not found")

gpu_stage = dockerfile.split(marker, 1)[1]

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

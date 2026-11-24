#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m venv .build/pose-bootstrap
.build/pose-bootstrap/bin/pip -q install uv yt-dlp
.build/pose-bootstrap/bin/uv venv --python 3.12 --allow-existing .build/pose-env
.build/pose-bootstrap/bin/uv pip install --python .build/pose-env/bin/python 'ultralytics==8.3.221' 'coremltools==8.3.0' 'torch==2.7.0' 'numpy<2'
.build/pose-env/bin/python scripts/setup-pose-model.py

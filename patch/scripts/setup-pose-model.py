#!/usr/bin/env python3
"""Export the fixed YOLO11n COCO pose model for Patch's native Core ML node.
Run with .build/pose-env/bin/python after scripts/setup-pose.sh.
"""
import json
import pathlib
import shutil
import hashlib
import os
import coremltools as ct
from ultralytics import YOLO

root = pathlib.Path(__file__).resolve().parents[1]
work = root / '.build/pose-model'
work.mkdir(parents=True, exist_ok=True)
os.chdir(work)
model = YOLO('yolo11n-pose.pt')
package = model.export(format='coreml', imgsz=640, batch=1, nms=False, half=True, device='cpu')
compiled = pathlib.Path(ct.models.utils.compile_model(str(package)))
destination = pathlib.Path.home() / 'Library/Application Support/Patch/Models'
destination.mkdir(parents=True, exist_ok=True)
target = destination / 'yolo11n-pose.mlmodelc'
if target.exists():
    shutil.rmtree(target)
shutil.copytree(compiled, target)
metadata = {'model': 'yolo11n-pose', 'source': 'https://github.com/ultralytics/assets/releases/download/v8.3.0/yolo11n-pose.pt',
            'weights_sha256': hashlib.sha256(pathlib.Path('yolo11n-pose.pt').read_bytes()).hexdigest(),
            'ultralytics': '8.3.221', 'coremltools': ct.__version__, 'input': [1, 3, 640, 640],
            'output': 'raw COCO 17 keypoints; [1,56,8400]; NMS in Patch', 'license': 'AGPL-3.0; Ultralytics enterprise terms also available'}
(destination / 'yolo11n-pose.json').write_text(json.dumps(metadata, indent=2) + '\n')
print(f'Installed {target}')

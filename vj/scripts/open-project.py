#!/usr/bin/env python3
"""Add a bundled VJ project (~/Projection3000/VJ/Projects) to the show library and open VJ on it."""
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('project', nargs='?', default='nov-14th')
parser.add_argument('--prepare-only', action='store_true')
args = parser.parse_args()
VJ = Path(__file__).resolve().parents[1]
projects = Path.home() / 'Projection3000/VJ/Projects'
project = (projects / args.project).resolve()
manifest = json.loads((project / 'manifest.json').read_text())
for entry in manifest:
    path = project / entry['path']
    if hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
        raise SystemExit(f'Project file differs from its snapshot: {path}')

def resolve(value):
    if isinstance(value, dict):
        return {k: resolve(v) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v) for v in value]
    if isinstance(value, str) and value.startswith('__PROJECT_DIR__/'):
        path = project / value.removeprefix('__PROJECT_DIR__/')
        if not path.is_file():
            raise SystemExit(f'Missing project asset: {path}')
        return str(path)
    return value

runtime = projects / '.local' / project.name
for name in ('native-state.json', 'Patch/session.json'):
    destination = runtime / name
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(resolve(json.loads((project / name).read_text())), indent=2) + '\n')
sys.path.insert(0, str(VJ / 'scripts'))
from import_show import LIBRARY, import_show
show = LIBRARY / project.name.replace('-', ' ').capitalize()
if not show.exists():
    import_show(runtime, show.name)
print(f'VJ show: {show}', flush=True)
if args.prepare_only:
    raise SystemExit(0)
app = VJ / 'native-app/build/mac/VJ.app'
if not app.is_dir():
    raise SystemExit('Build first: cd vj && cmake --preset mac -S native-app && cmake --build native-app/build/mac --target VJNative -j2')
subprocess.run(['open', '-n', str(app), '--args', '--state-root', str(show)], check=True)

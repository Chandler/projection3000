#!/usr/bin/env python3
"""Copy a VJ state folder into the show library (~/Projection3000/VJ/Shows).

Files the show references outside this checkout (for example Patch user nodes in
Application Support) are copied into the show's collected/ folder and repointed,
so the show opens on another laptop. Quit any VJ using the source folder first.
"""
import argparse
import glob
import hashlib
import json
import os
import shutil
from pathlib import Path

VJ = Path(__file__).resolve().parents[1]
REPO = VJ.parent
LIBRARY = Path(os.environ.get('VJ_SHOWS_DIRECTORY') or Path.home() / 'Projection3000/VJ/Shows')
RUNTIME = {'native.lock', 'native-state.json.bak', 'ndi-clients.json', 'thumbnail-cache',
           'media-cache', 'media-processing', 'text-cache'}


def collect(value, source, show, collected):
    if isinstance(value, dict):
        return {k: collect(v, source, show, collected) for k, v in value.items()}
    if isinstance(value, list):
        return [collect(v, source, show, collected) for v in value]
    if not (isinstance(value, str) and value.startswith('/') and '\n' not in value):
        return value
    path = Path(value)
    if path.is_relative_to(source):
        return str(show / path.relative_to(source))
    if not path.is_file() or path.is_relative_to(REPO):
        return value
    if path not in collected:
        # Same-name siblings travel together: shader nodes pair effect.metal with effect.json.
        folder = show / 'collected' / hashlib.sha256(str(path.parent).encode()).hexdigest()[:10]
        folder.mkdir(parents=True, exist_ok=True)
        for sibling in path.parent.glob(glob.escape(path.stem) + '.*'):
            if sibling.is_file():
                shutil.copy2(sibling, folder / sibling.name)
        collected[path] = folder / path.name
    return str(collected[path])


def import_show(source, name):
    source, show = Path(source).expanduser().resolve(), LIBRARY / name
    if not (source / 'native-state.json').is_file():
        raise SystemExit(f'Not a VJ state folder: {source}')
    if show.exists():
        raise SystemExit(f'Show already exists: {show}')
    shutil.copytree(source, show, ignore=lambda folder, names: [n for n in names if Path(folder) == source and n in RUNTIME])
    collected = {}
    for name_ in ('native-state.json', 'Patch/session.json'):
        path = show / name_
        if path.is_file():
            document = json.loads(path.read_text())
            path.write_text(json.dumps(collect(document, source, show, collected), indent=2, ensure_ascii=False) + '\n')
    for original, copy in collected.items():
        print(f'Collected {original} -> {copy.relative_to(show)}')
    print(f'Show ready: {show}')
    return show


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', help='VJ state folder to copy')
    parser.add_argument('name', help='show name, e.g. "Nov 14th"')
    args = parser.parse_args()
    import_show(args.source, args.name)

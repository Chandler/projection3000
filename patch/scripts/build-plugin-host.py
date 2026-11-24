#!/usr/bin/env python3
"""Build the pinned JUCE VST3 bridge. Downloads/build artifacts stay in .build."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

root = Path(__file__).resolve().parents[1]
version = '8.0.16-security'
sha256 = '7aec24b712e855fe696bcc98b222cd557c80f6716e11eeeefe690d1e9d67d255'
cache = root / '.build/plugin-sdk'
source = cache / ('JUCE-' + version)
cache.mkdir(parents=True, exist_ok=True)
if not source.exists():
    archive = cache / 'juce.tar.gz'
    urllib.request.urlretrieve('https://github.com/juce-framework/JUCE/archive/refs/tags/' + version + '.tar.gz', archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != sha256:
        raise SystemExit('JUCE archive checksum mismatch')
    with tarfile.open(archive) as package:
        for member in package.getmembers():
            target = (cache / member.name).resolve()
            if not target.is_relative_to(cache.resolve()):
                raise SystemExit('Unsafe archive path')
        package.extractall(cache)
cmake = shutil.which('cmake')
if not cmake:
    environment = root / '.build/plugin-tools'
    cmake = str(environment / 'bin/cmake')
    if not Path(cmake).exists():
        subprocess.run([sys.executable, '-m', 'venv', str(environment)], check=True, stdout=sys.stderr)
        subprocess.run([str(environment / 'bin/pip'), 'install', 'cmake==4.4.4'], check=True, stdout=sys.stderr)
build = root / '.build/plugin-host'
subprocess.run([cmake, '-S', str(root / 'Native/AudioPluginHost'), '-B', str(build),
                '-DJUCE_SOURCE=' + str(source), '-DCMAKE_BUILD_TYPE=Release'], check=True, stdout=sys.stderr)
subprocess.run([cmake, '--build', str(build), '-j', str(min(4, os.cpu_count() or 2))], check=True, stdout=sys.stderr)
print(build / 'libPatchAudioPluginHost.dylib')

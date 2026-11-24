#!/usr/bin/env python3
"""Inspect/package a local native build. Never changes build inputs or deploys."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = ('/System/Library/', '/usr/lib/')
PINS = {
    'Ableton Link': '902aef95bf94af49746fdda5369b42cdcfa1e6d2',
    'Asio': '231cb29bab30f82712fcd54faaea42424cc6e710',
}


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True, stderr=subprocess.PIPE).strip()


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def inside(path, root):
    return path.is_relative_to(root)


def macho(path):
    if not path.is_file():
        return False
    with path.open('rb') as stream:
        return stream.read(4) in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')


def loads(path):
    text = run('otool', '-arch', platform.machine(), '-l', path)
    rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', text)
    ids = re.findall(r'cmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.*?) \(offset', text)
    dependencies = []
    for line in run('otool', '-arch', platform.machine(), '-L', path).splitlines()[1:]:
        value = line.strip().split(' (compatibility version', 1)[0]
        if value and value not in ids:
            dependencies.append(value)
    return dependencies, rpaths, bool(ids)


def framework_root(path):
    for parent in [path, *path.parents]:
        if parent.suffix == '.framework':
            return parent
    return None


def license_files(path):
    result = []
    sibling = path.with_name(path.stem + '_licenses.txt')
    if sibling.is_file():
        result.append(sibling)
    for parent in list(path.parents)[:6]:
        if parent in (Path('/'), Path('/opt'), Path('/opt/homebrew'), Path('/Users')):
            break
        if not parent.is_dir():
            continue
        result.extend(file for file in parent.iterdir() if file.is_file() and
                      re.match(r'^(licen[sc]e|copying|notice|copyright)([._-].*)?$', file.name, re.I))
        if result:
            break
    return sorted(set(result))


class Graph:
    def __init__(self, app):
        self.app = app.resolve()
        self.files = {}
        self.destinations = {}
        self.frameworks = {}
        self.edges = []
        self.system = set()
        self.missing = []
        self.queue = []

    def add(self, path, target=None, executable=None, inherited=()):
        path = path.resolve(strict=True)
        if path in self.files:
            return self.files[path]
        frame = framework_root(path)
        if target is None:
            if inside(path, self.app):
                target = path.relative_to(self.app)
            elif frame:
                target = Path('Contents/Frameworks') / frame.name / path.relative_to(frame)
                self.frameworks[frame] = Path('Contents/Frameworks') / frame.name
            else:
                target = Path('Contents/Frameworks') / path.name
        target = Path(target)
        if target in self.destinations and self.destinations[target] != path:
            raise RuntimeError(f'Conflicting dependency names: {path} and {self.destinations[target]} -> {target}')
        self.destinations[target] = path
        self.files[path] = target
        self.queue.append((path, executable or path, tuple(inherited)))
        return target

    def resolve(self, value, loader, executable, rpaths):
        def expand(item):
            return item.replace('@loader_path', str(loader.parent)).replace('@executable_path', str(executable.parent))
        if value.startswith('@rpath/'):
            options = [Path(expand(base)) / value[7:] for base in rpaths if not base.startswith('@rpath')]
        else:
            options = [Path(expand(value))]
        for path in options:
            if path.is_file():
                return path.resolve()
        self.missing.append({'loader': str(loader), 'dependency': value, 'searched': [str(p) for p in options]})
        return None

    def scan(self):
        cursor = 0
        while cursor < len(self.queue):
            path, executable, inherited = self.queue[cursor]
            cursor += 1
            dependencies, own_rpaths, _ = loads(path)
            # Parent @loader_path rpaths are relative to the parent, not this dylib.
            own_rpaths = tuple(value.replace('@loader_path', str(path.parent)).replace('@executable_path', str(executable.parent)) for value in own_rpaths)
            rpaths = own_rpaths + inherited
            for dep in dependencies:
                if dep.startswith(SYSTEM):
                    self.system.add(dep)
                    continue
                source = self.resolve(dep, path, executable, rpaths)
                if source:
                    target = self.add(source, executable=executable, inherited=rpaths)
                    self.edges.append({'loader': str(self.files[path]), 'original': dep, 'target': str(target)})


def cache_values(build):
    values = {}
    path = build / 'CMakeCache.txt'
    if path.exists():
        for line in path.read_text().splitlines():
            if re.match(r'^[^/#][^=]*:[^=]+=', line):
                key, value = line.split('=', 1)
                values[key.split(':', 1)[0]] = value
    return values


def notices(graph, build):
    files = set()
    for source in graph.files:
        files.update(license_files(source))
    values = cache_values(build)
    link = Path(values.get('VJ_LINK_SDK') or build / '_deps/vj_ableton_link-src')
    for directory in (link, link / 'modules/asio-standalone', build / '_deps/vj_link_asio-src', ROOT.parent / 'static/fonts'):
        if directory.is_dir():
            files.update(file for file in directory.rglob('*') if file.is_file() and (re.match(r'^(licen[sc]e|copying|notice|copyright|ofl)([._-].*)?$', file.name, re.I) or file.name.lower().endswith('-ofl.txt')))
    syphon = build / 'Syphon-LICENSE.txt'
    if syphon.exists():
        files.add(syphon)
    return sorted(files)


def package(graph, manifest, args):
    output = args.output.resolve()
    allowed = (ROOT / 'build/package').resolve()
    if not inside(output, allowed) or output == allowed or output.suffix != '.app':
        raise RuntimeError('Package destination must be an .app inside native-app/build/package')
    if output.exists() and not args.replace:
        raise RuntimeError('Package exists; use --replace to replace this development artifact')
    if graph.missing:
        raise RuntimeError('Cannot package unresolved dependencies; inspect manifest')
    if manifest['copyBytes'] > args.max_mib * 1024 * 1024:
        raise RuntimeError(f"Copy size {manifest['copyBytes'] / 1024**2:.1f} MiB exceeds --max-mib {args.max_mib}; inspect manifest before raising the bound")
    staging = output.with_name(output.stem + '.staging.app')
    if staging.exists():
        shutil.rmtree(staging)
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.copytree(graph.app, staging, symlinks=True)
        for source, target in graph.frameworks.items():
            shutil.copytree(source, staging / target, symlinks=True, dirs_exist_ok=True)
        for source, target in graph.files.items():
            destination = staging / target
            destination.parent.mkdir(parents=True, exist_ok=True)
            if not inside(source, graph.app) and not any(inside(source, frame) for frame in graph.frameworks):
                shutil.copy2(source, destination)
            destination.chmod(destination.stat().st_mode | 0o200)
        for source, relative in graph.files.items():
            destination = staging / relative
            _, rpaths, dylib = loads(source)
            command = ['install_name_tool']
            if dylib:
                command += ['-id', '@rpath/' + relative.name]
            for edge in graph.edges:
                if edge['loader'] == str(relative):
                    replacement = '@loader_path/' + os.path.relpath(staging / edge['target'], destination.parent)
                    command += ['-change', edge['original'], replacement]
            for path in dict.fromkeys(rpaths):
                command += ['-delete_rpath', path]
            if len(command) > 1:
                run(*command, destination)
        licenses = staging / 'Contents/Resources/Licenses'
        licenses.mkdir(parents=True, exist_ok=True)
        for record in manifest['notices']:
            shutil.copy2(record['source'], licenses / record['bundledName'])
        (licenses / 'DEPENDENCIES.json').write_text(json.dumps(manifest, indent=2) + '\n')
        for source, relative in graph.files.items():
            path = staging / relative
            dependencies, rpaths, _ = loads(path)
            if rpaths or any(not dep.startswith(SYSTEM + ('@loader_path/',)) for dep in dependencies):
                raise RuntimeError(f'Nonrelocatable packaged dependency: {path}')
            for dep in dependencies:
                if dep.startswith('@loader_path/') and not (path.parent / dep[13:]).exists():
                    raise RuntimeError(f'Broken packaged dependency: {path}: {dep}')
            run('codesign', '--force', '--sign', '-', '--timestamp=none', path)
        for target in graph.frameworks.values():
            run('codesign', '--force', '--sign', '-', '--timestamp=none', staging / target)
        run('codesign', '--force', '--sign', '-', '--timestamp=none', staging)
        run('codesign', '--verify', '--deep', '--strict', staging)
        if output.exists():
            shutil.rmtree(output)
        staging.rename(output)
    except BaseException:
        if staging.exists():
            shutil.rmtree(staging)
        raise
    print(f'Packaged {output}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / 'build/mac/VJ.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/package/VJ.app')
    parser.add_argument('--manifest', type=Path, default=ROOT / 'build/package/dependencies.json')
    parser.add_argument('--ffmpeg', type=Path, default=Path(shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'))
    parser.add_argument('--ffprobe', type=Path, default=Path(shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'))
    parser.add_argument('--sdl3', type=Path, help='SDL3 runtime required by SDL2 compatibility builds')
    parser.add_argument('--libusb', type=Path)
    parser.add_argument('--ndi', type=Path)
    parser.add_argument('--syphon-framework', type=Path)
    parser.add_argument('--notice', type=Path, action='append', default=[])
    parser.add_argument('--package', action='store_true', help='Copy/rewrite/sign after inspecting the dry-run manifest')
    parser.add_argument('--replace', action='store_true')
    parser.add_argument('--max-mib', type=float, default=256, help='Bound copied app/dependency bytes')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Packaging requires macOS otool/install_name_tool/codesign')
    app = args.app.resolve(strict=True)
    if app.suffix != '.app':
        parser.error('--app must be a built .app')
    build = app.parent
    graph = Graph(app)
    for file in sorted(app.rglob('*')):
        if not file.is_symlink() and macho(file):
            graph.add(file)
    for tool in (args.ffmpeg, args.ffprobe):
        graph.add(tool, Path('Contents/Helpers') / tool.name)
    for tool, name in ((args.libusb, "libusb-1.0.0.dylib"), (args.ndi, "libndi.dylib")):
        if tool:
            graph.add(tool, Path("Contents/Frameworks") / name)
    if args.syphon_framework:
        framework = args.syphon_framework.resolve(strict=True)
        if framework.suffix != '.framework':
            parser.error('--syphon-framework requires a framework directory')
        for file in framework.rglob('*'):
            if not file.is_symlink() and macho(file):
                graph.add(file)
    graph.scan()
    sdl_compat = any('SDL2' in source.name and b'@loader_path/libSDL3.dylib' in source.read_bytes() for source in graph.files)
    if sdl_compat:
        choices = [args.sdl3] if args.sdl3 else [Path('/opt/homebrew/opt/sdl3/lib/libSDL3.dylib'), Path('/usr/local/opt/sdl3/lib/libSDL3.dylib')]
        sdl3 = next((file for file in choices if file and file.is_file()), None)
        if not sdl3:
            raise RuntimeError('SDL2 compatibility uses a dynamically loaded SDL3 runtime; supply --sdl3')
        graph.add(sdl3, Path('Contents/Frameworks/libSDL3.dylib'))
        # Scan only newly added nodes; edges are idempotently deduplicated below.
        graph.scan()
        graph.edges = list({(e['loader'], e['original'], e['target']): e for e in graph.edges}.values())
    extra = sorted(set(notices(graph, build) + [p.resolve(strict=True) for p in args.notice]))
    records = [{'source': str(path), 'bundledName': f'{index:03d}-{path.parent.name}-{path.name}', 'sha256': digest(path)} for index, path in enumerate(extra)]
    app_bytes = sum(path.stat().st_size for path in app.rglob('*') if path.is_file() and not path.is_symlink())
    external = sum(path.stat().st_size for path in graph.files if not inside(path, app) and not any(inside(path, frame) for frame in graph.frameworks))
    framework_bytes = sum(path.stat().st_size for frame in graph.frameworks for path in frame.rglob('*') if path.is_file() and not path.is_symlink())
    manifest = {
        'format': 'vj-native-mac-package/1', 'developmentOnly': True, 'signed': 'ad-hoc when packaged',
        'architecture': platform.machine(), 'app': str(app), 'output': str(args.output.resolve()), 'copyBytes': app_bytes + external + framework_bytes,
        'pinnedSDKCommits': PINS, 'buildLinkEnabled': cache_values(build).get('VJ_ENABLE_LINK') == 'ON',
        'files': [{'source': str(source), 'target': str(target), 'bytes': source.stat().st_size, 'sha256': digest(source), 'licenses': [str(p) for p in license_files(source)]} for source, target in graph.files.items()],
        'dependencies': graph.edges, 'systemDependencies': sorted(graph.system), 'unresolved': graph.missing,
        'notices': records,
        'sdl2CompatibilityRuntimeBundled': sdl_compat,
        'optionalRuntimePaths': {'libusb': str(args.libusb) if args.libusb else None, 'ndi': str(args.ndi) if args.ndi else None, 'syphonFramework': str(args.syphon_framework) if args.syphon_framework else None},
        'distributionStatus': 'Local development artifact. Bundled dependency notices are inventory, not a redistribution/notarization approval.',
    }
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'manifest': str(args.manifest), 'machoFiles': len(graph.files), 'copyMiB': round(manifest['copyBytes'] / 1024**2, 1), 'noticeFiles': len(records), 'unresolved': graph.missing}, indent=2))
    if args.package:
        package(graph, manifest, args)
    elif graph.missing:
        return 1
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f'Packaging failed: {error}', file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        raise SystemExit(1)

#!/usr/bin/env python3
"""Build pinned upstream Syphon with CLT; load its Metal source at runtime."""
import pathlib, subprocess, plistlib, shutil, json
root = pathlib.Path(__file__).resolve().parents[1]
cache = root / '.build/dependencies'
source = cache / 'Syphon-Framework'
commit = 'f4761677a45b8034a3c2069ec0f3d2553da81fba'
if not source.exists():
    subprocess.run(['git','clone','https://github.com/Syphon/Syphon-Framework.git',str(source)],check=True)
subprocess.run(['git','-C',str(source),'checkout','--detach',commit],check=True,stdout=subprocess.DEVNULL)
framework = cache / 'metal/Syphon.framework'
version = framework / 'Versions/A'
resources = version / 'Resources'
marker = resources / 'patch-build-version'
if marker.exists() and marker.read_text() == commit + '-1':
    print(framework); raise SystemExit(0)
resources.mkdir(parents=True,exist_ok=True)
headers = version / 'Headers'; headers.mkdir(exist_ok=True)
for header in source.glob('*.h'): shutil.copy2(header, headers / header.name)
# Runtime Metal compilation avoids requiring the full Xcode Metal compiler.
shader = (source/'SyphonMetalShaders.metal').read_text().replace('#include "SyphonServerMetalTypes.h"',(source/'SyphonServerMetalTypes.h').read_text())
(resources/'SyphonMetalShaders.metal').write_text(shader)
renderer = (source/'SyphonServerRendererMetal.m').read_text().replace('[device newDefaultLibraryWithBundle:bundle error:&error]', '[device newLibraryWithSource:[NSString stringWithContentsOfURL:[bundle URLForResource:@"SyphonMetalShaders" withExtension:@"metal"] encoding:NSUTF8StringEncoding error:&error] options:nil error:&error]')
patched = cache / 'metal/SyphonServerRendererMetal.m'; patched.write_text(renderer)
includes = cache / 'metal/include'
includes.mkdir(exist_ok=True)
if not (includes/'Syphon').is_symlink(): (includes/'Syphon').symlink_to(source)
files = [str(p) for p in source.glob('*.m') if p.name != patched.name] + [str(patched)] + [str(p) for p in source.glob('*.c')]
subprocess.run(['clang','-dynamiclib','-fobjc-arc','-fmodules','-O2','-mmacosx-version-min=14.0','-DSYPHON_CORE_SHARE','-DGL_SILENCE_DEPRECATION','-Wno-deprecated-declarations','-Wno-objc-missing-super-calls','-include',str(source/'Syphon_Prefix.pch'),'-I',str(source),'-I',str(includes),*files,'-framework','Cocoa','-framework','Metal','-framework','IOSurface','-framework','OpenGL','-framework','CoreVideo','-install_name','@rpath/Syphon.framework/Versions/A/Syphon','-o',str(version/'Syphon')],check=True)
with (resources/'Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleExecutable':'Syphon','CFBundleIdentifier':'info.v002.Syphon','CFBundleName':'Syphon','CFBundlePackageType':'FMWK','CFBundleVersion':'6','CFBundleShortVersionString':'6'},f)
shutil.copy2(source/'License.txt',resources/'License.txt')
for link,target in [(framework/'Versions/Current','A'),(framework/'Syphon','Versions/Current/Syphon'),(framework/'Resources','Versions/Current/Resources'),(framework/'Headers','Versions/Current/Headers')]:
    if not link.is_symlink(): link.symlink_to(target)
marker.write_text(commit+'-1')
print(framework)

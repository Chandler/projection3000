#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
# The Command Line Tools' default macOS 27 SDK lacks SwiftUI's macro plugins; build with the 26 SDK.
if [ -z "${SDKROOT:-}" ]; then SDKROOT="$(xcrun --sdk macosx26.5 --show-sdk-path 2>/dev/null || xcrun --sdk macosx26.4 --show-sdk-path 2>/dev/null || true)"; export SDKROOT; fi
swift build -c "$configuration"
bin="$(swift build -c "$configuration" --show-bin-path)"
framework="$(python3 scripts/build-syphon.py)"
plugin_host="$(python3 scripts/build-plugin-host.py)"
app="$PWD/build/.Patch-stage.app"
if [ -d "$app" ]; then rm -rf "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/Patch" "$app/Contents/MacOS/Patch"
cp "$plugin_host" "$app/Contents/Frameworks/"
cp .build/plugin-sdk/JUCE-8.0.16-security/LICENSE.md "$app/Contents/Resources/JUCE-LICENSE.md"
codesign --force --sign - "$app/Contents/Frameworks/libPatchAudioPluginHost.dylib"
cp Sources/PatchKit/Resources/Shaders.metal "$app/Contents/Resources/"
# Include the repo library without writing into the user's external library.
if [ -d "User Nodes" ]; then
  ditto "User Nodes" "$app/Contents/Resources/User Nodes"
fi
ditto ../vj/static/fonts "$app/Contents/Resources/fonts"
ditto Subpatches "$app/Contents/Resources/Subpatches"
cp Info.plist "$app/Contents/Info.plist"
if [ ! -f .build/Patch.icns ] || [ scripts/make-icon.swift -nt .build/Patch.icns ]; then
  swift scripts/make-icon.swift .build/Patch.iconset
  iconutil -c icns .build/Patch.iconset -o .build/Patch.icns
fi
cp .build/Patch.icns "$app/Contents/Resources/Patch.icns"
if [ -d "$app/Contents/Frameworks/Syphon.framework" ]; then
  rm -rf "$app/Contents/Frameworks/Syphon.framework"
fi
ditto "$framework" "$app/Contents/Frameworks/Syphon.framework"
codesign --force --sign - "$app/Contents/Frameworks/Syphon.framework"
codesign --force --sign - "$app"
# Stage/sign a separate bundle so a running executable is never overwritten.
previous="$PWD/build/.Patch-previous"
if [ -d "$previous" ]; then rm -rf "$previous"; fi
if [ -d "$PWD/build/Patch.app" ]; then mv "$PWD/build/Patch.app" "$previous"; fi
mv "$app" "$PWD/build/Patch.app"
printf '%s\n' "$PWD/build/Patch.app"

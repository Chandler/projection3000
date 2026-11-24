#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run PatchCoreChecks
# The Command Line Tools' default macOS 27 SDK lacks SwiftUI's macro plugins; build with the 26 SDK.
if [ -z "${SDKROOT:-}" ]; then SDKROOT="$(xcrun --sdk macosx26.5 --show-sdk-path 2>/dev/null || xcrun --sdk macosx26.4 --show-sdk-path 2>/dev/null || true)"; export SDKROOT; fi
swift build
framework="$(python3 scripts/build-syphon.py)"
bin="$(swift build --show-bin-path)"
export PATCH_API_PORT="${PATCH_API_PORT:-9418}"
export PATCH_SYPHON_FRAMEWORK="$framework"
if lsof -nP -iTCP:"$PATCH_API_PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "Refusing to test against an occupied port: $PATCH_API_PORT" >&2
  exit 1
fi
"$bin/Patch" --headless > .build/check-app.log 2>&1 &
check_pid=$!
trap 'kill "$check_pid" 2>/dev/null || true' EXIT
for attempt in {1..60}; do
  if curl -fsS "http://127.0.0.1:$PATCH_API_PORT/health" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
python3 -u scripts/test-api.py
python3 -u scripts/test-sources.py
python3 -u scripts/test-recording.py
python3 -u scripts/test-editor.py
python3 -u scripts/test-effects.py
python3 -u scripts/test-faces.py
clang -fobjc-arc -Wno-deprecated-declarations Tests/Outputs/SyphonProbe.m -F "$(dirname "$framework")" -framework Syphon -framework Cocoa -framework Metal -Wl,-rpath,"$(dirname "$framework")" -o .build/SyphonProbe
.build/SyphonProbe
python3 scripts/test-ndi.py

kill "$check_pid"
wait "$check_pid" 2>/dev/null || true
trap - EXIT
"$bin/Patch" --headless --verify-render-thread

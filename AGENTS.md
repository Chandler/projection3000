# Agent guide

## Layout
- `patch/`: Swift/Metal patcher (SwiftPM). `vj/`: C++/AppKit/OpenGL VJ app (CMake). VJ embeds Patch from `../../patch`.
- User data (projects, shows, media, textures) lives in `~/Projection3000`, never in the repo. Custom shader nodes ship from `patch/User Nodes/`.

## Code
- Keep VJ's state, commands, API, persistence and rendering in portable C++; AppKit only in the Mac UI.
- Every new performance control must also be reachable through the app's HTTP API. Remove obsolete API concepts when replacing them; make unimplemented APIs fail explicitly.
- Never silently drop unsupported state or overwrite a user's show or mapping data.
- UI text: names, action labels, values and status only. No explanatory banners or instructional sentences.

## Patch controls
- Numeric parameters take MIDI eligibility and range from `ParameterSpec`. Use `midi:false` for non-performance values and `step` for discrete values; use `.midiParameter(workspace:id:key:)` on custom numeric rows. MIDI bindings live in `Graph.midiMappings`.
- Pick controls by value type (see `patch/docs/parameter-controls.txt`): sliders for continuous values, steppers or choices for discrete ones, a neutral center marker with detent and reset for signed values. Always keep exact numeric entry.
- Pan/balance fills from center and reads Center / L% / R%, never negative numbers.
- Nodes with their own window are node apps: register in `NodeApp.for(_:)`, build from `NodeAppLayout`/`NodeAppSection`/`NodeAppParameter`, and expose editing operations through `NodeAppAPI` (`/v1/apps/{nodeID}`) via `GraphDocument`.

## Testing
- Keep tests small and targeted at state integrity, contracts, geometry and regressions.

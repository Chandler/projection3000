# Control API

All routes except `/health` require `Authorization: Bearer <local token>`. The supplied `scripts/patchctl.py` client reads the token automatically. The listener binds to loopback and closes each HTTP connection after one response. Requests are capped at 2 MiB, headers at 16 KiB, with an 8-second deadline. `Content-Length` bodies are supported; chunked request bodies are not.

Read node definitions from `GET /v1/schema`. Node IDs are UUID strings. Port IDs are case-sensitive strings.

## Ports, parameters and detached editing

`GET /v1/catalog` returns installed node definitions. Sockets declare an `id`, display `name`, signal `type`, and display order. `GET /v1/nodes/{uuid}/ports` returns an instance’s available sockets, connections, and latest observations keyed by output ID. For a subpatch, it returns the published interface.

Use `inputID` and `outputID` in graph commands. Omitting a socket selects the first available port for that direction. `connect`, `disconnect`, `modulate`, and `publish` reject numeric port selectors. In version 2 project JSON, each cable stores its own UUID, the `source` and `target` node UUIDs, and both socket IDs. Control bindings store the source socket’s `outputID`. Patch requires version 2 when opening or replacing a graph.

`POST /v1/connections/options` accepts `{"node":"NODE_UUID","direction":"output","portID":"Field"}`. It lists compatible catalog entries, socket IDs, and parameter keys using the canvas picker’s compatibility rules. Use direction `input` to find producers. The catalog also reports library loading issues.

Parameters declare `valueKind`, range, initial value, MIDI eligibility, and applicable choices, increment and unit. A `parameter` command accepts a number or the exact label of a declared choice. Connected controls and MIDI use the parameter’s declared increment.

To build a separate tree, send one ordinary graph transaction with fresh node IDs and connections among those nodes. A cable to an occupied input replaces its existing cable. Leave that final connection out until the tree is ready. Device and publication nodes have their own activation semantics. Sources that need no physical output can feed Render Field, the canvas preview, or a snapshot. A first snapshot of a newly compiled shader can report “No rendered frame” while Metal prepares it. Retry after compilation.

```json
{"op":"connect","source":"FIELD_UUID","outputID":"Field","target":"MIX_UUID","inputID":"A"}
{"op":"modulate","source":"LFO_UUID","outputID":"Control","target":"MIX_UUID","key":"mix"}
{"op":"connect","source":"MIX_UUID","outputID":"Field","target":"RENDER_UUID","inputID":"Field"}
```

## Source discovery and placement

`GET /v1/sources` lists discovered cameras, NDI and Syphon sources alongside published Patch outputs. Each item includes its stable `id`, display `name`, `type`, `group` and `available` flag. For an item with `action: "source_add"`, send its ID with a graph command:

```json
{"op":"source_add","sourceID":"ndi:STUDIO (Camera A)","x":120,"y":160}
```

The command returns the new node UUID and accepts an optional caller-supplied `id` for graph transactions. It places a disconnected node bound to the selected device or stream. Published sockets within the current graph have `action: "select"` and a `nodeID`. Published video from the other local Patch application can be received over Syphon when its stream is available. Other remote outputs retain their declared types and have no placement action.

## Fields

A Field is RGB sampled in normalized XY coordinates. Field Mix accepts two fields and a mix parameter. Its floating-point RGB surface retains values above one at the project resolution. Render Field produces a video frame at the project canvas dimensions. LED Matrix samples fields on its display grid. Cellular Automata exposes `gridColumns` and `gridRows`. At zero, automatic sizing uses the first directly connected LED Matrix in document order or a 320-column canvas-aspect grid. Each consumer samples the same simulation.

Install a custom field through `POST /v1/effects` with `kind: "fieldShader"`, a name, Metal source, and an optional ordered `parameters` array. Each declaration has a unique `key`, `title`, `min`, `max`, and `initial`; optional fields include `choices`, `step`, `midi`, and `unit`. The node instance saves its declaration. A standalone `add` command can supply `kind: "fieldShader"`, `file`, and `fieldParameters` directly. With a `catalogID`, Patch takes the declaration from that catalog entry.

Shader Effects may declare the same ordered numeric controls with `kind: "shaderEffect"`. Define `PATCH_EFFECT_RGBA(uv,time,input,controls)` to return an RGBA pixel. The input is a sampled 2D Metal texture. The first fifteen scalar lanes of the four `float4` controls follow declaration order, and the final lane holds shader time in seconds. An optional `scalesFieldTime:true` parameter scales that clock. Implement blending in the RGBA function if the effect exposes a mix control. A custom declaration and a built-in control style are mutually exclusive.

The Metal entry point is `float3 animation(float2 uv, float time, float4 a, float4 b, float4 c, float4 d)`. Up to fifteen declared values occupy the four vectors in order, starting at `a.x`. The final lane `d.w` carries the field time in seconds. By default this is transport time. A single parameter can declare `scalesFieldTime: true` to multiply transport time before delivery to both `time` and `d.w`.

## Graph commands

```json
{"op":"add","kind":"crt","name":"Monitor","x":350,"y":160,"parameters":{"scanlines":0.5}}
```

Returns `{"id":"..."}`. Optional fields: `id` (caller-supplied UUID for transactions), `name`, `x`, `y`, `file`, `text`, `deviceID`, `parameters`.

```json
{"op":"connect","source":"SOURCE_UUID","outputID":"Video","target":"TARGET_UUID","inputID":"Video"}
{"op":"disconnect","target":"TARGET_UUID","inputID":"Video"}
{"op":"publish","id":"AB_UUID","outputID":"Collection","mode":"on"}
{"op":"parameter","id":"NODE_UUID","key":"scanlines","value":0.4}
{"op":"update","id":"NODE_UUID","name":"Screen","enabled":true,"x":600,"y":160}
{"op":"update","id":"NODE_UUID","file":"/absolute/movie.mp4"}
{"op":"remove","id":"NODE_UUID"}
{"op":"replace","graph":{"version":2,"width":1280,"height":720,"fps":60,"nodes":[],"edges":[]}}
```

`text` sets a Text node’s multiline content. `deviceID` selects a Camera by AVFoundation unique ID; null uses the default camera. These fields are accepted by add and update. `file: null` clears a media/shader/audio path. Removing a node removes its cables. Replacing an input connection is atomic. The graph rejects cycles, incompatible port types, duplicate UUIDs, dangling cables, duplicate input connections, unknown parameters, out-of-range values, noninteger choice values, invalid render settings, and more than 200 nodes.

Resolution bounds: 64–3840 wide, 64–2160 high. Frame rate: 1–120. Change patch settings through a complete validated graph replacement.

An array of graph commands is one atomic operation:

```json
[
  {"op":"add","kind":"lorenz","id":"00000000-0000-4000-8000-000000000001","x":80,"y":140},
  {"op":"add","kind":"render","id":"00000000-0000-4000-8000-000000000002","x":370,"y":140},
  {"op":"connect","source":"00000000-0000-4000-8000-000000000001","outputID":"Geometry","target":"00000000-0000-4000-8000-000000000002","inputID":"Geometry"}
]
```

Any invalid command rejects the whole array. Batches only accept graph commands; file/window/transport actions cannot appear in transactions.

## Transport, view and persistence

```json
{"op":"play"}
{"op":"pause"}
{"op":"select","id":"NODE_UUID"}
{"op":"view","id":"NODE_UUID"}
{"op":"backdrop","enabled":true,"id":"NODE_UUID"}
{"op":"save","path":"/absolute/project.patch.json"}
{"op":"open","path":"/absolute/project.patch.json","discardChanges":true}
{"op":"snapshot","id":"NODE_UUID","path":"/absolute/frame.png"}
```

`open` rejects unsaved current changes unless `discardChanges` is explicitly true. Save writes atomically. Snapshot writes a rendered PNG and waits for the GPU copy; it is an occasional diagnostic/export operation, not a streaming transport. The `view` command opens a viewer for any node.

## Preview and organization

```json
{"op":"preview","id":"NODE_OR_COMPONENT_UUID","enabled":true}
{"op":"component","nodes":["FIRST_UUID","SECOND_UUID"],"name":"Effects"}
{"op":"component_toggle","id":"COMPONENT_UUID"}
{"op":"ungroup","id":"COMPONENT_UUID"}
{"op":"layout"}
```

Component creation returns its ID. Graph JSON optionally contains `components` (id, name, member node IDs, position, collapsed). Internal nodes and edges remain in the main graph; exposed boundary slots connect their actual member IDs. Component containers cannot overlap or nest. `select` accepts component IDs as well as node IDs. `previewVisible` and `selectedNodes` are included in state. Each schema node declares `preview`: video, geometry, audio, or empty. The preview is independent of persistent output windows.

Video `start` and `end` parameters are seconds; end zero means file end. If nonzero, end must exceed start. Out-of-duration start points report an error asynchronously.

## Movie recording

```json
{"op":"record_start","id":"RECORD_NODE_UUID"}
{"op":"record_stop","id":"RECORD_NODE_UUID"}
{"op":"record_save","id":"RECORD_NODE_UUID","path":"/absolute/take.mov"}
```

Use a connected, enabled `record` node. Start creates a new H.264 MOV in Patch’s recovery recordings directory. Stop is asynchronous; poll `recordings[id].state` until `ready` before saving. `record_save` copies on a worker queue and leaves the recovery take intact. Existing destinations are rejected unless `replace:true` is supplied. API stop does not display a Save dialog. Fields are `state` (recording, finishing, ready, saved, failed), `path`, `frames`, `droppedFrames`, `seconds`, and `error`. Recorded movies contain video only. Changing resolution/frame rate or disabling/removing/disconnecting the node finishes the current take.

Image/video transform parameters are `rotation` (clockwise degrees), `flipX`, `flipY` (0 or 1), `scale`, `x`, `y`. Quarter turns refit without cropping; position offsets are normalized to half the output width/height. Query schema for bounds/defaults.

## State

`GET /v1/state` returns:

- `graph`: nodes, edges, resolution and target frame rate.
- `selection`, `playing`, `time`, `file`, `dirty`.
- `frames`, `droppedFrames`, `gpuMS`.
- `recordings`: per-recording-node capture/finalization state and recoverable movie paths.
- `viewers`: node/window identity, visibility, actual presented frame count, and last presentation timestamp. These counters measure display presentation separately from graph rendering.
- `status`: per-node loading/render/compile/output status keyed by UUID.
- `outputs`: availability of `window`, `syphon` and `ndi`.

Audio ports feed Waveform nodes; video and geometry ports retain their own types. Text, Camera, Audio File and Waveform definitions are included in `/v1/schema`.

The initial graph renders immediately. Wait for a node's status to become `Ready`, `Publishing`, or a vertex count before capturing it. Loading and compiling are asynchronous. An output's `Publishing` status confirms sender creation; use a receiving application to verify end-to-end delivery.

Errors return non-200 JSON containing `error`. Invalid commands use 400; missing/incorrect authentication 401; browser origins 403; timeouts 408; oversized requests 413. Success returns 200.

### Face coordinates

`faceDetect` takes video and produces a `faces` port. Its `rate` parameter is the maximum detection FPS (1–60, default 30). `faceBoxes` accepts video on `Video` and face detections on `Faces`, outputs video, and has `thickness` (1–12 pixels, default 3).

State includes `faceDetections[detectorUUID]` with `{sequence, timestamp, width, height, inferenceMS, faces}`. Each face has `{bounds: {x,y,width,height}, confidence, landmarks: {regionName: [{x,y}]}}`. Bounds and landmarks use full-canvas normalized coordinates with top-left origin, including all upstream transforms. `timestamp` is monotonic host seconds at frame submission, not wall time or transport time. Consumers reuse the latest asynchronously completed detection. Face array indices are not stable identities. An empty array means no faces; an absent detector key means disabled, disconnected, awaiting a result, failed, or stale. Consult node status for that distinction.

`faceReplace` outputs video with B's selected face composited onto A. Inputs: 0 Video A (`video`), 1 Video B (`video`), 2 Faces A (`faces`), 3 Faces B (`faces`). Parameters: `mix` 0–1 (default 1), `feather` 0.01–0.5 (default 0.18), `faceA` and `faceB` 0–31 (rounded to integer ranks, largest face first). It passes A through if any input or selected face is missing. Alignment uses eye and mouth landmarks with face-bounds fallback.

### Human poses

- `yoloPose`: `Video` input → `Poses` output. Parameters: `rate` (1–60, default 30), `confidence` (0.05–0.95, default 0.3), `iou` (0.1–0.9, default 0.45). Optional `file` points to a compatible compiled Core ML model; otherwise uses the model installed by `scripts/setup-pose.sh`.
- `poseRender`: `Poses` input → `Video` output. Parameters: `confidence` (0.05–0.95, default 0.3), `thickness` (1–16, default 4), `joints` (0/1), `color` (0 white / 1 colored limbs), `background` (0 black / 1 white). The default enables joint dots and colored limbs.
- `/v1/state.poseDetections[nodeID]`: `{sequence,timestamp,width,height,inferenceMS,poses:[{bounds:{x,y,width,height},confidence,keypoints:[{x,y,confidence}]}]}`. Coordinates use normalized top-left canvas space. Keypoint order is `/v1/schema.poseKeypoints` (COCO 17); identities/order are not tracked across frames. A successful no-person inference publishes an empty array; unavailable, disabled or stale analysis has no entry.
- Pose cables are type-checked. The detector's stick-figure preview is diagnostic, not a second video output. Use `poseRender` to turn the data into video.

Render Poses style controls now come from `PoseStyle.parameters`; `/v1/schema` is the authoritative list of 45 keys, bounds and defaults. The 36 continuous controls appear in `modulatableParameters` and accept the existing `modulate` command. Discrete palette/head/torso/joint/visibility choices use `parameter`. Time-based styling follows the transport. Style edits downstream of the detector retain live pose results.

Video `file` accepts MKV paths without conversion by the caller. Video and audio share a background FFmpeg preparation cache; `/v1/state.status` reports preparation or errors. The saved `file` remains the source MKV, not the cached MOV.

### Crop / Aspect

`crop`: `Video` input → `Video` output. `aspect`: 0 Input, 1 Free, 2 16:9, 3 9:16, 4 1:1, 5 4:3, 6 3:4, 7 4:5, 8 21:9, 9 Custom. Custom uses `ratioWidth`/`ratioHeight` (1–32). `zoom` is 1–8, `x`/`y` are 0–1 pan fractions (0.5 centered), `width`/`height` are 0.05–1 for Free. `fit`: 0 Fit, 1 Fill, 2 Stretch. `background`: 0 Black, 1 White. `flipX`/`flipY`: 0/1. `resolution`: 0 match input long edge, 1 720 short edge, 2 1080 short edge, 3 2160 short edge, 4 custom `outputWidth`/`outputHeight`. Output dimensions follow the selected crop aspect (or custom pixels), are even, and capped at 8192 per axis. Downstream effects inherit input A dimensions; recording uses incoming dimensions. Changing size finishes an active take.

`{"op":"record_discard","id":"…"}` discards a ready/failed unsaved take and clears its runtime state. It rejects recording, finishing and saved takes, and never removes an exported copy. Like `record_save`, it is a standalone command, not an atomic graph transaction.

`channelSplit` is a single-input video effect. `mode` is 0 RGB / 1 CMYK, `x0/y0` through `x3/y3` are pixel offsets (R/C, G/M, B/Y, K), and `amount`, `angle`, `radial`, `mix`, `edges` control the split. `edges`: 0 clamp, 1 wrap, 2 mirror, 3 neutral. Output stays RGB.

`color` (Color Adjust) is a single-input video effect: `brightness` −1–1, `contrast` 0–2, `saturation` 0–2, `exposure` −3–3 stops, `gamma` 0.1–4, `blackPoint`/`whitePoint` input levels and `outBlack`/`outWhite` output levels 0–1, `hue` −180–180°, `temperature` and `tint` −1–1, `invert` 0/1, `mix` 0–1.

`channelColors` is a single-input video effect that redraws the input's R, G and B channels as three colors. `color0`–`color2` are packed sRGB `0xRRGGBB` integers (defaults red, green, blue), `level0`–`level2` are 0–2, `channels` is 0 All / 1 Red / 2 Green / 3 Blue, `blend` is 0 Add / 1 Screen, and `mix` is 0–1.

`pictureInPicture` accepts video on inputs `A` and `B`. `width/height` are canvas fractions; `x/y` place the inset within the available space (0 left/top, 1 right/bottom). `fit`: 0 fit, 1 fill, 2 stretch. `opacity`, `radius` and `border` (pixels), and `shadow` set its finish. `lock` controls interactive proportional resizing.

### LED Matrix and Fields

`dataStream` emits the `field` port type. Its external Metal function has signature `float3 animation(float2 uv, float time, float4 a, float4 b, float4 c, float4 d)`; controls are documented in `User Nodes/Data Stream.metal`. `pattern`: 0 packets, 1 waves, 2 drifting mask, 3 staggered pulses. It does not allocate a video texture. `ledMatrix` accepts video on `Video` or a field on `Field`; a connected enabled field takes precedence and is evaluated directly at each cell center. Ordinary video can use center or five-point cell sampling. Fields use the project canvas dimensions unless a video input establishes another stream size. Query schema for matrix and driver parameters and modulation targets.

`ledMatrix` accepts a second field on `Light`. With a primary `Field` connected, the matrix evaluates that field in place of `Video`. A connected `Light` multiplies the result. Each field has an independent `speed` clock. `streakGlow` (title Glow) emits `field` with `function` (0 Streaks, 1 Gaussian noise, 2 Lava lamp, 3 Clouds, 4 Ripples, 5 Sweep, 6 Plasma, 7 Breathe), `speed`, `mode`, `invert`, `depth`, `scale`, `gain`, `detail`, `warp`, `contrast`, `angle` (degrees, 90 = up), `stretch`, `bias`, `pulse` and `seed`. Its function is built in, not an external file. Both field functions are namespaced and compiled into one matrix shader; no intermediate video textures are allocated.

`blockerField` emits `field` and can connect to the LED Matrix `Field` input. Its `rate` is widths per second, `segments` launches per second, `tail` stream duty, `density` launch probability, `variance` row-speed variation, `depth` blocking strength, `blockers` count, `motion` blocker movement, `height` height in rows, and `jitter`/`refresh` signal brightness jitter. `speed`, `rows` and `seed` set playback, row count and deterministic pattern. Obstruction states are sampled at retarded passage times, creating advected downstream gaps rather than a screen-space mask.

## MUX

`kind:"ab"` accepts video or collection on inputs `A` and `B`. The `Video` output carries the
preview. The `Collection` output carries a collection recipe that preserves individual
faces. Publish `Collection` for a VJ Patch Collection clip. Video inputs become
surface fills, and collection inputs retain their per-face sources. `mix` fades
from A (0) to B (1); `mode:1` cuts at the midpoint. Apply video effects such as
Dither before each Video Collection input to process every face independently.

`kind:"mux"` has eight optional video inputs (`Video 1` through `Video 8`) and one `Video` output.
`level1` through `level8` range from 0 to 1; `followAPC` is 0 or 1. The additive
mix uses the project canvas, aspect-fits each input, and clips at white.

```json
{"op":"parameter","id":"MUX_UUID","key":"level3","value":0.65}
{"op":"parameter","id":"MUX_UUID","key":"followAPC","value":1}
{"op":"midi_follow","node":"MUX_UUID","enabled":false}
```

Follow APC is persisted with the graph and follows track faders independently of
selection. It takes precedence over level modulation/MIDI mappings. Physical
positions are in `state.midi.channelFaders` (eight values, null until seen);
`state.midi.muxFollowNodes` lists enabled followers. Multiple MUX followers share
the same controls. The existing A/B follower and CC 15 are independent.

## MIDI hooks

`GET /v1/midi/hooks` returns every explicit mapping and every A/B or MUX follower,
including currently disabled followers. The same list is available in
`state.midi.controlHooks`. Entries include zero-based MIDI channel/CC, target node
name/ID and parameter, enabled state, and edit/disable/remove command payloads
for `POST /v1/commands`. MUX routes expose current and physical fader values;
Follow APC disables/enables all eight routes for that MUX. A/B follows globally,
regardless of selection or the active VJ tab, including with an APC40 node present.
Only one A/B node can follow CC 15; enabling another transfers the assignment.
In embedded VJ this reserves CC 15 from Composer. The assignment survives session
restore and controller reconnects. Manual A/B changes retain the assignment; use
`midi_follow` with `enabled:false` to detach. Explicit bindings report
when a MUX follower or the embedded host owns their physical control.

`midi_update` accepts `node` and `key` as well as channel, CC, device, range,
pickup, inversion, and enabled state. Invalid or conflicting assignments fail
without modifying the graph. Existing revision/output protection applies to
routing changes. Use `midi_unbind` to remove a mapping and `midi_follow` with the
node ID and `enabled:false` to detach a follower.

### Palette Adjust

`paletteAdjust` accepts and outputs a palette. Connect `videoPalette → paletteAdjust`
to separate color from video intensity, or use any other palette source. `mode` is
0 Off (default, exact passthrough), 1 Normalize brightness (retain hue and saturation),
or 2 Hue only (retain hue, set saturation). `brightness` and `saturation` are 0–1,
both defaulting to 1; saturation applies only in mode 2. Brightness is HSV value
(maximum sRGB channel), not perceptual luminance. All three controls support MIDI and the standard parameter API; brightness and
saturation also support modulation. Output color order/count are unchanged.
Node bypass also passes the input palette through. Leaf palettes publish normally.

Black stays black because it has no recoverable hue; neutral colors remain neutral.
Hue-only mode removes white/gray dilution, but cannot undo a colored blend that
changes the hue or changes which colors the upstream extractor selects.

### Glow Faces and Lightning Pulses

`glowFaces` takes a `palette` on its `Palette` input and publishes a `collection` recipe.
The destination supplies the faces. Colors repeat in face order; `brightness`
(0–1, default .7), `center_glow` (0–1, default 1), and `falloff` (.25–6, default
1.5) preserve Composer's Glow Faces profile. Without a palette, packed sRGB
`color` defaults to white. `previewFaces` changes preview geometry only.
Connected palette gaps hold the most recent colors; they do not select a theme.
The three performance controls support MIDI, modulation and `parameter` commands.

`lightningPulses` takes a palette on `Palette` and optional normalized control
on `Phase`. Its output is `trace`, available through `/v1/outputs` and the
VJ Patch library. The recipe includes `kind: lightningPulses`, `params`, `time`,
`phaseDriven`, `paletteConnected`, and ordered `colors`. Phase times `cycle`
(default 4 seconds) replaces the free-running clock. The destination supplies
its trace path, scope, width, offset and reverse. Original Lightning Pulses
shape, range, reflection, core/glow and rainbow controls remain available;
`/v1/schema` describes their exact ranges and MIDI eligibility. A connected
palette colors emitted packets in order; Single color also colors their cores.
Brief palette gaps hold the last palette. Missing initial colors emit nothing.

### Live Stream and MUX dropout masks

`liveStream` is a muted HTTP(S) video source. Set `text` to a direct AVFoundation-
compatible stream URL (for example an HLS `.m3u8` URL), using `add` or `update`.
Web pages such as YouTube watch URLs are not media URLs. Normal media transform
parameters apply. Decoder/network work runs independently of graph rendering;
reconnects hold the last decoded frame and retry with bounded backoff. Disable
or pause the node to pause playback. The API's node `status` reports connection,
live playback and the measured buffered duration. `buffer` sets the playback
reserve in seconds (0–8, default 2; 0 uses minimal buffering). It is a saved node
parameter exposed through the standard `parameter` command and UI. Playback
waits for a contiguous reserve at startup and after an underrun, then advances
at the original media rate. Short live windows cap the reserve to available history;
stale playheads recover into the current window. The last frame remains visible during refills.
AVFoundation stores the network reserve; Patch does not retain seconds of full-
resolution decoded textures. Buffering adds playback delay and cannot manufacture
frames missing from the source.

`powerGlitch` produces a grayscale dropout mask, white (pass-through) between
brief localized bursts. `burstRate` controls events per second (0 disables);
`flashes` controls flashes per event; `rate` controls the fast intra-burst tempo.
`flashMs` and `variation` control flash length and irregular timing. Defaults:
0.35 bursts/s, 3 flashes, 24 Hz, 25 ms, variation .55. At dense settings the
intra-burst interval is shortened to retain silence between bursts.

`recipe` selects 0 Power flicker or 1 Signal breakup. Each burst has a stable
spatial center and cell pattern; `spread`, `jitter`, and `blocks` control region
size, small per-flash displacement and detail. `dropout` sets cell cutout density;
`blackout` is the per-burst chance of brief full-frame cutouts. `static` and `bands`
remain confined to the local flash envelope. `seed` makes event timing and
patterns repeatable. Every performance control supports MIDI/modulation and the
standard parameter API. This is attenuation, not geometric video displacement.

MUX `mode1`–`mode8` select 0 Mix (default) or 1 Mask. Mix channels sum as before;
then mask channels multiply the combined frame by `mix(1, mask luminance, level)`.
A mask fader at zero leaves the image unchanged; at one, black mask regions erase
it. Disconnected or disabled mask sources are ignored. Modes support the standard
parameter API and MIDI. `followAPC` still drives all eight levels, not modes.

### Video Collection

`videoCollection` has eight Video inputs and one Collection output. Connected
inputs are assigned in input order to the destination's saved face order, with
the list repeated when there are more faces than inputs. One connected input
appears on every face. Each face receives the whole video, including for span
collections; ordinary surfaces and Out monitors show the first input.

Connect Video nodes, images, live inputs, or processed video outputs with the
standard `connect` command. Playback and speed belong to those upstream nodes.
Parameters are `fit` (0 Contain, 1 Cover, 2 Stretch), `brightness` (0–2), and
`previewFaces` (1–64, preview only). Brightness supports MIDI and modulation.
The Collection output can feed Layer Mux or be selected directly in VJ.
Its published recipe contains ordered `videos` port IDs, `fit`, and `brightness`;
the runtime retains those video streams only while the collection is consumed.

### Render demand

`GET /v1/state` exposes `renderDemand`: `activeNodes`, `idleNodes`,
`previewNodes`, `rasterNodes` (node UUID arrays), and `hostManaged`.
`gatedMuxInputs` maps MUX node UUIDs to zero-based input indices skipped because
their effective level is zero or they are outside the current channel count.
`GET /v1/outputs` retains dormant outputs in the catalog and adds `active` to
indicate whether their producer is currently evaluated. An enabled dormant port
remains available to select but has no current frame/value/recipe in the snapshot;
consuming it wakes the producer. Catalog listing alone is not render demand in
embedded Patch. Standalone publication keeps its existing listed-output behavior.

The embedded host retains outputs used by demanded compositor buses, including
projector/monitor/stream demand and enabled LED routes or Meta Mapping LED members.
Clips in other slots or saved shows do not continuously retain outputs. A visible
clip/library tile without a cached poster briefly requests its source, then keeps
the still image. The host's
`GET /api/v1/sources/patch` includes `consumed`, the retained port IDs.

Visible Patch views renew 300 ms preview leases. Hidden, off-canvas, paused, and
fully occluded views do not renew them. Explicit Syphon/NDI/Publish Palette nodes,
audio outputs, active recordings, audio auditions, and explicit API snapshots
remain consumers. Dependencies include modulation and audio. Zero-level MUX
channels and the unused A/B input at an endpoint/cut can sleep, including channels
driven by APC faders, LFOs, and audio envelopes. Controls are resolved before image
demand each frame and remain active while their mixer is consumed, so increasing
a level wakes its input on the next render pass. A source still needed by another
consumer or visible preview stays active. Paused nodes skip modulation and preview
rendering; bypass effects retain their pass-through input and its static-frame
version instead of evaluating their own effect. Live output resolution and frame rate are
unchanged. Dormant media pauses and unused camera/microphone capture is released.

Collection/trace recipes, palette values and control signals update without
rendering their preview images unless a visible view or snapshot requests one.
Consuming just a mesh gradient palette does not render its video texture.

## APC40 controller node and mux channel count

`apc40` is a singleton node. Its presence reserves the APC40 mkII for the graph,
including when paused. In embedded VJ Native it overrides Composer clip/grid,
DMX, crossfader and learned APC mappings as well as Patch's MUX Follow APC.
A/B Follow APC remains available and receives the crossfader globally.
Deleting the node releases ownership. Other MIDI devices retain their mappings.
The controller must still be selected in VJ's MIDI controls.

Outputs are normalized 0–1: indices 0–7 track faders, 8–15 track knobs,
16–23 device knobs, 24 master fader, 25 crossfader, and 26–33 momentary track
activator switches. The clip grid is reserved but has no graph outputs yet.
Port names are returned by `/v1/schema`; live values and ownership are in
`midi.apcOutputs` and `midi.apcNodeOwnsController` in `/v1/state`. Unseen controls
are null and leave the target's saved base value in effect. Hardware values are
runtime state; wiring and parameter ranges are saved with the graph.

The APC sidebar provides eight channel faders, master and crossfader without
hardware. GUI, API and MIDI write the same runtime values; the most recent
movement wins. The reset button releases that output to target base values.
Values are session-local and are not saved in the graph.

`apc_window` with `id` opens (or focuses) the APC40 node's standalone controller
window. The same action is **Pop out APC40** in its inspector and context menu.
Drag channel/master faders and the crossfader, drag track/device knobs vertically
(Shift for fine adjustment), or click activators. These 34 controls write the same
runtime values as `apc_control`; hardware is optional, and subsequent hardware/API
changes are reflected in the window. Closing the window retains the values.

```json
{"op":"apc_window","id":"APC_NODE_UUID"}
```

`apc_control` accepts an output index (0–33) and a normalized value (0–1), or
`null` to release it. An APC node must exist. It is a single runtime command,
not part of graph transactions. Live-output protection requires
`allowLiveChanges:true` and the current `expectedRevision` when applicable.

```json
{"op":"apc_control","output":0,"value":0.75}
{"op":"apc_control","output":0,"value":null}
```

```json
{"op":"add","kind":"apc40"}
{"op":"modulate","source":"APC_UUID","outputID":"Fader 5","target":"FACES_MUX_UUID","key":"level1","minimum":0,"maximum":1}
{"op":"parameter","id":"FACES_MUX_UUID","key":"channels","value":2}
{"op":"frame"}
```

`modulate.outputID` selects the source control, such as `Fader 5` or `Crossfader`. The canvas displays
these connections at their actual controller ports; drag a port onto a node to
choose a continuous parameter. Audio parameters support the same ports.

Both `mux` and `layerMux` have an integer `channels` parameter, 1–8, default 8
for new nodes. Input ports, rendering and the inspector use this count.
Disconnect inputs and level modulations above the desired count before reducing
it. `frame` fits the current graph in the editor without rearranging it.

MIDI assignments follow the [Akai APC40 mkII communications protocol](https://cdn.inmusicbrands.com/akai/attachments/apc40II/APC40Mk2_Communications_Protocol_v1.2.pdf).

## A/B Crossfade publication

`ab` publishes its blended Video output automatically in VJ's Patch source list,
including when its output feeds downstream nodes. No Patch Out node is required.
Explicit publication mode `off` still hides it; the node name is the default source
name. Rendering and stream publication remain demand driven. Its two inputs are
Video A and B; `mix` is 0–1 and `mode` selects Crossfade or Cut.

## WebP images

Still `.webp` files import as Image nodes through the media picker or file drop,
including when macOS file-type metadata is missing. The Image node picker lists
WebP explicitly; Video nodes accept movie files. API clients can use `add` with
`kind:"image"` and the original WebP path. Images decode through ImageIO, retain
alpha, and are limited to a 4096-pixel longest edge for texture upload. Animated
WebP playback is not supported by the Image node; it displays the first frame.


### Palette extraction from collections

`videoPalette` accepts video or collection on its `Video` input. A collection connection
samples its rendered preview, including active A/B branches, Video Collection
photos, and MUX layer levels. Connect Layer Mux’s `Layers` output to sample its combined
appearance. Its `Video` output contains the video inputs.
Collection sampling remains active when node previews are closed. Existing
extraction rate, smoothing, and color-count controls apply.


### Static frames and retained connections

Image and image-derived Crop outputs reuse their rendered textures until the
source texture, parameters, upstream cached version, or output size changes.
Static Syphon frames publish once per changed version. Up to 32 dormant Syphon
publishers remain available for connection reuse across A/B endpoints; dormant
publishers do not evaluate their source branches or republish frames. Removing
or disabling a source releases its publisher.

`state.renderDemand` includes `staticCacheHits` (reused nodes this frame),
`cachedStaticNodes`, and `warmPublishers` (all retained publisher instances,
including active ones). These counters do not imply that every cached node is
currently demanded.

## Cellular Automata field

`cellularField` is an external User Generated effect with a stateful Metal
`cellularStep` kernel. Connect it to LED Matrix **Field** to drive the LEDs, or
**Light** to block an existing Video/Field signal. Dark blockers is the default;
Lit cells reverses the mask. The matrix retains control of hue, LED shape, and
spacing. Each connected matrix samples the same simulation at its display grid.

Parameters (also available in the inspector and MIDI/modulation metadata):

| Key | Range | Meaning |
| --- | --- | --- |
| `rule` | 0–4 | Life, HighLife, Seeds, Brian's Brain, Cyclic waves |
| `rate` | 0–60 | Generations per second; zero freezes evolution |
| `density` | 0–100 | Starting density, percent |
| `inject` | 0–10 | New-cell probability per generation, percent |
| `trail` | 0–0.98 | Previous activity retained each generation |
| `depth` | 0–1 | Block/mask strength; zero passes full brightness |
| `output` | 0–1 | Dark blockers / Lit cells |
| `wrap` | 0–1 | Closed / Wrap edges |
| `neighbors` | 0–1 | Eight / Four neighbors |
| `states` | 3–16 | Number of cyclic states |
| `threshold` | 1–8 | Cyclic successor-neighbor threshold |
| `seed` | 0–65535 | Initial state; changing it reseeds |

Rule, density, seed, cyclic-state count, and matrix-grid changes reset the
simulation. The inspector's Reseed action increments `seed`. Global transport
pause freezes evolution. Other parameters update without reseeding. Four-neighbor
mode changes the neighborhood used by the selected rule; default Life uses eight.
Two private RGBA16F textures store one texel per simulation cell, with no CPU readback and no
full-resolution simulation pass. Catch-up is limited to four generations per
rendered frame. Hidden/inactive branches do not run. Simulation state is transient;
parameters and connections are saved in the graph.

The source contract is `cellularStep(old texture(0), next texture(1), controls
buffer(0), uint2 cell)`. Controls contain three `float4`s: rule/density-fraction/
seed/reset; injection-fraction/trail/wrap/neighborhood; states/threshold/generation/
reserved. Red stores the discrete cell state and green stores activity plus trails.
Live install and branch staging compile both this kernel and the connected matrix
pipeline before committing.

## Graph Cloud Particles

`graphCloudParticles` is a separate collection effect; `graphClouds` retains its
original strip renderer. Both accept a palette on `Palette` and publish a collection
on `Collection`. The particle variant uses independent, overlapping density particles
following a cubic B-spline route through the destination graph. Positions, radii
and orientation vary continuously, without connecting segments or tangent-aligned
texture coordinates.

It retains the cloud parameter keys, with `clouds` controlling 1–8 groups
(default 4), `length` controlling spread along the route, `width` controlling
particle size, and `wander` controlling turbulence (default 0.55). New `detail`
is 8–24 particles per group (default 16). Numeric performance controls support
the parameter API, MIDI and modulation. At most 192 particles are evaluated,
with group bounds and particle-radius rejection. Detail approximately preserves
total density per group.

Clear sky remains the default. Wind controls particle orientation independently
of graph corners. Drift zero freezes motion, including wisps; grain is spatial.
Motion is deterministic from time, seed and destination geometry, with no
simulation history or GPU readback. Like the original, Once traversal loops.
Preview and projector share the density model. LED fixtures sample coverage at
their graph member's center and use the dominant particle's palette color;
the projector blends overlapping colors by density.
## Audio channel routing

Audio File (`audio`), Audio Input (`audioInput`), Audio Gain / Pan (`audioGain`), and Audio Output (`audioOutput`) expose `channelMode`: 0 Stereo (default), 1 Left → both, 2 Right → both, 3 Mute left, 4 Mute right, 5 Swap left/right, 6 Mono mix (average). Channel selection precedes gain/pan on gain and output nodes. Right → both ignores the left source and copies the right sample to both output channels at its original level. The inspector uses a menu; the parameter is also MIDI-assignable.

Audio sources and processors expose `Stereo / XY`, `X / Left`, and `Y / Right`. Separate outputs duplicate the selected channel to both sides. Voltage Encoder exposes `XY Audio`, `Draw Rate`, `X`, and `Y`. Video exposes `Video`, `Stereo Audio`, `X / Left`, and `Y / Right`. Voltage Visualizer accepts `XY Audio`, `Draw Rate`, `X`, and `Y`. A separate axis overrides that channel of the combined input. An axis with neither connection is zero.

## Audio EQ / Balance

`audioEQ` has one stereo audio input plus stereo, X/Left, and Y/Right outputs. `bass`, `mid`, and `treble` are gentle tone bands (−18…+18 dB) with 200 Hz and 4 kHz crossovers; all zero is flat. `balance` ranges from −1 (left only) through 0 (center) to +1 (right only). `leftGain` and `rightGain` trim each side (−60…+12 dB), and `gain` sets output level. `muteLeft` and `muteRight` silence their respective outputs. `channelMode` selects the source channels before EQ; choose 2 for Right → both. Gain changes smooth over 10 ms. Disabling the node bypasses it. The inspector offers sliders, exact numeric values, and zero buttons.

### Subpatches

Use `subpatch_extract` with `nodes` (an array of member UUIDs) or `id` (an existing component), and an optional `name`. Extraction returns the component ID. Existing cables, modulation and hardware mappings retain their targets. Use `update` with a component `id` and `name` to rename an instance. The component's `interface` in `GET /v1/state` contains ordered `ports`, exposed `parameters`, and an optional preview member UUID.

`connect` and `disconnect` accept a subpatch UUID as an endpoint. Supply the public port UUID in `inputID` or `outputID`. For `parameter`, `modulate`, and `unmodulate`, supply the public parameter UUID in `key`. A public endpoint keeps its UUID when renamed or reassigned. Submit `subpatch_interface` with `id` and the complete edited `interface` to rename, reorder, expose, hide, or reassign endpoints. Each public port declares its direction, type, member UUID and member port ID. Reassigning an endpoint moves its external wires atomically. Remove a connected port after disconnecting its external wires.

`GET /v1/subpatches/{id}` returns a versioned `template` and the graph revision. Use `subpatch_instance` with a source subpatch `id` or an exported `template`, plus optional `x` and `y`. Each instance receives fresh member and cable IDs and keeps the public endpoint IDs. Copies include the selected controls' current base settings, member configurations and internal modulation. External drivers and cables belong to the source graph. Media and user shaders retain their file references. Templates carry MIDI bindings. Set `includeMIDI:true` when instantiating to apply them to fresh member IDs. Conflicting hardware assignments fail the transaction.

Instances open detached by default. Patch pauses copied output nodes, microphones, cameras, hardware audio and MIDI inputs, NDI inputs, and live streams. Copied publications start hidden and MUX hardware following starts off. Set `enableOutputs:true` to retain their saved states. An APC40 node reserves its device even when paused, so importing one requires this option. The template and original graph retain all saved settings.

On the canvas, extract a selection or convert an existing component. The inspector provides public port names and destinations, exposed controls, preview selection, **New Instance**, and JSON export. **Insert Subpatch…** imports that JSON into another composition.

### Shared library

Patch and Compose share favorites in `~/Projection3000/Library/Favorites.json`. Read `GET /v1/library/favorites`. Pin or remove an entry with `POST /v1/library/favorites` and a body such as `{"kind":"patchNode","id":"noise","name":"Noise","pinned":true}`. Use `pinned:false` to remove. The response contains the current ordered `favorites` array. Identity uses both `kind` and `id`, so renaming a favorite keeps its position. Kinds are `patchNode`, `subpatch`, `composeEffect`, `media`, `source` and `patchOutput`. Shader presets use `patchNode` with a `shader:` prefix and path relative to User Nodes. Shared source entries keep their device or stream selection when offline.

`GET /v1/library/subpatches` lists bundled and personal templates with stable file IDs and named input/output UUIDs. Personal files in `~/Projection3000/Patch/Subpatches` take precedence at the same relative path. Each supported Compose output includes `composeType`. The `diagnostics` array identifies unreadable templates. Save a component with `POST /v1/library/subpatches` and `{"id":"component-uuid","libraryID":"Scenes/Night.subpatch.json"}`. Set `replace:true` to overwrite a personal file.

Use `subpatch_instance` with `libraryID` to load a template into the current graph. To consume one output, include its public UUID as `outputID`. The result includes `id` (instance), `source` (native host source ID), `type`, `name` and `controls`. Each control carries the public parameter UUID, instance-local member/key, numeric limits and current value. Set its value with the existing `parameter` command using instance `id` and the public UUID as `key`. The selected source is unlisted and a host can retain it on demand. Other ports, devices and MIDI mappings follow the normal detached insertion defaults.

To copy an existing instance from its output, send `subpatch_instance` with `source` set to the host source ID. The copy receives a new source ID and the same exposed outlet, current control settings and internal wiring. An output must belong to an exposed subpatch port to support this operation.

A processor declares its video input by public UUID in `processingInput`. Supply a Patch video source ID in `inputSource` and select a video `outputID` to insert the processor and wire that inlet in one graph transaction. When making an independent copy of an existing processor through `source`, the copy shares the original upstream connection. Detached instances in the Patch editor can be wired manually. Catalog entries expose their canonical `favorite` identity, including shared Patch node identities for bundled single-node processors.

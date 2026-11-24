# VJ external API v1

This is the API reference. For what the running build supports, query `/api/v1/capabilities`. All paths below
are relative to the origin serving this document (for example
http://127.0.0.1:9120). Start with GET /api/v1/state. No deployment or renderer
restart is needed to upload and play a new animation.

## MIDI connection

Normal native launches restore saved MIDI device intent. Isolated development launches suppress hardware restoration. Select an input or Off explicitly in Controls.
Patch and VJ share an APC ownership lock. Selecting the APC in either application
requests a handoff; the other application releases it and stops reconnecting until
explicitly selected again. Only the owner initializes Live Mode or sends feedback.
The MIDI state reports `inputs`, the session’s selected device in `selected`,
the open device in `connected`, connection `status`, and `cooperative:true`.

## Standalone DMX

The **DMX** tab has its own output loop; it is independent of the Composer,
Outs, LED controls, and mixer blackout. It currently supports the SoundSwitch
DMX Micro USB adapter (`15e4:0053`) and JMAZ ATTCO Wash 100Z in 13/15-channel
mode. Set the fixture's physical address and mode to match the panel.

`GET /api/v1/dmx` returns adapter status, detected devices, selected serial,
fixture address/mode, controls, effective fixture channel values, successful
frame count, last transmission time, and any USB error. Connected means USB
output is working; this adapter does not report the fixture's state back.

`POST` or `PATCH /api/v1/dmx` accepts:

| Action | Additional fields | Behavior |
|---|---|---|
| `scan` | None | Refresh compatible USB devices |
| `connect` | Optional `serial`, `address`, `mode` | Open the adapter and begin continuous output at a target 40 Hz |
| `disconnect` | None | Send blackout while retaining position, then release USB |
| `set` (default) | `controls`, optional `address`, `mode`, `serial` | Update controls atomically; configuration changes require disconnection |
| `identify` | None | Steady white at 16% brightness for 3 seconds, then restore controls |
| `flash` | None | White flash for 250 ms; respects blackout |
| `blackout` | None | Latch blackout and cancel temporary identify/flash/reset |
| `reset` | `motor`: `all`, `pan_tilt`, or `zoom` | Motor reset for 3 seconds; requires blackout |

Address is 1-based and must leave room for the complete fixture within channels
1–512. Mode is `13` or `15`. Startup is disconnected with dimmer at zero;
leaving the tab does not stop output. USB loss stops the connection and reports
an error; reconnect explicitly. Server shutdown sends blackout before closing.

The DMX panel has **Controls** and **APC40** subtabs; the selected view is
remembered in browser storage. While DMX → APC40 is visible, channel 0 CC 13
(Tempo, signed relative values) adjusts brightness by 1/127 per step. CC 16–19
control pan, tilt, movement speed, and beam width; CC 20 controls strobe
(0 = steady; 1–127 = slow to fast); CC 21 selects eight solid RGB hues.
CC 22–23 are consumed but unassigned. Device knob rings reflect these values.
Leaving this view restores composer knob routing; DMX output continues.

The same performance controls are available through `POST/PATCH /api/v1/dmx`:
`{"apc":{"brightness":0.5,"pan":0.5,"tilt":0.5,"speed":0.3,"beam":0.5,"strobe":0,"color":0}}`.
All fields are optional. Values are normalized 0–1 except `color`, an integer
0–7: red, orange, yellow, green, cyan, blue, violet, magenta. Color uses direct
RGB mixing, clears white and color macros, and disables automatic programs.
Movement and strobe changes also disable automatic programs. Blackout remains
independent. Responses include `apc` (current performance values), `palette`,
and `apc_active`. With arbitrary RGB values, `apc.color` is the nearest palette
entry; reading it does not change the light.

`{"apc_active":true}` leases the APC knobs to DMX for five seconds; renew at
least once per second while controlling it. `false` releases them immediately.
The UI renews while this view is visible, so closing it or losing contact
releases controller routing. This field changes routing only, never light output.

### Motion patterns

`POST/PATCH /api/v1/dmx` accepts motion settings inside `controls`:
`{"controls":{"motion":"circle","motion_size":0.2,"motion_speed":0.15}}`.
`motion` is `off`, `circle`, `pan`, `tilt`, or `figure_eight`. `motion_size`
and `motion_speed` are normalized 0–1. Size sets the radius to up to 25% of
pan/tilt travel; speed maps to 0.05–1 cycles per second (20–1 seconds per cycle).
Defaults are off, size 0.2, speed 0.15. Existing `pan` and `tilt` set the center,
including through the APC40 knobs. The Motion section is shared by both views.

Patterns run in the server's 40 Hz DMX loop, independent of browser polling.
Starting, changing patterns/size, and stopping blend over 0.6 seconds. Stopping
returns to the center. Paths shrink at travel limits; these are pan/tilt-space
patterns, not calibrated circles on a wall. The fixture's motor speed is set to
maximum during motion so the host trajectory controls speed; the manual motor
speed setting is restored after stopping. Physical motor limits still apply.

Starting a motion disables the fixture's internal program. Selecting an internal
program, disconnecting, or resetting motors stops motion and retains the last
commanded target. A request enabling both a motion and an internal program is
rejected. Blackout suppresses light but lets motion continue. Leaving DMX does
not stop motion. Responses include `target: {pan, tilt}` for the generated DMX
destination; `controls.pan/tilt` remain the center. Target is not motor feedback.

All numeric controls are normalized `0..1`: `dimmer`, `red`, `green`, `blue`,
`white`, `pan`, `tilt`, `zoom`, `movement_speed`, `strobe_speed`, `macro_speed`.
Zoom runs narrow to wide; movement speed runs slow to fast. Pan/tilt use 16-bit
positioning in 15-channel mode. Other controls:

- `blackout`: boolean; set false to release. It suppresses dimmer, shutter,
  RGBW, macros, and programs while retaining movement/zoom.
- `strobe`: `open`, `strobe`, `pulse`, `random`.
- `macro`: `off`, `red`, `green`, `blue`, `white`, `yellow`, `magenta`,
  `red_white`, `cyan`, `green_white`, `blue_white`, `rgb`, `rgbw`, `jump`,
  `fade`, `mixed`.
- `program`: `off` (manual DMX), `1` through `7` (built-in auto programs,
  strings), or `sound` (sound-active program 1). The ATTCO Wash 100Z manual,
  section 9, lists these as internal programs without describing individual
  movement/color sequences. The numbered DMX selections use values 100–239;
  sound-active program 1 uses 240–255. The fixture menu/remote's nine programs
  are separate from the seven numbered programs exposed by its DMX chart.
  [Manufacturer manual, mirrored transcription](https://www.notice-facile.com/en/manual/1065307/jmaz%2Blighting%2Battco-wash-100z).

```javascript
await fetch('/api/v1/dmx', {method:'POST', headers:{'Content-Type':'application/json'},
  body:JSON.stringify({action:'connect', address:1, mode:15})});
await fetch('/api/v1/dmx', {method:'PATCH', headers:{'Content-Type':'application/json'},
  body:JSON.stringify({controls:{dimmer:0.2, red:1, green:0.25, blue:0,
    white:0, pan:0.5, tilt:0.5, zoom:1, macro:'off', program:'off'}})});
```

The driver uses libusb. It discovers a system installation, the Homebrew
locations, or TouchDesigner's bundled macOS library. `VJ_LIBUSB_PATH` can select
a specific library. No SoundSwitch subscription or application is needed for
this tested adapter. Only one application should own its output interface.

## Shared clip grid

Each named Show owns one shared grid. Rows are layers; columns hold alternative clips
for those layers. Clip content, parameters, layer order, opacity, blend and
enabled state are shared. Each Out bank independently chooses at most
one cell per row, and independently starts or stops its output.

GET `/api/v1/grid` returns `{grid, revision, result:null}`. POST to the same
endpoint with one action below; the response is `{grid, revision, result}`.
`result` contains the affected row, column, Show, or Out status. Use the returned IDs
in subsequent commands. The UI uses these exact commands.

| Action | Fields besides `action` | Behavior |
|---|---|---|
| `create_show` | optional `name` | Save the current Show and select a new empty Show |
| `duplicate_show` | optional `show` ID, `name` | Copy that Show (current by default) with new clip/row/column IDs and select the copy |
| `rename_show` | `name`; optional `show` ID | Rename that Show (current by default) |
| `select_show` | `show` ID | Save the current grid and restore the selected Show's grid, Out A/B selections and running states |
| `delete_show` | optional `show` ID | Delete that Show; deleting the current Show selects another; keep at least one Show |
| `add_column` | optional `name` | Append an empty shared column; returns the column |
| `rename_column` | `column`, `name` | Rename a shared column |
| `move_column` | `column`, `target`, `position` | Move the entire shared column `before` or `after` another column ID; keep clips and playback selections intact |
| `delete_column` | `column` | Delete its slots on every row; unset any selected cells in that column on every Out bank |
| `launch_column` | `column`, `bus` | Set every populated cell in the column for this bus; empty cells leave existing selections unchanged |
| `add_row` | optional `name` | Add an empty shared layer at the top of the stack; returns the row |
| `set_row` | `row`; any of `name`, `blend`, `enabled` | Edit shared layer settings |
| `move_row` | `row`, `dir` or `target` + `position` | Move the shared layer one position (`1` raises, `-1` lowers), or place it `above`/`below` a target row ID in visual order |
| `delete_row` | `row` | Delete the shared layer and all its clips; unset it everywhere |
| `stop_row` | `row`, `bus` | Unset this row for one bus; retain its saved clips |
| `put_clip` | `row`, `column`, `effect`; optional `params`, `name` | Create/replace a saved cell; replace it live wherever that cell is already selected |
| `set_clip` | `row`, `column`; optional `params`, `name`, `opacity`, `blend` | Update a saved clip, including when unselected; update every Out using it |
| `copy_clip` | `row`, `source_column`, `column` | Duplicate within the same row into an empty destination; does not select it |
| `delete_clip` | `row`, `column` | Clear one slot; unset that cell everywhere |
| `delete_cell` | `row`, `column` | Clear an occupied slot; for an empty slot, shift the cells below it up one row in that column. The last slot becomes empty. Row settings stay in place. A/B selections follow moved clips unless the destination row already selects another column. Undoable. |
| `launch_clip` | `row`, `column`, `bus` | Select this cell, replacing the bus's previous selection in this row |
| `toggle_clip` | `row`, `column`, `bus` | Unset it if already selected; otherwise select it, replacing the previous cell in this row |
| `start_out` | `bus` | Render the bus's selected cells |
| `stop_out` | `bus` | Black out the bus and stop its contribution to audio; preserve every selection |
| `toggle_out` | `bus` | Toggle the same start/stop state |

`row` and `column` are IDs, not names or positions. `bus` accepts `out1` through
the active output count, `program` is also accepted for Out 1.
The default bus is `out1`. Shared edits do not become Out-specific when a bus is
supplied. Launch/toggle/stop commands target one bus; `all` is only supported by
A/B crossfading below. Launching or editing cells does not start a stopped Out.

`grid.active_show` identifies the current Show; `grid.shows` lists `{id,name}`.
Only the current Show's grid is included in normal state responses. All Shows
autosave on the server and survive restarts. Existing sessions become “Show 1”.
Include `active_show` in a mutation to reject an edit if another client has
switched Shows in the meantime. Mapping, LEDs, Mix, clocks and output count are
global rather than per-Show. Switching Shows changes live Out selections.
Saved live-input clips retain their source identity when a sender is absent;
rebind using `set_clip` and `params.source` (NDI/Syphon) or `params.device`
(camera). Source discovery remains available through `/api/v1/sources/ndi`,
`/api/v1/sources/syphon` and `/api/cameras`.

`params` is a partial object validated against GET `/api/v1/effects/{effect}`.
Media collections use `effect: "media_collection"`. Set `params.items` to an
ordered array of `{type:"image"|"video", file:"library://…"}` entries (up to 256;
removable-media references also work). Use `set_clip` with a replacement array
to add, remove, or reorder entries. The inspector offers the same controls,
library drag-and-drop, and an Add media picker with multiple selection.
For surface collections, `fit: "cover"` crops each item to its mapped face
without changing its proportions; `contain` preserves the complete image with
unused space, and `stretch` fills the face by changing its proportions. Fitting
uses each face's mapped pixel aspect, including projector rotation.
GET `/api/media/catalog` returns `{items:[{type,file,name,path}]}` for all built-in
images and videos, including subfolders, without generating thumbnails. The
picker refreshes this catalog on open and supports search and Select results.

```json
{"action":"put_clip","row":"ROW_ID","column":"COLUMN_ID","effect":"media_collection","params":{"items":[{"type":"image","file":"library://photo.jpg"},{"type":"video","file":"library://clip.mp4"}],"fit":"contain","speed":1,"playing":true,"gain":1}}
```

Ordinary surfaces and Out monitors show the first item. Planar, box, and point
collections assign items in their saved face order, repeating the list when
there are more faces than items. Extra items are unused; an empty list contributes
no layer. Each face gets the whole assigned item, including when a planar
collection uses span layout. `fit`, `speed`, `playing`, and `gain` apply to all
items; collection `playing: false` pauses every video. Videos loop silently.
Each list entry has independent playback; faces repeating the same entry share it. A/B banks retain
independent collections without consuming extra Outs.

Video entries accept an optional unique `id` and `params` containing
`playing`, `loop_start`, `loop_end`, `position`, and `seek_nonce`. Loop bounds
are fractions of the whole file (0..1, start < end); position is a fraction
of the selected loop. Preserve each entry's `id` when reordering. Old entries
without IDs remain supported; transport commands assign stable IDs without
changing their source identity. The inspector selects each video and provides
play/pause/stop, scrub, and start/end percentage controls. Slider edits commit
on release to avoid repeated decoder rebuilds. Inactive entries retain edits
for their next launch; playhead telemetry is available only while rendered.

POST `/api/v1/grid` with `action: "video_transport"`, `row`, `column`, and
`item_id` (or zero-based `item_index`) targets a collection video. Supported
operations are `play`, `pause`, `stop`, `seek` with `position`, and `range`
with `loop_start` and/or `loop_end`. Range edits return to the new start while
preserving play/pause; stop pauses at the loop start. The same operations work
without an item selector for a standalone video clip.

```json
{"action":"video_transport","row":"ROW_ID","column":"COLUMN_ID","item_index":0,"operation":"range","loop_start":0.2,"loop_end":0.8}
```

For uploaded effects, use the returned `effect` name (`external_…`). `put_clip`
starts from effect defaults; `set_clip` retains omitted parameters. Video
play/pause, seeking, loops and audio are clip parameters, shared by every Out
using that clip. Out start/stop is output gating, not a saved playback position:
clocks continue, and media may restart when its last active source was released.

`opacity` is 0..1; `blend` is normal/add/screen/multiply; `enabled` is boolean.
For video Out banks, clip opacity applies to every clip, including the bottom
content clip. The bottom content clip uses normal blending against black;
higher clips use their chosen blend mode. Adjustment layers require content
below them. Legacy row opacity is stripped when shows load; use `set_clip` for blend amount.
Mix master brightness and LED layer opacity retain their existing behavior.
Disabling a shared row affects all Outs using it. There are at most 64 rows and
64 columns; at least one column must remain. Deletions execute immediately
without an API confirmation step. Vector clips can be stacked with other vector,
raster, video and adjustment layers. A lone enabled vector retains direct
surface rendering; with other enabled layers it is rasterized into a transparent
texture at the Out's render resolution and participates in normal compositing.
`grid.rasterized_vectors` maps buses to affected row IDs; the UI displays an amber
“Vector rasterized” status. Output state also exposes `vectorRasterized`.
Disabling or unsetting the other layers restores direct rendering automatically.

Include optional `revision` from the latest grid or full state response for
optimistic concurrency. A mismatch returns HTTP 409 with the current revision
without applying the command. Invalid actions, IDs, parameters and inactive
buses return HTTP 400 with `{error}`. Serialize commands and use each response's
revision for the next edit; toggles are evaluated by the server at execution.

The grid is also available at `state.grid` in `/api/v1/state` and event messages:

```json
{
  "version": 2,
  "columns": [{"id":"column_…","name":"1"}],
  "rows": [{
    "id":"row_…","name":"Base","blend":"normal","enabled":true,
    "clips":{"column_…":{"id":"clip_…","name":"Orange","gen":"solid_color","params":{"color":"#ff8000"}}}
  }],
  "selections": {"program":{"row_…":"column_…"}},
  "running": {"program":true}
}
```

Rows are stored bottom to top (Composer displays the top layer first). Grid
`selections` and `running` use internal bus keys: `program`, `out2`…`out20`,
with separate A/B maps. Missing row entries mean unset. Runtime output layers expose
`grid_row` and `grid_column`; their numeric layer IDs can change on launch.
Prefer row/column IDs for persistent clients. The external state also exposes
`outputs.out1.selections` and `outputs.out1.running`, and corresponding fields
for other Outs. `active` means the Out exists; `running` means it is started.

`capabilities.gridActions` lists supported action names, alongside
`clipGridVersion`, `sharedClipGrid`, `maxGridRows` and `maxGridColumns`.
Plain clicking to inspect a clip, choosing an Out tab and collapsing panels are
local editor state; they do not launch anything or require API mutations.

### Out A/B workflow

Select an Out, prepare its A and B clip selections, and use `set_crossfade`
with `value` from 0 (A) to 1 (B). Both banks have independent pre-fade JPEG
monitor streams at `/ws/outputs/{bus}/banks/A` and `/ws/outputs/{bus}/banks/B`.
`bus` accepts `out1` through the active Out count (`program` also means Out 1).
The mixed output keeps its existing `/ws/output`, `/ws/output2`, etc. stream.
All streams accept `profile=monitor|normal|hd|mobile`.

`set_fader_sync` accepts `bus` (the selected Out) and boolean `enabled`.
Enabling applies the last known APC crossfader position and follows CC15;
BANK (note 103 / 0x67) toggles sync, with its LED on while synced. Selecting another Out or disconnecting the controller
detaches it. The web slider remains active. `grid.fader_sync` and
`grid.fader_position` expose runtime sync and the last hardware position
(null until moved); sync is not restored on startup.

External state exposes `outputs.outN.banks.A/B` with `selections`, `layers`, and
`frames`, plus `outputs.outN.crossfade`. `launch_clip`, `toggle_clip`,
`launch_column`, and `stop_row` accept `bank: "A" | "B"`, default A.
`outputs.outN.projectors` lists the projector IDs whose mapping surfaces use that Out (deduplicated, excluding muted objects, test grids, and graphic overlays).
The separate Preview bus, `/ws/preview`, `/api/v1/preview`, and old Send/Grab
commands have been removed. Shared saved clips remain available.
PUT `/api/v1/outputs` with `{"count":N}` adds/removes Outs.

The former Show sequencer, global scenes and stack looks remain removed. Their
old commands are rejected. Named grid Shows use the grid actions above;
LED looks remain separate.

## Use the existing controls first

The compact effect/filter list is at the end of **this document**. Follow an
effect link or GET /api/v1/effects/{name} for its parameters, defaults, ranges and
choices. Read the list before writing or uploading custom code.

| Desired change | Existing mechanism |
|---|---|
| One solid color | Load `solid_color`, set `color` to `#rrggbb` |
| Animated two-color wash | Load `gradient`; color_a/color_b, angle, speed, breathe |
| Change colors/levels of existing raster content | Add `color_adjust` above it; exposure, contrast, gamma, saturation, hue, temperature, tint, black/white points |
| RGB split, lens distortion, zoom | Add `lens_adjust` above raster content |
| Moving colored bars | Load or stack `scan_lines`; tint, rate, spacing, width, blur, angle, amount |
| Text, still image, video, camera | Existing `text`, `image`, `video`, `usb_webcam` sources; inspect their parameters |
| Layer strength, compositing, visibility | Grid `set_clip`: opacity and blend; `set_row`: enabled; shared across Outs |
| Stacking and order | Grid `add_row`, `move_row`, `delete_row`; list order is bottom to top |
| Clip selection and launch | Grid `launch_clip`, `toggle_clip`, `launch_column`, `stop_row` |
| Out start/stop | Grid `start_out`, `stop_out`, `toggle_out`; selections are retained |
| Whole-show brightness, color wash or blackout | POST /api/v1/mix; applies across outputs |
| Select which content appears on a card | Mapping rectangle source=out1..out20; source=none mutes it |
| Show a portion of an output on a card | Set that rectangle's `uvs`; retain calibrated `corners` |
| Hide or orient a whole projector | Mapping output.enabled / output.rotation (0, 90, 180, 270); use the Mapping UI to preserve calibration compensation |
| Toggle selected mapper surfaces between Live and Pattern | Press ⌘L in the Mapping UI; selected collections switch as a unit |
| A new procedural design not covered above | Upload AssemblyScript/WASM using the SDK below |

Filters apply to the **composited layers below them**, including rasterized
vectors, not to one mapped card independently. Stacking vectors is allowed and
preserves the existing layers. Master mixer controls are
separate from layer filters. Mapping grids/alignment are calibration tools;
show content belongs in output compositions, not new mapping graphics.

A shared output can carry multiple colors. For example, to give nine
cards nine distinct solid colors, load one nine-band image on an unused output
and map each card's UVs to the interior of its band. Calibrated corners stay
unchanged. Cropping a shared output works for videos and custom animations too.
Full-frame Solid Color is the simpler choice when a whole output needs one color.

## Raster source and filter example

Using the `api` helper from the quick start below:

```js
await api('/outputs/out1', {action:'load', effect:'solid_color',
  params:{color:'#ff8000'}});
const {grid} = await api('/grid');
const column = grid.columns[0].id;
const {result: filter} = await api('/grid', {action:'add_row', name:'Color'});
await api('/grid', {action:'put_clip', row:filter.id, column,
  effect:'color_adjust', params:{exposure:-0.5, saturation:0.8}});
await api('/grid', {action:'launch_clip', row:filter.id, column, bus:'out1'});
await api('/grid', {action:'set_clip', row:filter.id, column,
  params:{hue:30}});
await api('/grid', {action:'set_clip', row:filter.id, column,
  opacity:0.75, blend:'normal'});
// dir:-1 moves one step toward the bottom; +1 moves toward the top.
await api('/grid', {action:'move_row', row:filter.id, dir:-1});
await api('/grid', {action:'delete_row', row:filter.id});
```

`load` replaces the output's entire stack; `add_layer` preserves existing raster
content and appends above it. Do not `load` an adjustment by itself; there would
be nothing beneath it to adjust. Video seek/loop/audio, image scale/position/fit,
text formatting and camera gain/rotation are all ordinary `params` changes.
For image/video `file`, use the file value from GET /api/images or /api/videos,
or the matching choice in the effect detail response. Adding media through the existing
library makes it available to these sources; no new rendering feature is needed.

## Client dials and exposed parameters

Fetch GET /api/v1/effects/{name} for an effect's controls. Use an output layer's
`gen` as the effect name. Each parameter declares name, label, kind, default and,
for numeric controls, min/max/step; choices list their allowed values.
Use the grid clip's `gen` when editing a saved cell. An uploaded effect must
include `manifest.parameters`, even if explicitly []
for no controls. WASM export names alone cannot describe a useful control UI.

A client dial updates a running effect without a module upload or restart:

```js
await api('/grid', {
  action:'set_clip', row:rowId, column:columnId, params:{speed:1.25}
});
```

Use a parameter actually declared by that effect. A request can set several
parameters together. For dragging, start with a 50 ms throttle (20 Hz), keep at
most one request in flight, coalesce pending changes to the newest values, and
send the final value on release. This avoids building a queue of obsolete dial
positions. The current HTTP control returns full state and broadcasts UI updates;
it is not a guaranteed frame-rate modulation stream. Smooth per-frame oscillators
belong inside the effect, driven by the server clock; the dial can control their
speed, depth or offset. Changes also arrive on /api/v1/events and in Vibe's UI.

## Master mixer

POST /api/v1/mix accepts a partial object; omitted settings remain unchanged:

```json
{"video_master":0.8,"blackout":false,"cast":"#ff8000","cast_amount":0.25}
```

Levels (0..1): video_master, led_master, cast_amount. Booleans: video_mute,
led_mute, pulse, strobe, invert, blackout, movie_mode. `cast` is #rrggbb or null.
`sync` is an object with optional clock, video, led offsets (-1000..1000 ms).
These are global controls, not per-card properties. Full current settings are
returned at state.mix in GET /api/v1/state. Invalid fields reject the whole edit.

## Quick start: drive two existing outputs

```js
const base = 'http://127.0.0.1:9120';
async function api(path, body, method = 'POST') {
  const r = await fetch(base + '/api/v1' + path, body === undefined ? {} : {
    method, headers: {'Content-Type':'application/json'}, body: JSON.stringify(body)
  });
  const data = await r.json();
  if (!r.ok) throw new Error(data.error || `HTTP ${r.status}`);
  return data;
}
const state = await api('/state');
const effects = await api('/effects');
// Only change output count when needed. Reducing it clears deactivated outputs.
if (!state.outputs.out2.active) await api('/outputs', {count:2}, 'PUT');
const {grid} = await api('/grid');
const first = grid.columns[0].id;
const second = grid.columns[1]?.id || (await api('/grid', {action:'add_column'})).result.id;
const {result: row} = await api('/grid', {action:'add_row', name:'Base'});
await api('/grid', {action:'put_clip', row:row.id, column:first,
  effect:'solid_color', params:{color:'#ff8000'}});
await api('/grid', {action:'put_clip', row:row.id, column:second, effect:'gradient'});
await api('/grid', {action:'launch_clip', row:row.id, column:first, bus:'out1'});
await api('/grid', {action:'launch_clip', row:row.id, column:second, bus:'out2'});
await api('/grid', {action:'start_out', bus:'out1'});
await api('/grid', {action:'start_out', bus:'out2'});
```

Outputs out1..out20 are content buses, NOT projectors. Existing mapping rectangles
choose which output they display. A projector can contain rectangles from several
outputs. Output commands never change mapping geometry or calibration. Read
mappings before deciding which output to drive. This example adds one shared
row with different selected clips on the two Outs; other rows keep their
selections. Active clients share control; the last accepted edit wins. The UI
receives the same authoritative state and shows external effects.

## Optimize library videos

POST **/api/v1/media/preprocess** (no body required) starts a background scan of
all current library videos. Returns HTTP 202 and job status immediately. Repeated
requests while running return the same job; they do not enqueue another scan.
GET **/api/v1/media/preprocess** returns status; poll every two seconds.
The same action is in Settings → Videos → Optimize new videos.

Status includes `state` (idle/running/completed/completed_with_errors/failed),
`total`, `completed`, `processed`, `skipped`, `failed`, `currentFile`, `errors`,
and job timestamps. Errors include the failed file; other files continue.
A later POST rescans, skips valid unchanged copies, and retries missing, invalid,
changed or failed videos. New videos arriving during a job are picked up next run.

Creates aspect-preserving 540p/1080p H.264 MP4 copies at 30 FPS with one-second
keyframes. Originals and mapping geometry are preserved. The renderer chooses a
suitable cached size automatically. Completed work is saved after each video;
job status is in memory and resets on server restart. Restarting stops the worker;
run again to resume from valid cached copies. Processing uses one worker with
limited ffmpeg threads and lower process priority, but still consumes CPU/disk.
When a job finishes, new copies are sent to the renderer; affected playing videos
may restart as their decoder switches to the optimized file.

## Network and WLED discovery

GET **/api/v1/network** reports the Vibe hostname, serverPort, network interfaces
with their IP addresses and link status, and the configured `wled` controller:

- `host`, `url` (open the WLED UI), `infoUrl`, `transport`, `udpPort`.
- `online`, `checkedAt`, `sampleAgeSeconds`, `latencyMs`, `error`.
- WLED-reported `name`, `version`, `ip`, `ledCount` when reachable.
- Physical `fixtures` with id, label, enabled, start and count.

The server checks WLED's `/json/info` with a two-second timeout and caches the
result for five seconds. `online` means WLED HTTP responded with device info
from the Vibe host; it does not prove UDP delivery, physical LED operation, or
reachability from the client's network. A failed check returns `online:false`
and an error rather than failing the whole endpoint. Strip `enabled` is Vibe's
routing state, independent of network availability. No network scan is performed.
Use `/api/v1/state` for LED compositions and mixer/mute settings; `/api/v1/stats`
for system and renderer performance. `/state.links.network` advertises this route.

POST **/api/v1/fixture-output/discover** performs an explicit, read-only WLED
scan. The native **LEDs → Scan for WLED** button calls this endpoint in a
background worker. It browses `_wled._tcp` with Bonjour, probes the configured
host, and checks directly attached private IPv4 ranges (at most the local /24
per interface, 512 candidates total). VPN and loopback ranges are excluded;
self-assigned interfaces are reported without sweeping the link-local /16.
The scan takes up to roughly 22 seconds, with bounded HTTP concurrency.

The response contains `devices` (`name`, `host`, actual UDP `port`, `httpPort`,
`version`, `ledCount`, `mac`, `url`, `online`), `interfaces`, `warnings`,
`probed`, `candidates`, `complete`, and `checkedAt`. Each result is verified with
WLED's `/json/info`; the HTTP service port is not used as the LED UDP port.
Discovery does not change a destination or start output. Stop WLED, choose
**Use**, then **Start WLED** to select another controller. Results describe the
last scan, not continuous monitoring. Controllers without an assigned IP need
DHCP or a static address before discovery can reach them.

`python3 scripts/find_wled.py` covers those cases offline. It runs the same checks
(saved addresses, Bonjour, the local /24 of every connected interface) and, when
they find nothing, repairs a wired link that has no DHCP server: it moves the
Mac's adapter onto the subnet of a controller heard over Bonjour, or sets the
adapter to 192.168.77.1 and answers the controller's DHCP request with a one-off
lease, then offers to save that address on the controller. It never answers DHCP
on a network that already has a server, prints the undo command for each change,
and points VJ at the controller it finds. `--look` only looks.

## System and renderer statistics

GET **/api/v1/stats** is the lightweight monitoring endpoint (also linked in
Settings → API). Poll about once per second. It reports:

- system.cpuPercent (whole machine, 0..100), logicalCpus, loadAverage,
  memory availability/usage, swap usage, disk free space, uptime.
- processes: Vibe server and native renderer PID, CPU percent, RSS bytes and
  thread counts. Process CPU can exceed 100% when using multiple cores.
- renderer.connected / stale / sampleAgeSeconds. Treat stale metrics as last
  known values, not a current performance measurement.
- renderer.metrics.presentFps and targetFps; native samples span about 2 seconds.
- renderer.metrics.graph: frames, renderMsEma, renderMsMax, missedDeadlines,
  decoderUploads, monitorReadbacks, renderSizes per bus, and sources with decoder
  backends, dimensions, playhead/decoded timestamps, decodeLagSeconds and errors.

System samples update about once per second. CPU is null until an initial
sampling interval completes. GPU utilization is currently null (unavailable).
Graph render timing is CPU-side submission time, not a GPU timer. Max timing and
missed-deadline counters are cumulative since renderer startup; compare deltas
across samples. Decode lag is signed and can jump at loops/seeks. Presentation FPS
alone does not prove that every video decoded a fresh frame.

Vibe supports **up to 20 independent output buses**. This is a routing limit,
not a promise that the device can decode 20 videos at full frame rate. Use stats
to assess your media and hardware. Increasing the limit does not activate or
replace outputs; PUT /api/v1/outputs {"count":N} chooses the active count.

## Endpoints

| Method | Path | Request / response |
|---|---|---|
| GET | /api/v1/docs | This complete Markdown guide |
| GET | /api/v1/stats | System load, renderer FPS/timing, render sizes and decoder status |
| GET | /api/v1/state | Device, capabilities, displays, all outputs, mapping snapshots, full Vibe state, upload history |
| GET | /api/v1/grid | Shared grid, per-bus selections, start/stop state and revision |
| POST | /api/v1/grid | One grid action from the table above; returns updated grid, revision and result |
| GET | /api/v1/effects/{name} | One effect/filter, including its parameter schema |
| GET | /api/v1/effects | Live catalog with kind, adjustment/vector/exclusive flags, parameters and blend modes |
| GET | /api/v1/effects/{name}/wasm | Download current WASM for a built-in/uploaded vector effect |
| GET | /api/v1/animations/{id} | Manifest, stable identity, revision, module URL and timestamps |
| GET | /api/v1/animations/{id}/wasm | Download uploaded effect's current WASM |
| PUT | /api/v1/animations/{id} | `{revision,manifest,wasmBase64}`; replace in place, update loaded instances (200) |
| GET | /api/v1/animations | `{animations:[entry]}`; uploaded modules and latest used parameters |
| POST | /api/v1/animations | `{manifest,wasmBase64}`; validates, archives and registers module; returns entry (201) |
| POST | /api/v1/mappings/{1\|2}/rects | Create surface or clipped overlay; requires mapping revision |
| POST | /api/v1/mix | Partial mixer settings; returns state |
| PUT | /api/v1/outputs | `{count:1..20}`; activates that many output buses; returns state |
| POST | /api/v1/outputs/out1 | One action below; out1 through out20 supported; returns state |
| GET (WebSocket) | /api/v1/events | Initial full state, then full snapshots at approximately 4 Hz; read-only |
| GET | /api/v1/sdk/abi.ts | AssemblyScript vector SDK (ABI 1) |
| GET | /api/v1/sdk/graphics-v2.ts | Rich vector SDK (ABI 2) |
| GET | /api/v1/sdk/math.ts | Optional math helpers |
| GET | /api/v1/sdk/example.ts | Complete runnable rotating-line example |
| GET | /api/v1/sdk/runtime.js | Browser preview runtime; global `VibeVector` |

Output actions (JSON). For saved clip slots and shared rows, use `/grid` above:

Layer and surface blend modes include `subtract`: `max(0, destination - source × alpha × opacity)`. A white-on-black Syphon visualization above a solid-color layer cuts black shapes into that color. Black pixels leave the base unchanged. Set the shared row with `{action:"set_row", row, blend:"subtract"}` or use `set_layer` / `set_clip`; the UI exposes the same mode.

`laser_text` is a vector effect with `content`, `font`, `color`, `line_width`,
`glow_width`, `brightness`, `size`, `x`, `y`, `pulse`, and `speed` parameters.
It outlines the bundled fonts with a bright core and colored glow. Text supports
up to 256 characters and newlines (including literal `\n`); longer content is
truncated for rendering. Long names and multiple lines automatically fit the
canvas at the default centered position. `pulse: 0` gives steady text; `speed`
sets pulse cycles per second. All controls are available through the effect API.

`cube` and `vector_cube` accept `pose_x`, `pose_y`, and `pose_z` in degrees
(-180 to 180), applied in X, then Y, then Z order. Set `speed: 0` for a fixed
pose. The orientation widget writes these four parameters together through
`/grid` `set_clip`; `rotate_x/y/z` remain the automatic rotation rates.

```json
{"action":"load","animationId":"ID_FROM_UPLOAD","params":{"speed":1}}
{"action":"load","effect":"vector_cube","params":{"speed":1}}
{"action":"params","params":{"speed":0.5}}
{"action":"params","layerId":"LAYER_ID_FROM_STATE","params":{"speed":0.5}}
{"action":"add_layer","effect":"color_adjust","params":{"exposure":-0.5}}
{"action":"set_layer","layerId":123,"opacity":0.5,"blend":"screen","enabled":true}
{"action":"move_layer","layerId":123,"dir":-1}
{"action":"remove_layer","layerId":123}
{"action":"start"}
{"action":"stop"}
{"action":"toggle"}
{"action":"pause"}
{"action":"play"}
{"action":"restart"}
{"action":"mute","muted":true}
{"action":"mute","muted":false}
{"action":"clear"}
```

`load` and `add_layer` create a shared grid row with a clip in its first column,
selected on this Out. `load` first clears this Out's other selections; it retains
their saved rows and clips. `params` defaults to the top selected layer; optional
numeric `layerId` targets a specific runtime layer. Parameter names, types and
limits come from /effects/{name}; invalid values return 400. These parameter
edits update the saved clip and all Outs selecting it. `set_layer` and
`move_layer` change the shared row's settings/order. `remove_layer` only unsets
that row on this Out; use grid `delete_row` to delete the saved layer everywhere.
`clear` unsets every row on this Out, retaining the grid and its running state.

`start`, `stop` and `toggle` operate the same Out control as Composer and grid
`start_out`, `stop_out`, `toggle_out`. `mute:true` is an alias for stop;
`mute:false` starts the Out. They preserve selections and shared row enablement.
The older `play`, `pause`, `restart` actions operate only the animation clock:
play resumes it, pause freezes it, restart resets it to time/beat zero. They
do not start/stop an Out or control a video's media transport. Use a saved
video clip's `playing`, `position` and `seek_nonce` parameters for that.
An optional `revision` on any output action must match state.revision, otherwise
409 returns without applying the action. This revision concerns content state;
geometry has its own revision per mapping. Inactive outputs return 400.
Accepted commands return authoritative state, not a guarantee that a physical
projector has rendered a frame. Check projectors.error for renderer availability. projectors.vectors[out1..out20]
reports {ready,error,module} from the native renderer; compare module to the
recipe URL to distinguish a pending update from a rendered one.

## State schema and geometry

`GET /state` and event messages return:

- apiVersion: 1, type: "state", revision: content revision.
- device: hostname, platform, architecture, uptimeSeconds.
- capabilities: vectorAbis [1,2], maxModuleBytes, maxParameters, maxOutputs,
  clipGrid, clipGridVersion, sharedClipGrid, gridActions, maxGridRows, maxGridColumns;
  liveFrameInput and shaderUpload are false in this version.
- projectors: {displays:[...], error:null|string}. Displays contain native
  identity, physical index, mapping id, name, dimensions and desktop viewport.
- outputs: out1..out20, each {active, running, internalBus, selections, layers, clock, vector}.
  out1's legacy internal name is "program"; API callers should use "out1".
  `vector` is null for raster/empty/disabled/stopped content, otherwise a complete recipe.
- mappings: keyed by mapping id; each {mappingId, revision, project, vectorBuses,
  ...}. project contains output settings, rects, traces, and editor selection.
- state: Vibe state including the shared grid, buses, master mix, fixtures,
  LED looks, BPM, clock/link state, and vector recipes.
- history: upload entries, with manifest, module URL, effect name, id, createdAt;
  lastUsedAt, lastOutput and lastParams appear once played through this API.

Each mapping rectangle includes ordered `corners` and corresponding `uvs`,
`source` (out1..out20 or none), mode, opacity/blend/fit settings as applicable,
and calibration provenance (`origin: "calibration"`). Corners are normalized
editor coordinates, x right, y down. `project.output.rotation` is 0, 90, 180,
or 270 degrees clockwise and rotates the rendered output. Calibrated editor
coordinates compensate for the rotation so their physical positions stay
fixed; use the Mapping UI when changing rotation to preserve that compensation.
Keep corner/UV pairs in order; do not reorder by top-left. UVs follow the mapping
renderer texture convention (default [[0,1],[1,1],[1,0],[0,0]]). For an accurate
mapped preview, reuse Vibe's mapping renderer rather than guessing UV orientation.
Mapping output.enabled=false hides the whole projector. Rectangle source=none
mutes that rectangle even in grid mode. Output grids and LED traces are separate.
The surface list's `M` button toggles this mute. `mutedSource` retains the prior
Out while `source` is `none`, so unmute restores it. To perform the same toggle
through a mapping commit, save the current source into `mutedSource` and set
`source:"none"`; unmute by restoring `source` from `mutedSource` (default `out1`).
Changing the Source selector while muted updates `mutedSource` without unmuting.

GET /mapping/1 and /mapping/2 are existing interactive mapped previews. They
include native geometry, fit, rotation and vector rendering. They also permit
editing, so embed them only when that is intended. Source modules are served at
/mapping/js/ and /mapping/graphics.js for clients implementing their own preview.

## Overlay rectangles: continuous content across cards

An ordinary rectangle has kind="surface" (the default). A kind="overlay"
rectangle plays one continuous output across its area, clipped to the union of
ordinary surfaces **earlier in project.rects**. The overlay's own polygon also
clips it. Spaces between cards remain untouched; on an otherwise black output
they stay black. Existing content beneath uses the selected blend: normal covers
it, multiply multiplies it, add/screen combine it. Later rectangles draw on top.
This layer order applies to raster and vector sources alike.

Muted surfaces (source="none") still contribute their geometry to the mask.
An overlay does not add new mask area. With no earlier surfaces, it draws
nothing. Masks update when shapes move, reorder, or are deleted. Masking stays
within one projector. Traces and the optional bounds grid are separate overlays.
Calibrated corners and their rotation compensation are unaffected.

Manual UI: Mapping → **+ Add → Overlay** (purple boundary), select an output and blend.
The type dropdown also converts selected rectangles between Surface and Overlay.
**↓ / ↑** moves the selected layer(s). The UI lists the top layer first;
the API's `project.rects` remains bottom to top.

API creation appends a new manual rectangle at the top:

```js
const state = await api('/state');
const created = await api('/mappings/1/rects', {
  revision: state.mappings['1'].revision,
  kind:'overlay', name:'Video across cards', source:'out2', blend:'normal',
  corners:[[0.05,0.05],[0.95,0.05],[0.95,0.95],[0.05,0.95]]
});
// created.rectId; created.mapping is the committed mapping snapshot.
```

POST /api/v1/mappings/{1|2}/rects accepts revision (required), kind
(surface/overlay), name, source, blend, fit, corners, optional uvs. It returns
201 {rectId,mapping}; stale/missing revision returns 409 without mutation.
Defaults: full-frame quad, full-frame UVs, surface, out1, normal, stretch, live.
Coordinates must be finite normalized [0,1] pairs. Non-quads require corresponding
UVs. Existing rectangles and calibration geometry are preserved. To modify,
reorder or delete later, use the revisioned mapping protocol below.

## Edit routing and UV crops through the existing mapping protocol

Connect to /ws/state?mapping=1 (or 2). The first message is a mapping_snapshot.
Copy its complete project, preserve corners and unknown fields, and edit only
the selected rectangle sources/UVs. Send:

```js
socket.send(JSON.stringify({
  type:'mapping_commit', clientId:'my-client', commitId:'unique-edit-id',
  baseRevision:snapshot.revision, project:editedProject,
  nextRectId:snapshot.nextRectId,
  nextTraceId:snapshot.nextTraceId
}));
```

Wait for the matching commitId; rejected:true means the edit did not apply.
On a stale revision fetch the new snapshot and reapply the intended changes;
do not overwrite it with an old whole-project copy. Successful commits persist
and update the Mapping UI and renderer. Use mode=live for output content.
Example UV crop for a vertical color band between u=0.1 and u=0.2:
`[[0.1,1],[0.2,1],[0.2,0],[0.1,0]]` for a rectangle using the default corner/UV
ordering. For nondefault UV layouts transform existing u values into the band
instead of replacing the vertex ordering. Leave a small margin inside the band
to avoid sampling neighboring colors. Modifying UVs changes content sampling;
modifying corners changes physical geometry. Keep calibrated corners intact.

## Author a custom animation

Write AssemblyScript (TypeScript-like syntax), compile on your development
machine to WebAssembly, then upload the bytes. The receiving machine needs no compiler or redeploy.
Download /api/v1/sdk/example.ts to effects/example.ts and /api/v1/sdk/abi.ts to
sdk/abi.ts. In that working directory:

```sh
npm install --save-dev assemblyscript@0.28.20
npx asc effects/example.ts --outFile example.wasm --optimize --runtime stub --noAssert
```

The complete example served by the API exports these functions:

```ts
abi_version(): i32          // 1 or 2, must match manifest
params_ptr(): usize        // float32 parameter buffer address
params_capacity(): i32
commands_ptr(): usize      // float32 drawing command buffer address
commands_capacity(): i32
render(time: f64, beat: f64): i32 // write commands; return float count (not bytes)
```

Export linear memory. Import only env.abort(i32,i32,i32,i32); the supplied SDK
and compile command produce this contract. No DOM, filesystem, network, WASI or
native machine code. Parameters are float32 values in manifest array order;
there are no implicitly appended parameters. Pass aspect ratio as an explicit
parameter if your design needs it. Coordinates use normalized content space
(0..1 across width/height); stroke sizes are fractions of content height. Call
beginFrame, emit a bounded command sequence, return finishFrame. The host applies
mapping after evaluating your geometry. Derive motion from time/beat for matching
previews and reliable seeking; avoid relying on frame count or accumulated state.

ABI 1: style (RGBA core/glow and widths), moveTo, lineTo, closePath.
ABI 2 additionally supports per-vertex colors/widths, cubic Bézier curves and
Gaussian splats. Download graphics-v2.ts for exact function signatures.
The SDK buffers hold 65,536 floats. Never exceed that capacity in a frame.
The runtime enforces 5 million Wasmtime fuel units per frame and 64 MiB memory.
Uploads are compiled and sampled at several times before acceptance. This does
not prove that every possible time/parameter combination will render correctly.

Upload from Python (stdlib only):

```python
import base64, json, urllib.request
base = 'http://127.0.0.1:9120'
def post(path, value):
    req = urllib.request.Request(base + '/api/v1' + path,
        data=json.dumps(value).encode(), headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req) as response:
        return json.load(response)
entry = post('/animations', {
    'manifest': {
        'name':'Rotating line', 'description':'A client-authored vector animation',
        'abi':1, 'lineCap':'round',
        'parameters':[{'name':'speed','label':'Speed','default':1,
                       'min':0,'max':4,'step':0.01}]
    },
    'wasmBase64':base64.b64encode(open('example.wasm','rb').read()).decode()
})
post('/outputs/out1', {'action':'load','animationId':entry['id'],'params':{'speed':1.5}})
```

Manifest: name (1–100 characters), optional description, abi 1 or 2, optional
lineCap round/butt, required parameters (0–64 entries; explicitly [] for none). Each parameter has unique name
matching [a-z][a-z0-9_]{0,39}, optional label, finite numeric min/max/default and
positive step. All custom controls are numeric sliders; encode switches as 0/1.
Modules are limited to 2 MiB. Bad requests/modules return `{error:"..."}` with 400.
Identical POST uploads reuse the current matching entry. POST with changed code
or manifest creates a new entry. Use PUT `/animations/{id}` to replace an existing
effect while keeping its identity; versioned module URLs prevent stale cache reuse.

## Read and replace an uploaded effect

Use `GET /api/v1/effects/{name}/wasm` to download an effect's current raw WASM
(`application/wasm`). This works for built-in vector effects and uploaded effects;
raster effects have no WASM and return 404. Effect detail/catalog entries advertise
`wasm`, and uploaded effects also advertise `animationId` and `animation`.
WASM is compiled code; keep the original AssemblyScript sources locally for edits.

For uploaded effects, `GET /api/v1/animations/{id}` returns the manifest, stable
`id`/`effect`, `revision`, `contentHash`, versioned `module` URL, and timestamps.
`GET /api/v1/animations/{id}/wasm` downloads the current bytes.

**To edit an existing upload, use PUT instead of POST:**

```js
const existing = await api('/animations/' + animationId);
const response = await fetch(base + '/api/v1/animations/' + animationId + '/wasm');
const wasmBytes = await response.arrayBuffer(); // download for inspection or backup
// Edit your local source, rebuild, then upload the compiled replacement:
const updated = await api('/animations/' + animationId, {
  revision: existing.revision,
  manifest: revisedManifest,
  wasmBase64: rebuiltWasmBase64
}, 'PUT');
```

PUT requires both the complete manifest and WASM, plus the latest animation
revision (not the global state revision). It validates the replacement before
publishing and returns 200 with the updated entry. Missing/stale revision returns
409; an unknown ID returns 404; invalid modules/manifests return 400 without
replacing the current version. Identical content with the current revision is a
no-op. Concurrent replacements are serialized and stale writers are rejected.

The effect keeps its identity and one library entry. All loaded instances update
immediately, across Out banks, without resetting layer IDs, source IDs, opacity,
blend, enabled state or playback clocks. Existing parameter values are preserved
by name and clamped to new ranges; added parameters take defaults; removed
parameters disappear. Saved grid clips, including unselected cells, are updated
to the current parameter schema and retain their effect identity. Shared row
settings, saved slots and per-Out selections stay in place.

Each accepted version has a different module URL, so native and browser renderers
reload it without a renderer restart. Bytes are written first and the current
manifest pointer is replaced atomically. Prior versioned module URLs remain
readable. The latest version and current session persist across server restarts.
Built-in effects are readable but cannot be overridden with PUT; upload an edited
copy as a new effect first. POST `/animations` remains the explicit create action;
use PUT for subsequent edits to avoid duplicate library entries.

## Live browser preview and synchronization

Load a script from BASE/api/v1/sdk/runtime.js, then:

```js
const canvas = document.querySelector('canvas');
const monitor = new VibeVector.CanvasMonitor(canvas);
const events = new WebSocket(base.replace(/^http/, 'ws') + '/api/v1/events');
events.onmessage = ({data}) => {
  const snapshot = JSON.parse(data);
  const recipe = snapshot.outputs.out1.vector;
  monitor.setRecipe(recipe && {...recipe, module:new URL(recipe.module, base).href});
};
// On teardown: events.close(); monitor.destroy();
```

This previews the content bus; mapped previews also need the mapping geometry.
The runtime extrapolates seconds/beat from each received clock snapshot. Network
latency can cause a small preview offset; this is not frame-locked multi-host sync.
The projectors render locally even if the authoring client disconnects.

## Persistence and existing media

Uploads are automatically archived under the server's state directory in
external-animations/ (module bytes, manifest, last API-used parameters). They
reload at startup and appear in Vibe's vector library without refreshing the UI.
The shared grid, saved clips, per-Out selections and start/stop states are
autosaved in session.json and restored after a server restart. History is
not a recording of every parameter change; it keeps the latest API-used settings
per distinct module/manifest. Reuse an animationId to load a historical upload.

Built-in image/video effects can also be loaded via /effects names and parameter
schemas. Existing GET /api/videos and /api/images list local media; existing
POST /api/videos/upload accepts the Vibe video-upload workflow. This API does not
yet accept a live canvas/video stream or arbitrary shader programs.

This is the same trusted-LAN control model as Vibe's UI: no API credentials.
CORS is enabled for the external API and preview modules for local browser apps.
Use the reachable device URL as BASE; hostname metadata is informational and
is not automatic device discovery. No secrets or SSH configuration are exposed.

## Syphon live sources

On macOS, `GET /api/v1/sources/syphon` discovers live application feeds.
Use an entry's `selection` string as `params.source` with `effect: "syphon"`
in output or clip-grid commands. `GET /api/v1/effects/syphon` lists its controls.
Selections survive sender restarts; discovery does not start reception.
See `docs/syphon.md` for receiver behavior and build details.

## NDI live sources

`GET /api/v1/sources/ndi` discovers local and network feeds. Optional `extra_ips`
is a comma-separated list of remote IP addresses. Use a result's `selection` as
`params.source` with `effect: "ndi"` in output and clip-grid commands.
`GET /api/v1/effects/ndi` lists the controls. See `docs/ndi.md` for runtime setup.
[NDI®](https://ndi.video/) is a registered trademark of Vizrt NDI AB.

### NDI projector feeds

Four mapping workspaces are available (`1`–`4`). `GET /api/v1/ndi/projectors`
returns `projectors`, projector `ids`, per-feed `status`, and `rendererConnected`.
`PUT /api/v1/ndi/projectors` replaces all publishing settings:

```json
{"1":{"enabled":true,"name":"Stage Left","width":1280,"height":720,"fps":30}}
```

Feeds contain the complete mapped projector picture, including multiple buses,
masks, overlays, grids, rotation, and projector blackout. No physical display is
required. Names are unique; dimensions are even (64–1920 × 64–1080), fps 1–60.
`{}` disables publishing. Video only. The former `/api/v1/ndi/outputs` API is
removed; old saved bus 1–4 publishers migrate to corresponding projectors.


### VJ NDI clients

- `GET /api/v1/ndi/clients`: master identity, discovered/remembered clients,
  settings URLs, online state, logical inputs, current sources and assignments.
- `PUT /api/v1/ndi/clients/{clientUUID}/inputs/{display-1..display-4}` with
  `{"projector":"2"}` enables the projector publisher and assigns its feed.
  `{"projector":null}` disconnects only that client input. The response is the
  updated client. Unavailable publishers or clients return an error.
- `POST /api/v1/ndi/clients/{clientUUID}/restart`: restart the client's display
  player using its saved settings.

Receiver HTTP service (default port 9110): `GET /api/v1/receiver` returns its
UUID, name, version and inputs. `PUT /api/v1/receiver/inputs/{input}` accepts
`source` (the standard serialized NDI selection), `managed` (null or
`{"master_id":"UUID","projector":"2"}`), and optional `expected` previous
binding. A mismatched `expected` returns 409, preventing background reconciliation
from overwriting a manual assignment. These LAN controls preserve the existing
same-origin restriction on browser writes.


The client input PUT also accepts `{"rotate_180":true}` (or false), independently
of `projector`. Omitting `projector` preserves the existing feed and management
binding. Both fields can be supplied together. The receiver input PUT accepts
this same rotation flag independently of `source`; snapshots report saved
`rotate_180` and the player's `rotation_applied` state. Rotation is client-local.

### Reset projector mappings

Fresh installations enable four output buses and initialize each projector with
one full-screen live surface: Projector 1 → Out 1, through Projector 4 → Out 4.
Existing saved mappings and output counts are preserved on load.

`POST /api/v1/mappings/reset` accepts `{"revisions":{"1":0,"2":0,"3":0,"4":0}}`,
using the current revisions from `GET /api/v1/state`. It replaces all four working
layouts with these defaults, clears traces, resets projector orientation and
visibility, and enables at least four outputs. Saved layout presets, clips,
NDI publishers and client assignments are retained. Stale revisions return 409.
The UI action is **Settings → Projectors → Reset to full screen**; Mapping also
has a **Reset to full screen** action for the current projector only.

### Planar surface collections

Mapping projects now contain `collections` alongside `rects` and `traces`.
A collection owns shared content and layout. Its faces reference stable surface
IDs in `rects`; these are editable projector geometry, not separate content
assignments. The server resolves each face's source and UVs before broadcasting
the project, so the browser, native projectors and NDI use the same geometry.
Do not override a collection face's source, fit or UVs directly.

`GET /api/v1/mappings/{1..4}/collections` returns `{collections, revision}`.
All mutations require that mapping's current integer `revision`; conflicts
return 409 without applying changes.

- `POST /api/v1/mappings/{mid}/collections`: `{revision, rectIds, name?, content?}`.
  Creates a planar collection from ungrouped quadrilateral surfaces.
- `PATCH /api/v1/mappings/{mid}/collections/{id}`: `{revision, name?, content?, enabled?, referenceFaceId?, offset?}`.
  `content` is `{kind:"out", source:"out1", layout:"repeat"}`. Source supports
  `out1`–`out20`; layout supports `repeat` and `span`.
  `offset: [dx, dy]` translates all faces in normalized projector coordinates,
  limited as a group to the projector bounds.
- Collection `content.rotation` accepts 0, 90, 180, or 270 degrees for planar
  and point collections. The inspector's **Rotate direction 90°** button cycles
  these values, exchanging horizontal and vertical content directions without
  moving surface corners, curvature pins, or masks. It affects media, per-face
  effects, and repeated/spanned content; box collections retain their 3D axes.
  Include the existing `content.kind`, `source`, and `layout` when replacing
  `content` through the collection PATCH API.
- `DELETE /api/v1/mappings/{mid}/collections/{id}`: `{revision, removeFaces?}`.
  Default: ungroup, retaining the resolved face geometry and UVs.
  `removeFaces: true` deletes the collection and its faces.

Mutations return the committed mapping snapshot. The revisioned mapping
WebSocket protocol also accepts the full collection document:

```json
{
  "id": "collection-example",
  "name": "Cards",
  "kind": "planar",
  "origin": "manual",
  "content": {"kind":"out", "source":"out1", "layout":"span"},
  "enabled": true,
  "plane": {"space": "projector"},
  "faces": [
    {"id": "face-a", "rectId": "rect-1", "planeCorners": [[0,0],[1,0],[1,1],[0,1]]}
  ]
}
```

`planeCorners` are coordinates in the collection's shared plane, independent
of projector corners. Repeat maps the whole source onto every face. Span maps
one source across the plane's bounding box, masked by the faces; gaps remain
empty. Both modes use Warp (stretch). Geometry edits move the projection while
retaining face texture coordinates. One surface can belong to only one
collection. Faces must remain quadrilaterals.

Calibration imports one collection per calibrated projector, using the saved
camera corners for the initial plane layout. Manual grouping starts in projector
coordinates. `referenceFaceId` rectifies the plane using a chosen rectangular
face (corner order TL, TR, BR, BL); this assumes the other faces are coplanar.
This is not physical dimension measurement or 3D reconstruction. Existing saved
calibration surfaces migrate to a collection in projector coordinates without
moving their corners. Independent surfaces and overlays remain supported.

Only `kind: planar` is implemented. Face identities and plane coordinates are
kept separately to allow future box topology and adjacency without coupling
that data to calibration or to render order.

Collection `content` is separate from face geometry and plane coordinates.
Only `content.kind: out` is currently supported; geometry-aware collection
effects can add a content kind without changing composer output routing.

### Surface collection effects

`triangulate_faces`, `glow_faces`, and `flash_faces` are typed clips with
`collectionGeometry: "faces"`. Create, launch, reorder, blend and edit them
through the usual grid API. A planar collection receiving that Out evaluates
the complete layer stack at its destination. Other content still repeats or
spans normally; unsupported destinations skip these layers without replacing
the ordinary Out video. Projector NDI includes the rendered effects.

`sphere_gimbal` is a `collectionGeometry: "boxes"` effect. It treats the box
surface as a sphere direction map and draws sharp, single-color trails around
one equator. `trails` controls the number of equally spaced trails, `speed` is
revolutions per second (0–60), `tail` is a fraction of the orbit, and `width`
sets the line width. `fade_start` sets the point in the tail where dimming begins;
`tail_fade` sets its strength (0 keeps a solid tail, 1 fades to black). `spread`
(0–0.25) offsets each trail to a stable,
parallel path on either side of the equator. The speed slider uses an
exponential scale for finer control at low speeds while preserving zero and
the 60 rev/s maximum. `pose_x/y/z` orient
the gimbal in degrees; the Composer orientation widget edits these values.
`rotate_x/y/z` are optional degrees per second and default to zero. `brightness`
and `color` set the laser line. All
parameters are available through `/api/v1/effects/sphere_gimbal` and the usual
grid or output `params` action.

**Triangulate Faces** connects face centers with a Delaunay graph in the shared
plane. `line_ends: "edges"` clips lines and their halos against every face;
`edge_margin` (0–80 pixels at 1080p) adds clearance outside each face, including its halo.
`"centers"` lets the lines continue across cards. Parameters:

- `color`, `lines`, `thickness`, `glow`, `glow_radius`.
- `pulses`, `pulse_mode` (`wave` or `route`).
- `pulse_start` (`center`, `first`, `last`, `random`, `face`) and `start_face`.
- `pulse_end` (`farthest`, `first`, `last`, `random`, `face`) and `end_face`;
  these apply to route mode.
- `pulse_direction` (`forward`, `reverse`, `bounce`), `pulse_speed`,
  `pulse_rate`, `pulse_width`, `pulse_amount`, `sparkle` (Crackle).

Face selectors accept a stable collection face ID or a face name; names use the
first match. Invalid/missing start names fall back to the central face; end names
fall back to the farthest reachable face. First/last use collection face order.
Pulses follow shortest weighted graph paths. Waves branch across the graph;
route mode highlights one start-to-end path. Random endpoints change between
bursts. An unreachable endpoint falls back to the farthest reachable face.
Speed is normalized plane distance per second, rate is pulses per second,
width is a fraction of a pulse cycle. Time follows the Out's clock.

**Glow Faces** fills each card independently using `color`, `brightness`,
`center_glow` and `falloff`. Center glow `0` is a solid fill; `1` fades from the
center to the card edges. It is a separate clip, with independent opacity and
blend mode. Center circles are superseded by this face-fill effect.

**Flash Faces** (`flash_faces`, `collectionGeometry: "faces"`) fills each face
independently on planar, box, and point collections. Launch it on the Out feeding
the collection; ordinary video destinations skip it. Edit its parameters through
the usual clip/layer API; the same schema drives the UI.

- `pattern`: `alternate` rotates colors across face order; `chase` lights one face
  at a time; `shuffle` picks new colors together; `scatter` gives faces independent
  offsets; `strobe` flashes all faces together; `wave` sweeps a soft pulse across faces.
- `theme`: `neon`, `ice`, `fire`, `candy`, `rgb`, or `custom`.
- `colors`: 2–6 palette entries. Custom uses `color_a` through `color_f` in order.
- `speed`: 0–16 steps per second (default 2); 0 freezes the phase.
- `on_time`: lit fraction of each step, .05–1 (default .8). Set 1 for uninterrupted
  color alternation. `fade`: 0–1, from hard cuts to softened pulses/color changes.
- `brightness`: 0–1; `seed`: 0–999 for repeatable Shuffle/Scatter variation.

Timing uses the destination Out clock. Unlit faces are black with normal blend;
Add/Screen allow underlying layers to show through. Numbered controls are Speed,
Pattern, Theme, Colors, On time, Fade, Brightness, Seed. Custom colors remain
available in the full parameter editor and API.


These effects respect Out layer order, adjustment layers and the master mixer.
Opaque content above them covers them on faces. Lines in gaps remain visible
because ordinary mapped content has no coverage there. Mapping shows the native
composite while these effects are active (`GET /api/mapping/{1..4}/frame`),
including geometry-aware layers and traces. Read the live effect schemas for
parameter ranges/defaults and numbered performance controls.

### Shared mapping layouts

Mapping layouts are named templates shared by every projector, separate from
clip sets and shows. They contain `rects`, `traces`, `collections`, and `groups`, including
positions, geometry, UVs, patterns, Out assignments, and collection relationships.
They exclude projector output settings, editor selection, physical display
assignment, NDI configuration, and clips. Loading replaces the destination's
objects with an independent copy and preserves its output settings.

- `GET /api/v1/mapping-layouts`: `{revision, layouts:[{id,name,rects,traces,collections,groups}]}`.
  The four object fields are counts.
- `GET /api/v1/mapping-layouts/{id}`: `{id,name,objects,revision}`.
- `POST /api/v1/mapping-layouts`: save `{name,mappingId,revision,libraryRevision}`.
  `revision` is the source mapping revision; `libraryRevision` comes from the
  library GET. Names are unique, case-insensitively, and 1–200 characters.
- `PUT /api/v1/mapping-layouts/{id}`: explicitly update the saved template using
  the same body as POST. Ordinary live mapping edits never update a template.
- `DELETE /api/v1/mapping-layouts/{id}`: `{libraryRevision}`. Loaded mappings
  remain intact. Library mutations return `{id,revision,layouts}`.
- `POST /api/v1/mappings/{mid}/load-layout`:
  `{layoutId,revision,libraryRevision}`. Here `revision` is the destination's
  mapping revision. Returns the committed mapping snapshot and broadcasts it
  to mapper and renderer clients. Numeric object counters advance past loaded IDs.

Stale revisions and duplicate names return 409 without mutation; missing layouts
return 404. Saves persist to the shared `layouts` section of `mapping_state.json`.
Legacy per-projector presets migrate into this library; identical same-name
layouts are deduplicated and different layouts with the same name get a projector
suffix. The old `presets` field is no longer part of mapping snapshots or commits.

Mapping snapshots include `layout: {id, name, modified}` or `null` for custom
mappings. Save, update, and load associate that projector with the named template;
the association persists as `layoutId` in the mapping file. `modified` compares
objects only, excluding output settings and editor selection. Library mutations
broadcast snapshots with `layoutOnly: true`: mapper clients should update layout
status without replacing local objects or interrupting pending commits. Deletion
clears associations while retaining live objects. A `mapping_commit` may send
`clearLayout: true` to detach a new/reset mapping; omitting it retains the association.

### Move and copy mapper objects

Named selection groups are stored as `project.groups: [{id,name,rectIds}]`.
They impose no rendering, routing, or effect settings. A surface belongs to at
most one group; regrouping moves membership from the old group. Deleted members
are pruned and empty groups removed. Group names are 1–200 characters.

- `GET /api/v1/mappings/{mid}/groups`: returns `{revision, groups}`.
- `POST /api/v1/mappings/{mid}/groups`: `{revision,name,rectIds}`.
- `PATCH /api/v1/mappings/{mid}/groups/{gid}`: `{revision,name?,rectIds?}`.
- `DELETE /api/v1/mappings/{mid}/groups/{gid}`: `{revision}`; ungroups without deleting surfaces.

Mutations return the mapping snapshot plus `groupId`, persist, and broadcast.
Stale revisions return 409, missing groups 404, invalid names/members 400. Group
metadata is included in named mapping layouts.

Temporary projector selection marks use a separate channel:
`GET /api/v1/mappings/{mid}/selection` returns `{mappingId,rectIds}`;
`PUT` accepts `{rectIds}` (an empty array clears). Mapper clients send
`{type:"mapping_selection",rectIds}` over `/ws/state?mapping={mid}`. Render clients
receive `{type:"mapping_selection",mappingId,selectedRectIds,selectionRevision}`;
initial mapping snapshots also include `selectedRectIds` and `selectionRevision`.
Render clients must ignore older selection revisions when applying snapshots and
preserve selection across geometry previews that omit it. Only selected, unmuted
Pattern surfaces get the green center square; Live surfaces are excluded.
Selection changes do not increment mapping revisions or save state. Closing the
mapper that last selected objects clears its marks. API selections remain until
cleared, superseded, or the server restarts. This controls the projected markers;
each mapper tab retains its own editing selection.

`PATCH /api/v1/mappings/{mid}/rects` accepts
`{revision, rectIds: ["rect-1", "rect-2"], cornerRadius: 0.04}` to set all listed
surfaces' corner radius atomically. `cornerRadius` ranges from 0 to 0.5 as a
fraction of the shorter side (the UI shows percent). Zero restores square corners.
Positive values require four-corner, non-folded surfaces. Unknown IDs or invalid
values reject the entire batch with 400; stale revisions return 409. The response
is the committed mapping snapshot, also broadcast to mapping clients. The single
surface PATCH endpoint accepts `cornerRadius` too. This property is retained by
saved mapping layouts and applied to native output, preview, and overlay masks.

`POST /api/v1/mappings/{mid}/move-surfaces` accepts `{revision, rectIds, offset}`,
where `offset` is `[dx, dy]` in normalized projector coordinates. It moves all
specified surfaces together in one revision and returns/broadcasts the mapping
snapshot. Free and planar surfaces limit the shared translation to the projector
bounds, preserving shape and spacing. Generated point surfaces update their point
positions; selecting any box face moves that whole box. Unknown IDs or invalid
offsets return 400 without mutation; stale revisions return 409.

`POST /api/v1/mappings/{mid}/copy-object` accepts `revision` (the current source
mapping revision), `target` (projector ID), `kind` (`rect`, `trace`, or
`collection`), and `id`. Rects include surfaces and overlays. The source stays
unchanged; the destination receives a copy with new IDs and the same normalized
geometry and settings. Collections include all member surfaces and remap their
face references. Existing destination objects are preserved. Returns the new
object `id`, `target`, and destination `revision`; a stale source revision returns
409. The mapper exposes this through right-click → Send to projector. Right-clicking
a selected surface copies the full selection, preserving fully selected collections;
partially selected collection faces are copied as independent surfaces.
For `kind: "rect"`, `target` may also be the source projector to duplicate a
surface or overlay. Optional `offset` (−1 to 1, default 0) translates both
projector coordinates; use `0.025` for the UI's first-paste offset. Curvature,
pin targets, UVs and source settings are copied. The new rect is manual and
independent of the original's collection.


### Out A/B selections and crossfades

Each Out has two row-to-column selection maps: `selections` (A, backwards
compatible) and `selections_b` (B). `launch_clip` and `toggle_clip` accept
`bank: "A"` or `bank: "B"`; omitted means A.  The same
cell may belong to both banks. UI shortcuts are Command/Ctrl-click for A and
Option/Alt-click for B; inspector buttons also select either bank.

`set_crossfade` accepts `bus` and `value` from 0 (A) to 1 (B). Each bank is
composited separately before a linear image crossfade; empty banks are black.
Planar collection effects are rendered against destination geometry in each
bank before mixing. Master video controls apply once after mixing. A/B maps
and crossfade positions persist with shows and undo history.
This is a video crossfade; the existing single-source audio path is unchanged.

The UI has one A/B slider for the selected Out. While `fader_sync` is enabled,
APC40 mkII channel 0 CC 15 controls that Out's crossfade (0–127 maps to 0–1).
BANK (note 103) or `set_fader_sync` toggles attachment; its LED follows sync
changes from hardware, UI, or API. Shift cycles controller lighting. Selecting another Out detaches
the hardware fader and preserves the Out's saved position.

Clip `opacity` is an independent 0–1 multiplier, default 1, and affects even
the bottom content clip. Legacy row opacity is stripped when shows load; `set_row` rejects opacity edits. The grid's left-side controls edit the selected
clip's blend mode and amount via `set_clip`; they are blank for other rows
and empty cells. The selected cell's column CC 7 fader edits its opacity
without holding a pad. Other column faders do nothing. Clip blend amount/mode
edits are shared wherever that cell is used, including both A/B banks.

The eight parameter knobs (channel 0 CC16–23) edit the selected clip's numbered
performance controls without holding a pad. Their rings follow that clip's
values, including edits from the UI/API. Empty cells and unassigned knobs do
nothing. `select_cell` sets the shared target; `set_clip.params` edits the same
values through the API.

### Text fonts

The `text` effect's `font` parameter selects a bundled typeface:
Archivo Black (default), Bebas Neue, Bungee, DM Serif Display, Lobster,
Pacifico, Permanent Marker, Special Elite, Monoton, or Press Start 2P.
The font picker previews the clip text using the same files as the renderer.
`italic` applies an oblique transform to any face; `weight` thickens glyphs,
and outline, alignment, position and multiline text remain supported.
Old Hershey font names are migrated when loading saved clip parameters.
Font assets and licenses live in `static/fonts`; no system fonts or online
font service are required at runtime. Set these controls through the usual
`set_clip` action and `params` object.


### Trace clips and LED destinations

`trace_pulse` uses `rate` in pulses/second (0.02–10) when `beat_sync` is false.
`on_time` (0.1–0.9, default 0.5) is the lit fraction of each cycle. `attack`
and `release` (0–1) are fractions of that lit interval; they are scaled together
if their sum exceeds 1. Zero gives hard edges. The remaining interval stays at
`floor`. Beat sync uses `per_beat` instead of `rate`.

`trace_snake`, `trace_pulse`, `trace_rainbow`, `trace_solid`, and
`trace_lightning` have effect kind `trace`. Use the existing grid API to create,
launch, edit, blend, and select them in either Out bank. Both LED and mapped
surface rendering follow the Out clock and A/B crossfade. Trace clips default
to additive blending. Image and video clips fill the strip with the average RGB
color of their current native-rendered frame (including fit and clip brightness).
Sampling uses a small frame at up to 30 Hz and only runs for active LED routes.
Media and trace clips blend in layer order and follow A/B crossfade. Other
non-trace clips and adjustment layers are skipped. Existing route and grid APIs
control this behavior; no additional destination setting is required.

- `GET /api/v1/leds`: destination settings and `linked` state.
- `PUT /api/v1/leds`: `{ "linked": true, "source": "fixture-id" }`.
  Linking synchronizes route, brightness, and power limit from the source across
  physical strips; existing enabled states and pixel ranges are preserved.
  While linked, subsequent physical fixture PATCH changes to route, brightness,
  power limit, or enabled state apply to all physical strips. Virtual/projected
  LED paths stay independent. The native UI displays one combined strip panel
  and preview of enabled physical strips.
- `PATCH /api/v1/leds/{fixture-id}`: `enabled`, `brightness`, `power_limit`,
  and/or `route: {out, start, end, offset, reverse}`. `out` is `out1`…`out20`
  or `none`; normalized start/end satisfy `0 <= start < end <= 1`; offset
  is 0…1. Partial route updates are accepted. Inactive Outs render black.
- `/ws/leds` continues to provide live RGB strip previews after power limiting.

Rectangle `trace` settings and collection `content.trace` settings use
`{mode, scope, width, offset, reverse}`. Modes are `perimeter`, `horizontal`,
`vertical`; width is 0.001…1 of the face and applies to perimeter rendering.
Scope `face` repeats on each face; `collection` divides the normalized path
across faces in their saved order. Sequence does not imply physical adjacency.
These settings apply to planar and box collections. Raster UV layout remains
independent. Unconnected areas are transparent; trace color blends with other
layers on the same Out.

`PATCH /api/v1/mappings/{mid}/rects/{rid}` accepts `revision` plus `trace`,
`fold`, `corners`, `uvs`, or `removePoint` for an independent surface/overlay.
Set `fold: true` on a four-corner rectangle to add a vertical split at 50% of
the source; `fold: false` removes it while retaining the outer four corners.
Fold perimeter order is top-left, fold-top, top-right, bottom-right,
fold-bottom, bottom-left. Dragging or PATCHing those six `corners` changes the
geometry; each side uses its own perspective warp. The panels must stay convex
and must not overlap. `uvs` uses the same order and can set the source split.
In the mapper, double-click a selected surface's edge to split it with a new corner (UVs are interpolated); double-click a corner of a polygon with more than four corners to remove it. Splitting is unavailable on rounded, folded, curved or collection-owned surfaces.
`removePoint` is a zero-based perimeter index for an ordinary polygon with more
than four points; fold endpoints are removed together with `fold: false`.
Geometry operations on collection-owned faces are rejected. Full mapping
snapshots retain the `fold` boolean.
For a collection member it updates the owning collection. Collection settings
can also be set with the existing collection PATCH endpoint (`content.trace`).

The old fixture effect commands (`set_program`, LED preset save/load/delete,
and fixture layer edits) are removed. Supported existing fixture programs are copied to
an inactive **LED import** show on first load; saved legacy preset files remain
on disk. Set LED destination Out routes explicitly.

### Box corner alignment

Box collections use the same revision-checked collection endpoints. Create with
`kind: "boxes"` and `preset: "box"` or `"stack"`. PATCH accepts `boxes`,
`projection`, `mode` (`live` or `grid`), and `graphic` (`wireframe`, `grid`,
or `alignment`). All collection kinds—planar, boxes, and points—use the same
Display Live/Pattern control. `mode: "grid"` overrides the live Out with the
selected alignment pattern on every member, including newly added points/faces.
Switching back to `live` restores the routed content without changing geometry.
The old `alignmentPattern` API field is replaced by `mode`; saved projects using
it migrate to Pattern/Wireframe on load.

Each box may include `alignment: {matrix, vertices?, pins, sides}`. `matrix` is a row-major
3×4 projective camera, normalized so its last element is 1, mapping canonical
cuboid vertices at ±1 into normalized projector coordinates. `sides` preserves
the visible faces (`front`, `back`, `left`, `right`, `top`, `bottom`). `pins` maps
vertex indices as strings to `[u,v]` edited-corner markers. `vertices`, when
present, contains eight `[u,v]` screen positions in the vertex order below and
overrides the camera projection. Corner dragging materializes these positions
and changes only the dragged shared vertex; every other corner stays fixed.
Legacy camera alignments remain readable. Faces must remain convex and
consistently wound; box rigidity is not enforced during corner alignment. Remove `alignment` from a box to reset
its fit. PATCH the full `boxes` list to preserve the other boxes.

Vertex order: `---`, `+--`, `++-`, `-+-`, `--+`, `+-+`, `+++`, `-++`.

For a box collection, PATCH also accepts either of these actions alongside
`revision`:

- `copyBox: {boxId, name?, offset?: [du,dv]}` duplicates one box, its face
  settings, and alignment. Default offset is `[0.025,0.025]`; the copy gets a
  new ID and joins the same collection (maximum 128 boxes, subject to 128 mapped surfaces).
- `boxTransform: {boxId, offset?: [du,dv], angle?: degrees, center?: [u,v],
  aspect?: width/height}` moves/rotates the entire mapped box and its pins.
  Defaults: zero translation/rotation, center `[0.5,0.5]`, aspect `1`.
  Supply projector aspect for a rotation that preserves pixel lengths.
  This rotates the projected outline, not the box's 3D world pose.

In the mapper, select a box and use Copy/Paste or ⌘C/⌘V (Ctrl on Windows/Linux).
The center handle translates it; the ↻ handle rotates it, with Shift snapping
rotation to 15°. Movement and rotation use the box alignment Undo/Redo buttons.

### Trace bounds and reflection

`trace_lightning` adds `start` and `end` (0–1, default 0 and 1), plus
`reflect` (boolean, default false). Bounds are sorted; equal bounds render
black. The effect draws only inside that interval. Speed remains whole trace
lengths per second. `origin` chooses the initial end. With Reflect enabled,
one pulse immediately reverses at each boundary and continues indefinitely;
`rate` is ignored. Without Reflect, rate schedules separate outgoing pulses.

Physical strips and mapper traces derive stable random seeds from destination
IDs. Projected faces have independent seeds in per-face mode; collection-wide
traces use one seed across the whole path. Linking shares controls, not seeds.
Set `jitter`, `burst`, `crackle`, `forks`, and `top_spray` to zero for identical
motion on destinations with identical routing. All these controls accept zero.

Lorenz `rotation` is now a nonnegative speed (0–0.8); zero stops rotation.
`rotation_direction` is `forward` or `reverse`. Saved negative rotation speeds
load as positive speeds with reverse direction.

### Slime Mold

`slime_mold` is a seeded line network rendered through the native graphics
pipeline. Parameters: `density` (80–580), `branching` (radial growth, 0–1),
`x`/`y` (origin, 0–1), `line_width` (0.5–5), `color`, `seed` (0–999999),
`pulse` (0–1), `speed` (0–1), and `pulse_length` (0.01–0.3).
The default is static. Pulses travel outward along connected branch paths.
The UI's Reset mold button changes `seed`; API clients do the same using
`set_clip` with `params: {seed: ...}`. Identical geometry parameters reproduce
identical shapes. Geometry rebuilds only when seed, density, radial growth,
origin, or aspect ratio changes. Ordinary clip blending and A/B routing apply.

Lightning Pulses speed supports 0.05–10 trace lengths/second. `single_color`
(default false) uses `glow` for the entire pulse, bypassing the separate `core`
color and `rainbow` variation. Turning it off restores those settings.

Point collections use the mapping collection endpoints. POST
`/api/v1/mappings/{mid}/collections` with `revision`, `kind: "points"`,
`points: [{id, name, position: [x,y]}]`, optional `radius` (0.001–0.5,
projector-height units), `shape` (`"circle"` default or `"square"`), `aspect` (projector width/height), `name`, and `source`.
Positions are normalized projector coordinates. PATCH the collection with
`points` to add, move, rename, or remove points, or with `shape`, `radius`, `content`,
`enabled`, or `offset`. Keep IDs stable when editing. Collections require
1–128 points; DELETE removes the collection and its derived footprints.
Calibrated points also preserve `cameraPosition` as calibration metadata.
Circle points set their faces' `cornerRadius` to 0.5, so overlay masks and rounded output follow the circle rather than its square footprint. Point connectivity uses projector-space centers. Glow Faces
uses the selected point shape, as does mapped video; Triangulate Faces connects point centers. Square half-width/half-height use the same radius/aspect bounds as the circle, so changing shape preserves point positions and size.


### APC controller lighting

Shift (note 98) cycles Full → Dim → Off → Full. This changes only controller
illumination, not clip playback, projection, LEDs connected to the show, fader
sync, or MIDI input. Dim uses darker RGB pad colors; fixed-color buttons and
knob rings retain normal brightness because they have no dimming control.
Off disables button LEDs and both banks of knob rings.
`set_controller_lights` with `mode: "full" | "dim" | "off"` provides the same
control via `/api/v1/grid`. `grid.controller_lights` reports the setting, which
is saved globally across shows. Settings → APC lights exposes it in the UI.

NDI receiver buffering: `PUT /api/v1/ndi/clients/{client}/inputs/{input}`
accepts `{"buffer_ms":100}` independently of routing and rotation. The receiver's
`PUT /api/v1/receiver/inputs/{input}` accepts the same field. Range: integer
0–500 ms; default 100; 0 selects latest-frame playback. Settings persist per
screen and apply without reconnecting the source. Receiver snapshots report
`buffer_ms`, `buffer_applied_ms`, and `queued_frames`. Each input caps queued
RGBA frames at 128 MiB and reduces effective buffering when necessary.


### Oriented planes in point collections

Point collections support `shape: "circle"`, `"square"`, or `"rectangle"`.
Each member of `points` is an oriented reference patch. Its `position` is the
normalized projector anchor. Existing points retain their original footprint.
The collection `radius` remains the default marker half-height; `aspect` is the
projector width/height ratio.

Per-point fields, available through the collection POST/PATCH `points` array:

- `rotation`: clockwise degrees in projector pixel space, default 0.
- `radius`: optional marker half-height override (.001–.5 of projector height).
- `alignment`: four marker corners, in TL/TR/BR/BL order, in local marker units.
  Default `[[-1,-1],[1,-1],[1,1],[-1,1]]`. These define a perspective transform;
  local X is corrected for projector aspect before rotation and translation.
- `coverage`: `[width,height]` multipliers of the reference patch, each 1–20,
  default `[1,1]`. Circle and square use width for both dimensions; rectangle
  uses width and height independently.
- `margin`: 0–10 reference-patch widths added on each side (default 0).
  Effective half-extents are `[width+2*margin,height+2*margin]`.

Coverage is expanded through the reference patch's homography, so enlarging it
preserves perspective and orientation. Crossed/degenerate reference corners and
coverage crossing the projective horizon are rejected atomically.
`mode: "grid"` displays the reference square, directional crosshair (cyan Top,
red Right), and green coverage outline. `mode: "live"` uses the same mapping
for the selected Out, including videos, media collections, and face effects.
Circle coverage is circular in the local plane, so its projector outline may
be elliptical or perspective-distorted. Pattern guides can extend outside the
circle; the Live mask remains circular.

In the mapper, select a plane to edit its marker size, rotation, coverage, and
margin. Drag its center, rotate handle (Shift snaps to 15 degrees), or four
labeled reference corners. Reset alignment restores the reference square and
zero rotation while retaining coverage. Undo restores the preceding individual
plane edit. Place planes enables click-to-add and switches to Pattern; new
planes inherit the last selected plane's orientation and coverage. Toggle it
off or press Escape to return to selection. Adding/removing markers leaves the
collection's content route unchanged.


## Curved surfaces

Independent four-corner surfaces, overlays, and individual planar collection faces
accept `curvature` through project commits and
`PATCH /api/v1/mappings/{mid}/rects/{rid}`. Independent surfaces and overlays also
accept it on creation. Planar face edits preserve collection membership and shared
content routing; generated box and point faces do not accept curvature:

```json
{"revision": 12, "curvature": {"top": 0.12, "bottom": -0.08, "wrapX": 120}}
```

`top`, `right`, `bottom`, and `left` are edge bows in the rectangle's perspective
frame, from -2 to 2. Positive bows move outward. The mapper displays these
as percentages with numeric entry and zero reset. `wrapX` and `wrapY` range from
0 to 170 degrees; they adjust spacing along a circular cross-section. Zero is
linear spacing. The four corners remain fixed.

Each edge also accepts `<side>Skew` and `<side>Shape` (for example `topSkew`
and `bottomShape`), each from -1 to 1, defaulting to zero. Skew redistributes
bend toward one end; positive is toward Right for Top/Bottom and toward Bottom
for Left/Right. Shape raises/lowers the shoulders for a wider/narrower curve.
Both retain the edge endpoints and midpoint bend. These shape controls work
on the chosen edge independently, allowing non-circular and asymmetric outlines.

`spacingX` and `spacingY` range from -3 to 3, default zero. They redistribute
source coordinates through the existing curved patch without changing its
boundary or geometry samples. Positive X compresses cells near Left and expands
them near Right; positive Y compresses near Top and expands near Bottom. The UI
shows these bias values on a -100..100 scale (API value multiplied by 100/3).
These are empirical sampling controls, not recovered surface measurements.

Partial PATCH objects preserve
other curvature values; `curvature: null` restores the flat surface.

### Edge pin constraints

`curvature.pins` stores the base-independent constraints:

```json
{
  "revision": 12,
  "curvature": {
    "pins": {
      "enabled": true,
      "method": "fit",
      "points": [
        {"id":"top-1", "side":"top", "t":0.3, "target":[0.3,-0.12], "enabled":true}
      ]
    }
  }
}
```

`method` is `fit` (default) or `local`. Fit derives bounded bend/skew/shape values
without overwriting the saved base controls. It minimizes edge-normal errors
with a small preference for the base parameters; it cannot generally satisfy
tangential movement or every target. Local uses cubic edge corrections blended
across the patch. Both keep corners fixed and use the same pin positions.

`side` is top/right/bottom/left. `t` is a geometric edge parameter in 0.01..0.99:
left-to-right on top/bottom, top-to-bottom on left/right, before spacing bias.
`target` is an `[x,y]` point in the quad's perspective frame (corner coordinates
0,0 through 1,1); targets may extend outside it, in -4..5 per axis. Projector
coordinates can be converted with the inverse quad homography. Thus pins travel
with the quad when its corners move. IDs must be unique strings of 1–64 characters.
At most eight pins per edge and 32 total are accepted; same-edge `t` positions
must be at least 0.005 apart, including disabled pins.

A partial pin PATCH preserves the existing points and method:
`{"revision":13,"curvature":{"pins":{"enabled":false}}}` disables all pins;
`enabled:true` restores them with their per-pin enable flags. Replace `points`
to move, enable, disable, or remove individual pins. `points:[]` deletes all pins;
`pins:null` clears the pin settings. Changing algorithms does not change targets.
The renderer ignores disabled constraints, and no fit is baked into the base.
Invalid final geometry or an invalid base is rejected atomically. Saved presets,
Pattern, Live, vector paths and clipping use the same corrections.

The same tessellated patch maps Pattern and Live content, including Syphon,
video, and vector paths. Selection and overlay clipping follow the curved edge.
Folds and curved patches cannot be combined; overlapping or collapsed patches
are rejected without changing the saved mapping. Geometry settings on collection
members are managed through the collection; ungroup a face to bend it individually.

These controls provide manual image correction. Edge alignment alone does not
measure the sheet's intrinsic distances or reconstruct its 3D shape. Match grid
spacing as well as the outline; roundness is in the sheet's coordinates and will
still appear foreshortened from an oblique viewing angle.

### Native physical projector activation

`PUT /api/v1/display-assignments` accepts `assignments` and optional `activate`
(a projector ID such as `"1"`). A newly enabled or changed display assignment
also enables that mapping's `project.output.enabled` in the same transaction.
`activate` explicitly re-enables an already assigned projector, as used by the
native Assign display action. Unchanged assignments preserve intentional output
muting. Activation requires an enabled assignment; invalid requests change
neither routing nor mappings. Mapping revisions advance when activation changes
the mapping. `PATCH /api/v1/mappings/{id}/output` still exposes `enabled` directly.

The mapper's Live / Pattern buttons and Command+L use the existing mapping `mode`
values `live` / `grid` through the selection batch API, including collection-owned
faces. A mixed selection switches to Pattern on the first Command+L and Live on the
next. Text editing and other workspaces retain their ordinary key behavior.

Command+1–9 sets the selection's `source` to `out1`–`out9`; Command+0 selects
`out10`. Add Shift for `out11`–`out20`. Only active Outs are eligible. These
shortcuts use the same mapping batch endpoint, updating independent rectangles
or an owning collection's `content.source`, and remain undoable.

### Native WLED transport and live monitoring

`GET /api/v1/state` and WebSocket `/api/v1/events` retain the full live-state
contract. Events send an initial snapshot and approximately four snapshots per
second, including runtime changes when the saved document revision is unchanged.
The events connection is read-only; use HTTP commands or `/ws/ui` for edits.

`GET /api/v1/fixture-output` returns the saved `host`, `port`, and `requested`
state plus live `active`, `status`, `error`, `resolved`, `packets`, `last_sent`,
and `stale` fields. Start WLED with
`POST /api/v1/fixture-output {"action":"start","host":"wled.local","port":21324}`.
`{"action":"stop"}` clears the previously sent segments and stops output.
Use `{"action":"set","host":"...","port":21324}` to configure an idle sender;
stop before changing the destination of an active sender.

Physical strips retain their pixel counts and start offsets from the VJ data
source. `/api/v1/leds` controls routes, per-strip enable/brightness/power limits,
and linking; `/api/v1/mix` controls LED master/mute. `/ws/leds` sends
`{"type":"led_frames","frames":{"strip-1":"<base64 RGB8>"}}` previews after
brightness and power limiting. Inactive Out routes are black. Starting a sender
does not enable disabled strips or start stopped Outs.

### Native performance telemetry

The native editor's bottom status bar uses the same measurements exposed by
`GET /api/v1/stats`: `renderer.metrics.fps` is completed render frames per second;
`targetFps` is the target; `frameMs` and `frameMsMax` cover the full worker frame,
including mapping, readback and GPU completion. `snapshotMs` measures state
snapshot cost. `engine.renderMsEma` remains the narrower graph-only measurement.
`worstFrameStagesMs` breaks down the longest worker frame in the reporting
interval into snapshot, demand/scene preparation, graph rendering, LEDs, views,
outputs/publication, and GPU completion. These are CPU wall times; GPU work can
be charged to a later synchronization stage. `sceneRebuildCount` counts scene
rebuilds since renderer creation, and `sceneRebuildEvents` retains the latest
eight triggers with frame sequence, reasons, and previous/current view demand.
`engine.patchResolutionCacheHits` and `engine.patchResolutionRebuilds` count
collection-bus reuse and rebuilds since renderer creation. Resolved Patch layers
are reused while their recipes, controls and referenced source identities remain
unchanged. Video texture updates continue independently; faders, source changes
and scene edits invalidate the relevant cached state automatically.
`engine.projectorBackdropCopies` counts GPU captures for Meta graph glass
overlays. Glass samples the projector composition below that overlay, including
lower surfaces and earlier Meta graphs. It uses sampled colors without palette
tint or added highlights. Captures and overlay targets stay on the GPU; no CPU
readback is required. Ordinary Layer Mux glass retains its local backdrop.
`sampledAt` is a monotonic timestamp; measurements update approximately once per
second. Render FPS is not a measurement of a projector's physical refresh rate.

`ui.delayMs` reports recent excess delay of a 100 ms main-thread heartbeat;
delays of at least 50 ms remain visible for five seconds. `maxDelayMs` is the
maximum since launch and `lateTicks` counts delayed heartbeats. A stall is
reported when the main thread resumes. `processes[0].cpuPercent` counts 100% as
one CPU core and `rssBytes` is resident memory. Renderer and UI telemetry also
appear at `state.renderer` and `state.ui` in full state snapshots and events.


### Patch palettes for Flash Faces

`GET /api/v1/sources/palettes` returns `{ "sources": [...] }`. Each runtime source has a stable `id`, `name`, `kind` (`publishPalette` or `syphon`), `available`, `colorSpace: "sRGB"`, and ordered `colors: [{r,g,b}, ...]` with normalized channels. The Mac host supplies enabled Publish Palette nodes and implicit Syphon Out palettes from embedded Patch, plus standalone Patch's authenticated local API. A disconnected, missing, or invalid source retains its last valid `colors` with `available: false` and `held: true`; a fresh valid palette has `held: false`. Missing sources are hidden from discovery menus (`listed: false`) but remain resolvable by their saved IDs for this session. A snapshot older than three seconds is marked unavailable without discarding its colors. No color data is stored in Syphon metadata.

Set Flash Faces' `params.palette_source` to a discovered ID through the existing `set_clip` or composition-layer parameter API. `""` uses Theme / Custom. A selected live source uses its full ordered list, overriding local theme/color-count/custom-color settings. Those settings remain saved and apply only when `palette_source` is cleared. A selected external source holds its last valid palette until another complete valid palette arrives; before its first valid palette it renders black. It never falls back to a local theme during extraction or connection gaps. The source ID persists, so reconnection resumes automatically. Palette updates are transient runtime data and do not alter document revisions, undo history, or animation clocks. The source picker is a routing selection, not a continuous MIDI control.

## MIDI routing inspection

`GET /api/v1/midi/hooks` reports built-in APC routes, explicit mappings, the A/B
follower, MIDI clock, and forwarding of track faders to embedded Patch. The same
inventory is in `state.midi.controlHooks` and `GET /api/v1/midi`. Channels are
zero-based. Each hook includes its source, destination, enabled/active state,
and edit/disable commands where applicable. Grouped APC hooks declare their edit
scope. Inspect `/v1/midi/hooks` on embedded Patch's API for the final node/parameter
of forwarded track faders.

**Intentional removal:** APC track faders (CC 7, channels 0–7) no longer
implicitly change Composer clip or layer opacity. Only explicit mappings and
Patch Follow APC routes can consume them.

POST `/api/v1/midi`, with the normal optional `revision` guard:

- `midi_set_hook`: `hook`, `enabled`. Hook IDs: `clip_launch`, `column_launch`,
  `output_select`, `clip_parameters`, `dmx_parameters`, `fader_attach_button`,
  `controller_lights`. Disabled built-ins release their inputs to explicit mappings.
- `midi_bind`: `target` (same schema as `midi_learn`), `channel`, exactly one of
  `cc`/`note`. Binds directly without simulating a hardware message.
- `midi_update`: `index`, optional `enabled`, `channel`, `cc`/`note`, `target`.
  Source and destination changes are atomic; conflicting assignments are rejected.
- `midi_unmap`: `index` removes an explicit mapping.

The crossfader hook uses existing grid `set_fader_sync`; MIDI clock uses
`midi_clock_sync`. Built-in enable flags and explicit mappings persist with VJ.

### Typed embedded Patch sources

`GET /api/v1/sources/patch` exposes stable `patch:<node UUID>:<port>` outputs:
`video`, `collection`, `palette`, `control`. `listed` controls library visibility;
`available` is live runtime status. `patch_video` and `patch_collection` clips use
`params.source` as this identity. Collection clips evaluate on mapper collections.
Palette IDs are also accepted by `palette_source` parameters.

`set_clip` accepts a replacement `patchControls` object mapping continuous
raster/collection parameters to `{source,min,max}`. Values map from 0–1, with
saved parameter values used when a source is unavailable. `{}` removes bindings.
Vector/compiled animation parameters are not currently eligible. These bindings
are saved with the clip and available in state; runtime values remain in the
source catalog. Sources can be authored/renamed/hidden using Patch's `/v1/outputs`
and `publish` command without changing the VJ clip identity.

### Mapping clipboard snapshots (native)

`POST /api/v1/mappings/{id}/paste` accepts the destination `revision`, a
`clipboard` object with `format: "vj-mapping-clipboard/1"`, and optional `offset`
(default `0.025`, applied to X and Y). Each paste is one validated transaction and
undo step, returns fresh `rectIds` or `traceId`, and preserves projector settings.

- `kind: "surfaces"`: `rects` contains full surface snapshots. Copies retain
  geometry, UVs, curvature/pins, source, mode, pattern, blend, and trace settings;
  IDs and names are regenerated and copies become independent surfaces.
- `kind: "box"`: `mappingId`, `collection`, `box`, `faces`, and `rects` capture one
  aligned box. A compatible original collection on the same mapping receives the
  new box; another destination receives a new collection. Ownership and face
  topology remain intact.
- `kind: "trace"`: `trace` contains the copied trace definition.

The native mapper writes this snapshot to the `com.vibe.mapping-objects`
pasteboard type. Command-C/Command-V and Edit-menu actions use it. Repeated pastes
use increasing offsets; paste works without a current object selection. Text
editing retains normal AppKit clipboard behavior. Source edits or deletions after
copy do not change the clipboard snapshot.

Planar mapper clipboard payloads include a `collections` array containing source
collection metadata and only the copied faces. `POST /api/v1/mappings/{id}/paste`
reuses the same planar collection on the source projector, or creates a new planar
collection for the copied subset when pasting elsewhere or after the original
collection was removed. Face IDs and reference-face links are remapped atomically.
Older payloads without `collections` retain their independent-surface behavior.

Native mapper quick placement uses the existing mapping API: POST
`/api/v1/mappings/:id/preview` with `baseRevision`, `clientId`, `_owner`, and a
project containing the temporary rectangle; DELETE the same route with `_owner`
to cancel. POST `.../rects` with `revision` and final normalized `corners` to
place a surface (one undo step). Its initial pattern settings are `mode: "grid"`,
`graphic: "wireframe"`, `config: {color: "#ffffff", thickness: 3}`. Existing
surfaces use `.../transform-surfaces` or collection-aware `.../batch` operations.
Scale and rotation operate in projector aspect-correct space, preserving squares.

Alignment patterns: surfaces and collections accept `graphic: "solid"` in addition
to `grid`, `wireframe`, and `alignment`; box collections also accept `faces` for
their original CMY face colors. Set `mode: "grid"` to show the chosen pattern;
`mode: "live"` shows the assigned Out. Solid uses each surface's `config.color`.
An explicit collection `graphic` replaces its default calibration pattern and
persists across geometry regeneration. The native inspector exposes these choices
beside Live/Pattern, with color under Pattern.


### Native surface subdivision and box placement

`POST /api/v1/mappings/{mid}/subdivide` accepts:

```json
{"revision": 42, "rectId": "rect-1", "columns": 2, "rows": 3, "orientation": 0}
```

The mapping revision is required. Counts are positive integers with a product of
2–128, subject to the mapping's 128-surface limit. Orientation is 0–3 (quarter
turns); columns follow corner 0→1 and rows follow corner 0→3 at orientation 0.
The original surface is replaced in its draw order by row-major children. The
response includes `rectIds`, and the children become the mapping selection.
Perspective geometry and cropped UVs are preserved; planar collection/group
membership and reference-face links are updated. This is one undoable command.
New children start in solid Pattern mode with distinct bright alignment colors.
For a planar-owned face, the collection switches to solid Pattern mode; sibling
faces retain their existing colors. Live/Pattern remains the usual toggle.
Only unfolded four-corner surfaces without active curvature, edge pins, or rounded
corners are supported. Box/point faces and overlays are excluded. Invalid requests
return 400 without committing changes; stale revisions return 409.

`POST /api/v1/mappings/{mid}/collections` also accepts `faceCenters` when creating
one box:

```json
{"revision": 42, "kind": "boxes", "faceCenters": [[0.3,0.6],[0.7,0.6],[0.5,0.3]]}
```

The three normalized coordinates identify cyan/front, magenta/right, and yellow/
top face centers, in that order. The initial affine cube fit passes through all
three centers and opens in Pattern mode. It retains normal box alignment and
corner editing. Near-collinear or coincident centers fail without mutation.
The UI's Place box gesture uses the same route; cursor previews are transient
mapping previews and are never saved. Escape cancels, Backspace removes the most
recent center, and creation commits only after the third center.

### Lightweight placement markers

`POST /api/v1/mappings/{mid}/preview` also accepts `markers` instead of
`project`: an array of up to four surface-shaped dot markers with `mode: grid`,
`graphic: wireframe`, and `config: {centerOnly: true, color: "#RRGGBB"}`.
The same `baseRevision`, `clientId`, and preview ownership/cancellation rules
apply. Markers overlay the committed render geometry without modifying it,
regenerating collections, or rebuilding composition scenes. Empty markers
clear the dots; `DELETE` clears the owned preview. Saved mapping state is
unchanged. `previewRevision` includes marker updates; `scenePreviewRevision`
tracks previews that require composition setup.

### Box subdivision

`POST /api/v1/mappings/{mid}/subdivide-box` accepts:

```json
{"revision": 42, "collectionId": "collection-1", "boxId": "box-1", "columns": 2, "rows": 2, "depth": 2}
```

Counts are integers 1–128 (default 2), along the box's local X, Y, and Z axes.
The product must be at least two; the result must fit the collection's 128-box
and mapping's 128-surface limits. The parent is replaced by a regular volume
grid of independently editable boxes in the same collection. Projection, world
rotation, authored screen corner adjustments, source routing, group membership,
and removed visible sides are preserved. Shared subdivision corners remain
continuous. Children start in solid Pattern mode with distinct bright face
colors; existing sibling faces retain their colors. The response includes
`boxIds` and `rectIds`; all new mapped faces become selected. This is one
revision-checked, undoable command. Invalid requests leave saved state unchanged.

Faces remain individually deletable via the existing rect DELETE routes.
Deleting a generated box face removes its side from the box alignment; deleting
its last remaining face removes that box. Deleted sides do not regenerate on
refresh or reload. Shared interior faces are omitted automatically. Only subdivisions
on the parent's remaining outer sides create mapped faces; fully covered cells
create no Mapper box object. Existing boxes are unchanged.

### Mapper visibility

`GET /api/v1/mappings/{mid}/editor-visibility` returns `hiddenRectIds`,
`hiddenTraceIds`, `soloRectIds`, `soloTraceIds`, and `solo`.
`POST` accepts an `action` and optional `rectIds` / `traceIds` arrays:

- `hide`: exclude the targets from the Mapper.
- `show`: restore targets; extend the visible set when solo is active.
- `solo`: show only these targets, preserving earlier hidden objects.
- `clear_solo`: exit solo, retaining explicit hidden objects.
- `show_all`: clear hidden objects and solo.

This only controls editor drawing and picking. Projector output, show revisions,
and undo history are unchanged. State persists separately in
`mapper-visibility.json`; mapping snapshots include `editorVisibility` and
state snapshots include `editorVisibilityRevision`.

When embedded Patch contains an `apc40` node, MIDI runtime reports
`patchAPCOwned: true`. All APC input is then reserved for Patch, overriding
Composer, DMX and learned APC actions. MIDI selection remains explicit.
Patch `/v1/state` reports `midi.apcOutputs` (port index, name, current value or
null), and `modulate` accepts an `output` index for visible graph wiring.


### Patch collection crossfades

Patch A/B collection output (port 1) can be selected by a `patch_collection`
clip. Its `layerMux` recipe uses `composite:"crossfade"`; leaf opacities multiply
through the recipe and VJ adds the weighted branches. Video branches use
`surfaceGate` fills, while Video Collection branches retain their individual
face sources and fit mode. The existing A/B video output remains port 0.


### Per-face content fit in surface collections

Collection member rectangles accept `contentFit: "inherit" | "contain" | "cover"
| "stretch"` through the existing revisioned rectangle PATCH and batch APIs.
Missing values mean `inherit`, preserving existing output. Inherit uses the
media collection fit for media inputs and the existing mapped UV behavior for
ordinary video. Explicit settings override fit for the selected face, including
Patch Video Collection and video-backed surfaceGate/A-B branches. Contain shows
the full image; Cover crops to fill; Stretch fills without preserving aspect.
Colors and procedural face effects retain their face geometry. The native
collection inspector exposes Content fit for selected member surfaces.

Collection rectangles also accept `contentPosition: [x, y]`, with finite values
from 0 to 1 and a default of `[0.5, 0.5]`. In Cover fit, 0 selects the left/top
edge of the available crop and 1 selects the right/bottom edge. It has no effect
on Contain or Stretch. The same revisioned rectangle PATCH, batch, preview,
undo, and saved-layout paths preserve this setting. It applies to media
collections, ordinary video, and video-backed Patch surfaceGate branches.

In the native collection inspector, select one face and enable **Position
content**. This selects Cover fit. Drag inside that face in the mapping canvas
to reposition its image; Shift-drag adjusts it more slowly. Arrow keys adjust
position, and **Center crop** restores `[0.5, 0.5]`. Dragging previews the output
and commits once on release; Escape cancels the current drag. Toggle Position
content off to resume geometry editing.

Overlays expose the same Position content and Center crop controls. Position
content selects the overlay's existing `fit: "fill"` mode and uses the same
`contentPosition: [x, y]` rectangle field. Native mapping output and editor
previews apply the crop before clipping the overlay to underlying surfaces.
The position has no effect in the overlay's Fit or Stretch modes; it is retained
when switching modes. Overlay corners, masks, and blending are unchanged.

Surface order in `rects` is stacking order: later surfaces draw in front of
earlier ones. `POST /api/v1/mappings/{mid}/arrange-surfaces` with
`{revision, rectIds, to}` reorders independent surfaces, where `to` is `front`,
`forward`, `backward` or `back`; selected surfaces keep their relative order.
The Mapper offers Bring to Front (⇧⌘]), Bring Forward (⌘]), Send Backward (⌘[)
and Send to Back (⇧⌘[) in the selection and context menus.

Surfaces accept `occlude: true | false` (default `false`) through the revisioned
rectangle PATCH and batch APIs. An occluding surface blacks out surfaces behind
it inside its shape before drawing its own content, so they stay hidden even
where its content is transparent, feathered or uses add/screen blending. It
never changes stacking order. Muted (`source: "none"`) surfaces do not occlude.
Overlays ignore the setting. The Mapper inspector shows it as **Occlude** for
selected independent surfaces; collection faces are not supported.

Surfaces also accept `hemisphere: {enabled, wrap, feather, inset, edgeBoost}` for
projecting onto domes and balls. The circle inscribed in the surface's four
corners is the dome, so an off-axis ball is fitted by dragging corners into an
oval. `wrap` (0–1, default 1) spreads flat Out content evenly along the dome's
arc so it reads as painted on; 0 projects it flat. `feather` (0–0.5, default
0.04) and `inset` (0–0.5, default 0) soften and shrink the rim as fractions of
the radius. `edgeBoost` (0–1, default 0) brightens the grazing-lit rim. PATCH
merges the supplied fields into the current settings. Hemispheres require four
corners, no fold or rounded corners, and an independent surface. Content keeps
the surface's Fit; new hemispheres use Fill, which crops to the circle's square.
Occluding hemispheres hide lower surfaces only inside their feathered circle,
and overlays above them are clipped to it. **Add → Hemisphere** creates one, and
the Mapper inspector's **Hemisphere** section edits it.

Renderer statistics include `engine.warmSourceCount` for inactive Syphon
receivers retained for reuse (at most 32 and 128 MiB of destination textures).
They do not receive frame updates while inactive.

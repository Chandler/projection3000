# Directory ping-pong edits

`pingpong_video.py` creates a silent MP4 containing one fixed-duration section
per source clip. Each section repeatedly plays the complete clip forward and
then backward, and cuts to the next clip when its allotted time is up.

Run from `vj/` with Python 3.11+ and `ffmpeg`/`ffprobe` on your PATH:

```bash
.venv/bin/python -m tools.pingpong_video /path/to/clips /path/to/edit.mp4
```

The output directory is created automatically. An existing output is never
overwritten; choose a new filename for another run.

Defaults:

- 120 seconds per clip, 1920×1080, 24 fps, H.264 at 16 Mb/s, no audio.
- Clips sorted by filename, case-insensitively. Prefix names with `01`, `02`,
  etc. to control order. Add `--recursive` to include subdirectories.
- Aspect ratio preserved with black padding where needed; all clips normalized
  to the requested resolution and frame rate.
- Each full forward/backward cycle includes both endpoint frames in each
  direction. Partial final cycles are cut at the section boundary. Durations
  are rounded to the nearest output frame.

Options:

```bash
.venv/bin/python -m tools.pingpong_video /path/to/clips /path/to/edit.mp4 \
  --seconds 120 --size 1920x1080 --fps 24 --bitrate 16M
```

Use `--dry-run` to inspect the input order and total duration without rendering.
`--fps` also accepts fractions such as `30000/1001`.

On macOS, the default encoder is `h264_videotoolbox` (Apple hardware H.264).
On other systems, it defaults to `libx264`. Use `--encoder libx264` to explicitly
choose software encoding. The normalized forward clip is encoded once, then
decoded and reversed in bounded chunks. Only one forward/backward cycle is
encoded; all repetitions and the final join copy compressed packets. Reversal
defaults to four-second chunks (approximately 300 MB of raw frame data at
1080p/24, plus decoder and encoder overhead). Reduce
`--reverse-chunk-seconds` for larger resolutions or lower memory use.

Progress is printed per source clip. Intermediate files live in a temporary
directory beside the destination and are removed on completion or handled
failure. The final file is published only after its frame count and duration
are verified. MP4 metadata is moved to the beginning for quick playback.

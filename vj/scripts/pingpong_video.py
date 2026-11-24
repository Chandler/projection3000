#!/usr/bin/env python3
"""Make a silent, fixed-duration ping-pong section per clip, then join them.

Python 3.9+ and ffmpeg/ffprobe are the only dependencies. On macOS the default
encoder is Apple's H.264 VideoToolbox encoder. Only a single forward/backward
cycle is encoded; the repetitions and final join copy compressed packets.
"""
from __future__ import annotations

import argparse
from fractions import Fraction
import json
import math
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time


EXTENSIONS = {'.mp4', '.mov', '.m4v', '.mkv', '.avi', '.webm'}


def run(args):
    result = subprocess.run(args, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed:\n{result.stderr[-8000:]}")
    return result.stdout


def probe(path):
    data = json.loads(run([
        'ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height,nb_frames,avg_frame_rate,duration',
        '-of', 'json', str(path),
    ]))
    if not data.get('streams'):
        raise ValueError(f'No video stream: {path}')
    return data['streams'][0]


def ffmpeg(args):
    return run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-nostdin',
                '-y', '-filter_threads', '2', *map(str, args)])


def concat(paths, output):
    # All files are generated in one private directory, with controlled names.
    listing = output.with_suffix('.ffconcat')
    listing.write_text('ffconcat version 1.0\n' + ''.join(
        f"file '{path.name}'\n" for path in paths), encoding='utf-8')
    ffmpeg(['-f', 'concat', '-safe', '1', '-i', listing,
            '-map', '0:v:0', '-an', '-c:v', 'copy', output])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Directory of clips (filename order)')
    parser.add_argument('output', type=Path, help='Destination .mp4 (must not exist)')
    parser.add_argument('--seconds', type=float, default=120,
                        help='Seconds per clip, rounded to a frame (default: 120)')
    parser.add_argument('--size', default='1920x1080', help='Output size (default: 1920x1080)')
    parser.add_argument('--fps', default='24', help='Frame rate, e.g. 24 or 30000/1001')
    parser.add_argument('--bitrate', default='16M', help='H.264 bitrate (default: 16M)')
    parser.add_argument('--encoder', choices=['auto', 'h264_videotoolbox', 'libx264'],
                        default='auto')
    parser.add_argument('--reverse-chunk-seconds', type=float, default=4,
                        help='Limit frames buffered for reversal (default: 4 seconds)')
    parser.add_argument('--recursive', action='store_true', help='Also scan subdirectories')
    parser.add_argument('--dry-run', action='store_true', help='List the plan without rendering')
    args = parser.parse_args()
    source, output = args.source.expanduser().resolve(), args.output.expanduser().resolve()
    try:
        width, height = map(int, args.size.lower().split('x'))
        fps = Fraction(args.fps)
        if (min(width, height) < 2 or width % 2 or height % 2 or fps <= 0
                or not math.isfinite(args.seconds) or args.seconds <= 0
                or not math.isfinite(args.reverse_chunk_seconds)
                or args.reverse_chunk_seconds <= 0):
            raise ValueError()
        section_frames = max(1, round(args.seconds * fps))
        chunk_frames = max(1, round(args.reverse_chunk_seconds * fps))
    except (ValueError, ZeroDivisionError):
        parser.error('Use an even positive size and positive finite fps/durations.')
    if not source.is_dir():
        parser.error(f'Source directory does not exist: {source}')
    if output.suffix.lower() != '.mp4':
        parser.error('Output must have an .mp4 extension.')
    if output.exists():
        parser.error(f'Output already exists; choose another name: {output}')
    if not all(shutil.which(tool) for tool in ('ffmpeg', 'ffprobe')):
        parser.error('Install ffmpeg and ffprobe first (macOS: brew install ffmpeg).')
    files = sorted((p for p in (source.rglob('*') if args.recursive else source.iterdir())
                    if p.is_file() and p.suffix.lower() in EXTENSIONS
                    and not p.name.startswith('.') and p.resolve() != output),
                   key=lambda p: (str(p.relative_to(source)).casefold(), str(p)))
    if not files:
        parser.error(f'No supported videos in {source}')
    encoder = args.encoder
    if encoder == 'auto':
        encoder = 'h264_videotoolbox' if platform.system() == 'Darwin' else 'libx264'
    seconds = float(section_frames / fps)
    print(f'{len(files)} clips × {seconds:g}s = {len(files) * seconds:g}s; '
          f'{width}x{height} @ {fps} fps; {encoder}; silent', flush=True)
    for index, path in enumerate(files, 1):
        print(f'  {index:02}: {path.relative_to(source)}', flush=True)
        probe(path)
    if args.dry_run:
        return

    # No B frames: a packet-copy cut at any frame ends cleanly, with no trailing
    # references into the next cycle. Every encoded fragment begins with an IDR.
    encoding = ['-an', '-c:v', encoder, '-b:v', args.bitrate, '-pix_fmt', 'yuv420p',
                '-profile:v', 'high', '-g', str(max(1, round(fps))), '-bf', '0',
                '-video_track_timescale', str(fps.numerator), '-map_metadata', '-1']
    if encoder == 'h264_videotoolbox':
        encoding += ['-allow_sw', '0']
    else:
        encoding += ['-preset', 'veryfast', '-sc_threshold', '0']
    scale = (f'fps={fps},scale={width}:{height}:force_original_aspect_ratio=decrease:'
             f'force_divisible_by=2,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,'
             f'setsar=1,format=yuv420p,setpts=N/({fps}*TB)')
    output.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    # Same filesystem as output, so publishing the completed file is atomic.
    with tempfile.TemporaryDirectory(prefix='.pingpong-', dir=output.parent) as work:
        root = Path(work)
        sections = []
        for index, path in enumerate(files, 1):
            clip_start = time.monotonic()
            print(f'[{index}/{len(files)}] Encode forward: {path.name}', flush=True)
            forward = root / f'{index:04}-forward.mp4'
            ffmpeg(['-i', path, '-map', '0:v:0', '-vf', scale, *encoding, forward])
            frames = int(probe(forward)['nb_frames'])
            reverse_parts = []
            # Seek near each chunk, reverse at most chunk_frames, and join chunks
            # in descending order. Memory is bounded even for long source clips.
            for start in reversed(range(0, frames, chunk_frames)):
                count = min(chunk_frames, frames - start)
                part = root / f'{index:04}-reverse-{start:09}.mp4'
                ffmpeg(['-ss', f'{float(start / fps):.12f}', '-i', forward,
                        '-map', '0:v:0', '-vf',
                        f'trim=end_frame={count},reverse,setpts=N/({fps}*TB)',
                        '-frames:v', count, *encoding, part])
                if int(probe(part)['nb_frames']) != count:
                    raise RuntimeError(f'Reverse chunk frame mismatch: {path.name}')
                reverse_parts.append(part)
            cycle = root / f'{index:04}-cycle.mp4'
            concat([forward, *reverse_parts], cycle)
            if int(probe(cycle)['nb_frames']) != frames * 2:
                raise RuntimeError(f'Cycle frame mismatch: {path.name}')
            section = root / f'{index:04}-section.mp4'
            ffmpeg(['-stream_loop', '-1', '-i', cycle, '-map', '0:v:0',
                    '-an', '-c:v', 'copy', '-frames:v', section_frames, section])
            info = probe(section)
            if (int(info['nb_frames']) != section_frames
                    or abs(float(info['duration']) - seconds) > float(1 / fps) / 2):
                raise RuntimeError(f'Section duration/frame mismatch: {path.name}')
            sections.append(section)
            for intermediate in [forward, *reverse_parts, cycle]:
                intermediate.unlink()
            print(f'[{index}/{len(files)}] {seconds:g}s ready '
                  f'({time.monotonic() - clip_start:.1f}s elapsed)', flush=True)
        combined = root / 'combined.mp4'
        print('Joining sections and placing MP4 index at the front…', flush=True)
        concat(sections, combined)
        final = root / 'final.mp4'
        ffmpeg(['-i', combined, '-map', '0:v:0', '-an', '-c:v', 'copy',
                '-movflags', '+faststart', final])
        info = probe(final)
        if (int(info['nb_frames']) != section_frames * len(files)
                or abs(float(info['duration']) - seconds * len(files)) > float(1 / fps) / 2):
            raise RuntimeError('Combined duration/frame mismatch')
        # Atomic no-clobber publication, including if another process created
        # the requested output while this job was rendering.
        os.link(final, output)
    print(f'Done: {output}\n{seconds * len(files):g}s, '
          f'{output.stat().st_size / 1e9:.2f} GB; '
          f'render took {time.monotonic() - started:.1f}s', flush=True)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('\nCancelled; temporary render files cleaned up.', file=sys.stderr)
        sys.exit(130)
    except (RuntimeError, ValueError, OSError) as exc:
        print(f'Error: {exc}', file=sys.stderr)
        sys.exit(1)

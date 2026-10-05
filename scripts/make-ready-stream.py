#!/usr/bin/env python3
"""Offline generation of the waiting screen's reusable HLS assets (requires ffmpeg)."""
import pathlib
import subprocess
import shutil
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
icon = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / 'build/AirThrow.app/Contents/Resources/AppIcon.icns'
output = root / 'Resources/WaitingScreen'
with tempfile.TemporaryDirectory(prefix='airthrow-ready-') as directory:
    frames = pathlib.Path(directory)
    segments = frames / "segments"
    segments.mkdir()
    subprocess.run(['swift', root / 'scripts/make-ready-screen.swift', icon, frames], check=True)
    # Exactly 30 seconds per still, with no fractional positioning or animation.
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                    '-framerate', '1/30', '-i', frames / 'frame%d.png',
                    '-vf', 'fps=30', '-t', '120', '-c:v', 'libx264', '-preset', 'veryfast',
                    '-tune', 'stillimage', '-crf', '14', '-pix_fmt', 'yuv420p',
                    '-profile:v', 'high', '-level:v', '4.1', '-g', '60', '-keyint_min', '60',
                    '-sc_threshold', '0', '-an', '-f', 'hls', '-hls_time', '6',
                    '-hls_list_size', '0', '-hls_flags', 'independent_segments',
                    '-hls_segment_filename', segments / 'segment%06d.ts',
                    frames / 'index.m3u8'], check=True)
    # The runtime supplies a sliding live playlist rather than this finite index.
    if len(list(segments.glob('segment*.ts'))) != 20:
        raise RuntimeError('Expected exactly twenty six-second segments')
    output.mkdir(parents=True, exist_ok=True)
    for old in output.glob('segment*.ts'):
        old.unlink()
    for segment in segments.glob('segment*.ts'):
        shutil.copyfile(segment, output / segment.name)
print(output)

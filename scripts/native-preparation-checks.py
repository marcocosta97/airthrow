#!/usr/bin/env python3
"""Synthetic GPU cleanup and shared preparation-input checks. No receiver claim."""
import argparse
import array
import math
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]

def run(args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, capture_output=True, text=True, timeout=300, **kwargs)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / '.build/debug/NativePreparationChecks')
    parser.add_argument('--reuse', type=Path)
    args = parser.parse_args()
    (ROOT / 'build').mkdir(exist_ok=True)
    folder = args.reuse.resolve() if args.reuse else Path(tempfile.mkdtemp(prefix='native-preparation-', dir=ROOT / 'build'))
    (folder / 'tmp').mkdir(exist_ok=True)
    if not args.reuse:
        run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=1920x1080:rate=30',
             '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '6.5',
             '-vf', 'setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709',
             '-c:v', 'libx264', '-preset', 'veryfast', '-g', '150', '-bf', '3', '-pix_fmt', 'yuv420p',
             '-color_range', 'tv', '-colorspace', 'bt709', '-color_trc', 'bt709', '-color_primaries', 'bt709',
             '-c:a', 'aac', '-ac', '2', '-movflags', '+faststart', folder / 'cleanup.mp4'])
        run(['ffmpeg', '-v', 'error', '-i', folder / 'cleanup.mp4', '-vf', 'scale=960:540',
             '-c:v', 'libx264', '-preset', 'veryfast', '-g', '150', '-bf', '3', '-c:a', 'copy',
             '-movflags', '+faststart', folder / 'ai.mp4'])
        for name, options in [('remux', ['-c', 'copy']), ('audio', ['-c:v', 'copy', '-c:a', 'pcm_s16le']),
                              ('convert', ['-vf', 'scale=640:360', '-c:v', 'libvpx-vp9', '-deadline', 'realtime', '-cpu-used', '8', '-c:a', 'copy'])]:
            run(['ffmpeg', '-v', 'error', '-i', folder / 'cleanup.mp4', *options, folder / f'{name}.mkv'])
        (folder / 'bytes.bin').write_bytes(bytes(x % 251 for x in range(4 * 1024 * 1024)))
    if not (folder / 'cleanup-fractional.mp4').exists():
        run(['ffmpeg', '-v', 'error', '-i', folder / 'cleanup.mp4', '-r', '30000/1001', '-c:v', 'libx264',
             '-preset', 'veryfast', '-g', '150', '-bf', '3', '-c:a', 'copy', '-movflags', '+faststart', folder / 'cleanup-fractional.mp4'])
    observed = []
    lock = threading.Lock()
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_): pass
        def handle(self):
            try: super().handle()
            except ConnectionResetError: pass
        def do_HEAD(self): self.respond(False)
        def do_GET(self): self.respond(True)
        def respond(self, body):
            name = self.path.lstrip('/')
            path = folder / ("bytes.bin" if name in ("uncached.bin", "changed.bin") else name)
            if '/' in name or not path.is_file(): self.send_error(404); return
            data = path.read_bytes(); size = len(data); start, end = 0, size - 1
            requested = self.headers.get('Range')
            if requested:
                match = re.fullmatch(r'bytes=(\d+)-(\d*)', requested)
                if not match: self.send_error(416); return
                start = int(match[1]); end = min(end, int(match[2])) if match[2] else end
            if start > end: self.send_error(416); return
            self.send_response(206 if requested else 200)
            self.send_header('Content-Length', str(end-start+1)); self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Type', 'application/octet-stream')
            if name != "uncached.bin":
                self.send_header('ETag', '"changed"' if name == "changed.bin" and end > 0 else '"synthetic-stable"')
            if requested: self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.end_headers()
            if body:
                with lock: observed.append(dict(name=name, start=start, end=end, at=time.monotonic()))
                try:
                    # Fixed per-request latency makes speculative fetching observable.
                    time.sleep(.015)
                    self.wfile.write(data[start:end+1])
                except (BrokenPipeError, ConnectionResetError): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = subprocess.run([str(args.binary.resolve()), str(folder.resolve()), f'http://127.0.0.1:{server.server_port}'],
            capture_output=True, text=True, timeout=600, env=dict(os.environ, TMPDIR=str(folder / 'tmp') + '/'))
        (folder / 'checks.log').write_text(result.stdout + result.stderr)
        (folder / 'requests.json').write_text(json.dumps(observed, indent=2))
        print(result.stdout, end='')
        if result.returncode: print(result.stderr, end='')
        if result.returncode: raise RuntimeError(f'Checks failed; see {folder}')
        ranges = [(r['start'], r['end']) for r in observed if r['name'] == 'bytes.bin' and r['end'] > r['start']]
        if len(ranges) != len(set(ranges)) or len(ranges) > 8: raise RuntimeError('Range cache fetched duplicate blocks')
        for file in sorted(folder.glob('*-*.mp4')) + sorted(folder.glob('*-*.ts')):
            if not any(x in file.name for x in ('-local-', '-remote-')): continue
            metadata = json.loads(run(['ffprobe', '-v', 'error', '-show_streams', '-count_frames', '-of', 'json', file]).stdout)
            video = next(s for s in metadata['streams'] if s['codec_type'] == 'video')
            audio = next(s for s in metadata['streams'] if s['codec_type'] == 'audio')
            index = int(file.stem.rsplit('-', 1)[1]) if file.suffix == '.ts' else None
            count = int(video['nb_read_frames'])
            expected = 180 if index == 0 else 15 if index == 1 else 195
            if count != expected: raise RuntimeError(f'Frame loss/duplication {file.name}: {count} vs {expected}')
            if file.name.startswith(('cleanup-', 'ai-')):
                if (video['width'], video['height']) != (1920, 1080) or audio['codec_name'] != 'aac': raise RuntimeError(f'Unexpected output {file.name}')
                if any(video.get(k) != 'bt709' for k in ('color_space', 'color_transfer', 'color_primaries')): raise RuntimeError(f'Unexpected colors {file.name}')
            frames = json.loads(run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_frames',
                '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', file]).stdout)['frames']
            pts = [float(f['best_effort_timestamp_time']) for f in frames]
            if any(abs((b-a) - (1001/30000 if "fractional" in file.name else 1/30)) > .002 for a,b in zip(pts, pts[1:])): raise RuntimeError(f'PTS discontinuity {file.name}')
            print(f'PASS frame count, cadence and tracks: {file.name} ({count} frames)')
        for name in ['cleanup.mp4', 'ai.mp4', 'remux.mkv', 'audio.mkv', 'convert.mkv']:
            transfers = [(r['start'], r['end']) for r in observed if r['name'] == name and r['end'] > r['start']]
            if len(transfers) != len(set(transfers)) or len(transfers) > math.ceil((folder / name).stat().st_size / 524288):
                raise RuntimeError(f'Duplicate upstream reads in preparation: {name}')
        for label in ['cleanup', 'cleanup-fractional']:
            def thumbnails(path):
                data = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-vf', 'scale=160:90',
                    '-fps_mode', 'passthrough', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'], check=True, capture_output=True).stdout
                width = 160 * 90 * 3
                return [data[i:i+width] for i in range(0, len(data), width)]
            source = thumbnails(folder / (label + '.mp4'))
            output = thumbnails(folder / (label + '-local-complete.mp4'))
            for index in [178, 179, 180, 181]:
                errors = [sum(abs(x-y) for x,y in zip(output[index], source[j])) for j in range(index-1, index+2)]
                if errors[1] >= min(errors[0], errors[2]): raise RuntimeError(f'Content shifted at segment boundary: {label}')
            audio = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(folder / (label + '-local-complete.mp4')),
                '-vn', '-ac', '1', '-ar', '48000', '-f', 's16le', '-'], check=True, capture_output=True).stdout
            samples = array.array('h', audio)
            if abs(len(samples) - 312000) > 2048: raise RuntimeError(f'Audio duration drift: {label}')
            for start in range(5 * 48000, 6 * 48000 + 12000, 480):
                if sum(abs(x) for x in samples[start:start+480]) / 480 < 500: raise RuntimeError(f'Audio dropout: {label}')
            print(f'PASS content alignment and audio continuity: {label}')
        if list((folder / 'tmp').rglob('*.mov')): raise RuntimeError('Raw intermediate retained')
        if any(p.is_file() for p in (folder / 'tmp/athrow-prepared-v1').rglob('*')):
            raise RuntimeError('Preparation workspace retained after stop/cancellation')
        print(f'PASS cache reused blocks ({len(ranges)} upstream blocks for overlapping readers)')
        print(folder)
    finally:
        server.shutdown(); server.server_close()

if __name__ == '__main__': main()

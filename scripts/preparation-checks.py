#!/usr/bin/env python3
"""Synthetic stream-copy and delivery checks; does not launch/control the desktop app."""
import http.server
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import urllib.parse

ROOT = Path(__file__).resolve().parent.parent
OUT = Path(tempfile.mkdtemp(prefix='preparation-', dir=ROOT / 'build'))
FFMPEG = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
FFPROBE = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'


def run(arguments, **options):
    return subprocess.run([str(arg) for arg in arguments], check=True, capture_output=True, text=True, **options)


def ffmpeg(*arguments):
    run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-nostdin', '-n', *arguments], timeout=30)


ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
       '-t', '2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-ac', '2', '-movflags', '+faststart', OUT / 'combined.mp4')
ffmpeg('-i', OUT / 'combined.mp4', '-map', '0', '-c', 'copy', OUT / 'combined.mkv')
ffmpeg('-i', OUT / 'combined.mp4', '-map', '0:v:0', '-c', 'copy', OUT / 'video.mp4')
ffmpeg('-i', OUT / 'combined.mp4', '-map', '0:a:0', '-c', 'copy', OUT / 'audio.m4a')
ffmpeg('-i', OUT / 'combined.mp4', '-c:v', 'copy', '-c:a', 'flac', OUT / 'flac.mkv')
ffmpeg('-i', OUT / 'combined.mp4', '-f', 'lavfi', '-i', 'sine=frequency=330:sample_rate=48000',
       '-t', '2', '-map', '0:v', '-map', '0:a', '-map', '1:a',
       '-c:v', 'copy', '-c:a:0', 'pcm_s16le', '-c:a:1', 'aac', '-ac:a:1', '2', OUT / 'multitrack.mkv')
FILES = {f'/{name}': (OUT / name).read_bytes() for name in ['combined.mp4', 'combined.mkv', 'video.mp4', 'audio.m4a', 'flac.mkv', 'multitrack.mkv']}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.respond(False)

    def do_GET(self):
        self.respond(True)

    def respond(self, body):
        data = FILES.get(urllib.parse.urlsplit(self.path).path)
        if data is None:
            self.send_error(404)
            return
        start, end = 0, len(data) - 1
        requested = self.headers.get('Range')
        if requested:
            first, last = requested.removeprefix('bytes=').split('-')
            start = int(first or 0)
            end = min(int(last) if last else end, end)
        self.send_response(206 if requested else 200)
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Accept-Ranges', 'bytes')
        if requested:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        self.end_headers()
        if body:
            try:
                self.wfile.write(data[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    binary = OUT / 'PreparationChecks'
    run(['swiftc', '-swift-version', '6', '-parse-as-library', *sorted((ROOT / 'Sources/AirPlayerCore').glob('*.swift')),
         ROOT / 'Sources/AirPlayerApp/MediaDiagnostics.swift', ROOT / 'Sources/AirPlayerApp/PlaybackController.swift',
         ROOT / 'Tests/PreparationChecks/main.swift', '-o', binary], timeout=90)
    checks = run([binary, f'http://127.0.0.1:{server.server_port}', OUT], timeout=100)
    print(checks.stdout, end='')
    # Compare each compressed packet: this establishes stream copying rather than merely matching codec names.
    def packets(path):
        result = json.loads(run([FFPROBE, '-v', 'error', '-show_packets', '-show_data_hash', 'sha256',
                                 '-show_entries', 'packet=stream_index,data_hash', '-of', 'json', path]).stdout)
        return {index: [p['data_hash'] for p in result['packets'] if p['stream_index'] == index] for index in [0, 1]}
    expected = packets(OUT / 'combined.mp4')
    for name in ['remuxed.mp4', 'joined.mp4']:
        assert packets(OUT / name) == expected, f'{name}: compressed media changed'
    print('PASS identical compressed video/audio packet hashes after remux and join')
    (OUT / 'results.json').write_text(json.dumps(dict(checks='passed', packetHashes='identical', receiver='untested'), indent=2) + '\n')
    print(f'Report: {OUT / "results.json"}')
except subprocess.CalledProcessError as error:
    print(error.stdout, error.stderr)
    raise
finally:
    server.shutdown()
    server.server_close()

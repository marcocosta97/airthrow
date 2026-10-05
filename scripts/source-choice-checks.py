#!/usr/bin/env python3
"""Controller-level source chooser checks over synthetic loopback fixtures.

Default checks inject candidates while exercising real AVPlayer loading.
--yt-dlp adds generic extraction over local pages using the installed helper.
--controller runs playback lifecycle and simulated AirPlay handoff regressions.
This suite shares system media services with the native/preparation/controller
suites, so run it sequentially with those.
"""
import argparse
import http.server
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compile-only', action='store_true',
                    help='Build the checks without starting AVPlayer')
parser.add_argument('--yt-dlp', help='Optional installed yt-dlp path for generic extraction over local fixture pages')
parser.add_argument('--controller', action='store_true', help='Run ControllerChecks using the same fixtures')
args = parser.parse_args()

(ROOT / 'build').mkdir(exist_ok=True)
# Dedicated compiler output path so the binary survives fixture-directory cleanup.
build = ROOT / 'build' / 'source-choice'
build.mkdir(parents=True, exist_ok=True)
out = pathlib.Path(tempfile.mkdtemp(prefix='source-choice-', dir=ROOT / 'build'))


def run(command, timeout=180):
    return subprocess.run([str(x) for x in command], cwd=ROOT, check=True,
                          capture_output=True, text=True, timeout=timeout)


# Original synthetic fixtures only; never reuse a user-owned file. FFmpeg's
# software encoder keeps this test independent of AVAssetWriter's hardware path.
fixture_seconds = '10' if args.controller else '2'
ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin', '-n', '-f', 'lavfi',
     '-i', 'testsrc2=size=320x180:rate=24', '-t', fixture_seconds, '-c:v', 'libx264',
     '-pix_fmt', 'yuv420p', '-an', '-movflags', '+faststart', out / 'video.mp4'])
run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin', '-n', '-i', out / 'video.mp4',
     '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', fixture_seconds,
     '-c:v', 'copy', '-c:a', 'aac', '-ac', '2', '-movflags', '+faststart', out / 'audio.mp4'])

FILES = {
    '/video.mp4': (out / 'video.mp4').read_bytes(),
    '/audio.mp4': (out / 'audio.mp4').read_bytes(),
    '/slow.mp4': (out / 'video.mp4').read_bytes(),
}
CONTENT_TYPES = {}
if args.yt_dlp:
    print(f'Generic extractor: yt-dlp {run([args.yt_dlp, "--version"]).stdout.strip()}', flush=True)
    run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin', '-n', '-i', out / 'audio.mp4',
         '-c', 'copy', '-hls_time', '1', '-hls_playlist_type', 'vod', out / 'stream.m3u8'])
    (out / 'master.m3u8').write_text(
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=320x180,'
        'CODECS="avc1.42e01e,mp4a.40.2"\nstream.m3u8\n')
    FILES['/generic-media'] = FILES['/audio.mp4']
    for name, source in [('generic-file', 'audio.mp4'), ('generic-hls', 'master.m3u8')]:
        FILES[f'/{name}'] = (
            '<html><title>Generic fixture</title><script>'
            f'jwplayer("player").setup({{file:"{source}"}});'
            '</script></html>').encode()
        CONTENT_TYPES[f'/{name}'] = 'text/html'
    for path in [*out.glob('*.m3u8'), *out.glob('*.ts')]:
        FILES['/' + path.name] = path.read_bytes()
        CONTENT_TYPES['/' + path.name] = 'application/vnd.apple.mpegurl' if path.suffix == '.m3u8' else 'video/mp2t'


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *unused):
        pass

    def do_HEAD(self):
        self.respond(False)

    def do_GET(self):
        self.respond(True)

    def respond(self, body):
        path = urllib.parse.urlsplit(self.path).path
        if path == '/slow.mp4':
            time.sleep(2)
        data = FILES.get(path)
        if data is None:
            self.send_error(404)
            return
        start, end = 0, len(data) - 1
        requested = self.headers.get('Range')
        if requested:
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', requested)
            if not match or not any(match.groups()):
                self.send_error(416)
                return
            first, last = match.groups()
            if first:
                start = int(first)
                end = min(int(last), end) if last else end
            else:
                start = max(0, len(data) - int(last))
            if start > end:
                self.send_response(416)
                self.send_header('Content-Range', f'bytes */{len(data)}')
                self.end_headers()
                return
        self.send_response(206 if requested else 200)
        self.send_header('Content-Type', CONTENT_TYPES.get(path, 'video/mp4'))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        if requested:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        self.end_headers()
        if body:
            try:
                self.wfile.write(data[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass


checks = 'ControllerChecks' if args.controller else 'SourceChoiceChecks'
binary = build / checks
server = None
try:
    run(['swiftc', '-swift-version', '6', '-parse-as-library',
         *sorted((ROOT / 'Sources/AirThrowCore').glob('*.swift')),
         ROOT / 'Sources/AirThrowApp/MediaDiagnostics.swift',
         ROOT / 'Sources/AirThrowApp/PlaybackController.swift',
         ROOT / 'Sources/AirThrowApp/ReceiverWaitingScreen.swift',
         ROOT / 'Tests' / checks / 'main.swift', '-o', binary], timeout=180)
    print(f'Built {binary}')
    if args.compile_only:
        print('Compilation only requested; AVPlayer checks were not run.')
        sys.exit(0)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    arguments = [binary, base] if args.controller else [binary, base, out / 'video.mp4']
    if args.yt_dlp and not args.controller:
        arguments.append(args.yt_dlp)
    result = run(arguments, timeout=300)
    print(result.stdout, end='')
    print(result.stderr, end='')
    (out / 'results.json').write_text(json.dumps(
        dict(checks='passed', suite=checks,
             genericExtractor='passed' if args.yt_dlp and not args.controller else 'not run',
             receiver='untested'), indent=2) + '\n')
    print(f'Report: {out / "results.json"}')
except subprocess.CalledProcessError as error:
    print(error.stdout)
    print(error.stderr)
    raise
finally:
    if server is not None:
        server.shutdown()
        server.server_close()

#!/usr/bin/env python3
"""Controller-level source chooser checks over synthetic loopback fixtures.

Injected candidates avoid live websites and helper executables while real AVPlayer
loading is still exercised. This suite shares system media services with the
native/preparation/controller suites, so run it sequentially with those.
"""
import argparse
import http.server
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compile-only', action='store_true',
                    help='Build the checks without starting AVPlayer')
args = parser.parse_args()

(ROOT / 'build').mkdir(exist_ok=True)
# Dedicated compiler output path so the binary survives fixture-directory cleanup.
build = ROOT / 'build' / 'source-choice'
build.mkdir(parents=True, exist_ok=True)
out = pathlib.Path(tempfile.mkdtemp(prefix='source-choice-', dir=ROOT / 'build'))


def run(command, timeout=180):
    return subprocess.run([str(x) for x in command], cwd=ROOT, check=True,
                          capture_output=True, text=True, timeout=timeout)


# Original two-second fixtures only; never reuse a user-owned file.
run(['swift', ROOT / 'scripts' / 'make-test-video.swift', out / 'video.mp4'])
run(['swift', ROOT / 'scripts' / 'add-test-audio.swift', out / 'video.mp4', out / 'audio.mp4'])

FILES = {
    '/video.mp4': (out / 'video.mp4').read_bytes(),
    '/audio.mp4': (out / 'audio.mp4').read_bytes(),
}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *unused):
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
        self.send_header('Content-Type', 'video/mp4')
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


binary = build / 'SourceChoiceChecks'
server = None
try:
    run(['swiftc', '-swift-version', '6', '-parse-as-library',
         *sorted((ROOT / 'Sources/AirThrowCore').glob('*.swift')),
         ROOT / 'Sources/AirThrowApp/MediaDiagnostics.swift',
         ROOT / 'Sources/AirThrowApp/PlaybackController.swift',
         ROOT / 'Tests/SourceChoiceChecks/main.swift', '-o', binary], timeout=180)
    print(f'Built {binary}')
    if args.compile_only:
        print('Compilation only requested; AVPlayer checks were not run.')
        sys.exit(0)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    result = run([binary, base, out / 'video.mp4'], timeout=300)
    print(result.stdout, end='')
    print(result.stderr, end='')
    (out / 'results.json').write_text(json.dumps(
        dict(checks='passed', receiver='untested'), indent=2) + '\n')
    print(f'Report: {out / "results.json"}')
except subprocess.CalledProcessError as error:
    print(error.stdout)
    print(error.stderr)
    raise
finally:
    if server is not None:
        server.shutdown()
        server.server_close()

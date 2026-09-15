#!/usr/bin/env python3
"""Exercise a running AirPlayer with a loopback-only synthetic media server."""
import http.server
import json
import pathlib
import subprocess
import sys
import threading
import time

serve_only = '--serve' in sys.argv
if serve_only:
    sys.argv.remove('--serve')
cli = str(pathlib.Path(sys.argv[1]).resolve())
video = pathlib.Path(sys.argv[2]).read_bytes()
audio_video = pathlib.Path(sys.argv[3]).read_bytes() if len(sys.argv) > 3 else None
slow_release = threading.Event()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.respond(False)

    def do_GET(self):
        self.respond(True)

    def respond(self, body):
        if self.path.startswith('/slow.mp4'):
            slow_release.wait(5)
        data = b'<html>Not a video</html>' if self.path.startswith('/bad') else (
            audio_video if self.path.startswith('/audio.mp4') and audio_video is not None else video)
        start, end = 0, len(data) - 1
        partial = self.headers.get('Range', '').startswith('bytes=')
        if partial:
            interval = self.headers['Range'][6:].split(',')[0].split('-')
            start = int(interval[0] or 0)
            end = min(int(interval[1]) if interval[1] else end, end)
        self.send_response(206 if partial else 200)
        self.send_header('Content-Type', 'text/html' if self.path.startswith('/bad') else 'video/mp4')
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Accept-Ranges', 'bytes')
        if partial:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        self.end_headers()
        if body:
            try:
                self.wfile.write(data[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'

if serve_only:
    # AVFoundation requests byte ranges; Python's basic file server omits them.
    print(f'Video-only fixture: {base}/video.mp4', flush=True)
    if audio_video is not None:
        print(f'Audio fixture: {base}/audio.mp4', flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
    sys.exit(0)

def command(*args, expected=0):
    result = subprocess.run([cli, *args, '--json'], capture_output=True, text=True, timeout=8)
    assert result.returncode == expected, (args[0], result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)

def wait_state(state):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        status = command('status')['status']
        if status['state'] == state:
            return status
        if status['state'] == 'failed' and state != 'failed':
            raise AssertionError(status)
        time.sleep(0.1)
    raise AssertionError(f'Timed out waiting for {state}: {status}')

assert command('status')['status']['state'] == 'idle', 'Stop existing playback before running integration checks.'
try:
    command('play', expected=6)
    command('seek', 'nan', expected=2)
    command('open', 'file:///tmp/test.mp4', expected=2)
    print('PASS invalid commands and exit codes')
    reply = command('open', base + '/video.mp4?signature=a%2Bb%3D')
    assert reply['pending'] and reply['status']['state'] == 'loading'
    ready = wait_state('awaiting_receiver')
    assert not ready['externalPlaybackActive'] and ready['duration'] > 1
    assert ready['hasAudio'] is False, 'The synthetic video-only fixture must flag missing audio'
    assert 'signature' not in json.dumps(ready)
    command('play', expected=4)
    time.sleep(0.5)
    assert command('status')['status'].get('position', 0) < 0.1
    command('pause')
    print('PASS HTTP video loading, status privacy, no receiver playback guard')
    print('PASS video-only source reports no audio track')
    if audio_video is not None:
        command('open', base + '/audio.mp4')
        assert wait_state('awaiting_receiver')['hasAudio'] is True
        print('PASS video with audio reports an audio track')
    command('open', base + '/slow.mp4')
    command('stop')
    slow_release.set()
    time.sleep(0.5)
    assert command('status')['status']['state'] == 'idle'
    assert 'hasAudio' not in command('status')['status']
    print('PASS stop cancels in-flight media load')
    slow_release.clear()
    command('open', base + '/slow.mp4')
    command('open', base + '/video.mp4')
    wait_state('awaiting_receiver')
    slow_release.set()
    time.sleep(0.5)
    assert command('status')['status']['state'] == 'awaiting_receiver'
    print('PASS newer load wins over a stale load')
    command('open', base + '/bad.html')
    failed = wait_state('failed')
    assert failed['error'] and base not in failed['error']
    print('PASS non-video URL error and redacted diagnostics')
finally:
    slow_release.set()
    command('stop')
    server.shutdown()
print('Integration checks passed')

#!/usr/bin/env python3
"""Bounded M3U import and channel lifecycle checks using synthetic local media."""
from pathlib import Path
import argparse
import http.server
import os
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / 'build/iptv-checks'
BUILD.mkdir(parents=True, exist_ok=True)
fixtures = Path(tempfile.mkdtemp(prefix='fixtures-', dir=BUILD))
parser = argparse.ArgumentParser()
parser.add_argument('--serve-only', action='store_true')
args = parser.parse_args()
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(BUILD/'ModuleCache'), SWIFT_MODULECACHE_PATH=str(BUILD/'ModuleCache'))
def run(cmd, **kwargs):
    return subprocess.run(list(map(str, cmd)), cwd=ROOT, env=env, check=True, **kwargs)
ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
run([ffmpeg, '-v', 'error', '-nostdin', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
     '-t', '10', '-c:v', 'libx264', '-g', '48', '-pix_fmt', 'yuv420p', '-an', '-movflags', '+faststart', fixtures/'video.mp4'])
video = (fixtures/'video.mp4').read_bytes()
run([ffmpeg, '-v', 'error', '-nostdin', '-i', fixtures/'video.mp4', '-c:v', 'copy',
     '-hls_time', '2', '-hls_list_size', '0', fixtures/'live.m3u8'])
live = fixtures/'live.m3u8'
live.write_text(live.read_text().replace('#EXT-X-ENDLIST\n', ''))
run([ffmpeg, '-v', 'error', '-nostdin', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
     '-t', '2', '-c:v', 'libx265', '-x265-params', 'log-level=error:pools=1:colorprim=9:transfer=16:colormatrix=9', '-g', '48',
     '-pix_fmt', 'yuv420p10le', '-color_trc', 'smpte2084', '-an', '-f', 'mpegts', fixtures/'hevc.ts'])
run([ffmpeg, '-v', 'error', '-nostdin', '-f', 'lavfi', '-i', 'sine=frequency=440',
     '-t', '2', '-c:a', 'aac', '-f', 'mpegts', fixtures/'audio.ts'])
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *unused): pass
    def do_HEAD(self): self.respond(False)
    def do_GET(self): self.respond(True)
    def respond(self, body):
        path = urllib.parse.urlsplit(self.path).path
        if path == '/unavailable.m3u':
            self.send_response(503); self.end_headers(); return
        if path == '/get.php':
            query = urllib.parse.urlsplit(self.path).query
            allowed = [f'username=fixture%2Buser&password=fixture%26pass%3Dword&type={kind}&output={output}'
                       for kind in ('m3u', 'm3u_plus') for output in ('ts', 'm3u8')]
            if query not in allowed:
                self.send_response(403); self.end_headers(); return
        if path == '/redirect.m3u':
            self.send_response(302); self.send_header('Location', '/nested/channels.m3u'); self.end_headers(); return
        if path == '/oversized.m3u':
            self.send_response(200); self.send_header('Content-Length', '9000000'); self.end_headers()
            if body:
                try:
                    self.wfile.write(b'x' * 8192); self.wfile.flush()
                    time.sleep(0.2)
                except (BrokenPipeError, ConnectionResetError): pass
            return
        if path == '/slow.m3u': time.sleep(2)
        if path == '/cold.m3u': time.sleep(12)
        if path in ('/channels.m3u', '/nested/channels.m3u', '/slow.m3u', '/cold.m3u', '/get.php'):
            data = REMOTE.encode(); mime = 'audio/x-mpegurl'
        elif path == '/bad.m3u': data = b'<html>No catalog</html>'; mime = 'text/html'
        elif path == '/live-channels.m3u':
            data = b'#EXTM3U\n#EXTINF:-1,Live One\nlive.m3u8\n#EXTINF:-1,Live Two\nno-range.m3u8\n'
            mime = 'audio/x-mpegurl'
        elif path == '/live.m3u8': data = live.read_bytes(); mime = 'application/vnd.apple.mpegurl'
        elif path == '/no-range.m3u8':
            data = live.read_bytes().replace(b'live0.ts', b'no-range.ts'); mime = 'application/vnd.apple.mpegurl'
        elif path == '/audio-only.m3u8':
            data = b'#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\naudio.ts\n'
            mime = 'application/vnd.apple.mpegurl'
        elif path == '/hevc.m3u8':
            data = b'#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nhevc.ts\n'
            mime = 'application/vnd.apple.mpegurl'
        elif path == '/no-range.ts': data = (fixtures/'live0.ts').read_bytes(); mime = 'video/mp2t'
        elif path == '/invalid.ts': data = b'Not a native media presentation'; mime = 'video/mp2t'
        elif path.endswith('.ts') and (fixtures/path.removeprefix('/')).is_file():
            data = (fixtures/path.removeprefix('/')).read_bytes(); mime = 'video/mp2t'
        else: data = video; mime = 'video/mp4'
        start, end = 0, len(data)-1
        requested = self.headers.get('Range')
        if path == '/no-range.ts': requested = None
        if requested and not path.endswith('.m3u'):
            value = requested.removeprefix('bytes='); first, _, last = value.partition('-')
            start = int(first) if first else max(0, len(data)-int(last)); end = min(end, int(last)) if first and last else end
        self.send_response(206 if requested and not path.endswith('.m3u') else 200)
        self.send_header('Content-Type', mime); self.send_header('Content-Length', str(end-start+1))
        if requested: self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        if path != '/no-range.ts': self.send_header('Accept-Ranges', 'bytes')
        self.end_headers()
        if body:
            try: self.wfile.write(data[start:end+1])
            except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
BASE = f'http://127.0.0.1:{server.server_port}'
REMOTE = '#EXTM3U\n#PLAYLIST:Fixture TV\n#EXTINF:-1 group-title="News",News One\n../video.mp4?token=a%2Bb%26c\n#EXTINF:-1 group-title="Sports",Sports Two\n../second.mp4\n#EXTINF:-1,Slow Channel\n../slow.mp4\n'
local = fixtures/'channels.m3u'
local.write_text(REMOTE.replace('../', BASE+'/'))
try:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    if args.serve_only:
        print(f'{BASE}/channels.m3u\n{local}', flush=True)
        threading.Event().wait()
    else:
        binary = BUILD/'IPTVChecks'
        run(['swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', BUILD/'ModuleCache',
             *sorted((ROOT/'Sources/AirThrowCore').glob('*.swift')),
             ROOT/'Sources/AirThrowApp/MediaDiagnostics.swift', ROOT/'Sources/AirThrowApp/InterfaceCopy.swift',
             ROOT/'Sources/AirThrowApp/PlaybackController.swift',
             ROOT / 'Sources/AirThrowApp/XtreamLibrary.swift',
             ROOT/'Sources/AirThrowApp/ReceiverWaitingScreen.swift', ROOT/'Tests/IPTVChecks/main.swift', '-o', binary], timeout=180)
        # Foundation enforces the packaged app's transport policy, unlike a
        # standalone command-line binary. Keep these checks under that policy.
        app = BUILD/'IPTVChecks.app'
        executable = app/'Contents/MacOS/IPTVChecks'
        executable.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(binary, executable)
        info = plistlib.loads((ROOT/'Resources/Info.plist').read_bytes())
        info['CFBundleIdentifier'] = 'app.airthrow.iptv-checks'
        info['CFBundleExecutable'] = 'IPTVChecks'
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        run([executable, BASE, local], timeout=180)
finally:
    server.shutdown(); server.server_close()

#!/usr/bin/env python3
"""Local Basic/Digest, receiver delivery and controller checks using synthetic media."""
from pathlib import Path
import argparse
import base64
import hashlib
import http.server
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--serve-only', action='store_true')
args = parser.parse_args()
BUILD = ROOT / 'build/http-authentication-checks'
BUILD.mkdir(parents=True, exist_ok=True)
FIXTURES = Path(tempfile.mkdtemp(prefix='fixtures-', dir=BUILD))
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(BUILD / 'ModuleCache'), SWIFT_MODULECACHE_PATH=str(BUILD / 'ModuleCache'))
def run(cmd, **kwargs):
    return subprocess.run(list(map(str, cmd)), cwd=ROOT, env=env, check=True, **kwargs)
ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
run([ffmpeg, '-v', 'error', '-nostdin', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
     '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '8', '-c:v', 'libx264',
     '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-ac', '2', '-movflags', '+faststart', FIXTURES / 'video.mp4'])
run([ffmpeg, '-v', 'error', '-nostdin', '-i', FIXTURES / 'video.mp4', '-c', 'copy', FIXTURES / 'video.mkv'])
run([ffmpeg, '-v', 'error', '-nostdin', '-i', FIXTURES / 'video.mp4', '-c:v', 'copy', '-c:a', 'pcm_s16le', FIXTURES / 'audio.mkv'])
run([ffmpeg, '-v', 'error', '-nostdin', '-i', FIXTURES / 'video.mp4', '-c', 'copy', '-hls_time', '2',
     '-hls_playlist_type', 'vod', FIXTURES / 'stream.m3u8'])
(FIXTURES / 'master.m3u8').write_text('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=320x180,CODECS="avc1.64000c,mp4a.40.2"\nstream.m3u8\n')
(FIXTURES / 'attributes.m3u8').write_text('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="A",URI="stream.m3u8?token=a%2Bb%26c"\n#EXT-X-KEY:METHOD=AES-128,URI="key"\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:2,\nstream0.ts\n')
(FIXTURES / 'unsafe.m3u8').write_text('#EXTM3U\n#EXTINF:2,\nfile:///etc/passwd\n')
(FIXTURES / 'oversized.m3u8').write_text('#EXTM3U\n' + '#' * 1_048_576)
(FIXTURES / 'key').write_bytes(bytes(range(16)))
(FIXTURES / 'init.mp4').write_bytes((FIXTURES / 'video.mp4').read_bytes())
observed = {'cross_origin_auth': 0, 'signed_queries': 0, 'digest': 0}
NONCE = 'airthrow-local-fixture'
BASIC = 'Basic ' + base64.b64encode(b'fixture-user:fixture-pass').decode()
def md5(value): return hashlib.md5(value.encode()).hexdigest()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *unused): pass
    def handle(self):
        try: super().handle()
        except ConnectionResetError: pass
    def do_HEAD(self): self.respond(False)
    def do_GET(self): self.respond(True)
    def respond(self, body):
        parsed = urllib.parse.urlsplit(self.path)
        group, _, name = parsed.path.lstrip('/').partition('/')
        if group in ('denied', 'bearer'):
            self.send_response(401)
            if group == 'bearer': self.send_header('WWW-Authenticate', 'Bearer realm="fixture"')
            self.send_header('Content-Length', '0'); self.end_headers(); return
        realm = 'different' if group == 'other' else 'fixture'
        auth = self.headers.get('Authorization', '')
        if group == 'public':
            if auth: observed['cross_origin_auth'] += 1
        else:
            accepted = auth == BASIC and group != 'other'
            if group == 'digest':
                fields = {m[0]: m[1] or m[2] for m in re.findall(r'(\w+)=(?:"([^"]*)"|([^, ]+))', auth.removeprefix('Digest '))}
                expected = md5(f'{md5("fixture-user:fixture:fixture-pass")}:{NONCE}:{fields.get("nc")}:{fields.get("cnonce")}:auth:{md5(self.command + ":" + fields.get("uri", ""))}')
                accepted = auth.startswith('Digest ') and fields.get('username') == 'fixture-user' and fields.get('response') == expected
                if accepted: observed['digest'] += 1
            if not accepted:
                self.send_response(401)
                challenge = f'Digest realm="fixture", nonce="{NONCE}", algorithm=MD5, qop="auth"' if group == 'digest' else f'Basic realm="{realm}"'
                self.send_header('WWW-Authenticate', challenge)
                self.send_header('Content-Length', '0'); self.end_headers(); return
        if name == 'delayed.mp4':
            time.sleep(3)
            name = 'video.mp4'
        if name == 'slow.mp4':
            self.send_response(200); self.send_header('Content-Type', 'video/mp4')
            self.send_header('Content-Length', str(8 * 1024 * 1024)); self.end_headers()
            if body:
                try:
                    for _ in range(1024):
                        self.wfile.write(b'x' * 8192); self.wfile.flush(); time.sleep(0.02)
                except (BrokenPipeError, ConnectionResetError): pass
            return
        if name == 'redirect.mp4':
            self.send_response(302); self.send_header('Location', f'http://127.0.0.1:{PUBLIC.server_port}/public/video.mp4')
            self.send_header('Content-Length', '0'); self.end_headers(); return
        if parsed.query:
            if parsed.query != 'token=a%2Bb%26c': self.send_error(403); return
            observed['signed_queries'] += 1
        file = FIXTURES / name
        if not file.is_file(): self.send_error(404); return
        data = file.read_bytes(); start, end = 0, len(data) - 1
        requested = self.headers.get('Range')
        if requested and file.suffix != '.m3u8':
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', requested)
            if not match: self.send_error(416); return
            first, last = match.groups()
            if first: start = int(first); end = min(end, int(last)) if last else end
            else: start = max(0, len(data) - int(last))
            if start > end:
                self.send_response(416); self.send_header('Content-Range', f'bytes */{len(data)}')
                self.send_header('Content-Length', '0'); self.end_headers(); return
        mime = 'application/vnd.apple.mpegurl' if file.suffix == '.m3u8' else 'video/mp2t' if file.suffix == '.ts' else 'video/x-matroska' if file.suffix == '.mkv' else 'video/mp4'
        self.send_response(206 if requested and file.suffix != '.m3u8' else 200)
        self.send_header('Content-Type', mime); self.send_header('Content-Length', str(end-start+1))
        self.send_header('Accept-Ranges', 'bytes')
        if requested and file.suffix != '.m3u8': self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        self.end_headers()
        if body:
            try: self.wfile.write(data[start:end+1])
            except (BrokenPipeError, ConnectionResetError): pass

PUBLIC = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
SERVER = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
try:
    for server in (PUBLIC, SERVER): threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{SERVER.server_port}'
    if args.serve_only:
        print(base, flush=True)
        threading.Event().wait()
    else:
        binary = BUILD / 'HTTPAuthenticationChecks'
        run(['swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', BUILD / 'ModuleCache',
             *sorted((ROOT / 'Sources/AirThrowCore').glob('*.swift')),
             ROOT / 'Sources/AirThrowApp/MediaDiagnostics.swift', ROOT / 'Sources/AirThrowApp/PlaybackController.swift',
             ROOT / 'Sources/AirThrowApp/XtreamLibrary.swift',
             ROOT / 'Sources/AirThrowApp/ReceiverWaitingScreen.swift', ROOT / 'Tests/HTTPAuthenticationChecks/main.swift',
             '-o', binary], timeout=180)
        run([binary, base], timeout=240)
        assert observed['cross_origin_auth'] == 0, 'Credentials sent to another origin'
        assert observed['signed_queries'] > 0 and observed['digest'] > 0
        print('PASS upstream observations: Digest, signed query, no cross-origin Authorization')
finally:
    for server in (PUBLIC, SERVER): server.shutdown(); server.server_close()

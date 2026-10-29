#!/usr/bin/env python3
"""Long synthetic remote MKV indexes with latency; no saved sources or accounts."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import shutil
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/remote-index-checks'
OUT.mkdir(parents=True, exist_ok=True)
FFMPEG = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
FFPROBE = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'

def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, text=True, **kwargs)

source = OUT / 'episode.mkv'
if not source.exists():
    run([FFMPEG, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=2', '-t', '2400',
         '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '12', '-keyint_min', '12', '-sc_threshold', '0', '-flags', '+cgop', source])
# Full preparation/native startup is measured separately from metadata indexing.
playback = OUT / 'episode-av.mkv'
if not playback.exists():
    run([FFMPEG, '-v', 'error', '-y', '-i', source, '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo',
         '-t', '2400', '-map', '0:v', '-map', '1:a', '-c:v', 'copy', '-c:a', 'aac', playback])
packets = json.loads(run([FFPROBE, '-v', 'error', '-read_intervals', '1800%+1', '-select_streams', 'v:0',
                         '-show_packets', '-show_entries', 'packet=pts_time,pos,size,flags', '-of', 'json', source]).stdout)['packets']
packet = packets[0]
assert 'K' in packet['flags'] and abs(float(packet['pts_time']) - 1800) < 0.001
raw = bytearray(source.read_bytes())
position = int(packet['pos'])
width = 9 - raw[position].bit_length()
position += width + 3
end = position + int(packet['size'])
while position < end:
    length = int.from_bytes(raw[position:position+4], 'big')
    assert 0 < length <= end-position-4
    kind = raw[position+4] & 31
    if kind == 5:
        raw[position+4] = (raw[position+4] & 0xe0) | 1
        break
    position += 4 + length
else: raise AssertionError('Fixture keyframe has no IDR')
(OUT / 'bad-frame.mkv').write_bytes(raw)
# A valid stream changes from closed to open AVC GOPs halfway through.
for label, open_gop in [('closed', 0), ('open', 1)]:
    run([FFMPEG, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=24',
         '-t', '18', '-c:v', 'libx264', '-g', '144', '-keyint_min', '144', '-sc_threshold', '0',
         '-x264-params', f'open-gop={open_gop}', OUT / (label + '.mkv')])
(OUT / 'mixed.txt').write_text("file 'closed.mkv'\nfile 'open.mkv'\n")
run([FFMPEG, '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', OUT / 'mixed.txt', '-c', 'copy', OUT / 'mixed.mkv'])
metrics = {'requests': 0, 'bytes': 0}
lock = threading.Lock()
metadata_gate = threading.Event()
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path == '/metrics':
            with lock: data = json.dumps(metrics).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        name = self.path.lstrip('/')
        if name == 'gated.bin':
            size = 64 * 1024 * 1024
            first, last = self.headers['Range'].removeprefix('bytes=').split('-')
            first, last = int(first), min(int(last), size-1) if last else size-1
            count = last-first+1
            if first in [2*1024*1024, 4*1024*1024] and count == 2*1024*1024:
                metadata_gate.wait(3)
            if first == 20*1024*1024 and count == 128*1024:
                metadata_gate.set()
            self.send_response(206); self.send_header('Content-Length', str(count))
            self.send_header('Content-Range', f'bytes {first}-{last}/{size}')
            self.send_header('ETag', '"gated-fixture"'); self.end_headers()
            try: self.wfile.write(b'Z' * count)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if name not in ['episode.mkv', 'bad-frame.mkv', 'mixed.mkv', 'episode-av.mkv']: self.send_error(404); return
        path = OUT / name; size = path.stat().st_size
        value = self.headers.get('Range')
        if not value: self.send_error(400); return
        first, last = value.removeprefix('bytes=').split('-')
        first, last = int(first), min(int(last), size-1) if last else size-1
        time.sleep(0.15)
        self.send_response(206); self.send_header('Content-Length', str(last-first+1))
        self.send_header('Content-Range', f'bytes {first}-{last}/{size}'); self.send_header('ETag', '"fixture"')
        self.send_header('Content-Type', 'video/x-matroska'); self.end_headers()
        try:
            with path.open('rb') as f:
                f.seek(first); data = f.read(last-first+1); self.wfile.write(data)
                with lock: metrics['requests'] += 1; metrics['bytes'] += len(data)
        except (BrokenPipeError, ConnectionResetError): pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    sources = sorted((ROOT / 'Sources/AirThrowCore').glob('*.swift'))
    run(['swiftc', '-swift-version', '6', '-parse-as-library', '-I', ROOT / 'Sources/CSQLite',
         '-module-cache-path', OUT / 'ModuleCache', *sources, ROOT / 'Tests/RemoteIndexChecks/main.swift',
         '-o', OUT / 'Checks'], timeout=240)
    result = run([OUT / 'Checks', f'http://127.0.0.1:{server.server_port}/'], timeout=300)
    print(result.stdout, flush=True)
except subprocess.CalledProcessError as error:
    print(error.stdout, error.stderr, flush=True)
    raise
finally: server.shutdown()

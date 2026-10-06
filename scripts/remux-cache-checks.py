#!/usr/bin/env python3
"""Local packet-preservation and AVPlayer checks; physical AirPlay is separate."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import http.server
import threading
import urllib.parse
import sys
import time
import struct

ROOT = Path(__file__).resolve().parent.parent
(ROOT / 'build').mkdir(exist_ok=True)
reuse = next((a.split('=', 1)[1] for a in sys.argv if a.startswith('--reuse-fixtures=')), None)
OUT = Path(reuse).resolve() if reuse else Path(tempfile.mkdtemp(prefix='remux-cache-', dir=ROOT / 'build'))
FFMPEG = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
FFPROBE = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'


def run(args, **options):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True, **options)


def encode(name, *video):
    run([FFMPEG, '-v', 'error', '-nostdin', '-n', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
         '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '20', *video,
         '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-ac', '2', OUT / name], timeout=45)


if not reuse:
    encode('remux-h264.mkv', '-c:v', 'libx264', '-g', '48', '-keyint_min', '48', '-sc_threshold', '0', '-flags', '+cgop')
    encode('remux-hevc.mkv', '-c:v', 'libx265', '-preset', 'ultrafast', '-x265-params', 'keyint=48:min-keyint=48:scenecut=0:open-gop=0')
    encode('remux-variable.mp4', '-c:v', 'libx264', '-g', '180', '-keyint_min', '180', '-sc_threshold', '0', '-flags', '+cgop', '-movflags', '+faststart')
    run([FFMPEG, '-v', 'error', '-n', '-i', OUT / 'remux-h264.mkv', '-c:v', 'copy', '-c:a', 'libmp3lame', OUT / 'remux-mp3.mkv'], timeout=30)
    (OUT / 'subtitle.srt').write_text('1\n00:00:00,000 --> 00:00:01,000\nHello\n')
    run([FFMPEG, '-v', 'error', '-n', '-i', OUT / 'remux-h264.mkv', '-i', OUT / 'subtitle.srt', '-map', '0', '-map', '1', '-c', 'copy', OUT / 'remux-subtitles.mkv'], timeout=30)
    # Only its first GOP is an IDR; all later recovery points are unsafe cache cuts.
    run([FFMPEG, '-v', 'error', '-n', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24', '-f', 'lavfi', '-i', 'sine=sample_rate=48000',
         '-t', '35', '-c:v', 'libx264', '-g', '48', '-sc_threshold', '0', '-x264-params', 'open-gop=1', '-c:a', 'aac', '-ac', '2', OUT / 'remux-open-gop.mkv'], timeout=45)
# Fail if any actual job attempts encoding, including silent AAC re-encoding.
(OUT / 'copy-only-ffmpeg').write_text('#!/usr/bin/python3\nimport os,sys\na=sys.argv[1:]\nfor flag in ["-c:v","-c:a"]:\n if flag not in a or a[a.index(flag)+1]!="copy": sys.exit(1)\nos.execv(' + repr(FFMPEG) + ',[' + repr(FFMPEG) + ']+a)\n')
(OUT / 'no-index-ffprobe').write_text('#!/usr/bin/python3\nimport os,sys\nif "-show_packets" in sys.argv: sys.exit(1)\nos.execv(' + repr(FFPROBE) + ',[' + repr(FFPROBE) + ']+sys.argv[1:])\n')
(OUT / 'no-chunk-ffmpeg').write_text('#!/usr/bin/python3\nimport os,sys\nif sys.argv[-1].endswith("part.m3u8"): sys.exit(1)\nos.execv(' + repr(FFMPEG) + ',[' + repr(FFMPEG) + ']+sys.argv[1:])\n')
(OUT / 'waiting-index-ffprobe').write_text('#!/usr/bin/python3\nimport os,sys,time,pathlib\nif "-show_packets" in sys.argv:\n pathlib.Path(' + repr(str(OUT / 'index-started')) + ').touch()\n time.sleep(30)\nos.execv(' + repr(FFPROBE) + ',[' + repr(FFPROBE) + ']+sys.argv[1:])\n')
for name in ['copy-only-ffmpeg', 'no-index-ffprobe', 'no-chunk-ffmpeg', 'waiting-index-ffprobe']:
    (OUT / name).chmod(0o700)
for name, maps in [('remux-tail.mp4', []), ('remux-video.mp4', ['-map', '0:v:0']), ('remux-audio.m4a', ['-map', '0:a:0'])]:
    if not (OUT / name).exists():
        run([FFMPEG, '-v', 'error', '-n', '-i', OUT / 'remux-h264.mkv', *maps, '-c', 'copy', OUT / name], timeout=30)

if not (OUT / 'remux-offset-audio.m4a').exists():
    run([FFMPEG, '-v', 'error', '-n', '-copyts', '-itsoffset', '2', '-i', OUT / 'remux-audio.m4a', '-c', 'copy', OUT / 'remux-offset-audio.m4a'], timeout=30)
    shutil.copyfile(OUT / 'remux-video.mp4', OUT / 'remux-offset-video.mp4')

# A sparse, large mdat with the movie index at the far end. Indexing and
# startup must seek to the metadata instead of downloading the padding.
big = OUT / 'remux-large.mp4'
if not big.exists():
    raw = (OUT / 'remux-tail.mp4').read_bytes()
    offset = 0
    while offset < len(raw):
        size = int.from_bytes(raw[offset:offset+4], 'big')
        if raw[offset+4:offset+8] == b'mdat': break
        offset += size
    padding = 128 * 1024 * 1024
    with big.open('wb') as f:
        f.write(raw[:offset])
        f.write(struct.pack('>I', size + padding))
        f.write(raw[offset+4:offset+size])
        f.seek(offset+size+padding)
        f.write(raw[offset+size:])

stats = {}
stats_lock = threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        name = Path(urllib.parse.urlsplit(self.path).path).name
        if name == '_metrics':
            with stats_lock: data = json.dumps(stats).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        mode = next((prefix for prefix in ['no-range-', 'bad-range-', 'delay-index-'] if name.startswith(prefix)), '')
        file_name = name.removeprefix(mode)
        path = OUT / file_name
        if not path.is_file(): self.send_error(404); return
        if self.headers.get('User-Agent') != 'AirThrow-RemuxChecks': self.send_error(403); return
        size = path.stat().st_size
        start, end = 0, size - 1
        requested = self.headers.get('Range')
        if mode == 'no-range-': requested = None
        if mode == 'bad-range-' and requested and not requested.endswith('-') and requested != 'bytes=0-0': requested = None
        if mode == 'delay-index-' and requested and not requested.endswith('-') and requested != 'bytes=0-0':
            with stats_lock: stats.setdefault(name, {})['waiting'] = True
            time.sleep(30)
        if requested:
            first, last = requested.removeprefix('bytes=').split('-', 1)
            start = int(first); end = min(end, int(last)) if last else end
        if start > end: self.send_error(416); return
        self.send_response(206 if requested else 200)
        self.send_header('Content-Length', str(end-start+1))
        self.send_header('Accept-Ranges', 'bytes')
        if requested: self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        with path.open('rb') as f:
            f.seek(start)
            remaining = end-start+1
            while remaining:
                data = f.read(min(65536, remaining))
                if not data: break
                try: self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError): break
                remaining -= len(data)
                with stats_lock:
                    record = stats.setdefault(name, {})
                    record['sent'] = record.get('sent', 0) + len(data)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
binary = OUT / 'RemuxCacheChecks'
try:
    run(['swiftc', '-swift-version', '6', '-parse-as-library', *sorted((ROOT / 'Sources/AirThrowCore').glob('*.swift')),
         ROOT / 'Tests/RemuxCacheChecks/main.swift', '-o', binary], timeout=90)
    print(run([binary, OUT, f'http://127.0.0.1:{server.server_port}', *[a for a in sys.argv[1:] if a in ['--remote-only', '--fallback-only']]], timeout=300).stdout, end='')
    def packets(path):
        data = json.loads(run([FFPROBE, '-v', 'error', '-show_packets', '-show_entries', 'packet=stream_index,data_hash',
                               '-show_data_hash', 'sha256', '-of', 'json', path], timeout=30).stdout)['packets']
        return [[p['data_hash'] for p in data if p['stream_index'] == st] for st in [0, 1]]
    names = [] if '--remote-only' in sys.argv else ['remux-h264.mkv', 'remux-hevc.mkv', 'remux-variable.mp4']
    names += ['remote-remux-h264.mkv', 'remote-remux-hevc.mkv', 'remote-remux-variable.mp4', 'remote-remux-tail.mp4', 'remote-remux-video.mp4', 'remote-remux-large.mp4', 'remote-remux-offset-video.mp4']
    for name in names:
        chunks = sorted((OUT / (name + '-cached')).glob('*.mp4'), key=lambda p: int(p.stem))
        copied = [[], []]
        for chunk in chunks:
            payload = packets(chunk)
            for st in [0, 1]:
                copied[st].extend(payload[st])
        source_name = name.removeprefix('remote-')
        expected = packets(OUT / source_name)
        if source_name in ['remux-video.mp4', 'remux-offset-video.mp4']:
            expected[1] = packets(OUT / ('remux-offset-audio.m4a' if 'offset' in source_name else 'remux-audio.m4a'))[0]
        assert copied == expected, f'Copy chunks lost, duplicated or changed compressed packets: {name}'
        def frames(path):
            output = run([FFMPEG, '-v', 'error', '-i', path, '-map', '0:v:0', '-f', 'framemd5', '-'], timeout=30).stdout
            return [line.rsplit(',', 1)[-1].strip() for line in output.splitlines() if not line.startswith('#')]
        decoded = [frame for chunk in chunks for frame in frames(chunk)]
        assert decoded == frames(OUT / source_name), f'Independent chunks changed decoded frames: {name}'
        print(f'PASS identical compressed packets and independently decoded video frames: {name}')
except subprocess.CalledProcessError as error:
    print(error.stdout, error.stderr)
    raise
finally:
    server.shutdown()
    print(f'Remux cache fixtures: {OUT}')

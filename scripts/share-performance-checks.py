#!/usr/bin/env python3
"""Opt-in, headless AirThrow/libVLC comparison with synthetic fixtures only.

Uses the libVLC installed in VLC.app with --ignore-config and memory video
callbacks. Never opens VLC/Infuse UI or reads saved sources, accounts or settings.
No AirPlay output, real NAS, bandwidth shaping or product-UI timing is measured.
"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
import base64
import ctypes as C
import json
import os
import statistics
import shutil
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/share-performance-checks'
OUT.mkdir(parents=True, exist_ok=True)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--runs', type=int, default=3)
parser.add_argument('--latency-ms', type=float, default=150)
parser.add_argument('--reuse-build', action='store_true')
parser.add_argument('--profile', choices=['long', '1080p', '1080p-open'], default='long')
args = parser.parse_args()
assert 1 <= args.runs <= 10 and 0 <= args.latency_ms <= 1000
if args.profile == 'long':
    fixture = ROOT / 'build/remote-index-checks/episode-av.mkv'
    assert fixture.is_file(), 'Run scripts/remote-index-checks.py to generate the synthetic fixture.'
    target, description = 1800, '40 minutes, 160x90 H.264 at 2 fps + AAC; low bitrate'
else:
    fixture = OUT / (args.profile + '.mkv')
    target, description = 30, '40 seconds, 1920x1080 H.264 at 30 fps, target 12 Mbit/s + AAC'
    if args.profile == '1080p-open': description += '; open GOP, 3 B-frames'
    if not fixture.exists():
        subprocess.run([shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg', '-v', 'error', '-y',
            '-f', 'lavfi', '-i', 'testsrc2=size=1920x1080:rate=30', '-f', 'lavfi', '-i', 'sine=sample_rate=48000',
            '-t', '40', '-c:v', 'libx264', '-preset', 'veryfast' if args.profile == '1080p-open' else 'ultrafast',
            '-g', '60', '-sc_threshold', '0', '-bf', '3' if args.profile == '1080p-open' else '0',
            '-x264-params', 'open-gop=1' if args.profile == '1080p-open' else 'open-gop=0',
            '-b:v', '12M', '-maxrate', '12M', '-bufsize', '24M', '-c:a', 'aac', '-ac', '2', str(fixture)], check=True, timeout=120)
library = Path('/Applications/VLC.app/Contents/MacOS/lib/libvlc.dylib')
assert library.is_file(), 'This optional comparison requires an existing VLC.app.'
metrics = {'requests': 0, 'bytes': 0}
lock = threading.Lock()
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *unused): pass
    def do_GET(self):
        time.sleep(args.latency_ms / 1000)
        if self.path != '/' + fixture.name: self.send_error(404); return
        if self.headers.get('Authorization') != 'Basic ' + base64.b64encode(b'fixture:fixture').decode():
            self.send_response(401); self.send_header('WWW-Authenticate', 'Basic realm="fixture"')
            self.send_header('Content-Length', '0'); self.end_headers(); return
        size = fixture.stat().st_size
        value = self.headers.get('Range')
        start, end = 0, size - 1
        if value:
            first, last = value.removeprefix('bytes=').split('-')
            start, end = int(first), min(int(last), size - 1) if last else size - 1
        if not 0 <= start <= end < size: self.send_error(416); return
        self.send_response(206 if value else 200)
        self.send_header('Content-Type', 'video/x-matroska'); self.send_header('ETag', '"synthetic"')
        self.send_header('Accept-Ranges', 'bytes'); self.send_header('Content-Length', str(end-start+1))
        if value: self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        with lock: metrics['requests'] += 1
        try:
            with fixture.open('rb') as file:
                file.seek(start)
                while start <= end:
                    data = file.read(min(65536, end-start+1)); self.wfile.write(data); start += len(data)
                    with lock: metrics['bytes'] += len(data)
        except (BrokenPipeError, ConnectionResetError): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}/'
binary = OUT / 'Checks'

def vlc_sample():
    # libVLC is embedded headlessly: no NSView, app interface or window exists.
    os.environ['VLC_PLUGIN_PATH'] = str(library.parent.parent / 'plugins')
    C.CDLL(str(library.parent / 'libvlccore.dylib'), mode=C.RTLD_GLOBAL)
    vlc = C.CDLL(str(library))
    def api(name, result, *parameters):
        fn = getattr(vlc, 'libvlc_' + name); fn.restype = result; fn.argtypes = list(parameters); return fn
    ptr = C.c_void_p
    new = api('new', ptr, C.c_int, C.POINTER(C.c_char_p))
    release = api('release', None, ptr)
    media_new = api('media_new_location', ptr, ptr, C.c_char_p)
    option = api('media_add_option', None, ptr, C.c_char_p)
    media_release = api('media_release', None, ptr)
    player_new = api('media_player_new_from_media', ptr, ptr)
    play = api('media_player_play', C.c_int, ptr)
    stop = api('media_player_stop', None, ptr)
    player_release = api('media_player_release', None, ptr)
    get_state = api('media_player_get_state', C.c_int, ptr)
    get_time = api('media_player_get_time', C.c_int64, ptr)
    set_time = api('media_player_set_time', None, ptr, C.c_int64)
    pause = api('media_player_set_pause', None, ptr, C.c_int)
    get_version = api('get_version', C.c_char_p)
    LOCK = C.CFUNCTYPE(ptr, ptr, C.POINTER(ptr))
    UNLOCK = C.CFUNCTYPE(None, ptr, ptr, C.POINTER(ptr))
    DISPLAY = C.CFUNCTYPE(None, ptr, ptr)
    callbacks = api('video_set_callbacks', None, ptr, LOCK, UNLOCK, DISPLAY, ptr)
    video_format = api('video_set_format', None, ptr, C.c_char_p, C.c_uint, C.c_uint, C.c_uint)
    switches = [b'--ignore-config', b'--no-interact', b'--no-video-title-show', b'--no-osd', b'--aout=dummy', b'--intf=dummy', b'--no-media-library', b'--no-metadata-network-access']
    instance = new(len(switches), (C.c_char_p * len(switches))(*switches))
    assert instance, 'Could not start headless libVLC'
    media = media_new(instance, (base.replace('http://', 'http://fixture:fixture@') + fixture.name).encode())
    option(media, b':http-user=fixture'); option(media, b':http-pwd=fixture')
    player = player_new(media); media_release(media)
    # Aligned video memory, never presented to any display.
    buffers = []
    frames = []
    @LOCK
    def video_lock(opaque, planes):
        buffer = C.create_string_buffer(160 * 90 * 4 + 32)
        buffers.append(buffer)  # Remain valid through display and any redraw until stop.
        address = (C.addressof(buffer) + 31) & ~31
        planes[0] = address
        return address
    @UNLOCK
    def video_unlock(opaque, picture, planes): pass
    @DISPLAY
    def video_display(opaque, picture): frames.append(time.perf_counter())
    callbacks(player, video_lock, video_unlock, video_display, None)
    video_format(player, b'RV32', 160, 90, 160 * 4)
    try:
        began = time.perf_counter()
        assert play(player) == 0
        while not frames and time.perf_counter() - began < 20: time.sleep(0.005)
        assert frames, f'VLC did not decode a first video frame: state={get_state(player)}, time={get_time(player)}, metrics={metrics}'
        first_frame = frames[0] - began
        pause(player, 1)
        pause_deadline = time.perf_counter() + 3
        while get_state(player) != 4 and time.perf_counter() < pause_deadline: time.sleep(0.005)
        assert get_state(player) == 4, 'VLC did not pause before seek'
        time.sleep(0.2)  # Drain any already scheduled old-position display callback.
        old_count = len(frames)
        seek_began = time.perf_counter(); set_time(player, target * 1000)
        while time.perf_counter() - seek_began < 20:
            if len(frames) > old_count and get_time(player) >= target * 1000 - 250: break
            time.sleep(0.005)
        else: raise AssertionError('VLC seek did not produce a new video frame')
        return {'first_frame_seconds': first_frame, 'seek_first_frame_seconds': time.perf_counter() - seek_began,
                'version': get_version().decode()}
    finally:
        stop(player); player_release(player); release(instance)

try:
    if not args.reuse_build:
        sources = sorted((ROOT / 'Sources/AirThrowCore').glob('*.swift'))
        subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-I', str(ROOT / 'Sources/CSQLite'),
            '-module-cache-path', str(OUT / 'ModuleCache'), *map(str, sources),
            str(ROOT / 'Tests/SharePerformanceChecks/main.swift'), '-o', str(binary)], check=True, timeout=240)
    results = []
    for run in range(args.runs):
        row = {}
        for engine in (['AirThrow', 'VLC'] if run % 2 == 0 else ['VLC', 'AirThrow']):
            if engine == 'AirThrow':
                result = subprocess.run([str(binary), base, fixture.name, str(target)], check=True,
                                        capture_output=True, text=True, timeout=90)
                row[engine] = json.loads(result.stdout)
            else: row[engine] = vlc_sample()
        results.append(row)
        print(json.dumps({'run': run+1, **row}), flush=True)
    report = {'latency_ms_per_request': args.latency_ms, 'fixture': description,
              'scope': 'Headless decoded frames, engine defaults, client caches fresh per run; no real NAS, AirPlay or GUI',
              'runs': results, 'median_seconds': {engine: {key: statistics.median(r[engine][key] for r in results)
                  for key in ['first_frame_seconds', 'seek_first_frame_seconds']} for engine in ['AirThrow', 'VLC']}}
    (OUT / (args.profile + f'-{args.latency_ms:g}ms-results.json')).write_text(json.dumps(report, indent=2))
    print(json.dumps(report['median_seconds']), flush=True)
except subprocess.CalledProcessError as error:
    print(error.stdout, error.stderr, flush=True)
    raise
finally: server.shutdown(); server.server_close()

#!/usr/bin/env python3
"""Generate original fixtures and inspect native loading; never claim receiver playback."""
import argparse
import http.server
import json
import math
import pathlib
import platform
import re
import shutil
import struct
import subprocess
import tempfile
import threading
import time
import urllib.parse
import wave

ROOT = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ffmpeg', help='Optional FFmpeg executable for additional test fixtures only')
parser.add_argument('--serve', action='store_true', help='Keep serving fixtures after checks for manual testing')
parser.add_argument('--bind', default='127.0.0.1', help='Server interface; use an explicit LAN IP for receiver tests')
args = parser.parse_args()
(ROOT / 'build').mkdir(exist_ok=True)
out = pathlib.Path(tempfile.mkdtemp(prefix='native-media-', dir=ROOT / 'build'))


def run(command, timeout=120):
    return subprocess.run([str(x) for x in command], cwd=ROOT, check=True,
                          capture_output=True, text=True, timeout=timeout)


def native(script, *arguments):
    run(['swift', ROOT / 'scripts' / script, *arguments])


cases = []

def case(name, path, container, video, audio, expected=None, has_audio=None, skipped=None):
    cases.append(dict(name=name, path=path, container=container, videoCodec=video,
                      audioCodec=audio, expectedState=expected, expectedAudio=has_audio, skipped=skipped))


native('make-test-video.swift', out / 'video.mp4')
native('add-test-audio.swift', out / 'video.mp4', out / 'audio.mp4')
native('add-test-audio.swift', out / 'video.mp4', out / 'audio.mov')
case('MP4 video only', 'video.mp4', 'MP4', 'H.264', 'none', 'awaiting_receiver', False)
case('MP4 with audio', 'audio.mp4', 'MP4', 'H.264', 'AAC', 'awaiting_receiver', True)
case('MOV with audio', 'audio.mov', 'MOV', 'H.264', 'AAC', has_audio=True)
try:
    native('make-test-video.swift', out / 'hevc.mp4', 'hevc')
    case('HEVC video only', 'hevc.mp4', 'MP4', 'HEVC', 'none', has_audio=False)
except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
    case('HEVC video only', None, 'MP4', 'HEVC', 'none', skipped='Native HEVC fixture generation failed on this host')
with wave.open(str(out / 'audio.wav'), 'wb') as wav:
    wav.setparams((1, 2, 44100, 0, 'NONE', 'not compressed'))
    wav.writeframes(b''.join(struct.pack('<h', int(4000 * math.sin(i * 2 * math.pi * 440 / 44100)))
                             for i in range(88200)))
case('Audio only', 'audio.wav', 'WAV', 'none', 'PCM', 'failed')
(out / 'invalid.mp4').write_bytes(b'This is deliberately not video data.')
case('Unreadable media', 'invalid.mp4', 'invalid', 'none', 'none', 'failed')

ffmpeg = args.ffmpeg or shutil.which('ffmpeg')
extra = [
    ('HLS with audio', 'stream.m3u8', 'HLS / MPEG-TS', 'H.264', 'AAC',
     ['-c', 'copy', '-hls_time', '1', '-hls_playlist_type', 'vod']),
    ('HLS video only', 'silent.m3u8', 'HLS / MPEG-TS', 'H.264', 'none',
     ['-an', '-c:v', 'copy', '-hls_time', '1', '-hls_playlist_type', 'vod']),
    ('HLS audio only', 'audio-only.m3u8', 'HLS / MPEG-TS', 'none', 'AAC',
     ['-vn', '-c:a', 'copy', '-hls_time', '1', '-hls_playlist_type', 'vod']),
    ('MKV with audio', 'video.mkv', 'MKV', 'H.264', 'AAC', ['-c', 'copy']),
    ('WebM with audio', 'video.webm', 'WebM', 'VP9', 'Opus', ['-c:v', 'libvpx-vp9', '-c:a', 'libopus']),
    ('Alternative audio codec', 'flac.mkv', 'MKV', 'H.264', 'FLAC', ['-c:v', 'copy', '-c:a', 'flac']),
]
for name, path, container, video, audio, options in extra:
    reason = None
    if not ffmpeg:
        reason = 'FFmpeg not installed; optional fixture skipped'
    else:
        try:
            run([ffmpeg, '-nostdin', '-v', 'error', '-i', out / 'audio.mp4', *options, out / path])
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            reason = 'FFmpeg fixture generation failed; check available encoders'
    expected = ('failed' if video == 'none' else 'awaiting_receiver') if path.endswith('.m3u8') else None
    case(name, None if reason else path, container, video, audio, expected=expected,
         has_audio=None if name == 'HLS video only' else audio != 'none', skipped=reason)
    if name == 'HLS with audio':
        case('HLS without URL extension', None if reason else 'hls-no-extension', container, video, audio,
             expected='awaiting_receiver', has_audio=True, skipped=reason)
if (out / 'silent.m3u8').exists() and (out / 'audio-only.m3u8').exists():
    (out / 'alternate-audio.m3u8').write_text(
        '#EXTM3U\n#EXT-X-VERSION:3\n'
        '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Default",DEFAULT=YES,AUTOSELECT=YES,URI="audio-only.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=500000,CODECS="avc1.42e01e,mp4a.40.2",AUDIO="aac"\n'
        'silent.m3u8\n')
    case('HLS alternate audio', 'alternate-audio.m3u8', 'HLS / MPEG-TS', 'H.264', 'AAC',
         expected='awaiting_receiver', has_audio=True)
(out / 'fixtures.json').write_text(json.dumps(cases, indent=2) + '\n')

# Only expose generated fixtures. URL query strings are ignored and never logged.
files = {p.name: p for p in out.iterdir() if p.suffix in {'.mp4', '.mov', '.wav', '.mkv', '.webm', '.m3u8', '.ts'}}
files['slow.mp4'] = out / 'video.mp4'
if (out / 'stream.m3u8').exists():
    files['hls-no-extension'] = out / 'stream.m3u8'
mime = {'.mp4': 'video/mp4', '.mov': 'video/quicktime', '.wav': 'audio/wav',
        '.mkv': 'video/x-matroska', '.webm': 'video/webm', '.m3u8': 'application/vnd.apple.mpegurl', '.ts': 'video/mp2t'}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *unused):
        pass

    def do_HEAD(self):
        self.respond(False)

    def do_GET(self):
        self.respond(True)

    def respond(self, body):
        name = urllib.parse.urlsplit(self.path).path.removeprefix('/')
        if name in {'oversized-master', 'oversized-stream'}:
            self.send_response(200)
            if name == 'oversized-master':
                self.send_header('Content-Length', str(1024 * 1024 + 1))
            self.end_headers()
            try:
                self.wfile.write(b'x' * (1024 * 1024 + 1))
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        path = files.get(name)
        if path is None:
            self.send_error(404)
            return
        if name == 'slow.mp4':
            time.sleep(2)
        data = path.read_bytes()
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
                if last:
                    end = min(int(last), end)
            else:
                start = max(0, len(data) - int(last))
            if start > end:
                self.send_response(416)
                self.send_header('Content-Range', f'bytes */{len(data)}')
                self.end_headers()
                return
        self.send_response(206 if requested else 200)
        self.send_header('Content-Type', mime[path.suffix])
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


server = http.server.ThreadingHTTPServer((args.bind, 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://{args.bind}:{server.server_port}'
try:
    binary = out / 'MediaChecks'
    run(['swiftc', '-swift-version', '6', '-parse-as-library',
         *sorted((ROOT / 'Sources/AirPlayerCore').glob('*.swift')),
         ROOT / 'Sources/AirPlayerApp/MediaDiagnostics.swift',
         ROOT / 'Sources/AirPlayerApp/PlaybackController.swift',
         ROOT / 'Tests/MediaChecks/main.swift', '-o', binary])
    result = run([binary, base, out / 'fixtures.json'], timeout=360)
    report = dict(macOS=platform.mac_ver()[0], machine=platform.machine(),
                  macModel=run(['sysctl', '-n', 'hw.model']).stdout.strip(),
                  ffmpegVersion=run([ffmpeg, '-version']).stdout.splitlines()[0] if ffmpeg else None,
                  receiverModel=None, receiverFirmware=None,
                  meaning='Native AVPlayer loading only; no sample decoding or receiver playback verified',
                  cases=json.loads(result.stdout))
    (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(result.stderr.strip())
    for entry in report['cases']:
        print(f"{entry['source']['name']}: {entry['loadState']}" +
              (f" ({entry['source']['skipped']})" if entry['source'].get('skipped') else ''))
    print(f'Report: {out / "results.json"}', flush=True)
    if args.serve:
        print(f'Fixture server: {base} (Ctrl-C to stop). Receiver results remain untested.', flush=True)
        threading.Event().wait()
except subprocess.CalledProcessError as error:
    print(error.stderr)
    raise
except KeyboardInterrupt:
    pass
finally:
    server.shutdown()
    server.server_close()

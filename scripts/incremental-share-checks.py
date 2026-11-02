#!/usr/bin/env python3
"""Authenticated loopback WebDAV MKV fixtures. No saved sources or Keychain."""
from check_build import build_check
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64
import json
import os
import shutil
import subprocess
import threading
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build' / 'incremental-share-checks'
OUT.mkdir(parents=True, exist_ok=True)
FFMPEG = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
FFPROBE = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'
LATENCY = float(next((a.split('=', 1)[1] for a in sys.argv if a.startswith('--latency-ms=')), '0')) / 1000

def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, text=True, **kwargs)

def fragment_decode_times(data):
    result = []
    offset = 0
    while offset < len(data):
        size = int.from_bytes(data[offset:offset+4], 'big')
        kind = data[offset+4:offset+8]
        header = 8
        if size == 1:
            size = int.from_bytes(data[offset+8:offset+16], 'big'); header = 16
        if size == 0: size = len(data) - offset
        assert size >= header and offset + size <= len(data)
        body = data[offset+header:offset+size]
        if kind in [b'moof', b'traf']: result += fragment_decode_times(body)
        elif kind == b'tfdt':
            result.append(int.from_bytes(body[4:12 if body[0] == 1 else 8], 'big'))
        offset += size
    return result

(OUT / 'en.srt').write_text('1\n00:00:00,000 --> 00:00:19,000\nCrossing cue\n\n2\n00:00:22,000 --> 00:00:24,000\nLast cue\n')
(OUT / 'it.srt').write_text('1\n00:00:01,000 --> 00:00:02,000\nItaliano\n\n2\n00:00:15,000 --> 00:00:17,000\nAncora\n')
if not (OUT / 'base.mkv').exists():
    run([FFMPEG, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24', '-f', 'lavfi', '-i', 'sine=sample_rate=48000',
         '-t', '30', '-c:v', 'libx264', '-b:v', '900k', '-g', '48', '-sc_threshold', '0', '-flags', '+cgop', '-c:a', 'aac', '-ac', '2', OUT / 'base.mkv'])
for name, encoder in [('aac','aac'), ('mp3','libmp3lame'), ('flac','flac'), ('ac3','ac3'), ('eac3','eac3'), ('dts','dca'), ('truehd','truehd'), ('ass','aac')]:
    if not (OUT / (name + '.mkv')).exists():
        run([FFMPEG, '-v', 'error', '-y', '-i', OUT / 'base.mkv', '-i', OUT / 'en.srt', '-i', OUT / 'it.srt',
             '-map', '0', '-map', '1', '-map', '2', '-c:v', 'copy', '-c:a', encoder, '-strict', '-2', '-c:s', 'ass' if name == 'ass' else 'srt',
             '-metadata:s:s:0', 'language=eng', '-metadata:s:s:1', 'language=ita', OUT / (name + '.mkv')])

# The first half has closed GOPs; only later cues become AVC recovery points.
if not (OUT / 'avc-mixed.mkv').exists():
    for label, seconds, opened in [('avc-closed', 18, 0), ('avc-open', 22, 1)]:
        run([FFMPEG, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
             '-f', 'lavfi', '-i', 'sine=sample_rate=48000', '-t', str(seconds),
             '-c:v', 'libx264', '-g', '48', '-sc_threshold', '0', '-x264-params', f'open-gop={opened}',
             '-c:a', 'aac', '-ac', '2', OUT / (label + '.mkv')])
    (OUT / 'avc-concat.txt').write_text("file 'avc-closed.mkv'\nfile 'avc-open.mkv'\n")
    run([FFMPEG, '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', OUT / 'avc-concat.txt',
         '-i', OUT / 'en.srt', '-i', OUT / 'it.srt', '-map', '0', '-map', '1', '-map', '2', '-c', 'copy', OUT / 'avc-mixed.mkv'])

# Typical HEVC episodes use CRA/open GOPs, including Main 10 sources.
for name, pixel in [('hevc-cra', 'yuv420p'), ('hevc-cra10', 'yuv420p10le')]:
    if not (OUT / (name + '.mkv')).exists():
        run([FFMPEG, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
             '-f', 'lavfi', '-i', 'sine=sample_rate=48000', '-i', OUT / 'en.srt', '-i', OUT / 'it.srt',
             '-t', '40', '-map', '0', '-map', '1', '-map', '2', '-map', '3',
             '-c:v', 'libx265', '-preset', 'ultrafast', '-pix_fmt', pixel,
             '-color_trc', 'bt709', '-color_primaries', 'bt709', '-colorspace', 'bt709',
             '-x265-params', 'keyint=48:min-keyint=48:scenecut=0:open-gop=1:colorprim=bt709:transfer=bt709:colormatrix=bt709:log-level=error',
             '-c:a', 'aac', '-ac', '2', '-c:s', 'srt',
             '-metadata:s:s:0', 'language=eng', '-metadata:s:s:1', 'language=ita', OUT / (name + '.mkv')])

# Combine HEVC Main 10, Dolby audio and eight text tracks, not just AAC/HEVC.
if not (OUT / 'hevc-eac3.mkv').exists():
    run([FFMPEG, '-v', 'error', '-y', '-i', OUT / 'hevc-cra10.mkv',
         '-map', '0:v', '-map', '0:a', *[flag for i in range(8) for flag in ['-map', f'0:s:{i%2}']],
         '-c:v', 'copy', '-c:a', 'eac3', '-ac', '6', '-b:a', '640k', '-c:s', 'copy',
         '-bsf:v', 'hevc_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1',
         '-color_trc', 'bt709', '-color_primaries', 'bt709', '-colorspace', 'bt709',
         *[value for i in range(8) for value in [f'-metadata:s:s:{i}', f'title=Fixture {i+1}']], OUT / 'hevc-eac3.mkv'])

# HEVC configurationVersion=0 predates the standardized hvcC record. The
# decoder accepts it, but some MOV muxers emit an empty hvcC when copying it.
# A same-size patch preserves every packet, Matroska Cue and byte offset.
if not (OUT / 'hevc-legacy.mkv').exists():
    source = OUT / 'hevc-eac3.mkv'
    info = json.loads(run([FFPROBE, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                           'stream=extradata', '-show_data', '-of', 'json', source]).stdout)
    extra = bytes.fromhex(''.join(line.split(':', 1)[1].strip().split('  ', 1)[0].replace(' ', '')
                                 for line in info['streams'][0]['extradata'].strip().splitlines()))
    data = bytearray(source.read_bytes())
    assert len(extra) >= 23 and extra[0] == 1 and data.count(extra) == 1
    data[data.index(extra)] = 0
    (OUT / 'hevc-legacy.mkv').write_bytes(data)

# Match high-resolution, 25 fps Main 10/HDR metadata without a real episode.
if '--surround-only' in sys.argv and not (OUT / 'hevc4k-eac3.mkv').exists():
    run([FFMPEG, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'testsrc2=size=3840x2160:rate=25',
         '-f', 'lavfi', '-i', 'sine=sample_rate=48000', '-i', OUT / 'en.srt', '-i', OUT / 'it.srt',
         '-t', '40', '-map', '0:v', '-map', '1:a', *[flag for i in range(8) for flag in ['-map', f'{2+i%2}:0']],
         '-c:v', 'hevc_videotoolbox', '-profile:v', 'main10', '-pix_fmt', 'p010le', '-b:v', '14M', '-g', '50',
         '-bsf:v', 'hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9',
         '-color_trc', 'smpte2084', '-color_primaries', 'bt2020', '-colorspace', 'bt2020nc',
         '-c:a', 'eac3', '-ac', '6', '-b:a', '640k', '-c:s', 'srt',
         *[value for i in range(8) for value in [f'-metadata:s:s:{i}', f'title=Fixture {i+1}',
             f'-metadata:s:s:{i}', 'language=eng' if i%2 == 0 else 'language=ita']], OUT / 'hevc4k-eac3.mkv'], timeout=180)
if '--surround-only' in sys.argv:
    hdr = OUT / 'hevc4k-eac3.mkv'
    color = json.loads(run([FFPROBE, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                           'stream=color_transfer', '-of', 'json', hdr]).stdout)
    if color['streams'][0].get('color_transfer') != 'smpte2084':
        tagged = OUT / 'hevc4k-eac3-tagged.mkv'
        run([FFMPEG, '-v', 'error', '-y', '-i', hdr, '-map', '0', '-c', 'copy',
             '-bsf:v', 'hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9',
             '-color_trc', 'smpte2084', '-color_primaries', 'bt2020', '-colorspace', 'bt2020nc', tagged])
        tagged.replace(hdr)

# Some FFmpeg/x265 combinations omit VUI transfer tags with multiple inputs.
# Make the synthetic Main 10 SDR intent explicit in both SPS and container.
ten_bit = OUT / 'hevc-cra10.mkv'
color = json.loads(run([FFPROBE, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                       'stream=color_transfer', '-of', 'json', ten_bit]).stdout)
if color['streams'][0].get('color_transfer') != 'bt709':
    tagged = OUT / 'hevc-cra10-tagged.mkv'
    run([FFMPEG, '-v', 'error', '-y', '-i', ten_bit, '-map', '0', '-c', 'copy',
         '-bsf:v', 'hevc_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1',
         '-color_trc', 'bt709', '-color_primaries', 'bt709', '-colorspace', 'bt709', tagged])
    tagged.replace(ten_bit)

# Legacy Cues can omit relative positions and durations. Keep all byte offsets
# unchanged by replacing optional fields with same-sized EBML Void elements.
for name, missing in [('legacy', False), ('unindexed', True)]:
    raw = bytearray((OUT / 'aac.mkv').read_bytes())
    def number(offset, ident=False):
        width = 9 - raw[offset].bit_length()
        value = int.from_bytes(raw[offset:offset+width], 'big')
        return (value if ident else value & ((1 << (7*width))-1)), width
    def children(start, end):
        while start < end:
            ident, iw = number(start, True); size, sw = number(start+iw)
            body = start + iw + sw
            yield ident, start, body, min(body+size,end)
            start = body + size
    def modify(start, end):
        for ident, offset, body, stop in children(start, end):
            if ident in [0x18538067, 0x1c53bb6b, 0xbb]: modify(body, stop)
            elif ident == 0xb7:
                fields = list(children(body, stop))
                track = next((int.from_bytes(raw[a:b],'big') for i,_,a,b in fields if i==0xf7), 0)
                if track in [2,3]:
                    if missing: raw[offset] = 0xec
                    else:
                        for field, position, _, _ in fields:
                            if field in [0xf0,0xb2]: raw[position] = 0xec
    modify(0,len(raw))
    (OUT / (name+'.mkv')).write_bytes(raw)

# A sparse Matroska Void expands the source without moving its Cues. Neither
# indexing nor startup may transfer this unused payload.
large = OUT / 'large.mkv'
if not large.exists():
    raw = (OUT / 'aac.mkv').read_bytes()
    def vint(offset, ident=False):
        width = 9 - raw[offset].bit_length()
        value = int.from_bytes(raw[offset:offset+width], 'big')
        return (value if ident else value & ((1 << (7*width))-1)), width
    _, iw = vint(0, True); size, sw = vint(iw)
    segment = iw + sw + size
    ident, iw = vint(segment, True); size, sw = vint(segment+iw)
    assert ident == 0x18538067 and sw == 8
    padding = 128 * 1024 * 1024
    with large.open('wb') as f:
        f.write(raw[:segment+iw])
        f.write(((1 << 56) | (size + padding + 9)).to_bytes(8, 'big'))
        f.write(raw[segment+iw+sw:])
        f.write(bytes([0xec]) + ((1 << 56) | padding).to_bytes(8, 'big'))
        f.seek(padding-1, 1); f.write(bytes([0]))
for codec in ['aac','mp3','flac','ac3','eac3','dts','truehd','ass','legacy']:
    assert (OUT / (codec + '.mkv')).stat().st_size > 2 * 1024 * 1024

metrics = {'sent': 0, 'range_requests': 0, 'plain_requests': 0, 'mutable_reads': 0}
metrics_lock = threading.Lock()
mutable_value = b"A"
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        global mutable_value
        if self.path == '/_advance':
            mutable_value = b'B'
            self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers(); return
        if self.path == '/mutable.bin':
            with metrics_lock: metrics['mutable_reads'] += 1
            size = 8 * 1024 * 1024
            first, last = self.headers.get('Range', 'bytes=0-').removeprefix('bytes=').split('-')
            start, end = int(first), int(last) if last else size-1
            data = mutable_value * (end-start+1)
            self.send_response(206); self.send_header('Content-Length', str(len(data)))
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}'); self.end_headers(); self.wfile.write(data); return
        if self.path == '/_metrics':
            with metrics_lock: data = json.dumps(metrics).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data); return
        time.sleep(LATENCY)
        if self.headers.get('Authorization') != 'Basic ' + base64.b64encode(b'fixture:fixture').decode():
            self.send_response(401); self.send_header('WWW-Authenticate', 'Basic realm="fixture"'); self.send_header('Content-Length', '0'); self.end_headers(); return
        name = self.path.lstrip('/')
        if name not in [c + '.mkv' for c in ['large','aac','mp3','flac','ac3','eac3','dts','truehd','ass','legacy','unindexed','hevc-cra','hevc-cra10','avc-mixed','hevc-eac3','hevc-legacy','hevc4k-eac3']]:
            self.send_error(404); return
        path = OUT / name
        size = path.stat().st_size
        start, end = 0, size - 1
        ranged = self.headers.get('Range')
        if ranged:
            with metrics_lock: metrics['range_requests'] += 1
            a,b = ranged.removeprefix('bytes=').split('-'); start = int(a); end = min(int(b), end) if b else end
        else:
            with metrics_lock: metrics['plain_requests'] += 1
        self.send_response(206 if ranged else 200)
        self.send_header('Content-Type', 'video/x-matroska'); self.send_header('Content-Length', str(end - start + 1)); self.send_header('Accept-Ranges', 'bytes')
        if name != 'legacy.mkv': self.send_header('ETag', '"fixture-v1"')
        if ranged: self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        try:
            with path.open('rb') as f:
                f.seek(start)
                while start <= end:
                    data = f.read(min(16384, end - start + 1))
                    self.wfile.write(data)
                    with metrics_lock: metrics['sent'] += len(data)
                    start += len(data)
        except (BrokenPipeError, ConnectionResetError): pass

server = ThreadingHTTPServer(('127.0.0.1',0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    build_check('IncrementalShareChecks', OUT / 'Checks')
    result = run([OUT / 'Checks', f'http://127.0.0.1:{server.server_port}/', OUT, *[flag for flag in ['--hevc-only', '--avc-only', '--surround-only'] if flag in sys.argv]], timeout=300)
    print(result.stdout, flush=True)
    cases = ['hevc-eac3', 'hevc-legacy', 'hevc4k-eac3'] if '--surround-only' in sys.argv else ['avc-mixed'] if '--avc-only' in sys.argv else ['hevc-cra','hevc-cra10','hevc-legacy'] if '--hevc-only' in sys.argv else ['large','aac','mp3','flac','ac3','eac3','dts','truehd','ass','legacy','hevc-cra','hevc-cra10','avc-mixed','hevc-eac3','hevc-legacy']
    for codec in cases:
        for file in sorted((OUT / codec).glob('*.mp4')):
            run([FFMPEG, '-v', 'error', '-xerror', '-i', file, '-f', 'null', '-'], timeout=30)
            info = json.loads(run([FFPROBE, '-v', 'error', '-show_streams', '-of', 'json', file]).stdout)
            if file.name.startswith('chunk'):
                assert next(s for s in info['streams'] if s['codec_type']=='video')['codec_name']==('hevc' if codec.startswith('hevc') else 'h264')
                expected = 'eac3' if codec in ['hevc-eac3', 'hevc-legacy', 'hevc4k-eac3'] else codec if codec in ['ac3','eac3'] else 'aac'
                assert next(s for s in info['streams'] if s['codec_type']=='audio')['codec_name']==expected
            else: assert info['streams'][0]['codec_name']=='aac'
    def packets(file, hevc=False):
        if hevc:
            # Framing normalization can repeat initialization SEI at recovery
            # points. Compare all coded picture NALs in canonical Annex B;
            # decoded-frame hashes below independently verify every picture.
            text = run([FFMPEG, '-v', 'error', '-i', file, '-map', '0:v:0', '-c:v', 'copy',
                        '-bsf:v', 'hevc_mp4toannexb,filter_units=pass_types=0-31', '-f', 'framehash', '-']).stdout
            return [line.split(',')[-1].strip() for line in text.splitlines() if not line.startswith('#')]
        return [p['data_hash'] for p in json.loads(run([FFPROBE, '-v', 'error', '-select_streams', 'v:0', '-show_packets', '-show_entries', 'packet=data_hash', '-show_data_hash', 'sha256', '-of', 'json', file]).stdout)['packets']]
    for codec in cases:
        chunks = sorted((OUT / codec).glob('chunk*.mp4'), key=lambda p: int(p.stem[5:]))
        clocks = [fragment_decode_times(p.read_bytes()) for p in chunks]
        assert clocks and all(len(t) == 2 and min(t) > 0 for t in clocks), codec
        assert all(all(b > a for a,b in zip(first,second)) for first,second in zip(clocks,clocks[1:])), codec
        print('PASS absolute decode timestamps advance across every fragment:', codec)
        hevc = codec.startswith('hevc')
        assert [h for p in chunks for h in packets(p, hevc)] == packets(OUT / (codec + '.mkv'), hevc), codec
        print('PASS identical ordered compressed picture NALs:' if hevc else 'PASS identical ordered compressed video packets:', codec)
    for codec in [c for c in cases if c in ['hevc-cra', 'hevc-cra10', 'avc-mixed', 'hevc-eac3', 'hevc-legacy', 'hevc4k-eac3']]:
        listing = OUT / (codec + '-concat.txt')
        listing.write_text(''.join("file '" + str(p.resolve()) + "'\n" for p in sorted((OUT / codec).glob('chunk*.mp4'), key=lambda p: int(p.stem[5:]))))
        def frame_hashes(inputs):
            text = run([FFMPEG, '-v', 'error', '-xerror', *inputs, '-map', '0:v', '-fps_mode', 'passthrough', '-f', 'framehash', '-'], timeout=30).stdout
            return [line.split(',')[-1].strip() for line in text.splitlines() if not line.startswith('#')]
        original = frame_hashes(['-i', OUT / (codec + '.mkv')])
        joined = frame_hashes(['-f', 'concat', '-safe', '0', '-i', listing])
        assert len(original) == (1000 if codec == 'hevc4k-eac3' else 960) and joined == original, (codec, len(original), len(joined))
        print('PASS every decoded frame preserved across recovery boundaries:', codec, len(joined))
    for codec in [c for c in cases if c in ['ac3', 'eac3', 'hevc-eac3', 'hevc-legacy', 'hevc4k-eac3']]:
        previous = None
        for file in sorted((OUT / codec).glob('audio*.mp4'), key=lambda p: int(p.stem[5:])):
            info = json.loads(run([FFPROBE, '-v', 'error', '-select_streams', 'a:0', '-show_packets',
                                  '-show_entries', 'packet=pts,duration:stream=sample_rate', '-of', 'json', file]).stdout)
            packets = info['packets']
            assert info['streams'][0]['sample_rate'] == '48000' and packets
            first, end = packets[0]['pts'], packets[-1]['pts'] + packets[-1]['duration']
            assert previous is None or first == previous, (codec, file.name, first, previous)
            assert all(packet['duration'] == 1024 for packet in packets), (codec, file.name)
            previous = end
        print('PASS AAC fallback has sample-exact continuous packet clocks:', codec)
    assert metrics['plain_requests']==0, metrics
    print('PASS all output chunks decode; compressed media preserved; authenticated requests use Range', metrics)
except subprocess.CalledProcessError as error:
    print(error.stdout, error.stderr, flush=True)
    raise
finally: server.shutdown()

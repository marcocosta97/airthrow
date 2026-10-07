#!/usr/bin/env python3
"""Synthetic stream-copy and delivery checks; does not launch/control the desktop app."""
import http.server
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.parse

sys.stdout.reconfigure(line_buffering=True)

ROOT = Path(__file__).resolve().parent.parent
(ROOT / 'build').mkdir(exist_ok=True)
reuse = next((arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--reuse-fixtures=')), None)
OUT = Path(reuse).resolve() if reuse else Path(tempfile.mkdtemp(prefix='preparation-', dir=ROOT / 'build'))
FFMPEG = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
FFPROBE = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'


def run(arguments, live=False, **options):
    try:
        return subprocess.run([str(arg) for arg in arguments], check=True,
                              capture_output=not live, text=True, **options)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        for name, stream in [('stdout', sys.stdout), ('stderr', sys.stderr)]:
            output = getattr(error, name, None)
            if output:
                stream.write(output.decode(errors='replace') if isinstance(output, bytes) else output)
                stream.flush()
        raise


def ffmpeg(*arguments):
    run([FFMPEG, '-hide_banner', '-loglevel', 'error', '-nostdin', '-n', *arguments], timeout=30)


def fraction(value):
    numerator, _, denominator = (value or '0/0').partition('/')
    return float(numerator or 0) / float(denominator) if float(denominator or 0) else 0.0


if not reuse:
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
           '-t', '2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-ac', '2', '-movflags', '+faststart', OUT / 'combined.mp4')
    ffmpeg('-i', OUT / 'combined.mp4', '-c', 'copy', '-hls_time', '1', '-hls_playlist_type', 'vod', OUT / 'source-hls.m3u8')
    ffmpeg('-i', OUT / 'combined.mp4', '-map', '0', '-c', 'copy', OUT / 'combined.mkv')
    (OUT / 'subtitle-it.srt').write_text('1\n00:00:00,200 --> 00:00:01,200\nCiao\n', encoding='utf-8')
    (OUT / 'subtitle-en.srt').write_text('1\n00:00:00,200 --> 00:00:01,200\nHello\n', encoding='utf-8')
    ffmpeg('-i', OUT / 'combined.mp4', '-i', OUT / 'subtitle-it.srt', '-i', OUT / 'subtitle-en.srt',
           '-map', '0:v:0', '-map', '0:a:0', '-map', '1:s:0', '-map', '2:s:0',
           '-c:v', 'copy', '-c:a', 'copy', '-c:s', 'subrip',
           '-metadata:s:s:0', 'language=ita', '-metadata:s:s:1', 'language=eng', OUT / 'subtitles.mkv')
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
           '-t', '2', '-c:v', 'mpeg2video', '-c:a', 'mp2', '-f', 'mpeg', OUT / 'synthetic.mpg')
    ffmpeg('-i', OUT / 'combined.mp4', '-map', '0:v:0', '-c', 'copy', OUT / 'video.mp4')
    ffmpeg('-i', OUT / 'combined.mp4', '-map', '0:a:0', '-c', 'copy', OUT / 'audio.m4a')
    ffmpeg('-i', OUT / 'combined.mp4', '-c:v', 'copy', '-c:a', 'flac', OUT / 'flac.mkv')
    ffmpeg('-i', OUT / 'combined.mp4', '-f', 'lavfi', '-i', 'sine=frequency=330:sample_rate=48000',
           '-t', '2', '-map', '0:v', '-map', '0:a', '-map', '1:a',
           '-c:v', 'copy', '-c:a:0', 'pcm_s16le', '-c:a:1', 'aac', '-ac:a:1', '2', OUT / 'multitrack.mkv')
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
           '-t', '2', '-c:v', 'libvpx-vp9', '-b:v', '0', '-crf', '30', '-c:a', 'libopus', OUT / 'vp9-opus.mkv')
    # Compatible 4K H.264 is remuxed; 100 fps still requires bounded conversion.
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=3840x2160:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
           '-t', '2', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-ac', '2',
           OUT / 'uhd.mkv')
    ffmpeg('-i', OUT / 'combined.mkv', '-c:v', 'libx265', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
           '-c:a', 'copy', OUT / 'hevc-sdr.mkv')
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=100', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
           '-t', '2', '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-ac', '2',
           OUT / 'highfps.mkv')
    # A 10-bit layout is not an understood 8-bit SDR input and is refused.
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
           '-t', '2', '-c:v', 'libvpx-vp9', '-pix_fmt', 'yuv420p10le', '-b:v', '200k', '-c:a', 'libopus',
           OUT / 'tenbit.mkv')
    # HDR-tagged input is refused even when video conversion is allowed: output must stay SDR.
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
           '-t', '2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
           '-x264-params', 'colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc',
           '-c:a', 'aac', '-ac', '2', OUT / 'hdr.mkv')
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
           '-t', '20', '-c:v', 'libx264', '-g', '48', '-keyint_min', '48', '-sc_threshold', '0', '-flags', '+cgop',
           '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-ac', '2', '-movflags', '+faststart', OUT / 'long.mp4')
    ffmpeg('-i', OUT / 'long.mp4', '-c:v', 'libvpx-vp9', '-b:v', '0', '-crf', '40',
           '-deadline', 'realtime', '-cpu-used', '8', '-c:a', 'libopus', OUT / 'long-vp9.mkv')
    ffmpeg('-i', OUT / 'long.mp4', '-c:v', 'copy', '-c:a', 'flac', OUT / 'long-flac.mkv')
    # Production runs at twice real time, making readiness-before-completion measurable.
    slow = OUT / 'paced-ffmpeg'
    slow.write_text('#!/usr/bin/python3\nimport os, sys\na = sys.argv[1:]\ni = a.index("-i")\na[i:i] = ["-readrate", "2"]\nos.execv(' + repr(FFMPEG) + ', [' + repr(FFMPEG) + '] + a)\n')
    slow.chmod(0o700)
    below_realtime = OUT / 'below-realtime-ffmpeg'
    below_realtime.write_text(slow.read_text().replace('["-readrate", "2"]', '["-readrate", "0.5"]'))
    below_realtime.chmod(0o700)
    fail = OUT / 'failing-ffmpeg'
    fail.write_text('#!/usr/bin/python3\nimport subprocess, sys\na = sys.argv[1:]\ni = a.index("-i")\na[i:i] = ["-readrate", "2"]\na[-1:-1] = ["-t", "10"]\nsubprocess.run([' + repr(FFMPEG) + '] + a, check=True)\nsys.exit(1)\n')
    fail.chmod(0o700)
    fallback = OUT / 'fallback-ffmpeg'
    fallback.write_text('#!/usr/bin/python3\nimport os, sys\na = sys.argv[1:]\nif "hls" in a: sys.exit(1)\nos.execv(' + repr(FFMPEG) + ', [' + repr(FFMPEG) + '] + a)\n')
    fallback.chmod(0o700)
    oversized = OUT / 'oversized-ffmpeg'
    oversized.write_text('#!/usr/bin/python3\nimport pathlib, sys, time\np = pathlib.Path(sys.argv[-1]).with_name("segment000000.ts.tmp")\nwith p.open("wb") as f: f.truncate(8 * 1024 * 1024)\ntime.sleep(20)\n')
    oversized.chmod(0o700)
    # Refuses the hardware preflight, so conversion must succeed through libx264.
    software = OUT / 'software-ffmpeg'
    software.write_text('#!/usr/bin/python3\nimport os, sys\na = sys.argv[1:]\nif "h264_videotoolbox" in a or "hevc_videotoolbox" in a: sys.exit(1)\nos.execv(' + repr(FFMPEG) + ', [' + repr(FFMPEG) + '] + a)\n')
    software.chmod(0o700)
    # Refuses every H.264 preflight so no encoder can be prepared.
    no_encoder = OUT / 'no-encoder-ffmpeg'
    no_encoder.write_text('#!/usr/bin/python3\nimport sys\nsys.exit(1)\n')
    no_encoder.chmod(0o700)
    # Pass the hardware preflight but fail the real job. Log encoder attempts so a
    # hardware HLS failure cannot silently retry hardware MP4 before software.
    hardware_failure = OUT / 'hardware-failure-ffmpeg'
    hardware_failure.write_text('#!/usr/bin/python3\nimport os, pathlib, sys\na = sys.argv[1:]\nhardware = "h264_videotoolbox" in a or "hevc_videotoolbox" in a\npreflight = "lavfi" in a\nwith pathlib.Path(' + repr(str(OUT / 'encoder-attempts.txt')) + ').open("a") as log:\n log.write(("hardware" if hardware else "software") + ("-preflight" if preflight else "-job") + "\\n")\nif hardware: sys.exit(0 if preflight else 1)\nos.execv(' + repr(FFMPEG) + ', [' + repr(FFMPEG) + '] + a)\n')
    hardware_failure.chmod(0o700)
    # A finite, seekable source larger than the rolling-cache budget.
    ffmpeg('-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000',
           '-t', '120', '-c:v', 'mpeg2video', '-b:v', '1500k', '-c:a', 'mp2', '-f', 'mpeg', OUT / 'cache-source.mpg')
    cache_encoder = OUT / 'cache-ffmpeg'
    cache_encoder.write_text('#!/usr/bin/python3\nimport os, pathlib, sys\na = sys.argv[1:]\nif a[-1].endswith("part.m3u8"):\n with pathlib.Path(' + repr(str(OUT / 'cache-jobs.txt')) + ').open("a") as log: log.write(a[-1] + "\\n")\nos.execv(' + repr(FFMPEG) + ', [' + repr(FFMPEG) + '] + a)\n')
    cache_encoder.chmod(0o700)
FILES = {f'/{name}': (OUT / name).read_bytes() for name in ['combined.mp4', 'combined.mkv', 'subtitles.mkv', 'video.mp4', 'audio.m4a',
                                                            'flac.mkv', 'multitrack.mkv', 'long.mp4', 'vp9-opus.mkv',
                                                            'hdr.mkv', 'uhd.mkv', 'hevc-sdr.mkv', 'highfps.mkv', 'tenbit.mkv',
                                                            'long-vp9.mkv', 'long-flac.mkv']}
FILES['/no-range-vp9.mkv'] = (OUT / 'long-vp9.mkv').read_bytes()
FILES['/native-stream'] = (OUT / 'source-hls.m3u8').read_bytes()
FILES.update({f'/{path.name}': path.read_bytes() for path in OUT.glob('source-hls*.ts')})


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
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
        requested = None if urllib.parse.urlsplit(self.path).path == '/no-range-vp9.mkv' else self.headers.get('Range')
        if requested:
            first, last = requested.removeprefix('bytes=').split('-')
            start = int(first or 0)
            end = min(int(last) if last else end, end)
        self.send_response(206 if requested else 200)
        if urllib.parse.urlsplit(self.path).path == '/native-stream':
            self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Accept-Ranges', 'none' if urllib.parse.urlsplit(self.path).path == '/no-range-vp9.mkv' else 'bytes')
        if requested:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(data)}')
        self.end_headers()
        if body:
            try:
                self.wfile.write(data[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    if "--progressive-only" not in sys.argv and "--cache-only" not in sys.argv:
        binary = OUT / 'PreparationChecks'
        run(['swiftc', '-swift-version', '6', '-parse-as-library', *sorted((ROOT / 'Sources/AirThrowCore').glob('*.swift')),
             ROOT / 'Sources/AirThrowApp/MediaDiagnostics.swift', ROOT / 'Sources/AirThrowApp/PlaybackController.swift',
             ROOT / 'Sources/AirThrowApp/ReceiverWaitingScreen.swift',
             ROOT / 'Tests/PreparationChecks/main.swift', '-o', binary], timeout=90)
        run([binary, f'http://127.0.0.1:{server.server_port}', OUT], live=True, timeout=180)
        # Compare each compressed packet: this establishes stream copying rather than merely matching codec names.
        def packets(path):
            result = json.loads(run([FFPROBE, '-v', 'error', '-show_packets', '-show_data_hash', 'sha256',
                                     '-show_entries', 'packet=stream_index,data_hash', '-of', 'json', path]).stdout)
            return {index: [p['data_hash'] for p in result['packets'] if p['stream_index'] == index] for index in [0, 1]}
        expected = packets(OUT / 'combined.mp4')
        for name in ['remuxed.mp4', 'joined.mp4', 'local-remuxed.mp4']:
            assert packets(OUT / name) == expected, f'{name}: compressed media changed'
        assert packets(OUT / 'hevc-remuxed.mp4') == packets(OUT / 'hevc-sdr.mkv'), \
            'HEVC remux changed compressed packets'
        # Audio conversion must preserve the H.264 packets and only re-encode audio.
        audio_converted = packets(OUT / 'audio-converted.mp4')
        assert audio_converted[0] == expected[0], 'audio conversion changed the video packets'
        assert audio_converted[1] != expected[1], 'audio conversion did not re-encode the audio'
        print('PASS identical compressed video/audio packet hashes after remux and join')

        # Validate the actual converted output profile, not just the reported path.
        def streams(path):
            return json.loads(run([FFPROBE, '-v', 'error', '-show_entries',
                'stream=codec_name,codec_type,codec_tag_string,pix_fmt,width,height,avg_frame_rate,channels,sample_rate',
                '-of', 'json', path]).stdout)['streams']

        video_converted = streams(OUT / 'video-converted.mp4')
        video = [s for s in video_converted if s['codec_type'] == 'video']
        audio = [s for s in video_converted if s['codec_type'] == 'audio']
        assert len(video) == 1 and len(audio) == 1, 'converted output lost a track'
        assert video[0]['codec_name'] == 'h264' and video[0]['pix_fmt'] == 'yuv420p', \
            'converted video is not SDR H.264 4:2:0'
        assert int(video[0]['width']) <= 1920 and int(video[0]['height']) <= 1080, 'converted video exceeded 1080p'
        assert fraction(video[0].get('avg_frame_rate')) <= 60, 'converted video exceeded 60 fps'
        assert audio[0]['codec_name'] == 'aac' and int(audio[0].get('sample_rate', 0)) <= 48000 \
            and int(audio[0].get('channels', 0)) <= 2, 'converted audio is not AAC LC mono/stereo <= 48 kHz'
        audio_only = [s for s in streams(OUT / 'audio-converted.mp4') if s['codec_type'] == 'audio']
        assert audio_only and audio_only[0]['codec_name'] == 'aac', 'audio-only conversion did not produce AAC'
        uhd_video = [s for s in streams(OUT / 'uhd-converted.mp4') if s['codec_type'] == 'video']
        assert uhd_video and int(uhd_video[0]['width']) == 3840 and int(uhd_video[0]['height']) == 2160, \
            '4K input was not retained by remux'
        for preset, height, codec in [('upscale_1080', 1080, 'h264'), ('cleanup_1080', 1080, 'h264'),
                                      ('upscale_4k', 2160, 'hevc'), ('cleanup_4k', 2160, 'hevc')]:
            enhanced = [s for s in streams(OUT / f'{preset}.mp4') if s['codec_type'] == 'video']
            assert enhanced and int(enhanced[0]['height']) == height and enhanced[0]['codec_name'] == codec, \
                f'{preset} did not produce expected SDR output'
        for preset in ['upscale_1080', 'cleanup_1080']:
            output = streams(OUT / f'native-hls-{preset}.mp4')
            video = [stream for stream in output if stream['codec_type'] == 'video']
            audio = [stream for stream in output if stream['codec_type'] == 'audio']
            assert len(video) == 1 and video[0]['codec_name'] == 'h264' and video[0]['pix_fmt'] == 'yuv420p' \
                and int(video[0]['height']) == 1080, f'{preset}: native HLS enhancement lost its video profile'
            assert len(audio) == 1 and audio[0]['codec_name'] == 'aac', f'{preset}: native HLS enhancement lost AAC audio'
        hevc_copy = [s for s in streams(OUT / 'hevc-remuxed.mp4') if s['codec_type'] == 'video']
        assert hevc_copy and hevc_copy[0]['codec_name'] == 'hevc' and hevc_copy[0]['codec_tag_string'] == 'hvc1', \
            'SDR HEVC was not remuxed as hvc1'
        high_fps = [s for s in streams(OUT / 'highfps-converted.mp4') if s['codec_type'] == 'video']
        assert high_fps and fraction(high_fps[0].get('avg_frame_rate')) <= 60, '100 fps input was not capped at 60 fps'
        software = [s for s in streams(OUT / 'software-converted.mp4') if s['codec_type'] == 'video']
        assert software and software[0]['codec_name'] == 'h264', 'software fallback did not produce H.264'
        software_4k = [s for s in streams(OUT / 'software-4k.mp4') if s['codec_type'] == 'video']
        assert software_4k and software_4k[0]['codec_name'] == 'hevc' and int(software_4k[0]['height']) == 2160, \
            '4K software fallback did not produce HEVC'
        tenbit = [s for s in streams(OUT / 'tenbit.mkv') if s['codec_type'] == 'video']
        assert tenbit and tenbit[0]['pix_fmt'] == 'yuv420p10le', '10-bit fixture is not 10-bit'
        print('PASS converted output is SDR H.264 yuv420p <=1080p/60 and AAC LC <=48 kHz mono/stereo')
        print('PASS 4K remux, four enhancement presets, 100->60 fps cap, software fallback and 10-bit refusal')
    cached = OUT / 'CacheChecks'
    run(['swiftc', '-swift-version', '6', '-parse-as-library', *sorted((ROOT / 'Sources/AirThrowCore').glob('*.swift')),
         ROOT / 'Sources/AirThrowApp/MediaDiagnostics.swift', ROOT / 'Sources/AirThrowApp/PlaybackController.swift',
         ROOT / 'Sources/AirThrowApp/ReceiverWaitingScreen.swift',
         ROOT / 'Tests/CacheChecks/main.swift', '-o', cached], timeout=90)
    run([cached, f'http://127.0.0.1:{server.server_port}', OUT], live=True, timeout=240)
    if '--cache-only' in sys.argv:
        print(f'Cache fixtures and results: {OUT}')
        raise SystemExit(0)
    progressive = OUT / 'ProgressiveChecks'
    run(['swiftc', '-swift-version', '6', '-parse-as-library', *sorted((ROOT / 'Sources/AirThrowCore').glob('*.swift')),
         ROOT / 'Sources/AirThrowApp/MediaDiagnostics.swift', ROOT / 'Sources/AirThrowApp/PlaybackController.swift',
         ROOT / 'Sources/AirThrowApp/ReceiverWaitingScreen.swift',
         ROOT / 'Tests/ProgressiveChecks/main.swift', '-o', progressive], timeout=90)
    (OUT / 'encoder-attempts.txt').unlink(missing_ok=True)
    run([progressive, f'http://127.0.0.1:{server.server_port}', OUT], live=True, timeout=240)
    def video_frames(path):
        return [line.split(',')[-1].strip() for line in run([FFMPEG, '-v', 'error', '-i', path,
                '-map', '0:v:0', '-f', 'framemd5', '-']).stdout.splitlines() if not line.startswith('#')]
    assert video_frames(OUT / 'long.mp4') == video_frames(OUT / 'hls/media.m3u8'), 'HLS changed decoded video frames'
    assert video_frames(OUT / 'combined.mp4') == video_frames(OUT / 'joined.ts'), 'HLS join changed video frames'
    streams = json.loads(run([FFPROBE, '-v', 'error', '-show_entries', 'stream=codec_name,codec_type', '-of', 'json',
                              OUT / 'joined.ts']).stdout)['streams']
    assert sorted(s['codec_name'] for s in streams) == ['aac', 'h264'], 'HLS join lost audio or video'
    print('PASS identical decoded video frames after HLS remux/join and retained AAC audio')
    # The first completed converted segment was probed before handoff; verify the
    # bounded SDR H.264/AAC output independently from the saved TS.
    converted = json.loads(run([FFPROBE, '-v', 'error', '-show_entries',
        'stream=codec_name,codec_type,pix_fmt,width,height,avg_frame_rate,profile,channels,sample_rate',
        '-of', 'json', OUT / 'converted.ts']).stdout)['streams']
    converted_video = [s for s in converted if s['codec_type'] == 'video']
    converted_audio = [s for s in converted if s['codec_type'] == 'audio']
    assert converted_video and converted_video[0]['codec_name'] == 'h264' \
        and converted_video[0]['pix_fmt'] == 'yuv420p' and 'high' in (converted_video[0].get('profile') or '').lower(), \
        'progressive conversion is not SDR H.264 High'
    assert int(converted_video[0]['width']) <= 1920 and int(converted_video[0]['height']) <= 1080 \
        and fraction(converted_video[0].get('avg_frame_rate')) <= 60, 'progressive conversion exceeded 1080p/60'
    assert converted_audio and converted_audio[0]['codec_name'] == 'aac' \
        and int(converted_audio[0].get('sample_rate', 0)) <= 48000 \
        and int(converted_audio[0].get('channels', 0)) <= 2, 'progressive conversion audio is not bounded AAC'
    print('PASS progressive video+audio conversion segment is bounded SDR H.264 High / AAC')
    (OUT / 'results.json').write_text(json.dumps(dict(checks='passed',
        packetHashes='not run' if '--progressive-only' in sys.argv else 'identical',
        conversion='not run' if '--progressive-only' in sys.argv else 'passed',
        progressiveHLS='passed', receiver='untested'), indent=2) + '\n')
    print(f'Report: {OUT / "results.json"}')
finally:
    server.shutdown()
    server.server_close()

#!/usr/bin/env python3
"""Local inputs exercise live remux/conversion, rolling delivery and cleanup."""
import http.server
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent
(ROOT / 'build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='live-remux-', dir=ROOT / 'build') as temporary:
    output = Path(temporary)
    ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
    ffprobe = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'

    def run(*arguments, timeout=90):
        return subprocess.run([str(argument) for argument in arguments], check=True,
                              capture_output=True, text=True, timeout=timeout)

    run(ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin', '-f', 'lavfi',
        '-i', 'testsrc2=size=320x180:rate=24', '-f', 'lavfi',
        '-i', 'sine=frequency=440:sample_rate=48000', '-t', '32',
        '-c:v', 'libx264', '-g', '48', '-keyint_min', '48', '-sc_threshold', '0',
        '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-ac', '2', output / 'source.mp4')
    for track, mapping in [('video', '0:v:0'), ('audio', '0:a:0')]:
        run(ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin', '-i', output / 'source.mp4',
            '-map', mapping, '-c', 'copy', '-f', 'hls', '-hls_time', '2',
            '-hls_list_size', '0', '-hls_playlist_type', 'vod',
            '-hls_segment_filename', output / f'{track}%03d.ts', output / f'{track}.m3u8')
    run(ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin', '-i', output / 'source.mp4',
        '-map', '0:a:0', '-c:a', 'libopus', output / 'audio-opus.webm')
    run(ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin', '-i', output / 'source.mp4',
        '-map', '0:v:0', '-c:v', 'libvpx-vp9', '-b:v', '500k', '-deadline', 'realtime',
        '-cpu-used', '8', output / 'video-vp9.webm')
    wrapper = output / 'paced-ffmpeg'
    wrapper.write_text('#!/usr/bin/python3\nimport os,sys\na=sys.argv[1:]\n'
                       'for i in reversed([n for n,v in enumerate(a) if v=="-i"]): '
                       'a[i:i]=["-readrate","4"]\n'
                       f'os.execv({str(ffmpeg)!r},[{str(ffmpeg)!r}]+a)\n')
    wrapper.chmod(0o700)
    for name, rate in [('software-ffmpeg', '4'), ('slow-ffmpeg', '0.25')]:
        script = output / name
        script.write_text('#!/usr/bin/python3\nimport os,sys\na=sys.argv[1:]\n'
                          'if "h264_videotoolbox" in a: sys.exit(1)\n'
                          'for i in reversed([n for n,v in enumerate(a) if v=="-i"]): '
                          f'a[i:i]=["-readrate",{rate!r}]\n'
                          f'os.execv({str(ffmpeg)!r},[{str(ffmpeg)!r}]+a)\n')
        script.chmod(0o700)
    failing = output / 'failing-ffmpeg'
    failing.write_text('#!/usr/bin/python3\nimport subprocess,sys\na=sys.argv[1:]\n'
                       'for i in reversed([n for n,v in enumerate(a) if v=="-i"]): '
                       'a[i:i]=["-readrate","4"]\n'
                       'a[-1:-1]=["-t","12"]\n'
                       f'subprocess.run([{str(ffmpeg)!r}]+a,check=True)\nsys.exit(1)\n')
    failing.chmod(0o700)

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(output), **kwargs)
        def log_message(self, *_):
            pass
        def copyfile(self, source, destination):
            try:
                super().copyfile(source, destination)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        binary = output / 'LiveRemuxChecks'
        run('swiftc', '-swift-version', '6', '-parse-as-library',
            *sorted((ROOT / 'Sources/AirThrowCore').glob('*.swift')),
            ROOT / 'Sources/AirThrowApp/MediaDiagnostics.swift',
            ROOT / 'Sources/AirThrowApp/PlaybackController.swift',
            ROOT / 'Tests/LiveRemuxChecks/main.swift', '-o', binary)
        shutil.copytree(ROOT / 'Sources/AirThrowCore/SourceProviders',
                        binary.parent / 'SourceProviders', dirs_exist_ok=True)
        result = run(binary, f'http://127.0.0.1:{server.server_port}', output, timeout=90)
        print(result.stdout, end='')
        streams = [stream['codec_name'] for stream in json.loads(run(ffprobe, '-v', 'error',
            '-show_entries', 'stream=codec_name', '-of', 'json',
            output / 'live-segment.ts').stdout)['streams']]
        assert sorted(streams) == ['aac', 'h264'], f'Live remux changed codecs: {streams}'
        print('PASS live segment contains copied H.264 and AAC tracks')
        for name, expected in [('live-audio-converted.ts', ['aac', 'h264']),
                               ('live-video-converted.ts', ['aac', 'h264'])]:
            details = json.loads(run(ffprobe, '-v', 'error', '-show_entries',
                'stream=codec_name,pix_fmt,width,height,profile,channels,sample_rate',
                '-of', 'json', output / name).stdout)['streams']
            codecs = [stream['codec_name'] for stream in details]
            assert sorted(codecs) == expected, f'{name}: unexpected codecs {codecs}'
            audio = next(stream for stream in details if stream['codec_name'] == 'aac')
            assert int(audio['channels']) <= 2 and int(audio['sample_rate']) <= 48000, \
                f'{name}: AAC output exceeded channel/rate bounds'
            if name == 'live-video-converted.ts':
                video = next(stream for stream in details if stream['codec_name'] == 'h264')
                assert video['pix_fmt'] == 'yuv420p' and 'high' in video['profile'].lower() \
                    and int(video['width']) <= 1920 and int(video['height']) <= 1080, \
                    'Live H.264 output exceeded its SDR profile'
        print('PASS live audio/video conversion produces H.264/AAC segments')
    finally:
        server.shutdown()

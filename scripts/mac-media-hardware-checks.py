#!/usr/bin/env python3
"""Audit actual AirThrow commands using synthetic local media, then time variants.

No app launch, preferences, private streams or global installs. Hardware encoder
success with allow_sw=0 proves hardware encoding. Timings compare the production
VideoToolbox surface path to CPU filters; they do not establish visual equivalence
to Lanczos or measure energy or CPU consumed in system media-service processes.
"""
import argparse
import json
import os
from pathlib import Path
import resource
import shutil
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
TEST_ENV = None


def run(args, **kwargs):
    if TEST_ENV is not None: kwargs.setdefault('env', TEST_ENV)
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def packets(file, stream):
    data = run(['ffprobe', '-v', 'error', '-select_streams', stream, '-show_packets',
                '-show_entries', 'packet=data_hash', '-show_data_hash', 'sha256', '-of', 'json', file], capture_output=True)
    return [p['data_hash'] for p in json.loads(data.stdout)['packets']]


def color_aspect_check(out, ffmpeg, command):
    """Exercise the production surface graph with tagged SD/anamorphic media."""
    source=out/'tagged-anamorphic.mkv'
    run([ffmpeg,'-v','error','-f','lavfi','-i','smptebars=size=720x480:rate=25',
         '-f','lavfi','-i','sine=sample_rate=48000','-t','2','-vf','setsar=8/9',
         '-c:v','libx264','-preset','ultrafast','-pix_fmt','yuv420p',
         '-color_range','tv','-color_primaries','smpte170m','-color_trc','smpte170m',
         '-colorspace','smpte170m','-bsf:v',
         'h264_metadata=colour_primaries=6:transfer_characteristics=6:matrix_coefficients=6',
         '-c:a','aac','-ac','2',source],timeout=30)
    a=command.copy();a[a.index('-i')+1]=str(source);a[-1]=str(out/'tagged-anamorphic.mp4')
    run([ffmpeg,*a],timeout=30)
    probe=run(['ffprobe','-v','error','-show_streams','-of','json',a[-1]],capture_output=True)
    v=next(s for s in json.loads(probe.stdout)['streams'] if s['codec_type']=='video')
    assert v['display_aspect_ratio']=='4:3',v
    assert all(v.get(k)=='smpte170m' for k in ['color_space','color_transfer','color_primaries']),v
    assert v['color_range']=='tv',v
    run([ffmpeg,'-v','error','-xerror','-i',a[-1],'-f','null','-'],timeout=30)
    proof={k:v[k] for k in ['width','height','sample_aspect_ratio','display_aspect_ratio',
                            'color_space','color_transfer','color_primaries','color_range']}
    (out/'color-aspect.json').write_text(json.dumps(proof,indent=2)+'\n')
    return proof


def main():
    global TEST_ENV
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag', default='mac-hardware')
    parser.add_argument('--functional-only', action='store_true', help='Skip repeated timing comparisons')
    options = parser.parse_args()
    assert options.tag.replace('-', '').isalnum()
    out = ROOT/'build'/options.tag
    out.mkdir()  # Keep prior evidence immutable.
    (out/'tmp').mkdir()
    TEST_ENV = dict(os.environ, TMPDIR=str(out/'tmp')+'/')
    ffmpeg = shutil.which('ffmpeg')
    assert ffmpeg
    run([ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=s=1280x720:r=25',
         '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '8',
         '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
         '-g', '50', '-c:a', 'aac', '-ac', '2', out/'input.mkv'], timeout=60)
    run([ffmpeg, '-v', 'error', '-i', out/'input.mkv', '-c:v', 'copy', '-c:a', 'flac', out/'flac.mkv'], timeout=30)
    run([ffmpeg, '-v', 'error', '-i', out/'input.mkv', '-c:v', 'hevc_videotoolbox',
         '-allow_sw', '0', '-pix_fmt', 'yuv420p', '-b:v', '2M', '-c:a', 'copy', out/'hevc-input.mkv'],timeout=30)
    for name, size, rate, extra in [('non-wide','640x480',25,[]),
                                    ('full-range','640x360',25,['-pix_fmt','yuvj420p','-color_range','pc']),
                                    ('high-rate','640x360',100,[])]:
        run([ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', f'testsrc2=s={size}:r={rate}',
             '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '2',
             '-c:v', 'libx264', '-preset', 'ultrafast', *extra, '-c:a', 'aac', '-ac', '2',out/(name+'.mkv')],timeout=30)
    wrapper = out/'fixture-ffmpeg'
    wrapper.write_text('#!/usr/bin/python3\nimport json, os, pathlib, sys\nroot=pathlib.Path('+repr(str(out))+')\n'
                       'with (root/"commands.jsonl").open("a") as f:\n'
                       ' f.write(json.dumps(dict(case=(root/"current-case").read_text(), args=sys.argv[1:]))+"\\n")\n'
                       'a=sys.argv[1:];case=(root/"current-case").read_text()\n'
                       'if case=="no-scale" and any("scale_vt=" in v for v in a): sys.exit(1)\n'
                       'if case=="failed-frames" and "-hwaccel" in a: sys.exit(1)\n'
                       'if case=="software" and any(v.endswith("_videotoolbox") for v in a): sys.exit(1)\n'
                       'os.execv('+repr(ffmpeg)+', ['+repr(ffmpeg)+']+a)\n')
    wrapper.chmod(0o700)
    run(['swiftc', '-swift-version', '6', '-parse-as-library',
         *sorted((ROOT/'Sources/AirThrowCore').glob('*.swift')),
         ROOT/'Tests/MacMediaHardwareChecks/main.swift', '-o', out/'checks'], timeout=120)
    run([out/'checks', out], timeout=180)
    commands = [json.loads(line) for line in (out/'commands.jsonl').read_text().splitlines()]
    jobs = {c['case']: c['args'] for c in commands if 'lavfi' not in c['args']}
    for name in ['remux', 'audio']:
        a = jobs[name]
        assert a[a.index('-c:v')+1]=='copy' and '-hwaccel' not in a and '-vf' not in a
        assert packets(out/'input.mkv', 'v:0') == packets(out/(name+'.mp4'), 'v:0')
    assert jobs['remux'][jobs['remux'].index('-c:a')+1]=='copy'
    assert packets(out/'input.mkv', 'a:0') == packets(out/'remux.mp4', 'a:0')
    assert jobs['audio'][jobs['audio'].index('-c:a')+1]=='aac'
    hardware = {}
    for name in ['h264', 'hevc', 'cleanup']:
        a = jobs[name]
        encoder = a[a.index('-c:v')+1]
        hardware[name] = encoder.endswith('_videotoolbox') and a[a.index('-allow_sw')+1]=='0'
        run([ffmpeg, '-v', 'error', '-xerror', '-i', out/(name+'.mp4'), '-f', 'null', '-'], timeout=60)
    assert all(hardware.values()), 'Hardware unavailable; software output alone is not hardware proof'
    for name in ['h264','hevc','non-wide','hevc-input','separate','progressive','cached']:
        a=jobs[name]
        assert '-hwaccel' in a and 'scale_vt=' in a[a.index('-vf')+1], name
    for name in ['cleanup','lanczos','no-scale','failed-frames','full-range','high-rate']:
        a=jobs[name]
        assert '-hwaccel' not in a and a[a.index('-c:v')+1].endswith('_videotoolbox'),name
    assert 'flags=lanczos' in jobs['lanczos'][jobs['lanczos'].index('-vf')+1]
    assert jobs['software'][jobs['software'].index('-c:v')+1]=='libx264'
    assert any(c['case']=='failed-frames' and '-hwaccel' in c['args'] for c in commands)
    for name in ['no-scale','failed-frames','software','non-wide','hevc-input','separate','full-range','high-rate','lanczos']:
        run([ffmpeg,'-v','error','-xerror','-i',out/(name+'.mp4'),'-f','null','-'],timeout=60)
    probe=run(['ffprobe','-v','error','-show_streams','-of','json',out/'non-wide.mp4'],capture_output=True)
    v=next(s for s in json.loads(probe.stdout)['streams'] if s['codec_type']=='video')
    assert (v['width'],v['height'])==(1440,1080),'Hardware scaler distorted source aspect ratio'
    a=jobs['separate'];assert a.count('-i')==2 and a.count('-hwaccel')==1
    color_aspect=color_aspect_check(out,ffmpeg,jobs['h264'])
    # Replay the exact 4K production command; adjust only decoder/filter/output
    # for explicitly labelled comparisons. This excludes AirThrow/probe CPU.
    base = jobs['hevc']
    measurements = []
    variants = ['production', 'cpu-filters', 'software-decode']
    for repeat in range(0 if options.functional_only else 3):
        for variant in (variants if repeat%2==0 else list(reversed(variants))):
            a = base.copy()
            a[-1] = str(out/f'{variant}-{repeat}.mp4')
            if variant != 'production':
                index=a.index('-hwaccel_output_format');del a[index:index+2]
                if '-pix_fmt' in a: a[a.index('-pix_fmt')+1]='yuv420p'
                else: a[a.index('-c:v'):a.index('-c:v')]=['-pix_fmt','yuv420p']
                a[a.index('-vf')+1]='scale=w=3840:h=2160:flags=lanczos:force_original_aspect_ratio=decrease:force_divisible_by=2'
            if variant == 'software-decode':
                index=a.index('-hwaccel');del a[index:index+2]
            before = resource.getrusage(resource.RUSAGE_CHILDREN)
            began = time.monotonic()
            result = subprocess.run([ffmpeg, *a], capture_output=True)
            wall = time.monotonic()-began
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            cpu = after.ru_utime+after.ru_stime-before.ru_utime-before.ru_stime
            measurements.append(dict(variant=variant, repeat=repeat, wallSeconds=wall,
                                     processCPUSeconds=cpu, exit=result.returncode))
            assert result.returncode == 0, result.stderr.decode(errors='replace')[-2000:]
            probe = run(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', a[-1]], capture_output=True)
            video = next(s for s in json.loads(probe.stdout)['streams'] if s['codec_type']=='video')
            assert (video['codec_name'], video['width'], video['height'], video['pix_fmt']) == ('hevc',3840,2160,'yuv420p')
            assert packets(out/'input.mkv', 'a:0') == packets(a[-1], 'a:0')
            run([ffmpeg, '-v', 'error', '-xerror', '-i', a[-1], '-f', 'null', '-'], timeout=60)
    result = dict(hardwareEncoding=hardware, remuxOriginalPackets=True, audioConversionOriginalVideo=True,
                  passedCases=list(jobs), nativePlayable=True,
                  taggedAnamorphic=color_aspect,
                  measurements=measurements, medians={v:dict(
                      wallSeconds=statistics.median(m['wallSeconds'] for m in measurements if m['variant']==v),
                      processCPUSeconds=statistics.median(m['processCPUSeconds'] for m in measurements if m['variant']==v)) for v in variants if measurements})
    (out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2), flush=True)


if __name__ == '__main__':
    main()

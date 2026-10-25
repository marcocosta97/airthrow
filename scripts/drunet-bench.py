#!/usr/bin/env python3
"""Compare same-resolution DRUNet cleanup on real footage, Gaussian noise and compression.

Uses the same native encoder for control, FFmpeg cleanup and DRUNet. Assets,
models and reports are local experiments, not application dependencies.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import time
import numpy as np

spec = importlib.util.spec_from_file_location('srbench', Path(__file__).with_name('super-resolution-bench.py'))
sr = importlib.util.module_from_spec(spec); spec.loader.exec_module(sr)

def command(args, **kwargs):
    return subprocess.run(list(map(str,args)), check=True, capture_output=True, timeout=180, **kwargs)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--fixtures',type=Path,required=True)
    parser.add_argument('--models',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--repeats',type=int,default=3)
    parser.add_argument('--resume',action='store_true')
    args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    folder=args.output.resolve()
    binary=folder/'SuperResolutionBench'
    if binary.exists() and not args.resume: raise RuntimeError('Refusing to overwrite an existing run')
    if not binary.exists(): shutil.copy2(args.binary,binary)
    report=dict(scope='Same-resolution SDR BT.709 video only; synthetic Gaussian RGB noise and real compression; paired native hardware encoder',
        dimensions='960x540 for motion/foliage; original 136x240 portrait sample',
        computeRequested='all', audioIncluded=False, receiverValidated=False, energyMeasured=False,
        gaussianNoiseSigma=10, gaussianNoiseDomain='decoded BT.709 RGB code values',
        denoiserNoiseDomain='Core ML sRGB image input; sigma is an approximate video strength, not exact sensor noise',
        binarySha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        converterSha256=hashlib.sha256(Path(__file__).with_name('convert-drunet.py').read_bytes()).hexdigest(),
        runnerSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        capabilities=json.loads(command([binary,'--probe']).stdout), repeats=args.repeats,
        conversion=[json.loads(p.read_text()) for p in sorted(args.models.glob('DRUNet-*.json'))], runs=[], failures=[])
    if args.resume:
        previous=json.loads((folder/'report.json').read_text())
        if previous['binarySha256']!=report['binarySha256']:raise RuntimeError('Benchmark binary changed')
        previous['priorRunnerSha256']=previous['runnerSha256']
        previous['runnerSha256']=report['runnerSha256']
        previous.setdefault('recoveredFailures',[]).extend(previous['failures'])
        previous['failures']=[]
        report=previous
    save=lambda: (folder/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    license_path=args.fixtures/'APPLE-SAMPLE-LICENSE.txt'
    if license_path.exists(): shutil.copy2(license_path,folder/license_path.name)
    print(folder,flush=True)
    flags=sr.reference_flags()
    for case,width,height,frames in [('motion-fur',960,540,60),('foliage-noise',960,540,60),('face',136,240,180)]:
        seconds=frames/30
        reference=folder/f'{case}-reference.mp4'
        if not reference.exists(): command(['ffmpeg','-v','error','-nostdin','-n','-i',args.fixtures/f'{case}-reference.mp4',
            '-t',seconds,'-vf',f'scale={width}:{height}:flags=area','-an','-c:v','libx264','-crf','0',*flags,reference])
        sr.validate_output(reference,width,height,frames,seconds)
        for corruption in ['compression','gaussian']:
            input_path=folder/f'{case}-{corruption}-input{".mov" if corruption=="gaussian" else ".mp4"}'
            if input_path.exists(): pass
            elif corruption=='compression':
                command(['ffmpeg','-v','error','-nostdin','-n','-i',reference,'-an','-c:v','libx264','-crf','30',*flags,input_path])
            else:
                data=command(['ffmpeg','-v','error','-i',reference,'-f','rawvideo','-pix_fmt','rgb24','-']).stdout
                rgb=np.frombuffer(data,np.uint8).reshape(frames,height,width,3)
                rng=np.random.default_rng(42)
                noisy=np.clip(rgb.astype(np.float32)+rng.normal(0,10,rgb.shape),0,255).round().astype(np.uint8)
                command(['ffmpeg','-v','error','-nostdin','-n','-f','rawvideo','-pix_fmt','rgb24','-s',f'{width}x{height}',
                    '-r','30','-i','-','-vf','setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709',
                    '-an','-c:v','rawvideo','-pix_fmt','uyvy422',
                    '-color_range','tv','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709',
                    '-movflags','+write_colr',input_path],input=noisy.tobytes())
                del data, rgb, noisy
            labels=['control','ffmpeg-cleanup','drunet-10']+(['drunet-5'] if case!='face' else [])
            for repeat in range(1,args.repeats+1):
                for label in labels if repeat%2 else labels[::-1]:
                    output=folder/f'{case}-{corruption}-{label}-{repeat}.mp4'
                    if any(r['output']==output.name for r in report['runs']):continue
                    start=time.monotonic(); source=input_path
                    if label=='ffmpeg-cleanup':
                        source=folder/f'{output.stem}-filtered.mov'
                        command(['ffmpeg','-v','error','-nostdin','-n','-i',input_path,'-vf',
                            'hqdn3d=1.5:1.5:4:4,deband=1thr=0.02:2thr=0.02:3thr=0.02',
                            '-an','-c:v','rawvideo','-pix_fmt','uyvy422','-color_range','tv','-colorspace','bt709',
                            '-color_primaries','bt709','-color_trc','bt709','-movflags','+write_colr',source])
                    native=[binary,'--backend','coreml' if label.startswith('drunet') else 'lanczos',
                        '--allow-raw-input','--scale','1','--frames',frames,'--input',source,'--output',output,'--compute','all']
                    if label.startswith('drunet'):
                        sigma=label.split('-')[1]
                        native+=['--model',args.models/f'DRUNet-color-{width}x{height}-sigma{sigma}.mlpackage']
                    print('Running',output.stem,flush=True)
                    try:
                        result=command(native)
                        elapsed=time.monotonic()-start
                        row=json.loads(result.stdout)
                        sr.validate_output(output,width,height,frames,seconds)
                        row.update(case=case,corruption=corruption,method=label,repeat=repeat,
                            jobSecondsIncludingStartup=elapsed,jobSpeed=seconds/elapsed,output=output.name,
                            **sr.compare(reference,output))
                        report['runs'].append(row);save()
                    except Exception as error:
                        report['failures'].append(dict(output=output.name,error=str(error),
                            stdout=getattr(error,'stdout',b'').decode(errors='replace')[-2000:],
                            stderr=getattr(error,'stderr',b'').decode(errors='replace')[-2000:]));save();raise
                    finally:
                        if source!=input_path and source.exists(): source.unlink()
    summary=['# DRUNet cleanup experiment','',report['scope'],'',
        '| Clip | Input | Method | Full job | Native pipeline | PSNR | SSIM |',
        '|---|---|---|---:|---:|---:|---:|']
    for case in ['motion-fur','foliage-noise','face']:
        for corruption in ['compression','gaussian']:
            for label in ['control','ffmpeg-cleanup','drunet-5','drunet-10']:
                rows=[r for r in report['runs'] if r['case']==case and r['corruption']==corruption and r['method']==label]
                if not rows: continue
                median=lambda key:statistics.median(r[key] for r in rows)
                summary.append(f'| {case} | {corruption} | {label} | {median("jobSpeed"):.3f}x | {median("pipelineSpeed"):.3f}x | {median("psnr"):.2f} | {median("ssim"):.4f} |')
    (folder/'summary.md').write_text('\n'.join(summary)+'\n')
    print('Report:',folder/'report.json',flush=True)

if __name__=='__main__':main()

#!/usr/bin/env python3
"""Compare isolated Core ML experiments against the same frozen footage/encoder."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import tempfile
import time

import importlib.util
spec = importlib.util.spec_from_file_location('super_resolution_bench', Path(__file__).with_name('super-resolution-bench.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
inspect, validate_output, compare, ffmpeg_lanczos = module.inspect, module.validate_output, module.compare, module.ffmpeg_lanczos


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--models', type=Path, required=True)
    parser.add_argument('--output-root', type=Path, required=True)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--piper', type=Path)
    args = parser.parse_args()
    if not 1 <= args.repeats <= 5: parser.error('Use 1...5 repeats')
    folder = Path(tempfile.mkdtemp(prefix='restoration-', dir=args.output_root)).resolve()
    binary = folder / 'SuperResolutionBench'
    shutil.copy2(args.binary, binary)
    backends = [('lanczos', []), ('low-latency', []),
        ('quick-small', ['--model', args.models / 'QuickSRNet-small-2x.mlpackage']),
        ('quick-medium', ['--model', args.models / 'QuickSRNet-medium-2x.mlpackage'])]
    if args.piper: backends.append(('piper', ['--model', args.piper]))
    report = dict(schemaVersion=1, runs=[], failures=[], binarySha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        runnerSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        capabilities=json.loads(subprocess.check_output([binary, '--probe'])),
        scope='Apple real footage, six seconds at 30fps, paired native encoder, video only; model load and CLI startup measured',
        compute='cpuAndGPU; all/cpuAndNeuralEngine failed in BNNS on this host',
        conversion=json.loads((args.models / 'conversion.json').read_text()),
        fixtureReportSha256=hashlib.sha256((args.fixtures / 'report.json').read_bytes()).hexdigest(),
        audioIncluded=False, receiverValidated=False, energyMeasured=False)
    save = lambda: (folder / 'report.json').write_text(json.dumps(report, indent=2)+'\n')
    license_file = args.fixtures / 'APPLE-SAMPLE-LICENSE.txt'
    if license_file.is_file(): shutil.copy2(license_file, folder / license_file.name)
    print(folder, flush=True)
    for case in ('foliage-noise', 'motion-fur', 'face'):
        reference = args.fixtures / f'{case}-reference.mp4'
        shutil.copy2(reference, folder / reference.name)
        stream = inspect(reference)
        width, height = int(stream['width']), int(stream['height'])
        for crf in (18, 30):
            input_path = args.fixtures / f'{case}-input-crf{crf}.mp4'
            for repeat in range(1, args.repeats+1):
                order = backends if repeat % 2 else backends[::-1]
                for label, extra in order:
                    output = folder / f'{case}-{label}-crf{crf}-{repeat}.mp4'
                    print(f'Running {output.stem}', flush=True)
                    command = [str(binary), '--backend', label if label in ('lanczos','low-latency') else 'coreml',
                        '--input', str(input_path), '--output', str(output), '--frames', '180', '--diagnostics',
                        '--compute', 'gpu', *map(str, extra)]
                    start = time.monotonic()
                    result = subprocess.run(command, capture_output=True, text=True, timeout=240)
                    elapsed = time.monotonic()-start
                    if result.returncode:
                        if output.exists(): output.unlink()
                        report['failures'].append(dict(case=case, backend=label, crf=crf, exitCode=result.returncode,
                            error=result.stdout[-2000:], stderr=result.stderr[-1000:]))
                        save()
                        raise RuntimeError(f'{label} failed; report: {folder}')
                    row = json.loads(result.stdout)
                    validate_output(output, width, height, 180, 6)
                    row.update(backend=label, case=case, inputCRF=crf, repeat=repeat,
                        jobSecondsIncludingStartup=elapsed, jobSpeed=6/elapsed, output=output.name,
                        **compare(reference, output))
                    report['runs'].append(row); save()
            output = folder / f'{case}-ffmpeg-lanczos-crf{crf}.mp4'
            elapsed = ffmpeg_lanczos(input_path, output, width, height)
            validate_output(output, width, height, 180, 6)
            report['runs'].append(dict(case=case, inputCRF=crf, backend='ffmpeg-lanczos', repeat=1,
                jobSpeed=6/elapsed, pipelineSpeed=6/elapsed, output=output.name, **compare(reference, output)))
            save()
    summary = ['# Native restoration experiment', '', report['scope'], '',
        '| Clip | CRF | Backend | Full job speed | Pipeline speed | PSNR | SSIM |',
        '|---|---:|---|---:|---:|---:|---:|']
    for case in ('foliage-noise','motion-fur','face'):
        for crf in (18,30):
            for label in [b[0] for b in backends]+['ffmpeg-lanczos']:
                rows = [r for r in report['runs'] if r['case']==case and r['inputCRF']==crf and r['backend']==label]
                median = lambda key: statistics.median(r[key] for r in rows)
                summary.append(f'| {case} | {crf} | {label} | {median("jobSpeed"):.2f}x | {median("pipelineSpeed"):.2f}x | {median("psnr"):.2f} | {median("ssim"):.4f} |')
    (folder / 'summary.md').write_text('\n'.join(summary)+'\n')
    print(f'Report: {folder / "report.json"}', flush=True)


if __name__ == '__main__':
    main()

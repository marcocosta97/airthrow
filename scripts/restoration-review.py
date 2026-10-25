#!/usr/bin/env python3
"""Aligned exported crops and temporal diagnostics, without opening desktop UI."""
import argparse
import html
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location('sr_review', Path(__file__).with_name('super-resolution-review.py'))
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    folder = args.report.resolve().parent
    crops = folder / 'review'
    crops.mkdir(exist_ok=True)
    panels = [('Reference', None), ('Lanczos FFmpeg', 'ffmpeg-lanczos'), ('AI Low Latency', 'low-latency'),
              ('QuickSRNet Small', 'quick-small'), ('QuickSRNet Medium', 'quick-medium')]
    page = ['<!doctype html><html lang="it"><meta charset="utf-8"><title>Restoration comparison</title>',
        '<style>body{font:16px system-ui;margin:24px;color:#222}img{max-width:100%;height:auto}'
        '.labels{display:grid;grid-template-columns:repeat(5,1fr);font-size:13px}figure{margin:24px 0}</style>',
        '<h1>Confronto sullo stesso video</h1><p>Ritagli allineati e ingranditi alla stessa scala. '
        'Filmati Apple ricampionati e compressi a CRF 18 e 30. Tutti gli output usano codifica hardware. '
        'Le metriche non dimostrano da sole la qualità percepita. Audio e AirPlay fisico esclusi.</p>']
    temporal = []
    for case in ('foliage-noise', 'motion-fur', 'face'):
        reference = folder / f'{case}-reference.mp4'
        width, height, x, y = {'foliage-noise': (600,480,450,350), 'motion-fur': (600,480,900,300), 'face': (272,480,0,0)}[case]
        for crf in (18,30):
            available = {r['backend'] for r in report['runs'] if r['case']==case and r['inputCRF']==crf}
            if not all(backend in available for _,backend in panels if backend): continue
            selected = {backend: next(r for r in report['runs'] if r['case']==case and r['inputCRF']==crf and r['backend']==backend)
                        for _, backend in panels if backend}
            page.append(f'<h2>{case} — CRF {crf}</h2>')
            for backend, row in selected.items():
                temporal.append(dict(case=case, inputCRF=crf, backend=backend,
                    temporalDifferencePSNR=review.temporal_difference_psnr(reference, folder / row['output'])))
            for seconds in (2,4):
                images = []
                for _, backend in panels:
                    source = folder / selected[backend]['output'] if backend else reference
                    pixels = review.command(['ffmpeg','-v','error','-ss',seconds,'-i',source,'-frames:v','1',
                        '-vf',f'crop={width}:{height}:{x}:{y}','-pix_fmt','rgb24','-f','rawvideo','-']).stdout
                    if len(pixels) != width*height*3: raise RuntimeError('Unexpected frame geometry')
                    images.append(pixels)
                combined = b''.join(b''.join(im[row*width*3:(row+1)*width*3] for im in images) for row in range(height))
                name = f'{case}-crf{crf}-{seconds}s.png'
                review.png(crops/name, width*len(panels), height, combined)
                labels = ''.join(f'<span>{html.escape(label)}</span>' for label,_ in panels)
                page.append(f'<figure><figcaption>{seconds}s — {width}×{height} pixels per pannello</figcaption>'
                    f'<div class="labels">{labels}</div><a href="review/{name}"><img src="review/{name}"></a></figure>')
    page.append('<p><a href="summary.md">Misure di velocità e qualità</a> · <a href="report.json">Report completo</a></p></html>')
    (folder/'review.html').write_text('\n'.join(page))
    (folder/'temporal-diagnostics.json').write_text(json.dumps(temporal,indent=2)+'\n')
    print(folder/'review.html')


if __name__ == '__main__': main()

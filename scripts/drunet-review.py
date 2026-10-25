#!/usr/bin/env python3
"""Create pixel-preserving contact sheets and a local video review for DRUNet."""
import argparse
import html
import json
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report',type=Path)
    args=parser.parse_args()
    folder=args.report.resolve().parent; report=json.loads(args.report.read_text())
    sections=[]
    for case in ['motion-fur','foliage-noise','face']:
        for corruption in ['compression','gaussian']:
            rows=[r for r in report['runs'] if r['case']==case and r['corruption']==corruption and r['repeat']==1]
            if not rows:continue
            row=rows[0];width=row['outputWidth'];height=row['outputHeight']
            columns=[('Reference',folder/f'{case}-reference.mp4')]
            for method in ['control','ffmpeg-cleanup','drunet-5','drunet-10']:
                found=next((r for r in rows if r['method']==method),None)
                if found:columns.append((method,folder/found['output']))
            # Decode the same presentation time and use nearest-neighbor for
            # magnified detail; no enhancement or interpolation alters pixels.
            images=[]
            for label,path in columns:
                data=subprocess.run(['ffmpeg','-v','error','-ss','1','-i',str(path),'-frames:v','1',
                    '-f','rawvideo','-pix_fmt','rgb24','-'],check=True,capture_output=True,timeout=30).stdout
                images.append((label,Image.frombytes('RGB',(width,height),data)))
            if case=='face': crop=(0,0,width,height);scale=2
            else:
                center=(width//2,height//2)
                crop=(center[0]-120,center[1]-90,center[0]+120,center[1]+90);scale=2
            cw=(crop[2]-crop[0])*scale;ch=(crop[3]-crop[1])*scale
            sheet=Image.new('RGB',(cw*len(images),ch+54),(24,24,24));draw=ImageDraw.Draw(sheet)
            for index,(label,picture) in enumerate(images):
                sheet.paste(picture.crop(crop).resize((cw,ch),Image.Resampling.NEAREST),(index*cw,54))
                draw.text((index*cw+12,10),label,fill='white')
                draw.text((index*cw+12,30),f'{width}x{height} source; 2x pixel view',fill=(180,180,180))
            name=f'{case}-{corruption}-review.png';sheet.save(folder/name)
            videos=''.join(f'<figure><figcaption>{html.escape(label)}</figcaption><video controls muted loop preload="none" src="{html.escape(path.name)}"></video></figure>' for label,path in columns)
            sections.append(f'<section><h2>{case} / {corruption}</h2><img src="{name}" alt="Matched-frame comparison"><div class="videos">{videos}</div></section>')
    document='''<!doctype html><html lang="en"><meta charset="utf-8"><title>DRUNet cleanup review</title>
<style>body{font:16px system-ui;margin:32px;background:#181818;color:#eee}section{margin:48px 0}img{max-width:100%}.videos{display:flex;flex-wrap:wrap;gap:12px}figure{margin:0;width:300px}video{width:100%;max-height:300px}figcaption{margin:12px 0}</style>
<h1>DRUNet same-resolution cleanup</h1><p>Native control, FFmpeg cleanup and DRUNet use the same hardware encoder. Clips are video-only; no physical TV acceptance. Gaussian RGB noise and real compression are separate tests. Contact sheets show the same frame at 1 second, with a nearest-neighbor pixel zoom; portrait source is only 136×240.</p>
<p><a href="summary.md">Numerical results</a> · <a href="report.json">Full report</a></p>'''+''.join(sections)+'</html>'
    (folder/'review.html').write_text(document)
    print(folder/'review.html')

if __name__=='__main__':main()

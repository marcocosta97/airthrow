#!/usr/bin/env python3
"""Export aligned review crops and temporal diagnostics from a real-footage report."""
import argparse
import html
import json
from pathlib import Path
import re
import statistics
import struct
import subprocess
import zlib


def command(args):
    result = subprocess.run([str(x) for x in args], capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace")[-1000:])
    return result


def png(path, width, height, pixels):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\0" + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def temporal_difference_psnr(reference, output):
    result = command(["ffmpeg", "-hide_banner", "-i", output, "-i", reference, "-filter_complex",
        "[0:v]setpts=PTS-STARTPTS,format=yuv420p,tblend=all_mode=difference[a];"
        "[1:v]setpts=PTS-STARTPTS,format=yuv420p,tblend=all_mode=difference[b];[a][b]psnr=shortest=1",
        "-an", "-f", "null", "-"])
    matches = re.findall(r"average:([\d.]+|inf)", result.stderr.decode())
    if not matches:
        raise RuntimeError("Missing temporal difference measurement")
    return matches[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    folder = args.report.resolve().parent
    review = folder / "review"
    review.mkdir(exist_ok=True)
    cases = sorted({(row["case"], row["inputCRF"]) for row in report["runs"]})
    native_rows = [row for row in report["runs"] if row["backend"] != "ffmpeg-lanczos"]
    seconds = min(row["mediaSeconds"] for row in native_rows)
    repetitions = max(row["repeat"] for row in native_rows)
    panels = [("Reference", None), ("Lanczos FFmpeg", "ffmpeg-lanczos"),
              ("AI Low Latency", "low-latency"), ("Lanczos native / shared encoder", "lanczos")]
    page = ['<!doctype html><html lang="en"><meta charset="utf-8"><title>Super resolution review</title>',
        '<style>body{font:16px system-ui;max-width:1100px;margin:32px auto;padding:0 16px;color:#222}'
        'img{max-width:100%;height:auto}table{border-collapse:collapse;width:100%}td,th{padding:8px;text-align:left;border-bottom:1px solid #ddd}'
        '.labels{display:grid;grid-template-columns:repeat(4,1fr);font-size:13px}figure{margin:24px 0}</style>',
        '<h1>Low Latency vs Lanczos</h1><p>Aligned crops, displayed at identical scale. Click a crop to inspect native pixels. '
        'The AI and native Lanczos use the same hardware encoder configuration. FFmpeg is the production filter baseline.</p>',
        '<p>Reference footage: Apple sample assets. Synthetic degradation at CRF 18 and 30. '
        'PSNR/SSIM and temporal differences do not establish perceptual quality or receiver acceptance.</p>']
    summary = ['# Real-footage super resolution comparison', '',
        f'Three public Apple sample clips; two degradation levels; {seconds:g}-second clips at 30 fps; {repetitions} native repetitions. '
        'The executable is frozen per suite and its hash is in report.json.', '',
        '| Clip | Input CRF | Backend | Speed | PSNR | SSIM | Temporal difference PSNR |',
        '|---|---:|---|---:|---:|---:|---:|']
    diagnostics = []
    for case, crf in cases:
        reference = folder / f"{case}-reference.mp4"
        selected = {}
        for _, backend in panels[1:]:
            rows = [r for r in report["runs"] if r["case"] == case and r["inputCRF"] == crf and r["backend"] == backend]
            if not rows:
                raise RuntimeError(f"Missing {case}/{crf}/{backend}")
            selected[backend] = rows[0]
            temporal = temporal_difference_psnr(reference, folder / rows[0]["output"])
            diagnostics.append(dict(case=case, inputCRF=crf, backend=backend, temporalDifferencePSNR=temporal))
            summary.append(f"| {case} | {crf} | {backend} | {statistics.median(r['pipelineSpeed'] for r in rows):.2f}x | "
                           f"{statistics.median(r['psnr'] for r in rows):.2f} | {statistics.median(r['ssim'] for r in rows):.4f} | {temporal} |")
        # Fixed coordinates, identical across all outputs. Portrait uses its full frame.
        crop = {"motion-fur": (600, 480, 900, 300), "foliage-noise": (600, 480, 450, 350),
                "face": (272, 480, 0, 0)}[case]
        width, height, x, y = crop
        page.append(f'<h2>{html.escape(case)} — input CRF {crf}</h2>')
        for time in (seconds / 3, seconds * 2 / 3):
            images = []
            for _, backend in panels:
                source = reference if backend is None else folder / selected[backend]["output"]
                pixels = command(["ffmpeg", "-v", "error", "-ss", time, "-i", source, "-frames:v", "1",
                                  "-vf", f"crop={width}:{height}:{x}:{y}", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]).stdout
                if len(pixels) != width * height * 3:
                    raise RuntimeError("Unexpected review frame size")
                images.append(pixels)
            combined = b"".join(b"".join(image[row * width * 3:(row + 1) * width * 3] for image in images)
                                for row in range(height))
            name = f"{case}-crf{crf}-{time:g}s.png"
            png(review / name, width * 4, height, combined)
            labels = ''.join(f'<span>{html.escape(label)}</span>' for label, _ in panels)
            page.append(f'<figure><figcaption>Time {time}s · crop {width}×{height}, origin {x},{y}</figcaption>'
                        f'<div class="labels">{labels}</div><a href="review/{name}"><img src="review/{name}" '
                        f'alt="Aligned comparison of {html.escape(case)} at {time} seconds"></a></figure>')
    summary += ['', 'Temporal difference PSNR compares absolute consecutive-frame differences with the reference. '
                'It is not optical-flow compensated and is not a perceptual flicker test.', '',
                'Native Lanczos explicitly supplies BT.709 on CIImage input and rendering output. Prior reports using '
                'implicit Core Image input color are not valid native comparisons.', '',
                '[Open review gallery](review.html). Images are in review/. Audio, long-run energy and physical AirPlay are untested.']
    page.append('<p><a href="report.json">Full measurements</a> · <a href="APPLE-SAMPLE-LICENSE.txt">Apple sample license</a></p></html>')
    (folder / "review.html").write_text('\n'.join(page))
    (folder / "summary.md").write_text('\n'.join(summary) + '\n')
    (folder / "temporal-diagnostics.json").write_text(json.dumps(diagnostics, indent=2) + '\n')
    print(folder / "review.html")


if __name__ == "__main__":
    main()

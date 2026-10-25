#!/usr/bin/env python3
"""Measure flat-field changes before encoding; do not infer perceptual quality."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("resolution_bench", ROOT / "scripts/super-resolution-bench.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/debug/SuperResolutionBench")
    args = parser.parse_args()
    (ROOT / "build").mkdir(exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="super-resolution-color-", dir=ROOT / "build"))
    binary = directory / "SuperResolutionBench"
    shutil.copy2(args.binary, binary)
    palettes = {
        "neutral": [(32, 32, 32), (64, 64, 64), (96, 96, 96), (128, 128, 128), (160, 160, 160), (200, 200, 200)],
        "muted": [(160, 80, 80), (80, 160, 80), (80, 80, 160), (160, 160, 80), (160, 80, 160), (80, 160, 160)],
        "saturated": [(255, 0, 0), (0, 255, 0), (255, 255, 0), (0, 0, 255), (255, 0, 255), (0, 255, 255)],
    }
    report = {"schemaVersion": 1, "cases": [],
        "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "runnerSha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "nativeSourceSha256": hashlib.sha256((ROOT / "Tests/SuperResolutionBench/SuperResolutionBench.swift").read_bytes()).hexdigest(),
        "scope": "Six 8x8 patches on the first frame: decoded vs processor input vs pre-encode output; video-range BT.709"}
    for case, colors in palettes.items():
        row = b"".join(bytes(color) * 160 for color in colors)
        pixels = row * 540
        input_path = directory / f"{case}.mp4"
        result = subprocess.run(["ffmpeg", "-v", "error", "-f", "rawvideo", "-pixel_format", "rgb24",
            "-video_size", "960x540", "-framerate", "30", "-i", "pipe:0", "-an", "-t", "0.4",
            "-vf", "loop=loop=-1:size=1:start=0,scale=out_color_matrix=bt709:out_range=tv,fps=30",
            "-c:v", "libx264", "-preset", "slow", "-crf", "12", "-profile:v", "high", *bench.reference_flags(), str(input_path)],
            input=pixels, capture_output=True, timeout=30)
        if result.returncode:
            raise RuntimeError(result.stderr.decode()[-1000:])
        for backend in ("lanczos", "low-latency"):
            output = directory / f"{case}-{backend}.mp4"
            measurement = bench.native_measurement(binary, input_path, output, 12, backend)
            bench.validate_output(output, 1920, 1080, 12, 0.4)
            measurement_path = output.with_suffix(".json")
            measurement_path.write_text(json.dumps(measurement, indent=2) + "\n")
            diagnostics = measurement["firstFrameDiagnostics"]
            for stage in ("decoded", "processorInput", "processorOutputBeforeEncoding"):
                if [sample["patch"] for sample in diagnostics[stage]] != list(range(6)):
                    raise RuntimeError(f"Missing or unordered diagnostic samples: {stage}")
            samples = []
            for decoded, source, processed in zip(diagnostics["decoded"], diagnostics["processorInput"], diagnostics["processorOutputBeforeEncoding"]):
                if any(abs(decoded[key] - source[key]) > 0.001 for key in ("yMean", "cbMean", "crMean", "yStdDev")):
                    raise RuntimeError("The source transfer changed flat-field samples")
                samples.append(dict(patch=source["patch"], source=source, output=processed,
                    yDelta=processed["yMean"] - source["yMean"], cbDelta=processed["cbMean"] - source["cbMean"],
                    crDelta=processed["crMean"] - source["crMean"]))
            if diagnostics["decodedColor"] != diagnostics["processorInputColor"] or diagnostics["processorInputColor"] != diagnostics["processorOutputColor"]:
                raise RuntimeError("Color tags changed along the processing path")
            report["cases"].append(dict(palette=case, backend=backend, sourceTransferSamplesUnchanged=True,
                colorTagsUnchanged=True, samples=samples, measurement=measurement_path.name,
                maximumAbsoluteLumaDelta=max(abs(sample["yDelta"]) for sample in samples),
                maximumAbsoluteChromaDelta=max(abs(sample[key]) for sample in samples for key in ("cbDelta", "crDelta"))))
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(directory / "report.json")


if __name__ == "__main__":
    main()

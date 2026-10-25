#!/usr/bin/env python3
"""Developer feasibility suite. Synthetic metrics do not establish visual quality."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run(args, timeout=120):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=timeout)


def checked(args):
    result = run(args)
    if result.returncode:
        raise RuntimeError(f"{Path(str(args[0])).name} failed: {result.stderr[-1200:]}")
    return result


def inspect(path):
    result = checked(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
                      "-show_entries", "stream=width,height,nb_read_frames,duration,color_transfer,color_primaries,color_space,color_range,pix_fmt,codec_name,profile",
                      "-of", "json", path])
    return json.loads(result.stdout)["streams"][0]


def validate_output(path, width, height, frames, seconds):
    stream = inspect(path)
    if (int(stream["width"]), int(stream["height"]), int(stream["nb_read_frames"])) != (width, height, frames):
        raise RuntimeError("Unexpected output geometry/frame count")
    if abs(float(stream["duration"]) - seconds) > 1 / 30:
        raise RuntimeError("Unexpected output duration")
    if any(stream.get(key) != "bt709" for key in ("color_transfer", "color_primaries", "color_space")):
        raise RuntimeError("Output lost SDR color metadata")


def compare(reference, output):
    metrics = {}
    for metric, pattern in [("psnr", r"average:([\d.]+|inf)"), ("ssim", r"All:([\d.]+)")]:
        result = checked(["ffmpeg", "-hide_banner", "-i", output, "-i", reference,
                          "-filter_complex", f"[0:v]setpts=PTS-STARTPTS,format=yuv420p[a];"
                          f"[1:v]setpts=PTS-STARTPTS,format=yuv420p[b];[a][b]{metric}=shortest=1",
                          "-an", "-f", "null", "-"])
        matches = re.findall(pattern, result.stderr)
        if not matches:
            raise RuntimeError(f"Missing {metric} measurement")
        value = float(matches[-1])
        metrics[metric] = value if math.isfinite(value) else "infinity"
    return metrics


def negative_checks(binary, directory, input_path):
    # These checks execute the native tool, including the failure cleanup boundary.
    tests = [
        ("unsupported-scale", ["--backend", "low-latency", "--scale", "3"], "does not support"),
        ("invalid-frames", ["--frames", "0"], "frame limit"),
        ("nan-scale", ["--scale", "nan"], "Invalid backend"),
    ]
    results = []
    for label, arguments, expected in tests:
        output = directory / f"rejected-{label}.mp4"
        result = run([binary, "--input", input_path, "--output", output, *arguments])
        report = json.loads(result.stdout)
        if result.returncode == 0 or expected not in report.get("error", "") or output.exists():
            raise RuntimeError(f"Negative check failed: {label}")
        results.append(label)
    existing = directory / "existing.mp4"
    existing.write_bytes(b"preserve me")
    result = run([binary, "--input", input_path, "--output", existing])
    if result.returncode == 0 or existing.read_bytes() != b"preserve me":
        raise RuntimeError("Existing output was not preserved")
    results.append("preserve-existing-output")
    unknown = directory / "unknown-color.mp4"
    checked(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30",
             "-t", "1", "-c:v", "libx264", "-preset", "ultrafast", unknown])
    rejected = directory / "rejected-color.mp4"
    result = run([binary, "--input", unknown, "--output", rejected])
    if result.returncode == 0 or rejected.exists() or "BT.709" not in json.loads(result.stdout).get("error", ""):
        raise RuntimeError("Unknown-color input was not rejected")
    results.append("reject-unknown-color")
    return results


def reference_flags():
    return ["-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
            "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709", "-movflags", "+write_colr"]


def ffmpeg_lanczos(input_path, output, width, height):
    start = time.monotonic()
    checked(["ffmpeg", "-v", "error", "-i", input_path, "-an", "-vf",
             f"scale=w={width}:h={height}:flags=lanczos:force_original_aspect_ratio=decrease:force_divisible_by=2",
             "-c:v", "h264_videotoolbox", "-allow_sw", "0", "-b:v", width * height * 6,
             "-profile:v", "high", "-bf", "0", "-g", "60", "-pix_fmt", "yuv420p",
             "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", output])
    return time.monotonic() - start


def native_measurement(binary, input_path, output, frames, backend, scale=2):
    result = run([binary, "--input", input_path, "--output", output, "--backend", backend,
                  "--scale", scale, "--frames", frames, "--diagnostics"])
    measurement = json.loads(result.stdout)
    if result.returncode:
        if output.exists():
            raise RuntimeError("Failed native job left a partial file")
        raise RuntimeError(f"Native {backend} failed: {measurement.get('error')}")
    measurement["status"] = "completed"
    return measurement


def real_comparison(args, directory, capabilities):
    assets = args.real_assets.resolve()
    cases = [("motion-fur", "FRC.mov", 1, 1920, 1080),
             ("foliage-noise", "TNF.mov", 1, 1920, 1080),
             ("face", "LLSRS.mov", 18, 272, 480)]
    report = {"schemaVersion": 2, "capabilities": capabilities, "runs": [], "sources": [],
        "scope": "Real footage from Apple's public sample; downsampled inputs at two compression levels",
        "pairedEncoder": "Native Lanczos and AI use the same AVAssetWriter hardware encoder settings",
        "productionBaseline": "FFmpeg Lanczos with VideoToolbox H.264 High, matching bitrate, GOP and no reordering",
        "audioValidated": False, "receiverValidated": False, "energyMeasured": False}
    report["binarySha256"] = hashlib.sha256(args.binary.read_bytes()).hexdigest()
    report["runnerSha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    report["nativeSourceSha256"] = hashlib.sha256((ROOT / "Tests/SuperResolutionBench/SuperResolutionBench.swift").read_bytes()).hexdigest()
    report["sourcePage"] = "https://developer.apple.com/documentation/videotoolbox/enhancing-your-app-with-machine-learning-based-video-effects"
    # Keep the third-party sample attribution beside the derived artifacts.
    license_path = assets.parent / "LICENSE.txt"
    if license_path.is_file():
        shutil.copyfile(license_path, directory / "APPLE-SAMPLE-LICENSE.txt")
    frames = args.seconds * 30
    for case, filename, start, width, height in cases:
        original = assets / filename
        if not original.is_file():
            raise RuntimeError(f"Missing Apple sample asset: {filename}")
        report["sources"].append(dict(case=case, asset=filename, startSeconds=start,
            sha256=hashlib.sha256(original.read_bytes()).hexdigest()))
        reference = directory / f"{case}-reference.mp4"
        checked(["ffmpeg", "-v", "error", "-ss", start, "-i", original, "-an", "-t", args.seconds,
                 "-vf", f"fps=30,scale={width}:{height}:flags=lanczos", "-c:v", "libx264",
                 "-preset", "slow", "-crf", "12", *reference_flags(), reference])
        validate_output(reference, width, height, frames, args.seconds)
        for crf in (18, 30):
            input_path = directory / f"{case}-input-crf{crf}.mp4"
            checked(["ffmpeg", "-v", "error", "-i", reference, "-vf", f"scale={width // 2}:{height // 2}:flags=area",
                     "-an", "-c:v", "libx264", "-preset", "slow", "-crf", crf, *reference_flags(), input_path])
            if case == "motion-fur" and crf == 18:
                report["negativeChecks"] = negative_checks(args.binary.resolve(), directory, input_path)
            for repeat in range(args.repeats):
                order = ["lanczos", "low-latency"]
                if repeat % 2: order.reverse()
                for backend in order:
                    label = f"{case}-{backend}-crf{crf}-{repeat + 1}"
                    print(f"Running {label}", flush=True)
                    output = directory / f"{label}.mp4"
                    measurement = native_measurement(args.binary.resolve(), input_path, output, frames, backend)
                    validate_output(output, width, height, frames, args.seconds)
                    measurement.update(case=case, inputCRF=crf, repeat=repeat + 1, output=output.name,
                                       encodedStream=inspect(output),
                                       **compare(reference, output))
                    report["runs"].append(measurement)
                    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            output = directory / f"{case}-ffmpeg-lanczos-crf{crf}.mp4"
            elapsed = ffmpeg_lanczos(input_path, output, width, height)
            validate_output(output, width, height, frames, args.seconds)
            report["runs"].append(dict(case=case, backend="ffmpeg-lanczos", inputCRF=crf, scale=2,
                output=output.name, status="completed", pipelineSpeed=args.seconds / elapsed,
                encodedStream=inspect(output),
                processStartupIncluded=True, **compare(reference, output)))
            (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Report: {directory / 'report.json'}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/debug/SuperResolutionBench")
    parser.add_argument("--seconds", type=int, default=6)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--output-root", type=Path, default=ROOT / "build")
    parser.add_argument("--real-assets", type=Path, help="Apple sample EmbeddedAssets directory; runs low-latency vs Lanczos only")
    args = parser.parse_args()
    if not 1 <= args.seconds <= 60 or not 1 <= args.repeats <= 10:
        parser.error("Use 1...60 seconds and 1...10 repetitions")
    if args.real_assets and args.seconds > 6:
        parser.error("Real-footage excerpts support at most six seconds")
    for tool in ("ffmpeg", "ffprobe"):
        if shutil.which(tool) is None:
            parser.error(f"Missing {tool}")
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("Build SuperResolutionBench first")
    args.output_root.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="super-resolution-", dir=args.output_root))
    # A later rebuild must not change the executable halfway through a comparison.
    snapshot = directory / "SuperResolutionBench"
    shutil.copy2(binary, snapshot)
    binary = snapshot.resolve()
    args.binary = binary
    capabilities = json.loads(checked([binary, "--probe"]).stdout)
    if args.real_assets:
        return real_comparison(args, directory, capabilities)
    report = {"schemaVersion": 1, "capabilities": capabilities, "runs": [],
              "qualityScope": "Synthetic references only; PSNR/SSIM are not a perceptual acceptance gate",
              "audioValidated": False, "receiverValidated": False, "energyMeasured": False}
    cases = [("motion", "testsrc2=size=1920x1080:rate=30"),
             ("detail", "mandelbrot=size=1920x1080:rate=30")]
    flags = reference_flags()
    try:
        for case, source in cases:
            reference = directory / f"{case}-reference.mp4"
            checked(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", source, "-t", args.seconds,
                     "-c:v", "libx264", "-preset", "ultrafast", "-crf", "12", *flags, reference])
            for scale in (2, 4):
                input_path = directory / f"{case}-input-x{scale}.mp4"
                checked(["ffmpeg", "-v", "error", "-i", reference, "-vf",
                         f"scale={1920 // scale}:{1080 // scale}:flags=area", "-c:v", "libx264",
                         "-preset", "ultrafast", "-crf", "26", *flags, input_path])
                if case == "motion" and scale == 2:
                    report["negativeChecks"] = negative_checks(binary, directory, input_path)
                backends = ["lanczos", "low-latency" if scale == 2 else "standard"]
                for repeat in range(args.repeats):
                    # Alternate order to reduce systematic cold-start/thermal bias.
                    for backend in (backends if repeat % 2 == 0 else list(reversed(backends))):
                        label = f"{case}-{backend}-x{scale}-{repeat + 1}"
                        print(f"Running {label}", flush=True)
                        output = directory / f"{label}.mp4"
                        result = run([binary, "--input", input_path, "--output", output,
                                      "--backend", backend, "--scale", scale, "--frames", args.seconds * 30])
                        measurement = json.loads(result.stdout)
                        measurement.update(case=case, repeat=repeat + 1)
                        if result.returncode:
                            measurement["status"] = "unavailable-or-failed"
                            if output.exists():
                                raise RuntimeError("Failed native job left a partial file")
                        else:
                            validate_output(output, 1920, 1080, args.seconds * 30, args.seconds)
                            measurement.update(compare(reference, output))
                            measurement["status"] = "completed"
                        report["runs"].append(measurement)
                        (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
                # Measure the current production scaling filter separately from the native baseline.
                output = directory / f"{case}-ffmpeg-lanczos-x{scale}.mp4"
                elapsed = ffmpeg_lanczos(input_path, output, 1920, 1080)
                validate_output(output, 1920, 1080, args.seconds * 30, args.seconds)
                report["runs"].append(dict(case=case, backend="ffmpeg-lanczos", scale=scale,
                    status="completed", pipelineSpeed=args.seconds / elapsed,
                    processStartupIncluded=True, **compare(reference, output)))
                (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Report: {directory / 'report.json'}")
        failures = [r for r in report["runs"] if r["status"] != "completed"]
        if failures:
            print(f"Incomplete comparisons: {len(failures)}; inspect report before choosing a backend.", file=sys.stderr)
            return 2
        return 0
    except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        report["suiteError"] = str(error)
        (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        raise


if __name__ == "__main__":
    sys.exit(main())

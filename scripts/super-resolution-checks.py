#!/usr/bin/env python3
"""Exercise real AI preparation with synthetic local/loopback media; no receiver claim."""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


def run(arguments):
    return subprocess.run([str(x) for x in arguments], check=True, capture_output=True, text=True, timeout=300)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/debug/SuperResolutionChecks")
    args = parser.parse_args()
    (ROOT / "build").mkdir(exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix="super-resolution-checks-", dir=ROOT / "build"))
    (folder / "tmp").mkdir()
    for name, duration, tagged in [("short", 0.5, True), ("long", 6.5, True), ("unknown", 0.5, False)]:
        arguments = ["ffmpeg", "-v", "error", "-nostdin", "-n", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", duration]
        if tagged:
            arguments += ["-vf", "setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709"]
        arguments += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2"]
        run(arguments + [folder / f"{name}.mp4"])
    fixture_names = {"long", "short", "unknown"}
    # Legacy VP8 WebM commonly omits every color tag, including HD sources.
    run(["ffmpeg", "-v", "error", "-i", folder / "short.mp4", "-vf",
         "colorspace=all=smpte170m:range=tv:format=yuv420p,setparams=range=unspecified:color_primaries=unknown:color_trc=unknown:colorspace=unknown", "-c:v", "libvpx", "-b:v", "1M",
         "-color_primaries", "unknown", "-color_trc", "unknown", "-colorspace", "unknown",
         "-color_range", "unknown", "-c:a", "opus", "-strict", "-2", folder / "vp8-untagged.webm"])
    run(["ffmpeg", "-v", "error", "-i", folder / "vp8-untagged.webm", "-vf",
         "colorspace=ispace=smpte170m:itrc=smpte170m:iprimaries=smpte170m:irange=tv:all=bt709:range=tv:format=yuv444p",
         "-c:v", "libx264", "-crf", "0", "-c:a", "aac", folder / "vp8-reference.mp4"])
    fixture_names.update({"vp8-untagged", "vp8-reference"})
    vp8 = json.loads(run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_streams",
                         "-of", "json", folder / "vp8-untagged.webm"]).stdout)["streams"][0]
    if any(vp8.get(key) not in (None, "unknown", "unspecified") for key in
           ("color_space", "color_transfer", "color_primaries")):
        raise RuntimeError("VP8 fixture unexpectedly has explicit color metadata")
    for name, size, rate, extra in [
        ("portrait", "180x320", "24", ""),
        ("anamorphic", "480x360", "24", "setsar=4/3,"),
        ("narrow-pixels", "480x270", "24", "setsar=3/4,"),
        ("fps50", "320x180", "50", ""), ("fps60", "320x180", "60", ""),
        ("fps5994", "320x180", "60000/1001", ""),
        ("sdr601", "320x180", "24", ""), ("partial-color", "320x180", "24", "")
    ]:
        tags = ("range=limited:color_primaries=smpte170m:color_trc=smpte170m:colorspace=smpte170m"
                if name == "sdr601" else "color_trc=bt709" if name == "partial-color"
                else "range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709")
        run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", f"testsrc2=size={size}:rate={rate}",
             "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "0.5",
             "-vf", extra + "setparams=" + tags, "-c:v", "libx264", "-crf", "0", "-pix_fmt", "yuv420p",
             "-c:a", "aac", "-ac", "2", folder / f"{name}.mp4"])
        fixture_names.add(name)
    for name, source in [("rotated", "short"), ("portrait-rotated", "portrait")]:
        run(["ffmpeg", "-v", "error", "-display_rotation:v:0", "90", "-i", folder / f"{source}.mp4", "-c", "copy", folder / f"{name}.mp4"])
        fixture_names.add(name)
        metadata = json.loads(run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                   "stream_side_data", "-of", "json", folder / f"{name}.mp4"]).stdout)
        if not any(abs(data.get("rotation", 0)) == 90 for data in metadata["streams"][0].get("side_data_list", [])):
            raise RuntimeError(f"Rotation fixture lacks display matrix: {name}")
    run(["ffmpeg", "-v", "error", "-i", folder / "sdr601.mp4", "-vf",
         "colorspace=all=bt709:range=tv:format=yuv444p", "-c:v", "libx264", "-crf", "0",
         "-c:a", "copy", folder / "sdr601-reference.mp4"])
    fixture_names.add("sdr601-reference")
    for name, tags, extra in [
        ("hdr", "color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc", []),
        ("ambiguous-color", "color_primaries=unknown:color_trc=bt709:colorspace=smpte170m", []),
        ("interlaced", "color_primaries=bt709:color_trc=bt709:colorspace=bt709", ["-x264-params", "tff=1", "-flags", "+ilme+ildct"])
    ]:
        run(["ffmpeg", "-v", "error", "-i", folder / "short.mp4", "-vf", "setparams=" + tags,
             "-c:v", "libx264", "-c:a", "copy", *extra, folder / f"{name}.mp4"])
        fixture_names.add(name)
    run(["ffmpeg", "-v", "error", "-display_rotation:v:0", "45", "-i", folder / "short.mp4",
         "-c", "copy", folder / "arbitrary-rotation.mp4"])
    fixture_names.add("arbitrary-rotation")
    (folder / "hls").mkdir()
    run(["ffmpeg", "-v", "error", "-i", folder / "short.mp4", "-c", "copy", "-hls_time", "1",
        "-hls_playlist_type", "vod", folder / "hls/stream.m3u8"])

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(folder)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = subprocess.run([str(args.binary.resolve()), str(folder), f"http://127.0.0.1:{server.server_port}"],
            capture_output=True, text=True, timeout=600,
            env=dict(os.environ, TMPDIR=str(folder / "tmp") + "/"))
        (folder / "checks.log").write_text(result.stdout + result.stderr)
        print(result.stdout, end="")
        if result.returncode:
            raise RuntimeError(f"Native checks failed; see {folder / 'checks.log'}")
        streams = {}
        for file in sorted(folder.iterdir()):
            if file.suffix in (".mp4", ".ts") and file.stem not in fixture_names:
                metadata = json.loads(run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", file]).stdout)
                video = next(s for s in metadata["streams"] if s["codec_type"] == "video")
                audio = next(s for s in metadata["streams"] if s["codec_type"] == "audio")
                expected_height = 2160 if "4k" in file.name else 1080
                if ((video["height"] != expected_height and video["width"] != 1920) or audio["codec_name"] != "aac"
                    or any(video.get(key) != "bt709" for key in ("color_space", "color_transfer", "color_primaries"))):
                    raise RuntimeError(f"Unexpected prepared stream: {file.name}")
                if file.name.startswith("normalized-"):
                    expected_size = ((608, 1080) if "normalized-rotated-" in file.name else
                                     (1920, 1080) if "portrait-rotated" in file.name or "anamorphic" in file.name else
                                     (1440, 1080) if "narrow-pixels" in file.name else (1920, 1080))
                    if (video["width"], video["height"]) != expected_size:
                        raise RuntimeError(f"Incorrect displayed geometry: {file.name} {video['width']}x{video['height']}")
                    if video.get("sample_aspect_ratio", "1:1") != "1:1" or any(
                        data.get("rotation", 0) != 0 for data in video.get("side_data_list", [])):
                        raise RuntimeError(f"Normalization left display metadata: {file.name}")
                    expected_rate = 50 if "fps50" in file.name else 60000/1001 if "fps5994" in file.name else 60 if "fps60" in file.name else 24
                    num, den = map(int, video["avg_frame_rate"].split("/"))
                    if abs(num/den - expected_rate) > 0.01:
                        raise RuntimeError(f"Frame rate changed: {file.name}")
                    frames = json.loads(run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_frames",
                                             "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", file]).stdout)["frames"]
                    pts = [float(f["best_effort_timestamp_time"]) for f in frames]
                    if len(pts) != round(0.5 * expected_rate) or any(b <= a for a, b in zip(pts, pts[1:])):
                        raise RuntimeError(f"Dropped/reordered frames: {file.name}")
                streams[file.name] = metadata
        # The native scaler must receive the same converted colors as an independently
        # normalized, losslessly encoded BT.709 reference, rather than retagged BT.601.
        for label, names in [("BT.601", ("sdr601", "sdr601-reference")),
                             ("untagged VP8", ("vp8-untagged", "vp8-reference"))]:
            color_outputs = [folder / f"normalized-{name}-ai_low_latency.mp4" for name in names]
            if all(file.exists() for file in color_outputs):
                pixels = [subprocess.run(["ffmpeg", "-v", "error", "-i", str(file), "-frames:v", "1", "-f", "rawvideo",
                                          "-pix_fmt", "rgb24", "-"], check=True, capture_output=True).stdout for file in color_outputs]
                error = sum(abs(a-b) for a, b in zip(*pixels)) / len(pixels[0])
                if len(pixels[0]) != len(pixels[1]) or error > 1:
                    raise RuntimeError(f"{label} conversion differs from reference: mean RGB error {error}")
                print(f"PASS {label} conversion against BT.709 reference (mean RGB error {error:.4f})")
        (folder / "report.json").write_text(json.dumps(dict(checks="passed", streams=streams,
            nativePreparation="passed" if streams else "skipped", receiver="untested"), indent=2) + "\n")
        print(folder / "report.json")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()

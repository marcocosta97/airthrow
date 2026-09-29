# AirThrow

AirThrow plays remote video on your TV through AirPlay, from a Mac.

Paste a video link or pick a local file, choose your Apple TV or other
video-capable AirPlay receiver, and watch it on the big screen — the Mac stays
the controller. The Mac's screen is never mirrored; the receiver fetches the
video on its own, so playback keeps going while you use the Mac normally. A
companion command-line tool drives the same session from a terminal or script.

## Requirements

- macOS 14 or later.
- Swift 6 Command Line Tools or Xcode, to build from source.
- Optional: `yt-dlp` for website links, `deno` for YouTube, and `ffmpeg`/
  `ffprobe` for preparation (`brew install ffmpeg yt-dlp deno`).
- The Mac and the receiver must be on the same network.

## Build and run

```bash
bash scripts/build.sh
open build/AirThrow.app
```

This produces a locally signed app, a ZIP archive, and the `build/athrow` CLI.

## Play a video

1. Paste a direct video URL, a website link, or a local file path, or drop a
   file onto the source area, then click **Load**.
2. Choose video and audio options while it loads, if the source offers them.
   Once ready, choose a subtitle track in **Video → Source → Subtitles** if one
   is available.
3. Click the AirPlay button and choose a video-capable receiver, then press
   **Play** when the video and route are ready.

## Website links (experimental)

With `yt-dlp`, `deno`, and `ffmpeg` installed, paste a public YouTube watch,
Shorts, `youtu.be`, playlist, or Mix link in the same field. AirThrow finds the
best playable source, preferring one the receiver can play directly. Dedicated
playlist links create a queue of up to 100 items.

Other public video pages may work through yt-dlp's generic extractor. Site
sign-in, DRM, and sources requiring custom request headers are unsupported.

Some videos are gated by a YouTube sign-in check. In **Settings → YouTube
access**, pick a browser or a Netscape `cookies.txt` file to supply a signed-in
session. Only `youtube.com` cookies are read; they never leave the Mac and are
never shown or logged. Safari needs Full Disk Access; Chrome-family browsers ask
for Keychain access.

## Local files (experimental)

Choose a local video with the folder button, drop it on the source area, or pass
its path to `athrow open`. MP4, M4V, MOV, MKV, and WebM are supported. A
receiver-compatible MP4 or MOV is served in place with no size limit; other
containers may be prepared or converted on the Mac first.

## Limitations

- Video conversion is off by default. Optional **Upscale** and **Clean up and
  upscale** work on finite SDR video at 1080p or 4K; 4K requires a compatible
  receiver. Enhancements never downscale.
- Native subtitles are available when the media exposes supported tracks.
  Image-based subtitles, burn-in, and subtitles in Mac-prepared live streams are
  unsupported.
- HDR/Dolby Vision processing, AI Super Resolution, and surround preservation
  are unsupported. Receiver compatibility still depends on the device.

See [CONTRIBUTING.md](CONTRIBUTING.md) for project layout, architecture, and
testing details.

## License

AirThrow's source code is licensed under the [Apache License 2.0](LICENSE).

This license covers AirThrow's own code only. It does not grant rights to
third-party media, to Apple frameworks and services (AVFoundation, AirPlay), or
to external tools such as FFmpeg/ffprobe and yt-dlp, which remain subject to
their own licenses and terms.

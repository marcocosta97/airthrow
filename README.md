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
- Optional, for YouTube links and format conversion: `ffmpeg`, `ffprobe`,
  `yt-dlp`, and `deno` (`brew install ffmpeg yt-dlp deno`).
- The Mac and the receiver must be on the same network.

## Build and run

```bash
bash scripts/build.sh
open build/AirThrow.app
```

This produces a locally signed app, a ZIP archive, and the `build/athrow` CLI.

## Play a video

1. Click the AirPlay button in the app and choose a video-capable receiver.
2. Paste a direct video URL, a YouTube link, or a local file path, or drop a
   file onto the source area, then click **Load**.
3. Press **Play** when the video and route are ready.

## YouTube links (experimental)

With `yt-dlp`, `deno`, and `ffmpeg` installed, paste a public YouTube watch,
Shorts, `youtu.be`, playlist, or Mix link in the same field. AirThrow finds the
best playable source, preferring one the receiver can play directly. Dedicated
playlist links create a queue of up to 100 items.

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

- Video conversion is optional and off by default; HDR/Dolby Vision, subtitle
  burn-in, and surround preservation are not supported yet.

See [CONTRIBUTING.md](CONTRIBUTING.md) for project layout, architecture, and
testing details.

## License

AirThrow's source code is licensed under the [Apache License 2.0](LICENSE).

This license covers AirThrow's own code only. It does not grant rights to
third-party media, to Apple frameworks and services (AVFoundation, AirPlay), or
to external tools such as FFmpeg/ffprobe and yt-dlp, which remain subject to
their own licenses and terms.

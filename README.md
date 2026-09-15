# AirPlayer

A small native macOS controller for playing direct video URLs on Apple TV and other video-capable AirPlay receivers. Built with Swift, AVPlayer, and Apple's system AirPlay picker, with a companion command-line tool.

Early version: receiver compatibility, audio playback, and physical remote behavior still need hardware validation. The app has no local video view.

## Build and run

Requires macOS 14+ and Swift 6 Command Line Tools or Xcode.

```bash
bash scripts/build.sh
open build/AirPlayer.app
```

This creates a locally signed app, ZIP archive, and `build/airplayer`. Pass `debug` to the build script for a development build. Quit the app before rebuilding its bundle. Alternatively, open `AirPlayer.xcodeproj` in Xcode and configure your signing team.

## Play a video

1. Choose a video-capable receiver using **AirPlay**, and paste a direct video URL and click **Load**. Either order works.
2. Press **Play** when the video and external route are ready.
3. Use Pause, Stop, or the available timeline. Load another URL to change videos.

Loading stays paused. AirPlayer may briefly attempt muted playback to establish the external video route. Route loss pauses and mutes playback. Closing the window keeps the app running; reopen it from the menu bar or CLI. The Mac must remain running and connected.

## Command line

```bash
./build/airplayer open 'https://example.com/movie.m3u8'
./build/airplayer play
./build/airplayer pause
./build/airplayer seek 120
./build/airplayer status --json
./build/airplayer stop
./build/airplayer show
```

`open` and `show` launch the app if necessary. Select the receiver through the UI; selection by name is not supported. `open` loads paused. `seek` takes absolute seconds within the available timeline. All commands accept `--json`; `pending: true` means an operation was accepted, so query `status` for its observed result. `hasAudio`, when present, describes the source's audio tracks, not audible output at the TV.

The CLI is also bundled at `AirPlayer.app/Contents/MacOS/airplayer`. Set `AIRPLAYER_APP` to the app's path if needed. Commands operate in the logged-in desktop session.

| Exit code | Meaning |
| --- | --- |
| 0 | Succeeded or accepted; inspect status |
| 2 | Invalid command, URL, or argument |
| 3 | App or command endpoint unavailable |
| 4 | Select an AirPlay video receiver first |
| 5 | Operation unavailable, such as an out-of-range seek |
| 6 | Missing video or playback failure |

## Supported sources and limitations

- Direct HTTP/HTTPS video supported by AVFoundation and the receiver; MP4 and HLS are the initial formats. File extension alone does not establish compatibility.
- Sources need their own audio track or HLS audio rendition. The app warns about detected video-only sources and does not combine separate audio/video URLs.
- Website watch pages, yt-dlp extraction, remuxing, transcoding, custom headers/cookies, DRM integrations, and local-file input are not implemented.
- Audio-only AirPlay speakers cannot display video. Television/receiver controls own volume.
- Apple TV Remote integration uses public Now Playing and remote-command APIs; actual receiver behavior remains subject to hardware testing.

The app stores no media history or pairing credentials of its own. Media URLs stay in memory and are omitted from status and errors; shell history is managed by your shell. macOS manages pairing and may save window geometry.

See [CONTRIBUTING.md](CONTRIBUTING.md) for tests, project layout, and packaging details.

# AirPlayer

A small native macOS controller for playing video URLs on Apple TV and other video-capable AirPlay receivers. Built with Swift, AVPlayer, and Apple's system AirPlay picker, with a companion command-line tool.

Early version: receiver compatibility, audio playback, and physical remote behavior still need hardware validation. The app has no local video view.

## Build and run

Requires macOS 14+ and Swift 6 Command Line Tools or Xcode.

```bash
bash scripts/build.sh
open build/AirPlayer.app
```

This creates a locally signed app, ZIP archive, and `build/airplayer`. Pass `debug` to the build script for a development build. Quit the app before rebuilding its bundle. Alternatively, open `AirPlayer.xcodeproj` in Xcode and configure your signing team.

## Play a video

1. Choose a video-capable receiver using **AirPlay**, and paste a direct video URL, YouTube video link, or public YouTube playlist and click **Load**. Either order works.
2. Press **Play** when the video and external route are ready.
3. Use Pause, Stop, or the available timeline. Load another URL to change videos.

Loading stays paused. AirPlayer may briefly attempt muted playback to establish the external video route. Route loss pauses and mutes playback. Closing the window keeps the app running; reopen it from the menu bar or CLI. The Mac must remain running and connected.

Live streams show their distance from the live edge and offer **Go Live** when playback falls behind. In **Settings**, choose whether a finished video remains loaded for replay or is unloaded so the receiver can return to its normal screen.

The playback summary shows the selected path: **Direct playback** uses the source without preparing a local file; **Remuxed playback** copies its compressed audio/video into a compatible file on the Mac. Hover over the label for details. These are processing tiers, not quality scores or confirmation of receiver playback. The same path appears in CLI status and the optional JSON `playbackPath` field (`direct` or `remux`).

## YouTube links (experimental)

Install the optional helpers for website playback:

```bash
brew install yt-dlp deno ffmpeg
```

Paste a public, on-demand YouTube watch, Shorts, `youtu.be`, or dedicated playlist link in the same field, or pass it to `airplayer open`. AirPlayer shows **Finding video…** while yt-dlp extracts metadata. It prefers a combined H.264/AAC MP4 or HLS source. If only suitable separate MP4/M4A tracks are available, it shows **Preparing video…**, copies them into a temporary MP4 without re-encoding, and serves the finished file to the receiver. Loading stays paused. Directly playable video URLs work without these helpers.

Source adapters discover candidates, and one shared policy prefers native playback over preparation. Among native candidates it prefers higher known resolution, then HLS at equal resolution, then bitrate. YouTube HLS masters are checked alongside combined MP4/HLS candidates; a lower-quality HLS option does not automatically beat a higher-quality native MP4. A usable H.264/AAC master goes directly to AVPlayer, which selects and synchronizes its renditions; FFmpeg is not involved. Direct URLs usually supply one candidate and retain their native attempt even when format details are unknown. Sources without a usable native presentation still need the preparation path above, which finishes the full file before playback.

Dedicated `youtube.com/playlist?list=…` links create a queue of up to 100 entries. The first playable item loads paused. Use Previous and Next in the app or CLI; once playback has actually started on a receiver, a normally completed item advances to the next playable entry. Entries resolve only when selected, so signed media URLs are not retained for the whole playlist. Unavailable, live, or unsupported entries are skipped with a notice. YouTube Mixes, private/authenticated playlists, shuffle, repeat, and queue editing are not supported. A watch link that also contains `list=` continues to load only its named video.

Some videos offer incompatible codecs, fragmented delivery, or custom request headers that this preparation path cannot handle. These produce a limitation message. Transcoding is not implemented. Live website streams, sign-in/cookies, and other websites remain outside this resolver slice. Local extraction does not establish receiver picture or sound.

The app finds helpers in standard Homebrew locations even when launched from Finder. For development, set `AIRPLAYER_YTDLP`, `AIRPLAYER_DENO`, `AIRPLAYER_FFMPEG`, and `AIRPLAYER_FFPROBE` to absolute executable paths **in the app's launch environment**. Setting them only on a CLI command does not change an already-running app. Keep yt-dlp and its JavaScript support current; see [yt-dlp's runtime requirements](https://github.com/yt-dlp/yt-dlp/wiki/EJS). Helpers are not bundled yet.

## Command line

```bash
./build/airplayer open 'https://example.com/movie.m3u8'
./build/airplayer play
./build/airplayer pause
./build/airplayer seek 120
./build/airplayer next
./build/airplayer previous
./build/airplayer status --json
./build/airplayer stop
./build/airplayer show
```

`open` and `show` launch the app if necessary. Select the receiver through the UI; selection by name is not supported. `open` loads paused. `seek` takes absolute seconds within the available timeline. `next` and `previous` navigate an active playlist. All commands accept `--json`; `pending: true` means an operation was accepted, so query `status` for its observed result. `hasAudio`, when present, describes the source's audio tracks, not audible output at the TV. Streaming track information can arrive after readiness; unknown audio status is omitted rather than reported as silence.

`status --json` includes `errorReason` when a media failure is diagnosed: network, unavailable source, unreadable media, missing video, protected media, or unsupported external playback. Website failures additionally distinguish missing helpers, resolution failure/timeout, unsupported pages, and required media preparation. Unclassified player failures remain `load_failed` or `playback_interrupted`; messages omit underlying URLs and request details. During extraction or preparation, the existing `loading` state has an optional `loadingPhase` field (`resolving` or `preparing`). An active playlist adds a privacy-safe `queue` object with its title, current zero-based index, item titles/states, and truncation flag; source URLs remain omitted. Preparation failures distinguish missing helpers, limits, processing failure, and local delivery failure. Live status can include `liveOffset`; the optional `diagnostics` object reports buffer ranges and state, waiting reason, bitrate estimates, and stall count without source URLs or request data.

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

- Direct HTTP/HTTPS video supported by AVFoundation and the receiver; MP4 and HLS are the initial formats. Other extensions are accepted too; file extension alone does not establish compatibility. Native loading does not prove receiver playback.
- Direct sources need their own audio track or HLS audio rendition. The app warns about detected video-only sources. Website extraction can combine compatible separate tracks; there is no manual two-URL input.
- Website extraction is limited to the experimental YouTube path above. After a native format failure, the app can also remux suitable H.264/AAC in MKV into MP4. Transcoding, custom headers/cookies, DRM integrations, and local-file input are not implemented.
- Audio-only AirPlay speakers cannot display video. Television/receiver controls own volume.
- Apple TV Remote integration uses public Now Playing and remote-command APIs; actual receiver behavior remains subject to hardware testing.

Stop and URL replacement cancel extraction/preparation, stop the session’s media server, and remove its temporary file. A source reported unavailable during initial website loading gets one re-resolution attempt; established playback is never automatically restarted. Load the original link again if it later expires.

Preparation currently accepts finite media up to four hours, with H.264 SDR video up to 1080p/60 and AAC-LC mono/stereo audio. It allows at most 2 GiB of prepared media and ten minutes of remux processing, requires disk headroom, and finishes the file before playback. These are conservative preparation limits, not receiver compatibility guarantees. Direct playback retains its existing native capabilities.

Prepared media is served on the Mac’s active Wi-Fi/Ethernet IPv4 address and an ephemeral port, through a random session URL. The Mac and receiver need network connectivity to one another; allow AirPlayer through the macOS firewall/local-network prompt if shown. Network changes may require loading again. Multi-interface setups can set `AIRPLAYER_MEDIA_HOST` to the Mac’s receiver-reachable IPv4 address in the app’s environment. Do not use `127.0.0.1` for a receiver. Prepared files are removed on Stop, replacement, failure, and Quit; abandoned preparation files are cleaned on the next launch.

The app stores no media history or pairing credentials of its own. Media URLs stay in memory and are omitted from status and errors; shell history is managed by your shell. macOS manages pairing and may save window geometry.

See [CONTRIBUTING.md](CONTRIBUTING.md) for tests, project layout, and packaging details.

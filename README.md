# AirThrow

A small native macOS controller for playing video URLs and local video files on Apple TV and other video-capable AirPlay receivers. Built with Swift, AVPlayer, and Apple's system AirPlay picker, with a companion command-line tool.

Early version: receiver compatibility, audio playback, and physical remote behavior still need hardware validation. The app has no local video view.

## Build and run

Requires macOS 14+ and Swift 6 Command Line Tools or Xcode.

```bash
bash scripts/build.sh
open build/AirThrow.app
```

This creates a locally signed app, ZIP archive, and `build/athrow`. Pass `debug` to the build script for a development build. Quit the app before rebuilding its bundle. Alternatively, open `AirThrow.xcodeproj` in Xcode and configure your signing team.

## Play a video

1. Choose a video-capable receiver using **AirPlay**, then paste a direct video URL, YouTube link, public YouTube playlist, or local file path and click **Load**. You can also choose a local file or drop a video file or web link onto the source area. Either order works.
2. Press **Play** when the video and external route are ready.
3. Use Pause, Stop, or the available timeline. Load another URL to change videos.

Loading stays paused. AirThrow may briefly attempt muted playback to establish the external video route. Route loss pauses and mutes playback. Closing the window keeps the app running; reopen it from the menu bar or CLI. The Mac must remain running and connected.

The AirPlay icon in the menu bar shows the current item and playback state. Use it for Play/Pause, Stop, ±10-second seeking, and playlist navigation without reopening the controller. Receiver selection remains in the controller's native AirPlay picker.

Live streams show their distance from the live edge and offer **Go Live** when playback falls behind. In **Settings**, choose whether a finished video remains loaded for replay or is unloaded so the receiver can return to its normal screen.

The playback summary shows the processing path: **Direct playback** uses the source without preparing a local file; **Remuxed playback** copies its compressed tracks; **Audio conversion** preserves compatible video and converts audio to AAC; **Video conversion** prepares SDR H.264 video on the Mac, converting audio only when needed. Hover over the label for details. These are processing tiers, not quality scores or confirmation of receiver playback. The same path appears in CLI status and the optional JSON `playbackPath` field (`direct`, `remux`, `audio_conversion`, or `video_conversion`). Inspection determines the actual preparation path.

### Quality and conversion

When a source offers multiple presentations, use the compact **Quality** menu beside the playback details to choose one. A single file has no meaningful alternate quality choice; its inspected resolution appears in the playback summary when preparation is needed. **Automatic** prefers less processing, then higher known quality within that tier; **Prefer higher quality** in Settings changes that priority. You can explicitly choose a higher-quality remuxed presentation instead of a lower-quality direct source. Known audio codec/language information and reasons an option is unavailable appear alongside each choice. HLS quality describes an available maximum, not the currently playing rendition.

Choosing an option resolves the original source again, reloads the current item from the start, and leaves it paused. Receiver selection and the playlist are preserved. The choice applies only to that item; navigation returns to Automatic. If the requested presentation disappears, loading fails with a recovery message instead of silently choosing another one.

**Avoid video conversion** is on by default in Settings. Audio conversion is allowed with this preference on. Turn it off to permit supported SDR video conversion when needed. Changes apply to the next load or source choice; an existing preparation or playing item continues with its captured settings. Conversion produces H.264/AAC up to 1080p/60 without upscaling, prefers hardware encoding when available, and has a software fallback. HDR/Dolby Vision tone mapping, subtitle burn-in, surround preservation, and arbitrary seeking into unprepared media are not supported. FFmpeg and ffprobe remain optional, separately installed helpers.

## YouTube links (experimental)

Install the optional helpers for website playback:

```bash
brew install yt-dlp deno ffmpeg
```

Paste a public YouTube watch, Shorts, `youtu.be`, live stream, dedicated playlist, or Mix link in the same field, or pass it to `athrow open`. AirThrow shows **Finding video…** while yt-dlp extracts metadata. It prefers a combined H.264/AAC MP4 or HLS source. A native HLS presentation, including a live stream, goes straight to AVPlayer. If only suitable separate MP4/M4A tracks are available, it shows **Preparing video…**, copies them into temporary HLS segments without re-encoding, and serves them to the receiver while preparation continues. Loading stays paused. Directly playable video URLs work without these helpers.

Source adapters discover candidates, and one shared policy prefers native playback over preparation. Among native candidates it prefers higher known resolution, then HLS at equal resolution, then bitrate. YouTube HLS masters are checked alongside combined MP4/HLS candidates; a lower-quality HLS option does not automatically beat a higher-quality native MP4. A usable H.264/AAC master goes directly to AVPlayer, which selects and synchronizes its renditions; FFmpeg is not involved. Direct URLs usually supply one candidate; MKV/WebM enter inspection, while other unknown formats retain a native attempt. Sources without a usable native presentation still need the preparation path above, which can serve prepared segments while the rest of the video is still being remuxed.

Dedicated `youtube.com/playlist?list=…` links and YouTube Mixes (`list=RD…`, whether shared as a playlist page or a watch link) create a queue of up to 100 entries. The first playable item loads paused. Use Previous and Next in the app or CLI; once playback has actually started on a receiver, a normally completed item advances to the next playable entry. Entries resolve only when selected, so signed media URLs are not retained for the whole playlist. Unavailable or unsupported entries, including not-yet-started premieres, are skipped with a notice. Live entries play through the native HLS path. Private/authenticated playlists, shuffle, repeat, and queue editing are not supported. A watch link with any other `list=` continues to load only its named video.

Some videos offer unsupported codecs, HDR, fragmented delivery, or custom request headers that this preparation path cannot handle. These produce a limitation message. Supported audio is converted when necessary; video conversion requires turning off **Avoid video conversion**. A live stream plays only when it offers a native H.264/AAC presentation; a live stream that would need remuxing or conversion cannot be prepared and is refused. DRM and non-YouTube websites remain outside this resolver slice. Local extraction does not establish receiver picture or sound.

Some public videos fail with "Could not find a playable video" because YouTube challenges the request, not because the video is private. In **Settings → YouTube access**, choose a browser or a Netscape `cookies.txt` file to answer that check. AirThrow reads the cookie source itself and keeps only `youtube.com`, `youtu.be`, and `youtube-nocookie.com` cookies; no other site's cookies are imported. The reduced set is written to a private temporary file and deleted once extraction finishes, and cookie values never appear in status or logs. The picker lists only browsers found on this Mac, and a status line reports whether a signed-in YouTube session was actually found: green when cookies loaded, red with the specific fix when the session is missing or a permission was denied. Safari requires Full Disk Access for AirThrow; Chromium-family browsers ask for Keychain access to decrypt their store. Cookies stay on the Mac.

The app finds helpers in standard Homebrew locations even when launched from Finder. For development, set `AIRTHROW_YTDLP`, `AIRTHROW_DENO`, `AIRTHROW_FFMPEG`, and `AIRTHROW_FFPROBE` to absolute executable paths **in the app's launch environment**. `AIRTHROW_YTDLP_COOKIES` (a Netscape file path) and `AIRTHROW_YTDLP_COOKIES_FROM_BROWSER` (a supported browser name) override the Settings cookie choice. Setting them only on a CLI command does not change an already-running app. Keep yt-dlp and its JavaScript support current; see [yt-dlp's runtime requirements](https://github.com/yt-dlp/yt-dlp/wiki/EJS). Helpers are not bundled yet.

## Local files (experimental)

Choose a local video with the folder button, drop it on the source area, paste its path or `file:` URL, open it from Finder, or pass its path to `athrow open`. The picker enables MP4, M4V, MOV, MKV, and WebM files. Relative CLI paths and an initial `~` are expanded before the request reaches the shared session. AirThrow resolves symlinks to a readable regular file and rejects directories, empty files, and remote `file:` hosts.

MP4, MOV, and unknown containers first use zero-copy delivery: AirThrow serves the selected file in place over the same private LAN endpoint used for prepared media. MKV and WebM enter FFmpeg inspection immediately; an initially unreadable local container gets the same bounded preparation fallback. Compatible tracks are copied, supported incompatible audio is converted, and video conversion follows the preference above. In-place delivery has no file-size limit, so a large receiver-compatible MP4 or MOV plays without copying it; prepared media still obeys the size (below 2 GiB) and four-hour duration limits. No local file is copied merely to make it reachable, and Stop never deletes the selected file. The Mac and receiver must be mutually reachable, and receiver playback remains subject to hardware validation. Local HLS folders/playlists, directory browsing, and local playlists are not supported.

## Command line

```bash
./build/athrow open 'https://example.com/movie.m3u8'
./build/athrow open '/Users/me/Movies/movie.mp4'
./build/athrow play
./build/athrow pause
./build/athrow seek 120
./build/athrow next
./build/athrow previous
./build/athrow status --json
./build/athrow sources --json
./build/athrow source automatic
./build/athrow conversion allow-video
./build/athrow stop
./build/athrow show
```

`open` and `show` launch the app if necessary. Select the receiver through the UI; selection by name is not supported. `open` loads paused. `seek` takes absolute seconds within the available timeline. `next` and `previous` navigate an active playlist. All commands accept `--json`; `pending: true` means an operation was accepted, so query `status` for its observed result. `hasAudio`, when present, describes the source's audio tracks, not audible output at the TV. Streaming track information can arrive after readiness; unknown audio status is omitted rather than reported as silence.

`sources` lists privacy-safe quality, audio, processing path, eligibility, and opaque option IDs. Use `source ID` to choose one or `source automatic` to restore automatic selection. IDs expire on reload, replacement, or Stop; list sources again before choosing. JSON status includes optional `sources`, `selectedSourceID` (absent for Automatic), and `allowVideoConversion`. `conversion allow-video` or `conversion avoid-video` saves the same preference used by the UI.

`status --json` includes `errorReason` when a media failure is diagnosed: network, unavailable source, unreadable media, missing video, protected media, or unsupported external playback. Website failures additionally distinguish missing helpers, resolution failure/timeout, unsupported pages, unsupported live streams, and required media preparation. Unclassified player failures remain `load_failed` or `playback_interrupted`; messages omit underlying URLs and request details. During extraction or preparation, the existing `loading` state has an optional `loadingPhase` field (`resolving` or `preparing`). An active playlist adds a privacy-safe `queue` object with its title, current zero-based index, item titles/states, and truncation flag; source URLs remain omitted. Preparation failures distinguish missing helpers, limits, processing failure, and local delivery failure. Live status can include `liveOffset`; the optional `diagnostics` object reports buffer ranges and state, waiting reason, bitrate estimates, and stall count without source URLs or request data.

The CLI is also bundled at `AirThrow.app/Contents/MacOS/athrow`. Set `AIRTHROW_APP` to the app's path if needed. Commands operate in the logged-in desktop session.

| Exit code | Meaning |
| --- | --- |
| 0 | Succeeded or accepted; inspect status |
| 2 | Invalid command, URL, or argument |
| 3 | App or command endpoint unavailable |
| 4 | Select an AirPlay video receiver first |
| 5 | Operation unavailable, such as an out-of-range seek |
| 6 | Missing video or playback failure |

## Supported sources and limitations

- Direct HTTP/HTTPS video supported by AVFoundation and the receiver; MP4 and HLS are the initial formats. Local MP4/MOV files use in-place LAN delivery. Remote and local MKV/WebM enter inspection and preparation immediately; compatible H.264/AAC tracks can be remuxed, while supported incompatible tracks require conversion under the current preference. Other extensions get one native attempt; file extension alone does not establish compatibility. Native loading does not prove receiver playback.
- Direct sources need their own audio track or HLS audio rendition. The app warns about detected video-only sources. Website extraction can combine compatible separate tracks; there is no manual two-URL input.
- Website extraction is limited to the experimental YouTube path above. After an initial native format failure, the app can prepare supported tracks into a finite MP4. Custom request headers and DRM integrations are not implemented; cookies are limited to the YouTube-scoped source described above.
- Audio-only AirPlay speakers cannot display video. Television/receiver controls own volume.
- Apple TV Remote integration uses public Now Playing and remote-command APIs; actual receiver behavior remains subject to hardware testing.

Stop and URL replacement cancel extraction/preparation, stop the session’s media server, and remove its temporary media. A source reported unavailable during initial website loading gets one re-resolution attempt; established playback is never automatically restarted. Load the original link again if it later expires.

Preparation accepts finite media up to four hours. Compatible H.264 SDR up to 1080p/60 and AAC-LC mono/stereo tracks are copied; other supported tracks can be converted as described above. Video conversion accepts known SDR inputs through 3840×2160 at 120 fps and produces at most 1080p/60. Preparation requires disk headroom, monitors a 2 GiB temporary-media limit, and allows ten minutes per processing attempt. The app now waits for a finalized MP4 before handing prepared media to the receiver, so finite videos have a finite timeline; conversion may take longer before playback becomes ready. Loading remains paused. Experimental progressive HLS remains available with `AIRTHROW_PREPARATION_MODE=progressive-hls` in the app’s launch environment, but a receiver may treat its growing EVENT playlist as live. These are conservative preparation limits, not receiver compatibility guarantees. Direct playback retains its existing native capabilities.

Prepared media is served on the Mac’s active Wi-Fi/Ethernet IPv4 address and an ephemeral port, through a random session URL. The Mac and receiver need network connectivity to one another; allow AirThrow through the macOS firewall/local-network prompt if shown. Network changes may require loading again. Multi-interface setups can set `AIRTHROW_MEDIA_HOST` to the Mac’s receiver-reachable IPv4 address in the app’s environment. Do not use `127.0.0.1` for a receiver. Prepared files are removed on Stop, replacement, failure, and Quit; abandoned preparation files are cleaned on the next launch.

The app stores no media history or pairing credentials of its own. Media URLs and local paths stay in memory and are omitted from status and errors; shell history is managed by your shell. macOS manages pairing and may save window geometry.

## License

AirThrow's source code is licensed under the [Apache License 2.0](LICENSE).

This license covers AirThrow's own code only. It does not grant rights to third-party media, to Apple frameworks and services (AVFoundation, AirPlay), or to external tools such as FFmpeg/ffprobe and yt-dlp, which remain subject to their own licenses and terms.

See [CONTRIBUTING.md](CONTRIBUTING.md) for tests, project layout, and packaging details.

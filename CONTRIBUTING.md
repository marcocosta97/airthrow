# Development

## Layout

- `Sources/AirPlayerApp`: native controller, persistent AVPlayer session, and remote commands.
- `Sources/AirPlayerCore`: validation, playback policy, command protocol, and local socket.
- `Sources/AirPlayerCLI`: command parsing and app launch.
- `Tests`: core checks and focused controller checks.
- `scripts`: packaging, Xcode project generation, icon generation, and test fixtures.

Use Apple's public APIs and the system receiver picker. Keep one playback session shared by the UI and CLI, with no local video presentation. Derive status from observed playback state and cancel stale work when media changes.

`SourceResolver` dispatches discovery to direct/YouTube adapters. Adapters return complete `MediaCandidate` presentations rather than selecting one: an upstream master, combined file, or paired audio/video tracks. `MediaSelector` ranks them without provider-specific logic and returns a `ResolvedSource` execution plan. Native playback wins over remuxing by default; within a tier, known resolution wins, HLS breaks resolution ties, then bitrate. HLS quality comes from eligible variants in the inspected master and is not the observed playback quality. Unknown direct media remains eligible for a native attempt without helper/network preflight. The shared remux fallback handles initial native format failures; HLS, network/DRM failures and already-prepared sources do not enter that fallback. `MediaPreparer` still validates actual streams before copying them.

The additive protocol-v1 `playbackPath` reports the chosen plan (`direct` or `remux`), including during preparation, and is absent before selection, after Stop, and on terminal failure. The UI and CLI use the same snapshot. It neither exposes candidate URLs nor asserts receiver compatibility. Resolver/core checks cover ranking independently of adapter order, preserving alternatives, lower-quality HLS versus native MP4, and bounded fallback; preparation checks cover label changes and cleanup across replacement/Stop.

## Core checks

```bash
swift build --disable-sandbox --build-system native
.build/debug/CoreChecks
```

These checks use a plain Swift executable and work with Command Line Tools. Python 3 is needed for integration checks and project generation, not by the app at runtime.

## App and controller checks

Build and launch the app first. Stop existing playback before running integration checks, which change the active session and leave it idle. Use fresh output filenames when generating fixtures:

```bash
swift scripts/make-test-video.swift /tmp/airplayer-test.mp4
swift scripts/add-test-audio.swift /tmp/airplayer-test.mp4 /tmp/airplayer-test-audio.mp4
python3 scripts/integration-checks.py build/airplayer /tmp/airplayer-test.mp4 /tmp/airplayer-test-audio.mp4
```

To serve fixtures without controlling the app, append `--serve`. The server binds to loopback and implements byte ranges needed for reliable loading. In another terminal, use the printed port for focused controller checks:

```bash
swiftc -swift-version 6 -parse-as-library Sources/AirPlayerCore/*.swift Sources/AirPlayerApp/MediaDiagnostics.swift Sources/AirPlayerApp/PlaybackController.swift Tests/ControllerChecks/main.swift -o .build/ControllerChecks
.build/ControllerChecks http://127.0.0.1:PORT
```

Run the AVPlayer-based controller and media suites sequentially on one machine to avoid interference through system media services. These checks do not establish AirPlay compatibility. On a physical receiver, verify picture and sound, load/select/play order, pause/seek, remote controls, URL replacement, connection loss, and absence of unintended local playback. Record OS versions and receiver models with results.

## Native media matrix

Run a self-contained check using a separate controller instance, without launching or controlling the desktop app:

```bash
python3 scripts/native-media-checks.py
```

The script generates original two-second MP4, MOV, HEVC, audio-only, and invalid-media fixtures, serves them with HTTP byte ranges, and checks native loading plus diagnostic privacy and lifecycle behavior. Each run writes fixtures and `results.json` to a new ignored `build/native-media-*` directory. The report records the host and explicitly leaves receiver picture, sound, seeking, and remote controls untested. `awaiting_receiver` means the native player loaded the item; it does not verify decoding or AirPlay compatibility.

If FFmpeg is installed, the same check adds HLS, MKV, WebM, and H.264/FLAC fixtures. HLS regressions cover muxed audio/video, video-only, audio-only, extensionless URLs, and receiver-first negotiation after streaming tracks appear. Use `--ffmpeg /path/to/ffmpeg` to select a binary. Missing tools/encoders or unavailable native HEVC encoding produce explicit skipped rows. The native matrix explicitly disables preparation to measure AVPlayer alone. The application uses optional FFmpeg/ffprobe helpers for the separate preparation path below. Silent HLS may retain unknown audio status because an empty dynamic track list cannot establish absence; file-based video-only fixtures still assert `hasAudio: false`. The FLAC case probes alternative audio handling; whether it is unsupported depends on the tested platform and receiver.

For manual receiver checks, append `--serve --bind YOUR_MAC_LAN_IP` to keep the generated fixtures available on that interface. Load the printed server URL plus the fixture's `path` from `fixtures.json` in AirPlayer. The default interface is loopback, which a receiver cannot access. Stop the fixture server with Ctrl-C; keep it running during the receiver test. Record receiver model/firmware and actual results separately before claiming format support.

## Website resolver checks

Deterministic checks use fake helper executables and metadata; no installed yt-dlp, external site, or receiver is needed:

```bash
swiftc -swift-version 6 -parse-as-library Sources/AirPlayerCore/Protocol.swift Sources/AirPlayerCore/MediaSelection.swift Sources/AirPlayerCore/SourceResolver.swift Sources/AirPlayerCore/HelperProcess.swift Tests/ResolverChecks/main.swift -o .build/ResolverChecks
.build/ResolverChecks
```

They cover direct bypass, exact website hosts, single-video playlist-context removal, bounded flat-playlist extraction, ordering, unavailable entries, Mix rejection, missing helpers, combined-stream selection, unknown codecs, custom headers, DRM/live restrictions, malformed output, output limits, timeout, and cancellation of child processes. The native media matrix also checks resolver Stop/replacement and exactly one retry for a source-unavailable error, with all loads paused.

Resolver checks also cover HLS master selection before remuxing, alternate-audio groups, malformed/missing audio references, unsupported codecs, custom-header exclusion, cancellation, and fallback after fetch failure. Master inspection tries at most two distinct URLs, each with an eight-second resource deadline and 1 MiB body limit, using an ephemeral session without cookies or stored credentials. Only a master advertising an H.264/AAC variant and valid HTTP(S) rendition references is eligible; AVPlayer selects and loads the actual renditions. The native matrix includes a separate-audio HLS fixture and exercises HTTP errors, advertised/unadvertised oversized bodies, and cancellation. Receiver audio, seeking and adaptive variant changes still need physical testing.

Playlist controller checks use injected deterministic metadata and media URLs. They verify that the first playable item stays paused, unavailable entries are skipped, navigation resolves items lazily, and Stop clears the queue. Physical receiver acceptance still needs normal-end automatic advancement, Previous/Next while playing and paused, route loss, replacement during preparation, and a public playlist containing both direct and remuxed entries.

Inspected HLS masters retain positive video evidence through source selection. A ready item on an active AirPlay route may expose no local video tracks or presentation size; this evidence lets the controller finish loading without waiting for those observations. Resolver checks ensure validated masters retain it and uninspected URLs or invalid masters do not invent it. Status diagnostics expose item/player readiness, transport state, and video confirmation to distinguish this gate from network buffering.

For an optional metadata-only live smoke check, install `yt-dlp` and `deno`, record their `--version` output, and run:

```bash
.build/ResolverChecks --resolve 'https://www.youtube.com/watch?v=VIDEO_ID'
```

This uses the same resolver as the app and prints a redacted result. Live-site results may change independently of AirPlayer. Validate UI and CLI loading and receiver picture/sound separately. The result distinguishes a combined source from separate tracks selected for preparation. It is metadata-only and is not a playback pass.

The subprocess runs in its own process group with a 40-second deadline, 8 MiB JSON limit, and 256 KiB discarded stderr limit. Stop/replacement kills the group and reaps the helper. Arguments disable user configuration, plugins, cache, and remote component installation; no browser cookies or authentication are imported. JavaScript/EJS support must already be installed. Default yt-dlp browser headers are retained in memory; direct playback does not forward them, while FFmpeg/ffprobe receive them for separate HTTP tracks. Other headers remain ineligible. Even candidates with only default headers can fail if a site requires them at fetch time.

## Preparation and HTTP delivery checks

With Homebrew FFmpeg installed, run:

```bash
python3 scripts/preparation-checks.py
```

This generates original short H.264/AAC fixtures, remuxes MKV, joins separate MP4/M4A tracks, and compares compressed packet hashes to prove the tracks were copied. It verifies GET/HEAD, byte ranges and invalid ranges, exact session routes, server closure, missing helpers, unsupported audio, limits, cancellation, abandoned-file cleanup, preservation of active sessions, and controller fallback/replacement. Each run writes a report and fixtures under ignored `build/preparation-*`. Run this suite sequentially with the AVPlayer-based native/controller checks.

The same suite also uses a paced 20-second fixture to check HLS readiness before producer completion, growing playlists, segment GET/HEAD/ranges, finite ENDLIST, unchanged decoded video frames, native paused loading, finite timeline/seek bounds, startup fallback, post-handoff producer failure, and Stop/quit cleanup. This exercises local HTTP delivery and AVPlayer; receiver playback remains untested.

Progressive stream copy uses FFmpeg’s [HLS EVENT muxer and `temp_file` flag](https://ffmpeg.org/ffmpeg-formats.html#hls-2). Two seconds is a segment target; stream copy cuts at source keyframes. Startup requires at least three complete segments covering six seconds and production averaging at least real time, or validated completion for short media. A 30-second startup deadline falls back once to MP4 before returning a URL. `MediaPreparer.prepare(_:mode:)` can explicitly select `.completeFile`; the app also accepts `AIRPLAYER_PREPARATION_MODE=complete-file` in its launch environment. After handoff, a producer failure ends the session rather than advancing a playlist. Stop detaches it and closes delivery immediately, cancels the process group, and keeps the workspace lease until the helper is reaped; Quit awaits this cleanup.

For a bounded live website check, the generated `PreparationChecks` binary also accepts `--website URL`. It resolves, prepares when required, checks native audio/video tracks, and removes its temporary result. This downloads the selected media; use a short public test clip. It does not verify receiver playback.

Preparation probes actual streams, maps one video and one audio stream, and invokes `-c copy`; no encoder fallback exists. Inputs are restricted to HTTP(S) MP4/M4A or Matroska/WebM demuxing. Output metadata/chapters/extra tracks are omitted. The complete-file path uses a 2 GiB output limit and final size/duration checks. Progressive HLS reserves headroom below the same cap during the source-size pre-check because MPEG-TS packetization inflates the remux, then monitors aggregate temporary size (including unfinished segments) every 250 ms, so brief overshoot is possible, and validates final playlist duration and ENDLIST after FFmpeg succeeds. ffprobe has a 40-second deadline per inspection, FFmpeg has ten minutes, and network reads have a 15-second inactivity limit. Limits also require finite duration of at most four hours, SDR H.264 8-bit 4:2:0 up to 1080p/60, AAC-LC up to stereo/48 kHz, and disk headroom.

Session directories under the user’s temporary directory hold lease locks. Stop/replacement/failure closes the listener and detaches the player item before releasing files; startup removes unlocked abandoned directories. The HTTP server binds a selected local IPv4 address, allows up to eight clients, bounds headers and idle time, and serves only session media through an unguessable URL prefix. HLS routes allow the media playlist and generated segment names; temporary files, leases, traversal, and unrelated files are not served. Playlists and segments are published by atomic rename, and each response reads and measures the same open file descriptor. It supports single byte ranges and uses `Connection: close`; multiple ranges are rejected. There is no directory browser, general proxy, or upstream HLS rewriting. `AIRPLAYER_MEDIA_HOST=127.0.0.1` is reserved for local automated checks; receiver tests need a LAN address.

Hardware acceptance remains separate: verify prepared-file picture/sound/sync, seeking, receiver controls, firewall permission, replacement, route loss, and network changes on Apple TV, then a second receiver. Local loading and packet identity alone do not establish AirPlay compatibility.

## Packaging

`bash scripts/build.sh` uses an ad-hoc signature for local testing. Set `AIRPLAYER_BUILD_DIR` to build elsewhere while preserving an existing bundle. Only one app session runs at a time. Regenerate the Xcode project using `python3 scripts/generate-xcode-project.py`; verify Xcode builds separately when full Xcode is available.

For distribution, supply `CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'` to the build script. This enables hardened runtime and timestamping; notarization is a separate release step. The app is not App Sandbox-enabled. Its command endpoint is a private per-user Unix socket, not a TCP listener.

Prefer extracting the packaged ZIP to an unsynced application directory: cloud-sync metadata on a loose app can interfere with strict signature verification. Do not commit build output, signing credentials, or local editor state.

The standard About AirPlayer panel shows the build’s short Git commit. Packaging and Xcode builds stamp it into `BuildCommit.txt` before signing; `-dirty` indicates uncommitted changes (including untracked, non-ignored files). Builds from a source export without Git metadata display `unknown`. Plain `swift build` does not package this resource; use the packaging script or Xcode for the About metadata.

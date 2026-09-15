# Development

## Layout

- `Sources/AirPlayerApp`: native controller, persistent AVPlayer session, and remote commands.
- `Sources/AirPlayerCore`: validation, playback policy, command protocol, and local socket.
- `Sources/AirPlayerCLI`: command parsing and app launch.
- `Tests`: core checks and focused controller checks.
- `scripts`: packaging, Xcode project generation, icon generation, and test fixtures.

Use Apple's public APIs and the system receiver picker. Keep one playback session shared by the UI and CLI, with no local video presentation. Derive status from observed playback state and cancel stale work when media changes.

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
swiftc -swift-version 6 -parse-as-library Sources/AirPlayerCore/Protocol.swift Sources/AirPlayerCore/SourceResolver.swift Sources/AirPlayerCore/HelperProcess.swift Sources/AirPlayerApp/MediaDiagnostics.swift Sources/AirPlayerApp/PlaybackController.swift Tests/ControllerChecks/main.swift -o .build/ControllerChecks
.build/ControllerChecks http://127.0.0.1:PORT
```

Run the AVPlayer-based controller and media suites sequentially on one machine to avoid interference through system media services. These checks do not establish AirPlay compatibility. On a physical receiver, verify picture and sound, load/select/play order, pause/seek, remote controls, URL replacement, connection loss, and absence of unintended local playback. Record OS versions and receiver models with results.

## Native media matrix

Run a self-contained check using a separate controller instance, without launching or controlling the desktop app:

```bash
python3 scripts/native-media-checks.py
```

The script generates original two-second MP4, MOV, HEVC, audio-only, and invalid-media fixtures, serves them with HTTP byte ranges, and checks native loading plus diagnostic privacy and lifecycle behavior. Each run writes fixtures and `results.json` to a new ignored `build/native-media-*` directory. The report records the host and explicitly leaves receiver picture, sound, seeking, and remote controls untested. `awaiting_receiver` means the native player loaded the item; it does not verify decoding or AirPlay compatibility.

If FFmpeg is installed, the same check adds HLS, MKV, WebM, and H.264/FLAC fixtures. HLS regressions cover muxed audio/video, video-only, audio-only, extensionless URLs, and receiver-first negotiation after streaming tracks appear. Use `--ffmpeg /path/to/ffmpeg` to select a binary. Missing tools/encoders or unavailable native HEVC encoding produce explicit skipped rows. FFmpeg is a test-fixture dependency only; the application still has no conversion helper dependency. Silent HLS may retain unknown audio status because an empty dynamic track list cannot establish absence; file-based video-only fixtures still assert `hasAudio: false`. The FLAC case probes alternative audio handling; whether it is unsupported depends on the tested platform and receiver.

For manual receiver checks, append `--serve --bind YOUR_MAC_LAN_IP` to keep the generated fixtures available on that interface. Load the printed server URL plus the fixture's `path` from `fixtures.json` in AirPlayer. The default interface is loopback, which a receiver cannot access. Stop the fixture server with Ctrl-C; keep it running during the receiver test. Record receiver model/firmware and actual results separately before claiming format support.

## Website resolver checks

Deterministic checks use fake helper executables and metadata; no installed yt-dlp, external site, or receiver is needed:

```bash
swiftc -swift-version 6 -parse-as-library Sources/AirPlayerCore/Protocol.swift Sources/AirPlayerCore/SourceResolver.swift Sources/AirPlayerCore/HelperProcess.swift Tests/ResolverChecks/main.swift -o .build/ResolverChecks
.build/ResolverChecks
```

They cover direct bypass, exact website hosts, playlist removal, missing helpers, combined-stream selection, unknown codecs, custom headers, DRM/live restrictions, malformed output, output limits, timeout, and cancellation of child processes. The native media matrix also checks resolver Stop/replacement and exactly one retry for a source-unavailable error, with all loads paused.

For an optional metadata-only live smoke check, install `yt-dlp` and `deno`, record their `--version` output, and run:

```bash
.build/ResolverChecks --resolve 'https://www.youtube.com/watch?v=VIDEO_ID'
```

This uses the same resolver as the app and prints a redacted result. Live-site results may change independently of AirPlayer. Validate UI and CLI loading and receiver picture/sound separately. A preparation-required result means extraction succeeded but no eligible combined source was found; it is not a playback pass.

The subprocess runs in its own process group with a 40-second deadline, 8 MiB JSON limit, and 256 KiB discarded stderr limit. Stop/replacement kills the group and reaps the helper. Arguments disable user configuration, plugins, cache, and remote component installation; no browser cookies or authentication are imported. JavaScript/EJS support must already be installed. Default yt-dlp browser headers are retained in memory but not forwarded; other headers make a candidate ineligible until a delivery layer exists. Even candidates with only default headers can fail if a site requires them at fetch time.

## Packaging

`bash scripts/build.sh` uses an ad-hoc signature for local testing. Set `AIRPLAYER_BUILD_DIR` to build elsewhere while preserving an existing bundle. Only one app session runs at a time. Regenerate the Xcode project using `python3 scripts/generate-xcode-project.py`; verify Xcode builds separately when full Xcode is available.

For distribution, supply `CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'` to the build script. This enables hardened runtime and timestamping; notarization is a separate release step. The app is not App Sandbox-enabled. Its command endpoint is a private per-user Unix socket, not a TCP listener.

Prefer extracting the packaged ZIP to an unsynced application directory: cloud-sync metadata on a loose app can interfere with strict signature verification. Do not commit build output, signing credentials, or local editor state.

The standard About AirPlayer panel shows the build’s short Git commit. Packaging and Xcode builds stamp it into `BuildCommit.txt` before signing; `-dirty` indicates uncommitted changes (including untracked, non-ignored files). Builds from a source export without Git metadata display `unknown`. Plain `swift build` does not package this resource; use the packaging script or Xcode for the About metadata.

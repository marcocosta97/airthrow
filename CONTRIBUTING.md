# Development

## Layout

- `Sources/AirThrowApp`: native controller, persistent AVPlayer session, and remote commands.
- `Sources/AirThrowCore`: validation, playback policy, command protocol, and local socket.
- `Sources/AirThrowCLI`: command parsing and app launch.
- `Tests`: core checks and focused controller checks.
- `scripts`: packaging, Xcode project generation, icon compilation, and test fixtures.

Use Apple's public APIs and the system receiver picker. Keep one playback session shared by the UI and CLI, with no local video presentation. Derive status from observed playback state and cancel stale work when media changes.

`SourceResolver` dispatches discovery to direct/YouTube/local adapters. Adapters return complete `MediaCandidate` presentations rather than selecting one: an upstream master, combined file, paired audio/video tracks, or a validated local regular file. `MediaSelector` ranks them without provider-specific logic and returns a `ResolvedSource` execution plan. Native playback wins over remuxing by default; within a tier, known resolution wins, HLS breaks resolution ties, then bitrate. HLS quality comes from eligible variants in the inspected master and is not the observed playback quality. Unknown direct media remains eligible for a native attempt without helper/network preflight, except remote MKV/WebM, which enter preparation like local MKV/WebM. Local MP4/MOV files are served in place. The shared remux fallback handles initial native format failures; HLS, network/DRM failures and already-prepared sources do not enter that fallback. `MediaPreparer` still validates actual streams before copying them.

The additive protocol-v1 `playbackPath` reports `direct`, `remux`, `audio_conversion`, or `video_conversion`, and is absent before selection, after Stop, and on terminal failure. An unknown preparation plan remains unlabelled while inspection runs; prepared media reports the actual path used. The UI and CLI use the same snapshot. It neither exposes candidate URLs nor asserts receiver compatibility. Resolver/core checks cover ranking independently of adapter order, preserving alternatives, lower-quality HLS versus native MP4, and bounded fallback; preparation checks cover label changes and cleanup across replacement/Stop.

`ConversionPolicy.avoidVideo` is the default. It permits audio conversion while requiring compatible video to be copied. Explicit source choices override quality ranking, but never conversion permissions or unsupported-source restrictions. Adapters return bounded, complete presentations with stable metadata identities; the controller exposes fresh session-scoped IDs rather than provider IDs or URLs. Choosing a source resolves the original input again and reloads paused on the persistent player. Generation guards discard stale discovery and preparation results. Navigation resets the per-item override; source changes preserve the queue without advancing it on failure.

## Product behaviour and limits

User-facing behaviour that is too detailed for the README lives here.

### Receiver selection

Receiver selection uses Apple's system AirPlay picker and stays in the app. There
is no public API to select an AirPlay route by name, so the CLI cannot choose a
receiver: it only controls playback and observes `externalPlaybackActive`. A
command that needs a route fails with exit code 4. The picker is usable before
media is loaded; opening it is not evidence that a receiver was selected.

### Loading, route negotiation, and playback

Loading always starts paused. AirThrow may briefly attempt muted playback to
establish the external video route; a receiver chosen in the picker sets the
active route before the picker reports dismissal, so a bounded negotiation
window covers that gap. Route loss pauses and mutes playback. Closing the window
keeps the app running; the Mac must remain awake and connected. Live streams show
their distance from the live edge and offer **Go Live** when playback falls
behind. In Settings, a finished video either stays loaded for replay or is
unloaded so the receiver returns to its normal screen.

### Playback paths

The processing path is reported as one of four tiers: **direct** (source played
without preparing a local file), **remux** (compressed tracks copied), **audio
conversion** (compatible video kept, audio converted to AAC), and **video
conversion** (SDR H.264 produced on the Mac). These are processing tiers, not
quality scores or proof of receiver playback. The same value appears in UI, CLI
status, and the optional JSON `playbackPath` field. Inspection determines the
actual path.

**Avoid video conversion** is on by default. Audio conversion is allowed under
it; turn it off to permit supported SDR video conversion. Changes apply to the
next load or source choice; an in-flight preparation keeps its captured
settings. Conversion produces H.264/AAC up to 1080p/60 without upscaling,
prefers hardware encoding, and has a software fallback. HDR/Dolby Vision tone
mapping, subtitle burn-in, surround preservation, and arbitrary seeking into
unprepared media are unsupported.

### Source quality

When a source offers multiple presentations, use the **Quality** menu beside the
playback details. **Automatic** prefers less processing, then higher known
quality within that tier; **Prefer higher quality** in Settings changes that
priority. A single file has no meaningful alternate quality. Explicitly choosing
a higher-quality remuxed presentation over a lower-quality direct source is
allowed. Choosing an option re-resolves the original source, reloads the item
from the start, and leaves it paused; receiver selection and the playlist are
preserved. The choice applies only to that item, and navigation returns to
Automatic. If the requested presentation disappears, loading fails with a
recovery message instead of silently choosing another. HLS quality describes an
available maximum, not the current rendition.

`source` IDs are session-scoped and expire on reload, replacement, or Stop.
List sources again before choosing. Status exposes optional `sources`,
`selectedSourceID` (absent for Automatic), and `allowVideoConversion`.
`conversion allow-video` / `conversion avoid-video` saves the same preference as
the UI.

### YouTube extraction and cookies

Source adapters discover candidates; one shared policy prefers native playback
over preparation. Among native candidates it prefers higher resolution, then HLS
at equal resolution, then bitrate. A usable H.264/AAC HLS master goes straight to
AVPlayer, which selects and synchronizes its renditions; FFmpeg is not involved.
Direct URLs usually supply one candidate; MKV/WebM enter inspection, while other
unknown formats get one native attempt. Dedicated `playlist?list=…` links and
Mixes (`list=RD…`) create a queue of up to 100 entries; entries resolve lazily, so
signed URLs are not retained for the whole playlist, and unavailable or
not-yet-started entries are skipped with a notice. Live entries play through the
native HLS path when one is available. Private/authenticated playlists,
shuffle, repeat, and queue editing are unsupported. A watch link with any other
`list=` loads only its named video. DRM, non-YouTube sites, and custom request
headers are out of scope.

Some public videos fail with "Could not find a playable video" because YouTube
challenges the request, not because the video is private. Settings → YouTube
access selects a browser or a Netscape `cookies.txt` file. AirThrow reads the
source itself and keeps only `youtube.com`, `youtu.be`, and
`youtube-nocookie.com` cookies, writes them to a private `0600` temporary
Netscape file, and deletes it once extraction finishes; cookie values never
appear in status or logs. The picker lists only browsers found on this Mac, and a
status line reports whether a signed-in session was found. Safari requires Full
Disk Access; Chromium-family browsers ask for Keychain access to decrypt their
store.

Helpers are found in standard Homebrew locations even when the app is launched
from Finder. `AIRTHROW_YTDLP`, `AIRTHROW_DENO`, `AIRTHROW_FFMPEG`, and
`AIRTHROW_FFPROBE` override their paths, and `AIRTHROW_YTDLP_COOKIES` /
`AIRTHROW_YTDLP_COOKIES_FROM_BROWSER` override the Settings cookie choice — all
read **in the app's launch environment**, not from a CLI command. Helpers are not
bundled.

### Local files

Local files are chosen with the folder button, dropped on the source area, pasted
as a path or `file:` URL, opened from Finder, or passed to `athrow open`.
Relative CLI paths and a leading `~` are expanded before the request reaches the
shared session. AirThrow resolves symlinks to a readable regular file and rejects
directories, empty files, and remote `file:` hosts. MP4/MOV and unknown
containers first use zero-copy delivery over the private LAN endpoint; MKV/WebM
enter inspection immediately, with a bounded fallback for an initially unreadable
container. In-place delivery has no size cap and Stop never deletes the selected
file; prepared media still obeys the size and duration limits below. Local HLS
folders/playlists, directory browsing, and local playlists are unsupported.

### Preparation limits

Preparation accepts finite media up to four hours. Compatible H.264 SDR up to
1080p/60 and AAC-LC mono/stereo are copied; other supported tracks are converted
as described above. Video conversion accepts known SDR inputs through 3840×2160
at 120 fps and produces at most 1080p/60. Preparation requires disk headroom,
monitors a 2 GiB temporary-media limit, and allows ten minutes per processing
attempt. The app waits for a finalized MP4 before handing prepared media to the
receiver, so finite videos have a finite timeline; loading stays paused.
Progressive HLS remains available with `AIRTHROW_PREPARATION_MODE=progressive-hls`
in the app's launch environment, but a receiver may treat its growing EVENT
playlist as live. These are conservative limits, not receiver compatibility
guarantees.

### Supported sources and failure handling

- Direct HTTP/HTTPS video supported by AVFoundation and the receiver; MP4 and HLS
  are the initial formats. Local MP4/MOV use in-place LAN delivery. Remote and
  local MKV/WebM enter preparation; compatible H.264/AAC tracks can be remuxed,
  and supported incompatible tracks require conversion. Other extensions get one
  native attempt; the extension alone does not establish compatibility. Native
  loading does not prove receiver playback.
- Direct sources need their own audio track or HLS audio rendition; the app warns
  about detected video-only sources. There is no manual two-URL input.
- Live streams use a native H.264/AAC presentation when available. Compatible
  separate tracks can be remuxed into a rolling local HLS playlist. Live
  conversion remains unsupported.
- Audio-only AirPlay speakers cannot display video; the TV owns volume.
- Apple TV Remote integration uses public Now Playing and remote-command APIs;
  actual receiver behaviour needs hardware testing.

Stop and URL replacement cancel extraction/preparation, stop the session media
server, and remove temporary media. A source reported unavailable during initial
website loading gets one re-resolution attempt; established playback is never
automatically restarted. Unclassified player failures remain `load_failed` or
`playback_interrupted`; status messages omit underlying URLs and request details.

### Network delivery

Prepared media is served on the Mac's active Wi-Fi/Ethernet IPv4 address and an
ephemeral port, through a random session URL. Allow AirThrow through the macOS
firewall/local-network prompt if shown; network changes may require loading
again. Multi-interface setups can set `AIRTHROW_MEDIA_HOST` to the
receiver-reachable IPv4 address (never `127.0.0.1` for a receiver). Prepared
files are removed on Stop, replacement, failure, and Quit; abandoned preparation
files are cleaned on the next launch. The app stores no media history or pairing
credentials of its own; media URLs and local paths stay in memory and are omitted
from status and errors.

Run the source-choice controller regressions sequentially with the other AVPlayer suites:

```bash
python3 scripts/source-choice-checks.py
```

The suite uses synthetic local fixtures and injected candidates to verify automatic selection, explicit reloads, stale IDs, queue navigation, captured load preferences, missing or ambiguous refreshed candidates, direct-load gating, privacy, and stale resolver completion. Fallback regressions verify that an explicit choice retains its presentation while Automatic can choose the best remux, with bounded preparation attempts. Identity intentionally includes exact format metadata: metadata jitter invalidates an explicit choice rather than guessing between potentially different presentations. URL/header rotation alone does not invalidate identity. It does not exercise a live website or receiver.

Settings checks use synthetic cookie probes to verify serialized reads, coalesced preference changes, and rejection of stale results. They do not read browser data:

```bash
swiftc -swift-version 6 -parse-as-library Sources/AirThrowCore/*.swift Sources/AirThrowApp/MediaDiagnostics.swift Sources/AirThrowApp/PlaybackController.swift Sources/AirThrowApp/SettingsView.swift Tests/SettingsChecks/main.swift -o .build/SettingsChecks
.build/SettingsChecks
```

## Core checks

```bash
swift build --disable-sandbox
.build/debug/CoreChecks
```

These checks use a plain Swift executable and work with Command Line Tools. Python 3 is needed for integration checks and project generation, not by the app at runtime.

Core checks exercise the CLI's production argument parser without launching or controlling an app, including source/conversion commands, JSON flags, invalid arguments, local paths, and seek values.

## App and controller checks

Build and launch the app first. Stop existing playback before running integration checks, which change the active session and leave it idle. Use fresh output filenames when generating fixtures:

```bash
swift scripts/make-test-video.swift /tmp/athrow-test.mp4
swift scripts/add-test-audio.swift /tmp/athrow-test.mp4 /tmp/athrow-test-audio.mp4
python3 scripts/integration-checks.py build/athrow /tmp/athrow-test.mp4 /tmp/athrow-test-audio.mp4
```

To serve fixtures without controlling the app, append `--serve`. The server binds to loopback and implements byte ranges needed for reliable loading. In another terminal, use the printed port for focused controller checks:

```bash
swiftc -swift-version 6 -parse-as-library Sources/AirThrowCore/*.swift Sources/AirThrowApp/MediaDiagnostics.swift Sources/AirThrowApp/PlaybackController.swift Tests/ControllerChecks/main.swift -o .build/ControllerChecks
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

For manual receiver checks, append `--serve --bind YOUR_MAC_LAN_IP` to keep the generated fixtures available on that interface. Load the printed server URL plus the fixture's `path` from `fixtures.json` in AirThrow. The default interface is loopback, which a receiver cannot access. Stop the fixture server with Ctrl-C; keep it running during the receiver test. Record receiver model/firmware and actual results separately before claiming format support.

## Website resolver checks

Deterministic checks use fake helper executables and metadata; no installed yt-dlp, external site, or receiver is needed:

```bash
swiftc -swift-version 6 -parse-as-library Sources/AirThrowCore/Protocol.swift Sources/AirThrowCore/MediaSelection.swift Sources/AirThrowCore/SourceResolver.swift Sources/AirThrowCore/HelperProcess.swift Sources/AirThrowCore/YouTubeCookies.swift Tests/ResolverChecks/main.swift -o .build/ResolverChecks
.build/ResolverChecks
```

They cover direct bypass, exact website hosts, single-video playlist-context removal, bounded flat-playlist extraction, ordering, unavailable entries, Mix acceptance, live entries, missing helpers, combined-stream selection, unknown codecs, custom headers, DRM and upcoming rejection, native-live selection, malformed output, output limits, timeout, and cancellation of child processes. The native media matrix also checks resolver Stop/replacement and exactly one retry for a source-unavailable error, with all loads paused.

Resolver checks also cover HLS master selection before remuxing, alternate-audio groups, malformed/missing audio references, unsupported codecs, custom-header exclusion, cancellation, and fallback after fetch failure. Master inspection tries at most two distinct URLs, each with an eight-second resource deadline and 1 MiB body limit, using an ephemeral session without cookies or stored credentials. Only a master advertising an H.264/AAC variant and valid HTTP(S) rendition references is eligible; AVPlayer selects and loads the actual renditions. The native matrix includes a separate-audio HLS fixture and exercises HTTP errors, advertised/unadvertised oversized bodies, and cancellation. Receiver audio, seeking and adaptive variant changes still need physical testing.

Playlist controller checks use injected deterministic metadata and media URLs. They verify that the first playable item stays paused, unavailable entries are skipped, navigation resolves items lazily, and Stop clears the queue. Physical receiver acceptance still needs normal-end automatic advancement, Previous/Next while playing and paused, route loss, replacement during preparation, and a public playlist containing both direct and remuxed entries.

Inspected HLS masters retain positive video evidence through source selection. Direct streaming assets that expose no local video tracks receive the same bounded manifest/segment inspection during loading, regardless of their URL extension. A ready item on an active AirPlay route may expose no local video tracks or presentation size; this evidence lets the controller finish loading without waiting for those observations. Resolver and native-media checks ensure validated presentations retain it and invalid or audio-only presentations do not invent it. Status diagnostics expose item/player readiness, transport state, and video confirmation to distinguish this gate from network buffering.

For an optional metadata-only live smoke check, install `yt-dlp` and `deno`, record their `--version` output, and run:

```bash
.build/ResolverChecks --resolve 'https://www.youtube.com/watch?v=VIDEO_ID'
```

This uses the same resolver as the app and prints a redacted result. Live-site results may change independently of AirThrow. Validate UI and CLI loading and receiver picture/sound separately. The result distinguishes a combined source from separate tracks selected for preparation. It is metadata-only and is not a playback pass.

The subprocess runs in its own process group with a 40-second deadline, 8 MiB JSON limit, and 256 KiB discarded stderr limit. Stop/replacement kills the group and reaps the helper. Arguments disable user configuration, plugins, cache, and remote component installation. When YouTube cookies are configured, AirThrow reads the browser store or the supplied cookies file itself, keeps only `youtube.com`/`youtu.be`/`youtube-nocookie.com` records, writes them to a private `0600` temporary Netscape file, and passes that file to yt-dlp; the scratch directory is removed once the helper exits. No other site's cookies are imported, and cookie values never enter status, logs, or identifiers. JavaScript/EJS support must already be installed. Default yt-dlp browser headers are retained in memory; direct playback does not forward them, while FFmpeg/ffprobe receive them for separate HTTP tracks. Other headers remain ineligible. Even candidates with only default headers can fail if a site requires them at fetch time.

## Preparation and HTTP delivery checks

With Homebrew FFmpeg installed, run:

```bash
python3 scripts/preparation-checks.py
```

This generates original short fixtures, remuxes MKV, joins separate MP4/M4A tracks, and compares compressed packet hashes to prove copied tracks are unchanged. Conversion cases cover H.264/FLAC audio conversion, opt-in VP9/Opus video conversion, output profile bounds, and HDR refusal. It verifies GET/HEAD, byte ranges and invalid ranges, exact session routes, server closure, missing helpers, unsupported tracks, limits, cancellation, abandoned-file cleanup, preservation of active sessions, and controller fallback/replacement. Each run writes a report and fixtures under ignored `build/preparation-*`. Run this suite sequentially with the AVPlayer-based native/controller checks.

The same suite also uses a paced 20-second fixture to check HLS readiness before producer completion, growing playlists, segment GET/HEAD/ranges, finite ENDLIST, unchanged decoded video frames, native paused loading, finite timeline/seek bounds, startup fallback, post-handoff producer failure, and Stop/quit cleanup. This exercises local HTTP delivery and AVPlayer; receiver playback remains untested.

Run `python3 scripts/live-remux-checks.py` for a separate paced live-remux fixture. It serves HLS video and audio inputs locally, verifies readiness before source completion, a six-segment sliding playlist, native AVFoundation readability, natural stream end, server shutdown, and copied H.264/AAC output. This is local validation; receiver playback remains untested.

The preparation suite also checks local-file parsing, symlink resolution, zero-copy MP4 delivery, source preservation after Stop, path privacy, MKV remuxing, replacement cleanup, and packet identity. Local delivery uses the selected file in place; tests must never place a disposable fixture over a user-owned path.

The app defaults to finalized MP4 preparation so finite videos are not presented as live on the receiver. The experimental progressive path can be tested with `MediaPreparer.prepare(_:mode: .progressiveHLS)` or `AIRTHROW_PREPARATION_MODE=progressive-hls`. It uses FFmpeg’s [HLS EVENT muxer and `temp_file` flag](https://ffmpeg.org/ffmpeg-formats.html#hls-2). Two seconds is a segment target; stream copy cuts at source keyframes. Startup requires at least three complete segments covering six seconds and production averaging at least real time, or validated completion for short media. A 30-second startup deadline falls back once to MP4 before returning a URL. After handoff, a producer failure ends the session rather than advancing a playlist. Stop closes delivery and cancels the process group, keeping the workspace lease until the helper is reaped; Quit awaits this cleanup.

For a bounded live website check, the generated `PreparationChecks` binary also accepts `--website URL`. It resolves, prepares when required, checks native audio/video tracks, and removes its temporary result. This downloads the selected media; use a short public test clip. It does not verify receiver playback.

Preparation probes actual streams and maps one video and one audio stream. Compatible tracks are copied independently; supported incompatible audio is encoded to AAC, and incompatible SDR video is encoded only under `.allowVideo`. Video conversion is bounded to known SDR inputs through 3840×2160 at 120 fps, with output no larger than 1920×1080 at 60 fps. Hardware H.264 is capability-tested before use, with a bounded software fallback before handoff. No encoder restart occurs after handoff. HDR/Dolby Vision, unknown unsafe color metadata, protected media, and missing audio/video are rejected. Native direct playback retains its broader capabilities.

Finite inputs are restricted to HTTP(S) or local MP4/M4A and Matroska/WebM demuxing. Live remux also accepts HTTP(S) HLS video and audio playlists. Only locally generated segments permit MPEG-TS probing for converted-output validation. Output metadata/chapters/extra tracks are omitted. The complete-file path uses a 2 GiB output limit and final size/duration checks. Progressive HLS reserves headroom below the same cap during the source-size pre-check because MPEG-TS packetization inflates the remux, then monitors aggregate temporary size (including unfinished segments) every 250 ms, so brief overshoot is possible, and validates final playlist duration and ENDLIST after FFmpeg succeeds. ffprobe has a bounded inspection deadline, finite FFmpeg jobs have ten minutes per attempt, and network reads have a 15-second inactivity limit. Finite preparation requires a duration of at most four hours. Live remux uses a six-segment playlist with three retained older segments, a 512 MiB workspace cap and a 60-second output-progress deadline. AAC-LC output is limited to stereo/48 kHz, with disk headroom required. The finite path remains full-source preparation; the live path evicts old segments.

Session directories under the user’s temporary directory hold lease locks. Stop/replacement/failure closes the listener and detaches the player item before releasing files; startup removes unlocked abandoned directories. The HTTP server binds a selected local IPv4 address, allows up to eight clients, bounds headers and idle time, and serves only session media through an unguessable URL prefix. HLS routes allow the media playlist and generated segment names; temporary files, leases, traversal, and unrelated files are not served. Playlists and segments are published by atomic rename, and each response reads and measures the same open file descriptor. It supports single byte ranges and uses `Connection: close`; multiple ranges are rejected. There is no directory browser, general proxy, or upstream HLS rewriting. `AIRTHROW_MEDIA_HOST=127.0.0.1` is reserved for local automated checks; receiver tests need a LAN address.

Hardware acceptance remains separate: verify prepared-file picture/sound/sync, seeking, receiver controls, firewall permission, replacement, route loss, and network changes on Apple TV, then a second receiver. Local loading and packet identity alone do not establish AirPlay compatibility.

## Packaging

`bash scripts/build.sh` uses an ad-hoc signature for local testing. Set `AIRTHROW_BUILD_DIR` to build elsewhere while preserving an existing bundle. Only one app session runs at a time. Regenerate the Xcode project using `python3 scripts/generate-xcode-project.py`; verify Xcode builds separately when full Xcode is available.

For distribution, supply `CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'` to the build script. This enables hardened runtime and timestamping; notarization (`notarytool`) and stapling are separate release steps. The app is not App Sandbox-enabled. Its command endpoint is a private per-user Unix socket, not a TCP listener.

Prefer extracting the packaged ZIP to an unsynced application directory: cloud-sync metadata on a loose app can interfere with strict signature verification. Do not commit build output, signing credentials, or local editor state.

The standard About AirThrow panel shows the build’s short Git commit. Packaging and Xcode builds stamp it into `BuildCommit.txt` before signing; `-dirty` indicates uncommitted changes (including untracked, non-ignored files). Builds from a source export without Git metadata display `unknown`. Plain `swift build` does not package this resource; use the packaging script or Xcode for the About metadata.

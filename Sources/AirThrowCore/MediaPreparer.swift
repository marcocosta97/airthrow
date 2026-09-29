import Foundation
import AVFoundation
import Darwin

// Container duration may include an unselected subtitle or data track that
// outlasts the video. Keep completion validation strict for short clips, with
// at most two seconds of tolerance for longer sources.
private func completionTolerance(for duration: Double) -> Double {
    max(0.5, min(2, duration * 0.05))
}

public enum PreparationFailure: Error, Sendable, Equatable {
    case unavailable, unsupported, videoConversionRequired(height: Int?, frameRate: Double?), conversionWouldDownscale, failed, limit, delivery
    public var reason: MediaFailureReason {
        switch self {
        case .unavailable: .preparerUnavailable
        case .unsupported, .videoConversionRequired, .conversionWouldDownscale: .preparationRequired
        case .failed: .preparationFailed
        case .limit: .preparationLimit
        case .delivery: .deliveryUnavailable
        }
    }
}

/// Held for the lifetime of the prepared AVPlayer item. Stopping closes delivery before deleting media.
@MainActor
public final class PreparedMedia {
    public let url: URL
    /// Known finite source duration, even while an EVENT playlist is growing.
    public let sourceDuration: Double?
    /// The tier actually used to produce this media: `.direct` for in-place
    /// local delivery, otherwise the inspected remux/audio/video conversion.
    public let playbackPath: PlaybackPath
    /// Prepared video height observed by ffprobe, or source height for a copy.
    public private(set) var videoHeight: Int?
    public private(set) var videoFrameRate: Double?
    public private(set) var productionFailure: PreparationFailure?
    public private(set) var isProducing = false
    public var onFailure: (@MainActor (PreparationFailure) -> Void)?
    private var producer: Task<Void, Never>?
    private let server: MediaHTTPServer
    private var workspace: PreparationWorkspace?
    fileprivate init(server: MediaHTTPServer, workspace: PreparationWorkspace? = nil,
                     sourceDuration: Double? = nil, playbackPath: PlaybackPath = .remux,
                     videoHeight: Int? = nil, videoFrameRate: Double? = nil) {
        self.server = server; self.workspace = workspace; self.sourceDuration = sourceDuration
        self.playbackPath = playbackPath
        self.videoHeight = videoHeight; self.videoFrameRate = videoFrameRate
        url = server.url!
    }

    fileprivate func produce(executable: String, arguments: [String], workspace: PreparationWorkspace,
                             maximumBytes: Int64, timeout: Duration, duration: Double) {
        isProducing = true
        producer = Task { [weak self] in
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                                 reason: "Preparing AirPlay video")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            // The job owns a lease until the process group is terminated and reaped.
            // Stop may release the player/server earlier, but cannot delete a writer's directory.
            do {
                _ = try await HelperProcess.run(executable: executable, arguments: arguments,
                    timeout: timeout, outputLimit: 64 * 1024, monitor: {
                        try workspace.checkSize(maximumBytes)
                    })
                try workspace.checkSize(maximumBytes)
                let playlist = try HLSPlaylist(directory: workspace.directory)
                guard playlist.complete, playlist.duration >= duration - completionTolerance(for: duration),
                      playlist.duration <= duration + 2 else { throw PreparationFailure.failed }
            } catch is CancellationError {
                // Cancellation belongs to Stop/replacement, not a playback error.
            } catch {
                let failure = (error as? PreparationFailure)
                    ?? ((error as? ResolutionFailure) == .timedOut ? .limit : .failed)
                self?.productionFailure = failure
                self?.onFailure?(failure)
            }
            self?.isProducing = false
        }
    }

    fileprivate func produceLive(executable: String, arguments: [String], workspace: PreparationWorkspace,
                                 maximumBytes: Int64, videoConversion: Bool) {
        workspace.startLiveProgress()
        isProducing = true
        producer = Task { [weak self] in
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                                 reason: "Preparing AirPlay live video")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                _ = try await HelperProcess.run(executable: executable, arguments: arguments,
                    timeout: nil, outputLimit: 64 * 1024, monitor: {
                        try workspace.checkSize(maximumBytes)
                        try workspace.checkLiveProgress(videoConversion: videoConversion)
                    })
                let playlist = try HLSPlaylist(directory: workspace.directory)
                guard playlist.complete else { throw PreparationFailure.failed }
            } catch is CancellationError {
            } catch {
                let failure = (error as? PreparationFailure) ?? .failed
                self?.productionFailure = failure
                self?.onFailure?(failure)
            }
            self?.isProducing = false
        }
    }

    public func waitForProducer() async { await producer?.value }
    deinit { producer?.cancel() }
    /// Replaces the planned height and rate with the observed output once a
    /// converted segment has been probed. Live and progressive jobs share this
    /// so they report the same output quality as the complete-file path.
    fileprivate func recordInspectedVideo(height: Int?, frameRate: Double?) {
        if let height { videoHeight = height }
        if let frameRate { videoFrameRate = frameRate }
    }
    /// Halt conversion during a player-item handoff while keeping its delivery
    /// server alive until AVPlayer has received the replacement item.
    public func cancelProduction() { producer?.cancel() }
    public func stop() {
        onFailure = nil
        server.stop()
        cancelProduction()
        workspace = nil
    }
}

/// An advisory lease prevents startup cleanup from deleting another active session's files.
private final class PreparationWorkspace: @unchecked Sendable {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("athrow-prepared-v1", isDirectory: true)
    let directory: URL
    private let lease: Int32
    private let progressLock = NSLock()
    private var liveStarted = Date()
    private var lastProgress = Date()
    private var publishedEndSequence: Int?
    private var publishedSeconds = 0.0
    init() throws {
        Self.cleanAbandoned()
        directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        lease = open(directory.appendingPathComponent("lease").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lease >= 0, flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            if lease >= 0 { close(lease) }
            try? FileManager.default.removeItem(at: directory)
            throw PreparationFailure.failed
        }
    }
    deinit {
        try? FileManager.default.removeItem(at: directory)
        close(lease)
    }
    func checkSize(_ maximumBytes: Int64) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        var bytes: Int64 = 0
        for file in files {
            // Atomic renames may remove a .tmp between enumeration and stat.
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize { bytes += Int64(size) }
        }
        guard bytes < maximumBytes else { throw PreparationFailure.limit }
        let space = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let free = (space[.systemFreeSize] as? NSNumber)?.int64Value,
              free > 64 * 1024 * 1024 else { throw PreparationFailure.limit }
    }

    func startLiveProgress() {
        progressLock.withLock {
            liveStarted = Date()
            lastProgress = liveStarted
            publishedEndSequence = nil
            publishedSeconds = 0
        }
    }

    func checkLiveProgress(videoConversion: Bool) throws {
        let playlist = try? HLSPlaylist(directory: directory)
        let behind = progressLock.withLock { () -> Bool in
            let now = Date()
            if let playlist {
                let end = playlist.mediaSequence + playlist.count
                if let previous = publishedEndSequence {
                    if end > previous {
                        let missed = max(0, playlist.mediaSequence - previous)
                        publishedSeconds += Double(missed) * playlist.duration / Double(playlist.count)
                        publishedSeconds += playlist.segmentDurations.enumerated()
                            .filter { playlist.mediaSequence + $0.offset >= previous }
                            .reduce(0) { $0 + $1.element }
                        publishedEndSequence = end
                        lastProgress = now
                    }
                } else {
                    publishedSeconds = playlist.duration
                    publishedEndSequence = end
                    lastProgress = now
                }
            }
            let elapsed = now.timeIntervalSince(liveStarted)
            return now.timeIntervalSince(lastProgress) > 60
                || (videoConversion && elapsed > 12 && elapsed - publishedSeconds > 10)
        }
        if behind { throw PreparationFailure.failed }
    }

    static func cleanAbandoned() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
            guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            let fd = open(entry.appendingPathComponent("lease").path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { try? fm.removeItem(at: entry) }
            close(fd)
        }
    }
}

/// Reads only our generated, atomically published media playlist.
private struct HLSPlaylist {
    let duration: Double
    let count: Int
    let complete: Bool
    let mediaSequence: Int
    let segmentDurations: [Double]
    /// Completed segment names in playlist order. The first entry is safe to
    /// probe: `-hls_flags temp_file` only publishes atomically renamed files.
    let segments: [String]
    init(directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("media.m3u8"))
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#EXTM3U") else { throw PreparationFailure.failed }
        let lines = text.split(separator: "\n").map(String.init)
        let durations = lines.filter { $0.hasPrefix("#EXTINF:") }.compactMap {
            $0.dropFirst(8).split(separator: ",").first.flatMap { Double($0) }
        }
        let names = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty }
        guard !names.isEmpty, names.count == durations.count,
              durations.allSatisfy({ $0.isFinite && $0 > 0 }),
              names.allSatisfy({ name in
                  MediaHTTPServer.isSegmentName(name)
                      && ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size]
                           as? NSNumber)?.int64Value ?? 0) > 0
              }) else { throw PreparationFailure.failed }
        let sequence = lines.first(where: { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") })
            .flatMap { Int($0.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) } ?? 0
        guard sequence >= 0 else { throw PreparationFailure.failed }
        duration = durations.reduce(0, +)
        count = names.count
        mediaSequence = sequence
        segmentDurations = durations
        segments = names
        complete = lines.contains("#EXT-X-ENDLIST")
    }
}

public enum PreparationMode: Sendable {
    case progressiveHLS, completeFile
}

public struct MediaPreparer: Sendable {
    private let environment: [String: String]
    private let maximumBytes: Int64
    private let timeout: Duration
    private let startupTimeout: Duration
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment; maximumBytes = 2 * 1024 * 1024 * 1024; timeout = .seconds(600); startupTimeout = .seconds(30)
    }
    init(environment: [String: String], maximumBytes: Int64, timeout: Duration = .seconds(600),
         startupTimeout: Duration = .seconds(30)) {
        self.environment = environment; self.maximumBytes = maximumBytes; self.timeout = timeout; self.startupTimeout = startupTimeout
    }
    public static func cleanAbandonedFiles() { PreparationWorkspace.cleanAbandoned() }

    /// Inspects actual tracks, copies compatible ones, and converts only what is
    /// required. `onPlan` publishes the inspected path before any processing, so
    /// a control surface can label a job that has not produced media yet.
    public func prepare(_ source: ResolvedSource, mode: PreparationMode? = nil,
                        onPlan: (@Sendable (PlaybackPath) async -> Void)? = nil) async throws -> PreparedMedia {
        // A growing EVENT playlist is presented as live by AirPlay receivers,
        // even when its source duration is known. Hand off a finalized VOD file
        // for finite media so receiver seeking and host controls remain usable.
        var mode = source.enhancement == .original
            ? (mode ?? (environment["AIRTHROW_PREPARATION_MODE"] == "progressive-hls" ? .progressiveHLS : .completeFile))
            : .completeFile
        try Task.checkCancellation()
        guard source.enhancement == .original || !source.isLive else { throw PreparationFailure.unsupported }
        // Resolve a LAN address before downloading. Loopback requires an explicit test override.
        let host = try environment["AIRTHROW_MEDIA_HOST"] ?? MediaHTTPServer.localAddress()
        do {
            if source.url.isFileURL && !source.needsPreparation {
                let file = try MediaInput.localFile(source.url)
                let asset = AVURLAsset(url: file)
                let loadedDuration = try? await asset.load(.duration)
                let duration = loadedDuration.flatMap { $0.seconds.isFinite && $0.seconds > 0 ? $0.seconds : nil }
                if let duration, duration > 4 * 60 * 60 { throw PreparationFailure.limit }
                await onPlan?(.direct)
                let server = try await MediaHTTPServer.start(file: file, host: host)
                do { try Task.checkCancellation() }
                catch { await server.stop(); throw error }
                return await PreparedMedia(server: server, sourceDuration: duration, playbackPath: .direct)
            }
            let finder = HelperExecutables(environment: environment)
            guard let ffmpeg = finder.executable("ffmpeg", override: "AIRTHROW_FFMPEG"),
                  let ffprobe = finder.executable("ffprobe", override: "AIRTHROW_FFPROBE") else {
                throw PreparationFailure.unavailable
            }
            let videoInput = try await probe(source.url, headers: source.headers, executable: ffprobe,
                                             hls: source.delivery == .hls)
            let audioInput: Probe
            if let audio = source.audio {
                audioInput = try await probe(audio.url, headers: audio.headers, executable: ffprobe,
                                              hls: source.delivery == .hls)
            } else { audioInput = videoInput }
            // Keep text subtitles as soft tracks in finite MP4 delivery. MPEG-TS
            // EVENT output cannot carry these tracks as selectable renditions,
            // so a finite request that has them uses the complete-file path.
            let subtitleInputs: [(input: Int, stream: Stream)] =
                videoInput.streams.filter(\.supportedTextSubtitle).prefix(8).map { (0, $0) }
                + (source.audio == nil ? [] : audioInput.streams.filter(\.supportedTextSubtitle)
                    .prefix(8).map { (1, $0) })
            if !source.isLive && !subtitleInputs.isEmpty { mode = .completeFile }
            let subtitleTracks = source.isLive ? [] : Array(subtitleInputs.prefix(8))
            // The inspect step rejects HDR/Dolby Vision, encrypted, attached-picture
            // and unknown tracks, and refuses video conversion unless the source
            // explicitly allows it.
            let plan = try Self.plan(videoInput: videoInput, audioInput: audioInput,
                                     separateAudio: source.audio != nil, policy: source.conversionPolicy,
                                     enhancement: source.enhancement)
            let videoDuration = source.isLive ? nil : try videoInput.finiteDuration
            let audioDuration = source.isLive ? nil : try audioInput.finiteDuration
            if let videoDuration, let audioDuration, abs(videoDuration - audioDuration) > 2 {
                throw PreparationFailure.unsupported
            }
            let videoBytes = Int64(videoInput.format.size ?? "") ?? 0
            let audioBytes = source.audio == nil ? 0 : (Int64(audioInput.format.size ?? "") ?? 0)
            // MPEG-TS packetization and per-segment tables add overhead the source
            // container did not have. Reserve headroom so a source admitted here
            // still fits under the same prepared-media cap during progressive output.
            let sourceLimit = mode == .progressiveHLS ? maximumBytes - maximumBytes / 10 : maximumBytes
            if !source.isLive {
                guard videoBytes >= 0, audioBytes >= 0, videoBytes < sourceLimit, audioBytes < sourceLimit,
                      videoBytes + audioBytes < sourceLimit else { throw PreparationFailure.limit }
            }
            await onPlan?(plan.path)
            let workspace = try PreparationWorkspace()
            let space = try FileManager.default.attributesOfFileSystem(forPath: workspace.directory.path)
            let liveLimit = min(maximumBytes, 512 * 1024 * 1024)
            guard let free = (space[.systemFreeSize] as? NSNumber)?.int64Value,
                  free > (source.isLive ? liveLimit : maximumBytes) + 64 * 1024 * 1024 else {
                throw PreparationFailure.limit
            }
            let output = workspace.directory.appendingPathComponent("media.mp4")
            func conversionArguments(encoder: String) throws -> [String] {
                var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n"]
                    + (try Self.inputArguments(url: source.url, headers: source.headers,
                                               hls: source.delivery == .hls))
                if let audio = source.audio {
                    arguments += try Self.inputArguments(url: audio.url, headers: audio.headers,
                                                         hls: source.delivery == .hls)
                }
                arguments += ["-map", "0:\(plan.video.index)", "-map", "\(plan.audioInput):\(plan.audio.index)"]
                if mode == .completeFile {
                    for subtitle in subtitleTracks {
                        arguments += ["-map", "\(subtitle.input):\(subtitle.stream.index)"]
                    }
                }
                arguments += Self.videoArguments(stream: plan.video, action: plan.videoAction,
                                                 encoder: encoder, enhancement: plan.enhancement)
                    + Self.audioArguments(stream: plan.audio, action: plan.audioAction)
                if mode == .completeFile && !subtitleTracks.isEmpty {
                    arguments += ["-c:s", "mov_text"]
                }
                arguments += ["-map_metadata", "-1", "-map_chapters", "-1", "-dn"]
                if mode == .completeFile {
                    for (index, subtitle) in subtitleTracks.enumerated() {
                        // Suppressing global source metadata also suppresses
                        // automatic language tags. Restore only bounded track
                        // labels so native selection remains meaningful.
                        if let language = subtitle.stream.tags?.language,
                           language.range(of: "^[A-Za-z]{2,3}$", options: .regularExpression) != nil {
                            arguments += ["-metadata:s:s:\(index)", "language=\(language)"]
                        }
                        if let title = subtitle.stream.tags?.title, title.utf8.count <= 100,
                           !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                            arguments += ["-metadata:s:s:\(index)", "title=\(title)"]
                        }
                    }
                }
                return arguments
            }
            // A hardware encoder is selected by a preflight at the real output
            // size, rate and profile. If it still fails before any URL handoff,
            // retry once in software; the item is never restarted after handoff.
            func produce(encoder: String) async throws -> PreparedMedia {
                let arguments = try conversionArguments(encoder: encoder)
                if source.isLive {
                    return try await live(workspace: workspace, arguments: arguments, executable: ffmpeg,
                                          host: host, playbackPath: plan.path, plan: plan,
                                          maximumBytes: liveLimit, ffprobe: ffprobe)
                }
                if mode == .progressiveHLS {
                    do {
                        return try await progressive(workspace: workspace, arguments: arguments, executable: ffmpeg,
                                                     host: host, duration: videoDuration!, playbackPath: plan.path,
                                                     plan: plan, ffprobe: ffprobe)
                    } catch ProgressiveStartup.useCompleteFile {
                        // Do not retry a failed hardware job in a second container.
                        // Switch encoder first; software retains the bounded MP4 fallback.
                        if encoder == "h264_videotoolbox" { throw PreparationFailure.failed }
                        // No URL has reached the player. A bounded startup failure can
                        // safely use the existing complete-file path once.
                        try Task.checkCancellation()
                    }
                }
                // -n never overwrites, so clear a partial output from a prior attempt.
                var attempt = 0
                while true {
                    try? FileManager.default.removeItem(at: output)
                    do {
                        _ = try await HelperProcess.run(executable: ffmpeg,
                                                        arguments: arguments + ["-movflags", "+faststart", "-fs",
                                                                                String(maximumBytes), "-f", "mp4", output.path],
                                                        timeout: timeout, outputLimit: 64 * 1024)
                        break
                    } catch let error as ResolutionFailure {
                        // Retry a transient remote failure, not a rejected source.
                        guard case .failed = error, attempt < 2 else { throw error }
                        attempt += 1
                        try await Task.sleep(for: .milliseconds(600 * attempt))
                    }
                }
                try Task.checkCancellation()
                let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0, size < maximumBytes else { throw PreparationFailure.limit }
                let verified = try await probe(output, headers: [:], executable: ffprobe, local: true)
                try Self.validateConverted(verified, plan: plan)
                let duration = try verified.finiteDuration
                let expectedSubtitles = subtitleTracks.count
                guard verified.streams.count == 2 + expectedSubtitles,
                      verified.streams.contains(where: {
                          $0.codec_type == "video" && (plan.videoAction == .convert || $0.copyableVideo)
                      }),
                      verified.streams.contains(where: { $0.copyableAudio }),
                      verified.streams.filter({ $0.codec_type == "subtitle" }).count == expectedSubtitles,
                      verified.streams.filter({ $0.codec_type == "subtitle" })
                        .allSatisfy({ $0.codec_name == "mov_text" }),
                      duration >= videoDuration! - completionTolerance(for: videoDuration!),
                      duration <= videoDuration! + 2 else { throw PreparationFailure.failed }
                let server = try await MediaHTTPServer.start(file: output, host: host)
                do { try Task.checkCancellation() }
                catch { await server.stop(); throw error }
                return await PreparedMedia(server: server, workspace: workspace, playbackPath: plan.path,
                                           videoHeight: verified.streams.first(where: { $0.codec_type == "video" })?.height,
                                           videoFrameRate: verified.streams.first(where: { $0.codec_type == "video" })?.frameRate)
            }
            let encoder = plan.videoAction == .convert
                ? try await Self.selectEncoder(stream: plan.video, enhancement: plan.enhancement, executable: ffmpeg)
                : "copy"
            do {
                return try await produce(encoder: encoder)
            } catch {
                guard encoder.hasSuffix("_videotoolbox"), Self.retryableHardwareFailure(error) else { throw error }
                try Task.checkCancellation()
                return try await produce(encoder: plan.enhancement.targetHeight == 2160 ? "libx265" : "libx264")
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as PreparationFailure { throw error }
        catch ResolutionFailure.timedOut { throw PreparationFailure.limit }
        catch { throw PreparationFailure.failed }
    }

    private enum ProgressiveStartup: Error { case useCompleteFile }

    @MainActor
    private func live(workspace: PreparationWorkspace, arguments: [String], executable: String,
                      host: String, playbackPath: PlaybackPath, plan: PreparationPlan,
                      maximumBytes: Int64, ffprobe: String) async throws -> PreparedMedia {
        let playlist = workspace.directory.appendingPathComponent("media.m3u8")
        let arguments = arguments + ["-f", "hls", "-hls_segment_type", "mpegts", "-hls_time", "2",
            "-hls_list_size", "6", "-hls_delete_threshold", "3",
            "-hls_flags", "delete_segments+temp_file",
            "-hls_segment_filename", workspace.directory.appendingPathComponent("segment%06d.ts").path,
            playlist.path]
        let server = try await MediaHTTPServer.start(file: playlist, host: host, hls: true)
        let prepared = PreparedMedia(server: server, workspace: workspace, playbackPath: playbackPath,
                                     videoHeight: plan.video.height, videoFrameRate: plan.video.frameRate)
        prepared.produceLive(executable: executable, arguments: arguments, workspace: workspace,
                             maximumBytes: maximumBytes, videoConversion: plan.videoAction == .convert)
        let started = ContinuousClock.now
        do {
            while true {
                try Task.checkCancellation()
                if let failure = prepared.productionFailure { throw failure }
                if let manifest = try? HLSPlaylist(directory: workspace.directory),
                   (manifest.count >= 3 && manifest.duration >= 6)
                    || (manifest.complete && manifest.count > 0) {
                    let elapsed = started.duration(to: .now)
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    if plan.videoAction == .convert && !manifest.complete && seconds - manifest.duration > 4 {
                        throw PreparationFailure.failed
                    }
                    if plan.videoAction == .convert || plan.audioAction == .convert {
                        guard let segment = manifest.segments.last else { throw PreparationFailure.failed }
                        let probed = try await probe(workspace.directory.appendingPathComponent(segment),
                                                     headers: [:], executable: ffprobe, local: true, mpegts: true)
                        try Self.validateConverted(probed, plan: plan)
                        if plan.videoAction == .convert {
                            let video = probed.streams.first(where: { $0.codec_type == "video" })
                            prepared.recordInspectedVideo(height: video?.height, frameRate: video?.frameRate)
                        }
                    }
                    try Task.checkCancellation()
                    if let failure = prepared.productionFailure { throw failure }
                    return prepared
                }
                guard prepared.isProducing, started.duration(to: .now) < startupTimeout else {
                    throw PreparationFailure.failed
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            prepared.stop()
            await prepared.waitForProducer()
            if error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    @MainActor
    private func progressive(workspace: PreparationWorkspace, arguments: [String], executable: String,
                             host: String, duration: Double, playbackPath: PlaybackPath,
                             plan: PreparationPlan, ffprobe: String) async throws -> PreparedMedia {
        let playlist = workspace.directory.appendingPathComponent("media.m3u8")
        let arguments = arguments + ["-f", "hls", "-hls_segment_type", "mpegts", "-hls_time", "2",
            "-hls_playlist_type", "event", "-hls_list_size", "0", "-hls_flags", "temp_file",
            "-hls_segment_filename", workspace.directory.appendingPathComponent("segment%06d.ts").path,
            playlist.path]
        let server = try await MediaHTTPServer.start(file: playlist, host: host, hls: true)
        let prepared = PreparedMedia(server: server, workspace: workspace, sourceDuration: duration,
                                     playbackPath: playbackPath, videoHeight: plan.video.height,
                                     videoFrameRate: plan.video.frameRate)
        prepared.produce(executable: executable, arguments: arguments, workspace: workspace,
                         maximumBytes: maximumBytes, timeout: timeout, duration: duration)
        let started = ContinuousClock.now
        do {
            while true {
                try Task.checkCancellation()
                if let failure = prepared.productionFailure { throw failure }
                if let manifest = try? HLSPlaylist(directory: workspace.directory) {
                    let elapsed = started.duration(to: .now)
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    if !prepared.isProducing || (manifest.count >= 3 && manifest.duration >= 6 && manifest.duration >= seconds) {
                        // Converted tracks are verified against the first completed
                        // segment before the URL is handed off. A copy remux reuses
                        // source packets and is validated by the caller's fixtures.
                        if plan.videoAction == .convert || plan.audioAction == .convert {
                            guard let segment = manifest.segments.first else { throw PreparationFailure.failed }
                            let probed = try await probe(workspace.directory.appendingPathComponent(segment),
                                                         headers: [:], executable: ffprobe, local: true, mpegts: true)
                            try Self.validateConverted(probed, plan: plan)
                            if plan.videoAction == .convert {
                                let video = probed.streams.first(where: { $0.codec_type == "video" })
                                prepared.recordInspectedVideo(height: video?.height, frameRate: video?.frameRate)
                            }
                        }
                        try Task.checkCancellation()
                        if let failure = prepared.productionFailure { throw failure }
                        return prepared
                    }
                }
                guard prepared.isProducing, started.duration(to: .now) < startupTimeout else {
                    throw ProgressiveStartup.useCompleteFile
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            prepared.stop()
            await prepared.waitForProducer()
            // The caller still holds the lease. Remove partial HLS before an MP4 fallback.
            for file in try FileManager.default.contentsOfDirectory(at: workspace.directory, includingPropertiesForKeys: nil)
                where file.lastPathComponent != "lease" {
                try FileManager.default.removeItem(at: file)
            }
            if error is CancellationError { throw CancellationError() }
            if case PreparationFailure.limit = error { throw PreparationFailure.limit }
            throw ProgressiveStartup.useCompleteFile
        }
    }

    private enum TrackAction { case copy, convert }

    private struct PreparationPlan {
        let video: Stream
        let audio: Stream
        let audioInput: Int
        let videoAction: TrackAction
        let audioAction: TrackAction
        let enhancement: VideoEnhancement
        var path: PlaybackPath {
            if videoAction == .convert { return .videoConversion }
            if audioAction == .convert { return .audioConversion }
            return .remux
        }
    }

    /// Chooses the copied tracks first and only falls back to encoding what is
    /// missing. Video encoding requires an explicit `.allowVideo` policy.
    private static func plan(videoInput: Probe, audioInput: Probe, separateAudio: Bool,
                             policy: ConversionPolicy, enhancement: VideoEnhancement) throws -> PreparationPlan {
        let video = videoInput.streams.first(where: { $0.copyableVideo })
            ?? videoInput.streams.first(where: { $0.convertibleVideo })
        guard let video else { throw PreparationFailure.unsupported }
        let audio = audioInput.streams.first(where: { $0.copyableAudio })
            ?? audioInput.streams.first(where: { $0.convertibleAudio })
        guard let audio else { throw PreparationFailure.unsupported }
        let videoAction: TrackAction = enhancement == .original && video.copyableVideo ? .copy : .convert
        guard videoAction == .copy || policy == .allowVideo else {
            throw PreparationFailure.videoConversionRequired(height: video.height, frameRate: video.frameRate)
        }
        if videoAction == .convert {
            guard video.convertibleVideo else { throw PreparationFailure.unsupported }
            let maxWidth = enhancement.targetHeight == 2160 ? 3840 : 1920
            let maxHeight = enhancement.targetHeight == 2160 ? 2160 : 1080
            // The scale filter preserves aspect ratio inside this output box.
            // If either source dimension exceeds the box, it would shrink the
            // picture. Odd dimensions can also lose a pixel when made even.
            guard let width = video.width, let height = video.height,
                  width <= maxWidth, height <= maxHeight,
                  width.isMultiple(of: 2), height.isMultiple(of: 2) else {
                throw PreparationFailure.conversionWouldDownscale
            }
        }
        return PreparationPlan(video: video, audio: audio, audioInput: separateAudio ? 1 : 0,
                               videoAction: videoAction, audioAction: audio.copyableAudio ? .copy : .convert,
                               enhancement: enhancement)
    }

    /// Bounded SDR output shared by the preflight and real job. Automatic
    /// conversion stays at or below 1080p H.264; explicit presets target 1080p
    /// H.264 or 4K HEVC. All cap frame rate at 60 and use a two-second GOP.
    private static func videoArguments(stream: Stream, action: TrackAction, encoder: String,
                                       enhancement: VideoEnhancement) -> [String] {
        guard action == .convert else {
            return stream.codec_name == "hevc" ? ["-c:v", "copy", "-tag:v", "hvc1"] : ["-c:v", "copy"]
        }
        let fourK = enhancement.targetHeight == 2160
        let bitrate = fourK ? "14000k" : "4000k"
        let buffer = fourK ? "28000k" : "8000k"
        var arguments = ["-c:v", encoder, "-pix_fmt", "yuv420p", "-profile:v", fourK ? "main" : "high",
                         "-b:v", bitrate, "-maxrate", bitrate, "-bufsize", buffer,
                         "-color_range", "tv", "-g", "120", "-keyint_min", "120", "-sc_threshold", "0",
                         "-force_key_frames", "expr:gte(t,n_forced*2)",
                         "-vf", Self.scaleFilter(for: stream, enhancement: enhancement)]
        if fourK { arguments += ["-tag:v", "hvc1"] }
        else { arguments += ["-level:v", "4.2"] }
        arguments += encoder.hasSuffix("_videotoolbox") ? ["-allow_sw", "0"] : ["-preset", "veryfast"]
        return arguments
    }

    private static func scaleFilter(for stream: Stream, enhancement: VideoEnhancement) -> String {
        let dimensions = enhancement.targetHeight == 2160 ? "w=3840:h=2160"
            : enhancement == .original ? "w='min(1920,iw)':h='min(1080,ih)'" : "w=1920:h=1080"
        var filter = ""
        if enhancement.cleansUp { filter = "hqdn3d=1.5:1.5:4:4,deband=1thr=0.02:2thr=0.02:3thr=0.02," }
        filter += "scale=\(dimensions):flags=lanczos:force_original_aspect_ratio=decrease:force_divisible_by=2"
        // Full-range VP9 can otherwise retain a yuvj420p output despite
        // -pix_fmt yuv420p. Normalize it to the bounded SDR output range.
        if stream.color_range == "pc" { filter += ":in_range=full:out_range=tv" }
        if let fps = stream.frameRate, fps > 60 { filter += ",fps=60" }
        return filter
    }

    private static func audioArguments(stream: Stream, action: TrackAction) -> [String] {
        guard action == .convert else { return ["-c:a", "copy"] }
        let channels = min(max(stream.channels ?? 2, 1), 2)
        return ["-c:a", "aac", "-ar", "48000", "-ac", String(channels), "-b:a", "160k"]
    }

    /// Chooses a video encoder before any media is produced. Hardware must pass
    /// a preflight at the real bounded output size, rate and profile with
    /// `-allow_sw 0`; software is only used if it can encode that same output.
    /// Cancellation during a preflight propagates instead of being swallowed.
    private static func selectEncoder(stream: Stream, enhancement: VideoEnhancement,
                                      executable: String) async throws -> String {
        let encoders = enhancement.targetHeight == 2160
            ? ["hevc_videotoolbox", "libx265"] : ["h264_videotoolbox", "libx264"]
        for encoder in encoders {
            if try await canEncode(stream: stream, enhancement: enhancement,
                                   encoder: encoder, executable: executable) {
                return encoder
            }
        }
        throw PreparationFailure.failed
    }

    private static func canEncode(stream: Stream, enhancement: VideoEnhancement,
                                  encoder: String, executable: String) async throws -> Bool {
        do {
            _ = try await HelperProcess.run(executable: executable,
                                            arguments: Self.encoderPreflightArguments(stream: stream,
                                                enhancement: enhancement, encoder: encoder),
                                            timeout: .seconds(30), outputLimit: 4096)
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    private static func encoderPreflightArguments(stream: Stream, enhancement: VideoEnhancement,
                                                  encoder: String) -> [String] {
        let width = max(2, min(3840, stream.width ?? 1920))
        let height = max(2, min(2160, stream.height ?? 1080))
        let rate = min(60, max(1, stream.frameRate ?? 30))
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi",
                         "-i", "color=c=black:s=\(width)x\(height):r=\(rate):d=0.1",
                         "-frames:v", "1"]
        arguments += Self.videoArguments(stream: stream, action: .convert,
                                         encoder: encoder, enhancement: enhancement)
        arguments += ["-f", "null", "-"]
        return arguments
    }

    /// A hardware encode that fails before handoff may retry once in software.
    /// Limits, cancellation and delivery errors are not retried.
    private static func retryableHardwareFailure(_ error: Error) -> Bool {
        if let failure = error as? PreparationFailure {
            if case .failed = failure { return true }
            return false
        }
        if case ResolutionFailure.failed = error { return true }
        return false
    }

    /// Verifies the first completed converted segment against the bounded H.264
    /// profile. Applied only to locally generated MPEG-TS, never to a source.
    private static func validateConverted(_ probe: Probe, plan: PreparationPlan) throws {
        guard let video = probe.streams.first(where: { $0.codec_type == "video" }) else {
            throw PreparationFailure.failed
        }
        if plan.videoAction == .convert {
            let fourK = plan.enhancement.targetHeight == 2160
            let maxWidth = fourK ? 3840 : 1920
            let maxHeight = fourK ? 2160 : 1080
            let expectedCodec = fourK ? "hevc" : "h264"
            let expectedProfile = fourK ? "main" : "high"
            guard video.codec_name == expectedCodec, video.pix_fmt == "yuv420p",
                  (video.profile ?? "").localizedCaseInsensitiveContains(expectedProfile),
                  video.color_range != "pc", !video.isHDR,
                  (1...maxWidth).contains(video.width ?? 0),
                  (1...maxHeight).contains(video.height ?? 0),
                  (plan.enhancement == .original
                   ? (video.width ?? 0) <= min(maxWidth, plan.video.width ?? maxWidth)
                   : (video.width == maxWidth || video.height == maxHeight)),
                  (plan.enhancement == .original
                   ? (video.height ?? 0) <= min(maxHeight, plan.video.height ?? maxHeight)
                   : true),
                  let fps = video.frameRate, fps.isFinite, fps > 0, fps <= 60.5 else {
                throw PreparationFailure.failed
            }
            guard let inputWidth = plan.video.width, let inputHeight = plan.video.height,
                  (video.width ?? 0) >= inputWidth, (video.height ?? 0) >= inputHeight else {
                throw PreparationFailure.conversionWouldDownscale
            }
        } else {
            // Video is copied: it must still match the inspected source stream.
            guard video.codec_name == plan.video.codec_name else { throw PreparationFailure.failed }
        }
        guard let audio = probe.streams.first(where: { $0.codec_type == "audio" }) else {
            throw PreparationFailure.failed
        }
        if plan.audioAction == .convert {
            guard audio.codec_name == "aac", (1...2).contains(audio.channels ?? 0),
                  let rate = Int(audio.sample_rate ?? ""), (1...48000).contains(rate) else {
                throw PreparationFailure.failed
            }
        } else {
            guard audio.codec_name == plan.audio.codec_name else { throw PreparationFailure.failed }
        }
    }

    private static func inputOptions(headers: [String: String], hls: Bool = false) throws -> [String] {
        var options = ["-protocol_whitelist", "http,https,tcp,tls,crypto", "-format_whitelist",
                       hls ? "hls,mov,mpegts,aac,matroska,webm,mpeg" : "mov,matroska,webm,mpeg",
                       "-rw_timeout", "15000000", "-probesize", "5000000", "-analyzeduration", "5000000"]
        guard headers.count <= 8, headers.allSatisfy({ key, value in
            ["user-agent", "accept", "accept-language", "sec-fetch-mode"].contains(key.lowercased())
                && value.utf8.count <= 4096 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }) else { throw PreparationFailure.unsupported }
        if !headers.isEmpty {
            options += ["-headers", headers.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)\r\n" }.joined()]
        }
        return options
    }

    private static func inputArguments(url: URL, headers: [String: String], hls: Bool = false) throws -> [String] {
        if url.isFileURL {
            guard headers.isEmpty else { throw PreparationFailure.unsupported }
            _ = try MediaInput.localFile(url)
            return ["-protocol_whitelist", "file", "-format_whitelist", "mov,matroska,webm,mpeg",
                    "-probesize", "5000000", "-analyzeduration", "5000000", "-i", url.path]
        }
        return try inputOptions(headers: headers, hls: hls) + ["-i", url.absoluteString]
    }

    private func probe(_ url: URL, headers: [String: String], executable: String, local: Bool = false,
                       mpegts: Bool = false, hls: Bool = false) async throws -> Probe {
        let isLocal = local || url.isFileURL
        if isLocal { _ = try MediaInput.localFile(url) }
        else { _ = try MediaInput.url(url.absoluteString) }
        // `mpegts` is scoped to our own generated, local segments only. It never
        // broadens the source input whitelist.
        let options: [String]
        if mpegts {
            options = ["-protocol_whitelist", "file", "-f", "mpegts"]
        } else if isLocal {
            options = ["-protocol_whitelist", "file", "-format_whitelist", "mov,matroska,webm,mpeg"]
        } else {
            options = try Self.inputOptions(headers: headers, hls: hls)
        }
        let arguments = ["-v", "error"] + options + ["-show_entries",
            "format=duration,size:stream=index,codec_type,codec_name,codec_tag_string,pix_fmt,width,height,profile,channels,sample_rate,color_range,color_transfer,color_primaries,color_space,avg_frame_rate,r_frame_rate:stream_disposition=attached_pic:stream_side_data:stream_tags=language,title",
            "-of", "json", "-i", isLocal ? url.path : url.absoluteString]
        let data = try await runProbe(executable: executable, arguments: arguments,
                                      timeout: .seconds(mpegts ? 8 : 40), retry: !isLocal)
        return try JSONDecoder().decode(Probe.self, from: data)
    }

    /// A remote media URL can answer with a transient 403 (throttling or a
    /// flagged address) before succeeding on a fresh connection. Retry only
    /// immediate failures on remote inputs; local files and our own segments
    /// never retry.
    private func runProbe(executable: String, arguments: [String], timeout: Duration,
                          retry: Bool) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await HelperProcess.run(executable: executable, arguments: arguments, timeout: timeout)
            } catch let error as ResolutionFailure {
                guard retry, case .failed = error, attempt < 2 else { throw error }
                attempt += 1
                try await Task.sleep(for: .milliseconds(600 * attempt))
            }
        }
    }

    private struct Probe: Decodable {
        let streams: [Stream]
        let format: Format
        struct Format: Decodable { let duration: String?; let size: String? }
        var finiteDuration: Double {
            get throws {
                guard let duration = Double(format.duration ?? ""), duration.isFinite, duration > 0 else { throw PreparationFailure.unsupported }
                guard duration <= 4 * 60 * 60 else { throw PreparationFailure.limit }
                return duration
            }
        }
    }
    private struct Stream: Decodable {
        let index: Int
        let codec_type: String?
        let codec_name: String?
        let codec_tag_string: String?
        let pix_fmt: String?
        let width: Int?
        let height: Int?
        let profile: String?
        let channels: Int?
        let sample_rate: String?
        let color_transfer: String?
        let color_range: String?
        let color_primaries: String?
        let color_space: String?
        let avg_frame_rate: String?
        let r_frame_rate: String?
        let disposition: Disposition?
        let side_data_list: [SideData]?
        let tags: Tags?
        struct Tags: Decodable { let language: String?; let title: String? }
        var supportedTextSubtitle: Bool {
            codec_type == "subtitle" && ["mov_text", "subrip", "webvtt", "ass", "ssa", "text"]
                .contains(codec_name ?? "")
        }
        struct Disposition: Decodable { let attached_pic: Int? }
        struct SideData: Decodable { let side_data_type: String? }
        var frameRate: Double? {
            for value in [avg_frame_rate, r_frame_rate] {
                let parts = (value ?? "").split(separator: "/").compactMap { Double($0) }
                if parts.count == 2, parts[1] > 0, parts[0] > 0 { return parts[0] / parts[1] }
            }
            return nil
        }
        private var encrypted: Bool { codec_tag_string == "encv" || codec_tag_string == "enca" }
        private var attachedPicture: Bool { disposition?.attached_pic == 1 }
        /// A conservative HDR/Dolby Vision signal from transfer, primaries, tags
        /// and side data. SDR output is required for the tested H.264 profile.
        var isHDR: Bool {
            if ["smpte2084", "arib-std-b67"].contains((color_transfer ?? "").lowercased()) { return true }
            if (color_primaries ?? "").lowercased() == "bt2020" { return true }
            if let tag = codec_tag_string?.lowercased(), ["dvhe", "dvh1", "dav1", "dvav"].contains(tag) { return true }
            return (side_data_list ?? []).contains { item in
                let type = (item.side_data_type ?? "").lowercased()
                return type.contains("dovi") || type.contains("dolby vision")
                    || type.contains("mastering display") || type.contains("content light level")
                    || type.contains("hdr dynamic metadata")
            }
        }
        var copyableVideo: Bool {
            guard let fps = frameRate, fps.isFinite, fps > 0 else { return false }
            let supportedProfile = (codec_name == "h264"
                && ["Constrained Baseline", "Baseline", "Main", "High"].contains(profile ?? ""))
                || (codec_name == "hevc" && profile == "Main")
            return codec_type == "video" && supportedProfile && !encrypted
                && ["yuv420p", "yuvj420p"].contains(pix_fmt ?? "")
                && (1...3840).contains(width ?? 0) && (1...2160).contains(height ?? 0)
                && !isHDR && !attachedPicture && understoodSDR && fps <= 60
        }
        /// A known 8-bit SDR pixel layout. Anything outside this set (including
        /// 10-bit and exotic layouts) is not understood for our 4:2:0 output.
        private static let sdrPixelFormats: Set<String> = [
            "yuv420p", "yuvj420p", "yuv422p", "yuvj422p", "yuv444p", "yuvj444p",
            "nv12", "nv21", "yuv410p", "yuv411p", "gray", "gray8", "monow", "monob",
            "rgb24", "bgr24", "argb", "rgba", "abgr", "bgra", "pal8"
        ]
        /// Known SDR transfer characteristics. An absent tag is accepted only
        /// for the 8-bit layouts above; every other value is refused rather than
        /// guessed, so unknown or HDR metadata cannot reach the encoder.
        private static let sdrTransfers: Set<String> = [
            "bt709", "smpte170m", "smpte240m", "gamma22", "gamma28", "iec61966-2-1"
        ]
        private var understoodSDR: Bool {
            guard Self.sdrPixelFormats.contains((pix_fmt ?? "").lowercased()) else { return false }
            let transfer = (color_transfer ?? "").lowercased()
            // An absent or explicitly unknown tag is common and acceptable for a
            // known 8-bit layout; any other unlisted transfer is not guessed at.
            if transfer.isEmpty || transfer == "unknown" || transfer == "unspecified" { return true }
            return Self.sdrTransfers.contains(transfer)
        }
        /// A known, unencrypted, attached-picture-free SDR video stream that our
        /// bounded H.264 output can represent. Kept deliberately conservative.
        var convertibleVideo: Bool {
            guard codec_type == "video", !encrypted, !attachedPicture, !isHDR,
                  understoodSDR,
                  let name = codec_name?.lowercased(),
                  Self.convertibleVideoCodecs.contains(name),
                  let fps = frameRate, fps.isFinite, fps > 0, fps <= 120,
                  (1...3840).contains(width ?? 0), (1...2160).contains(height ?? 0) else { return false }
            return true
        }
        var copyableAudio: Bool {
            codec_type == "audio" && codec_name == "aac" && !encrypted && profile == "LC"
                && (1...2).contains(channels ?? 0) && (1...48000).contains(Int(sample_rate ?? "") ?? 0)
        }
        /// A known, decodable audio codec with bounded channels and rate. The
        /// output is downmixed to AAC stereo at 48 kHz.
        var convertibleAudio: Bool {
            guard codec_type == "audio", !encrypted,
                  let name = codec_name?.lowercased(),
                  Self.convertibleAudioCodecs.contains(name),
                  (1...8).contains(channels ?? 0),
                  let rate = Int(sample_rate ?? ""), (8000...192000).contains(rate) else { return false }
            return true
        }
        private static let convertibleVideoCodecs: Set<String> = [
            "h264", "hevc", "vp9", "vp8", "av1", "mpeg4", "mpeg2video", "mpeg1video", "prores", "mjpeg", "theora", "wmv3", "vc1"
        ]
        private static let convertibleAudioCodecs: Set<String> = [
            "aac", "flac", "opus", "vorbis", "mp3", "mp2", "ac3", "eac3", "alac",
            "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f64le",
            "pcm_u8", "pcm_s16be", "pcm_s24be", "pcm_mulaw", "pcm_alaw",
            "pcm_s16le_planar", "pcm_s24le_planar", "pcm_f32le_planar"
        ]
    }
}

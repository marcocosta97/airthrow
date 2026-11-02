import Foundation
import AVFoundation
import Darwin

// Container duration may include an unselected subtitle or data track that
// outlasts the video. Keep completion validation strict for short clips, with
// at most two seconds of tolerance for longer sources.
private func completionTolerance(for duration: Double) -> Double {
    max(0.5, min(2, duration * 0.05))
}

/// A non-final chunk must match the requested length. The final chunk may be
/// shorter: container duration can include an audio tail, and ffmpeg stops at
/// the video.
enum ChunkOutputCheck {
    static func accepts(produced: Double, requested: Double, final: Bool, leadingPictureAllowance: Double = 0.15) -> Bool {
        guard produced.isFinite, requested.isFinite, produced > 0, requested > 0,
              produced <= requested + leadingPictureAllowance else { return false }
        if final { return true }
        return requested - produced < leadingPictureAllowance
    }
}

/// Plain VideoToolbox conversions keep frames on the media engine. Cleanup,
/// full-range video, and frame rates above 60 stay on the software filters.
enum HardwareDecode {
    static func enabled(encoder: String, enhancement: VideoEnhancement, frameRate: Double?, colorRange: String?) -> Bool {
        guard encoder.hasSuffix("_videotoolbox"), !enhancement.cleansUp,
              colorRange != "pc", let frameRate, frameRate.isFinite, frameRate > 0, frameRate <= 60 else { return false }
        return true
    }
}

/// Even output size for `scale_vt`, which has no aspect or divisible-by option.
/// The box matches the software scale: fit inside it, and do not enlarge an
/// original beyond its own frame.
enum HardwareScale {
    static func outputSize(width: Int, height: Int, enhancement: VideoEnhancement) -> (width: Int, height: Int) {
        let boxWidth: Int
        let boxHeight: Int
        switch enhancement {
        case .upscale4K, .cleanup4K: boxWidth = 3840; boxHeight = 2160
        case .original: boxWidth = min(1920, max(width, 2)); boxHeight = min(1080, max(height, 2))
        case .upscale1080, .cleanup1080: boxWidth = 1920; boxHeight = 1080
        }
        guard width > 0, height > 0 else { return (2, 2) }
        let scale = min(Double(boxWidth) / Double(width), Double(boxHeight) / Double(height))
        var outWidth = Int((Double(width) * scale).rounded(.towardZero))
        var outHeight = Int((Double(height) * scale).rounded(.towardZero))
        if outWidth % 2 != 0 { outWidth -= 1 }
        if outHeight % 2 != 0 { outHeight -= 1 }
        return (max(2, outWidth), max(2, outHeight))
    }
}

/// A deterministic codec error returns immediately and would fail the same way
/// on every retry. A dropped connection also returns immediately; allow two
/// more attempts only for that quick case, never for a failure that already
/// used a large part of the helper timeout.
enum RemoteFailureRetry {
    static func allows(error: Error, elapsed: Duration, attempt: Int) -> Bool {
        guard case ResolutionFailure.failed = error, attempt < 2 else { return false }
        return elapsed < .seconds(5)
    }
}

public enum PreparationFailure: Error, Sendable, Equatable {
    case unavailable, unsupported, videoConversionRequired(height: Int?, frameRate: Double?), conversionWouldDownscale, failed, limit, storageLimit, diskSpace, stalled, delivery
    public var reason: MediaFailureReason {
        switch self {
        case .unavailable: .preparerUnavailable
        case .unsupported, .videoConversionRequired, .conversionWouldDownscale: .preparationRequired
        case .failed: .preparationFailed
        case .limit: .preparationLimit
        case .storageLimit: .preparationStorageLimit
        case .diskSpace: .preparationDiskSpace
        case .stalled: .preparationStalled
        case .delivery: .deliveryUnavailable
        }
    }
}

/// Per-load trace propagated through the existing async preparation scope.
public final class PreparationDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var began = ContinuousClock.now
    private var value = PreparationDiagnostics()
    public init() {}
    public var snapshot: PreparationDiagnostics {
        lock.lock(); defer { lock.unlock() }
        var result = value
        if result.errorCode == nil && result.stage != .ready { result.phaseSeconds = began.duration(to: .now).timeInterval }
        return result
    }
    public func update(_ change: (inout PreparationDiagnostics) -> Void) {
        lock.lock(); defer { lock.unlock() }; change(&value)
    }
    public func mark(_ stage: PreparationDiagnostics.Stage) {
        lock.lock(); defer { lock.unlock() }
        began = .now
        value.stage = stage; value.phaseSeconds = 0
        value.errorCode = nil; value.failureReason = nil; value.helperExitCode = nil; value.helperFailure = nil
    }
    public func failed(_ error: Error) {
        update {
            if $0.errorCode == nil { $0.phaseSeconds = began.duration(to: .now).timeInterval }
            $0.errorCode = (error as NSError).code
            $0.failureReason = (error as? PreparationFailure)?.reason ?? (error as? ResolutionFailure)?.reason
        }
    }
}
public enum PreparationTrace {
    @TaskLocal public static var current: PreparationDiagnosticRecorder?
    static func mark(_ stage: PreparationDiagnostics.Stage) { current?.mark(stage) }
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
    fileprivate var liveInputIsTransportStream: Bool?
    public var onFailure: (@MainActor (PreparationFailure) -> Void)?
    public var onReadyRangesChanged: (@MainActor () -> Void)?
    private var progressNotification: Task<Void, Never>?
    private var sequentialPacing = PreparationPacing()
    private var sequentialSample: (seconds: Double, time: ContinuousClock.Instant)?
    private var producer: Task<Void, Never>?
    /// Memoized ready range for the non-cached progressive playlist. The
    /// playlist is re-parsed only when the file changes, so the periodic status
    /// refresh does not stat every segment for the lifetime of the item.
    private var cachedPlaylistRanges: (size: Int, modified: Date, ranges: [SeekRange])?
    private let server: MediaHTTPServer
    private var workspace: PreparationWorkspace?
    private var cache: CachedHLS?
    private var drainingCache: CachedHLS?
    /// Loopback relays standing in for secret origin URLs. Helpers only see these.
    private var upstream: PreparationUpstream?
    private var nativeInput: NativeInputPrefetch?
    private var drainingNativeInput: NativeInputPrefetch?
    private var nativeMetrics: NativeVideoMetrics?
    public var nativeProcessingDiagnostics: NativeVideoDiagnostics? { nativeMetrics?.snapshot }
    /// Model chosen for this enhancement, when preparation walked the ranking.
    public let resolvedUpscaler: VideoUpscaler?
    /// Higher-ranked model skipped because it cannot process this video.
    public let upscalerFellBackFrom: VideoUpscaler?
    fileprivate init(server: MediaHTTPServer, workspace: PreparationWorkspace? = nil,
                     sourceDuration: Double? = nil, playbackPath: PlaybackPath = .remux,
                     videoHeight: Int? = nil, videoFrameRate: Double? = nil) {
        self.server = server; self.workspace = workspace; self.sourceDuration = sourceDuration
        self.playbackPath = playbackPath
        self.videoHeight = videoHeight; self.videoFrameRate = videoFrameRate
        self.upstream = PreparationPrivacy.upstream
        let selection = PreparationPrivacy.upscalerResolution?.selection
        resolvedUpscaler = selection?.backend
        upscalerFellBackFrom = selection?.fellBackFrom
        url = server.url!
    }

    /// The preparing task owns the relays until this item does. Init also reads
    /// the task value; this covers a hop where that value is no longer visible.
    fileprivate func retain(_ upstream: PreparationUpstream) {
        if self.upstream == nil { self.upstream = upstream }
    }

    fileprivate func retain(_ input: NativeInputPrefetch, metrics: NativeVideoMetrics) {
        nativeInput = input; nativeMetrics = metrics
    }

    fileprivate func produce(executable: String, arguments: [String], workspace: PreparationWorkspace,
                             maximumBytes: Int64, timeout: Duration, duration: Double) {
        isProducing = true
        sequentialSample = (0, .now)
        let progress: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.notifyReadyRangesChanged() }
        }
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
                        progress()
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
            self?.notifyReadyRangesChanged()
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

    public func waitForProducer() async {
        await producer?.value
        if let drainingCache {
            await drainingCache.waitForJobs()
            self.drainingCache = nil
        } else { await cache?.waitForJobs() }
        await drainingNativeInput?.wait(); drainingNativeInput = nil
    }
    public var liveDiagnostics: LivePipelineDiagnostics {
        var result = LivePipelineDiagnostics()
        result.producerActive = isProducing && productionFailure == nil
        result.producerFailure = productionFailure?.reason
        result.inputIsTransportStream = liveInputIsTransportStream
        if let workspace, let playlist = try? HLSPlaylist(directory: workspace.directory) {
            result.playlistComplete = playlist.complete
            result.playlistSegments = playlist.count
            result.playlistSequence = playlist.mediaSequence
            result.playlistSeconds = playlist.duration
        }
        return result
    }
    public var usesBoundedCache: Bool { cache != nil }
    public func prepareSeek(at seconds: Double) async throws { try await cache?.prepareSeek(at: seconds) }
    public var preparationSpeed: Double? {
        guard isProducing else { return nil }
        return cache?.pacing.speed ?? sequentialPacing.speed
    }
    public var readyRanges: [SeekRange]? {
        if let cache { return cache.readyRanges }
        guard let duration = sourceDuration, duration.isFinite, duration > 0 else { return nil }
        if url.pathExtension == "m3u8" {
            guard let workspace else { return [] }
            let playlistURL = workspace.directory.appendingPathComponent("media.m3u8")
            let attributes = try? FileManager.default.attributesOfItem(atPath: playlistURL.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast
            if let cached = cachedPlaylistRanges, cached.size == size, cached.modified == modified {
                return cached.ranges
            }
            guard let playlist = try? HLSPlaylist(directory: workspace.directory) else { return [] }
            let ranges = [SeekRange(start: 0, end: min(duration, playlist.duration))]
            cachedPlaylistRanges = (size, modified, ranges)
            return ranges
        }
        return [SeekRange(start: 0, end: duration)]
    }
    private func notifyReadyRangesChanged() {
        if let sample = sequentialSample, let end = readyRanges?.last?.end, end > sample.seconds {
            let now = ContinuousClock.now
            sequentialPacing.record(mediaSeconds: end - sample.seconds,
                                    elapsedSeconds: sample.time.duration(to: now).timeInterval, bytes: 0)
            sequentialSample = (end, now)
        }
        guard onReadyRangesChanged != nil, progressNotification == nil else { return }
        progressNotification = Task { [weak self] in
            guard let self else { return }
            self.progressNotification = nil
            self.onReadyRangesChanged?()
        }
    }
    public func updatePlaybackPosition(_ seconds: Double, playing: Bool = false) { cache?.updatePosition(seconds, playing: playing) }
    fileprivate func installCache(_ cache: CachedHLS) {
        self.cache = cache
        cache.onActivity = { [weak self] active in self?.isProducing = active }
        cache.onFailure = { [weak self] failure in
            self?.productionFailure = failure
            self?.onFailure?(failure)
        }
        cache.onReadyRangesChanged = { [weak self] in self?.notifyReadyRangesChanged() }
    }
    deinit { producer?.cancel(); nativeInput?.stop() }
    /// Replaces the planned height and rate with the observed output once a
    /// converted segment has been probed. Live and progressive jobs share this
    /// so they report the same output quality as the complete-file path.
    fileprivate func recordInspectedVideo(height: Int?, frameRate: Double?) {
        if let height { videoHeight = height }
        if let frameRate { videoFrameRate = frameRate }
    }
    /// Halt conversion during a player-item handoff while keeping its delivery
    /// server alive until AVPlayer has received the replacement item.
    public func cancelProduction() { producer?.cancel(); cache?.cancelProduction() }
    public func stop() {
        onFailure = nil
        onReadyRangesChanged = nil
        progressNotification?.cancel(); progressNotification = nil
        nativeInput?.stop(); drainingNativeInput = nativeInput ?? drainingNativeInput; nativeInput = nil
        upstream?.stop()
        server.stop()
        cancelProduction()
        cache?.stop()
        drainingCache = cache ?? drainingCache
        cache = nil
        workspace = nil
    }

    /// Stop this attempt's output while leaving the shared input relay running.
    /// A later fallback in the same prepare still reads that relay.
    fileprivate func discardAttempt() {
        upstream = nil
        stop()
    }
}

/// Remembers file sizes and only walks the workspace when a directory changes.
/// Between those changes the growing output file is the only one restatted.
private final class WorkspaceBytes: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private var sizes: [String: Int64] = [:]
    private var directoryStamps: [String: Date] = [:]
    private var total: Int64 = 0
    private var hot: String?
    init(root: URL) { self.root = root }

    func totalBytes() throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if !directoryStamps.isEmpty, !directoriesChanged() {
            if let hot, let size = Self.fileSize(hot) {
                total += size - (sizes[hot] ?? 0)
                sizes[hot] = size
            }
            return total
        }
        try rescan()
        return total
    }

    private func directoriesChanged() -> Bool {
        directoryStamps.contains { path, stamp in Self.modificationDate(path) != stamp }
    }

    private func rescan() throws {
        var next: [String: Int64] = [:]
        var stamps: [String: Date] = [:]
        var newest: (String, Date)?
        stamps[root.path] = Self.modificationDate(root.path) ?? .distantPast
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]) else {
            sizes = [:]; directoryStamps = stamps; total = 0; hot = nil
            return
        }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        while let file = files.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true {
                stamps[file.path] = values.contentModificationDate ?? .distantPast
                continue
            }
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            next[file.path] = Int64(size)
            if let modified = values.contentModificationDate, newest == nil || modified > newest!.1 {
                newest = (file.path, modified)
            }
        }
        sizes = next
        directoryStamps = stamps
        total = next.values.reduce(0, +)
        hot = newest?.0
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }
    private static func fileSize(_ path: String) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value
    }
}

/// A downloaded source shares the preparation lease and crash recovery lifecycle.
@MainActor public final class TemporaryMediaDownload {
    public let url: URL
    private var workspace: PreparationWorkspace?
    public convenience init(filename: String) throws {
        try self.init(filename: filename, root: PreparationWorkspace.root)
    }
    init(filename: String, root: URL) throws {
        let workspace = try PreparationWorkspace(root: root)
        self.workspace = workspace
        url = workspace.directory.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
    }
    public func stop() { workspace = nil }
}

/// An advisory lease prevents startup cleanup from deleting another active session's files.
final class PreparationWorkspace: @unchecked Sendable {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("athrow-prepared-v1", isDirectory: true)
    let directory: URL
    private let lease: Int32
    private let progressLock = NSLock()
    private var liveStarted = Date()
    private var lastProgress = Date()
    private var publishedEndSequence: Int?
    private var publishedSeconds = 0.0
    private let bytes: WorkspaceBytes
    init(root: URL = PreparationWorkspace.root) throws {
        Self.cleanAbandoned(root: root)
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        bytes = WorkspaceBytes(root: directory)
        lease = open(directory.appendingPathComponent("lease").path,
                     O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lease >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw PreparationFailure.failed
        }
    }
    deinit {
        try? FileManager.default.removeItem(at: directory)
        close(lease)
    }
    static func size(of directory: URL) throws -> Int64 {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var bytes: Int64 = 0
        while let file = files?.nextObject() as? URL {
            // Atomic renames may remove a .tmp between enumeration and stat.
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true, let size = values.fileSize { bytes += Int64(size) }
        }
        return bytes
    }
    /// Clears partial output before a fallback while the lease stays held.
    func removeGeneratedFiles() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent != "lease" { try? FileManager.default.removeItem(at: file) }
    }
    func checkSize(_ maximumBytes: Int64) throws {
        let used = try bytes.totalBytes()
        guard used < maximumBytes else { throw PreparationFailure.storageLimit }
        let space = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let free = (space[.systemFreeSize] as? NSNumber)?.int64Value,
              free > 64 * 1024 * 1024 else { throw PreparationFailure.diskSpace }
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

    static func cleanAbandoned(root: URL = PreparationWorkspace.root) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey]) else { return }
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil {
            guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            let fd = open(entry.appendingPathComponent("lease").path, O_RDWR | O_NOFOLLOW)
            if fd < 0 {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if Date().timeIntervalSince(modified) > 60 { try? fm.removeItem(at: entry) }
                continue
            }
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
    init(directory: URL, name: String = "media.m3u8", initialization: String = "init.mp4",
         followMaster: Bool = true) throws {
        var playlistName = name
        var mapName = initialization
        var data = try Data(contentsOf: directory.appendingPathComponent(playlistName))
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#EXTM3U") else { throw PreparationFailure.failed }
        var lines = text.split(separator: "\n").map(String.init)
        // A Dolby copy publishes a master playlist under this name and keeps
        // the video media playlist at stream_0.m3u8. Readiness follows the video.
        if followMaster, lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }),
           !lines.contains(where: { $0.hasPrefix("#EXTINF:") }) {
            guard lines.contains("stream_0.m3u8") else { throw PreparationFailure.failed }
            playlistName = "stream_0.m3u8"
            mapName = "init0.mp4"
            data = try Data(contentsOf: directory.appendingPathComponent(playlistName))
            guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
                  text.hasPrefix("#EXTM3U") else { throw PreparationFailure.failed }
            lines = text.split(separator: "\n").map(String.init)
        }
        let durations = lines.filter { $0.hasPrefix("#EXTINF:") }.compactMap {
            $0.dropFirst(8).split(separator: ",").first.flatMap { Double($0) }
        }
        let names = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty }
        func isNonEmptyFile(_ name: String) -> Bool {
            let path = directory.appendingPathComponent(name).path
            return ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0) > 0
        }
        if names.contains(where: { $0.hasSuffix(".m4s") }) {
            guard MediaHTTPServer.isInitName(mapName), lines.contains("#EXT-X-MAP:URI=\"\(mapName)\""),
                  isNonEmptyFile(mapName) else { throw PreparationFailure.failed }
        }
        guard !names.isEmpty, names.count == durations.count,
              durations.allSatisfy({ $0.isFinite && $0 > 0 }),
              names.allSatisfy({ MediaHTTPServer.isSegmentName($0) && isNonEmptyFile($0) })
        else { throw PreparationFailure.failed }
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

/// Keeps secret origin URLs inside this process while ffmpeg and ffprobe read a loopback copy.
@MainActor
final class PreparationUpstream {
    private var relays: [HTTPMediaRelay] = []

    func localized(_ source: ResolvedSource) async throws -> ResolvedSource {
        let url = try await loopback(source.url, headers: source.headers, finite: !source.isLive)
        var audio = source.audio
        if let track = source.audio {
            let audioURL = try await loopback(track.url, headers: track.headers, finite: !source.isLive)
            if audioURL != track.url { audio = MediaTrack(url: audioURL) }
        }
        guard url != source.url || audio?.url != source.audio?.url else { return source }
        let headers = url == source.url ? source.headers : [:]
        return source.withHelperInputs(url: url, headers: headers, audio: audio)
    }

    func stop() {
        for relay in relays { relay.stop() }
        relays.removeAll()
    }

    private func loopback(_ url: URL, headers: [String: String], finite: Bool) async throws -> URL {
        guard !url.isFileURL, finite || MediaURLSecrets.contains(url) else { return url }
        let relay = try await HTTPMediaRelay.start(source: url, host: "127.0.0.1", sourceHeaders: headers,
                                                   readAheadBytes: finite ? 8 * 1024 * 1024 : 256 * 1024)
        guard let local = relay.url else { relay.stop(); throw PreparationFailure.unavailable }
        relays.append(relay)
        try Task.checkCancellation()
        return local
    }
}

private final class UpscalerResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var value: VideoUpscaler.Selection?
    var selection: VideoUpscaler.Selection? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ selection: VideoUpscaler.Selection) {
        lock.lock(); defer { lock.unlock() }
        value = selection
    }
}

private enum PreparationPrivacy {
    @TaskLocal static var upstream: PreparationUpstream?
    @TaskLocal static var upscalerResolution: UpscalerResolution?
}

public struct MediaPreparer: Sendable {
    private let environment: [String: String]
    private let maximumBytes: Int64
    private let timeout: Duration
    private let startupTimeout: Duration
    private let preferences: PreparationPreferences
    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                preferences: PreparationPreferences = PreparationPreferences()) {
        self.environment = environment; self.preferences = preferences
        maximumBytes = preferences.maximumBytes; timeout = .seconds(600); startupTimeout = .seconds(30)
    }
    init(environment: [String: String], maximumBytes: Int64, timeout: Duration = .seconds(600),
         startupTimeout: Duration = .seconds(30)) {
        self.environment = environment; self.maximumBytes = maximumBytes; self.timeout = timeout; self.startupTimeout = startupTimeout
        preferences = PreparationPreferences(maximumBytes: maximumBytes, retainAll: true)
    }
    public static func cleanAbandonedFiles() { PreparationWorkspace.cleanAbandoned() }

    /// Inspects actual tracks, copies compatible ones, and converts only what is
    /// required. `onPlan` publishes the inspected path before any processing, so
    /// a control surface can label a job that has not produced media yet.
    public func prepare(_ source: ResolvedSource, mode: PreparationMode? = nil,
                        onPlan: (@Sendable (PlaybackPath) async -> Void)? = nil) async throws -> PreparedMedia {
        let upstream = PreparationUpstream()
        let resolution = UpscalerResolution()
        do {
            let prepared = try await PreparationPrivacy.$upscalerResolution.withValue(resolution) {
                try await PreparationPrivacy.$upstream.withValue(upstream) {
                    try await self.prepareBody(source, mode: mode, onPlan: onPlan)
                }
            }
            await prepared.retain(upstream)
            PreparationTrace.mark(.ready)
            return prepared
        } catch {
            PreparationTrace.current?.failed(error)
            await upstream.stop()
            throw error
        }
    }

    private func prepareBody(_ source: ResolvedSource, mode: PreparationMode? = nil,
                             onPlan: (@Sendable (PlaybackPath) async -> Void)? = nil) async throws -> PreparedMedia {
        // Publish a small verified buffer, then keep producing on the same
        // session. Explicit complete-file delivery remains available for callers
        // that need the finalized file before handoff.
        var mode = mode ?? (environment["AIRTHROW_PREPARATION_MODE"] == "complete-file" ? .completeFile : .progressiveHLS)
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
            // Native-first links can be playable HLS without an extension or
            // extractor delivery metadata. Let the demuxer inspect unknown
            // network inputs as either a file or HLS; protocol restrictions
            // remain the same for every remote input.
            let allowHLSInput = source.delivery != .file
            var source = source
            if let upstream = PreparationPrivacy.upstream {
                source = try await upstream.localized(source)
            }
            PreparationTrace.current?.update {
                $0.remuxCache = preferences.remuxCache; $0.retainAll = preferences.retainAll
                $0.maximumBytes = preferences.maximumBytes
            }
            PreparationTrace.mark(.sourceProbe)
            let videoInput = try await probe(source.url, headers: source.headers, executable: ffprobe,
                                             hls: allowHLSInput)
            let audioInput: Probe
            if let audio = source.audio {
                PreparationTrace.mark(.audioProbe)
                audioInput = try await probe(audio.url, headers: audio.headers, executable: ffprobe,
                                              hls: allowHLSInput)
            } else { audioInput = videoInput }
            // Complete-file delivery retains native MP4 subtitle tracks. The
            // on-demand path publishes indexed Matroska text as WebVTT renditions.
            let subtitleInputs: [(input: Int, stream: Stream)] =
                videoInput.streams.filter(\.supportedTextSubtitle).prefix(8).map { (0, $0) }
                + (source.audio == nil ? [] : audioInput.streams.filter(\.supportedTextSubtitle)
                    .prefix(8).map { (1, $0) })
            let indexedSubtitleContainers = subtitleInputs.allSatisfy {
                ($0.input == 0 ? videoInput : audioInput).format.format_name == "matroska,webm"
            }
            if !source.isLive && !subtitleInputs.isEmpty
                && (!preferences.remuxCache || preferences.retainAll || !indexedSubtitleContainers) { mode = .completeFile }
            let subtitleTracks = source.isLive ? [] : Array(subtitleInputs.prefix(8))
            let videoForProcessing = videoInput.streams.first(where: { $0.copyableVideo })
                ?? videoInput.streams.first(where: { $0.convertibleVideo })
                ?? videoInput.streams.first(where: { $0.codec_type == "video" && $0.disposition?.attached_pic != 1 })
            PreparationTrace.current?.update {
                $0.videoCodec = videoForProcessing?.codec_name.map { PreparationDiagnostics.Codec(rawValue: $0) ?? .other }
                $0.audioCodec = audioInput.streams.first(where: { $0.codec_type == "audio" })?.codec_name.map { PreparationDiagnostics.Codec(rawValue: $0) ?? .other }
                $0.width = videoForProcessing?.width; $0.height = videoForProcessing?.height
                $0.frameRate = videoForProcessing?.frameRate.flatMap { $0.isFinite ? $0 : nil }
                let pixel = videoForProcessing?.pix_fmt ?? ""
                $0.videoBitDepth = pixel.contains("10") ? 10 : pixel.contains("12") ? 12 : ["yuv420p", "nv12"].contains(pixel) ? 8 : nil
                $0.dolbyVisionProfile = videoForProcessing?.side_data_list?.compactMap(\.dv_profile).first
                let audio = audioInput.streams.first(where: { $0.codec_type == "audio" })
                $0.audioChannels = audio?.channels; $0.audioSampleRate = Int(audio?.sample_rate ?? "")
                if let duration = Double(videoInput.format.duration ?? ""), duration.isFinite, duration > 0 { $0.sourceDuration = duration }
                $0.sourceBytes = Int64(videoInput.format.size ?? ""); $0.subtitleCount = subtitleTracks.count
            }
            PreparationTrace.mark(.planning)
            let noiseReduction: CleanupNoiseReduction
            if preferences.noiseReduction == .automatic {
                if #available(macOS 26, *), videoForProcessing.map(Self.nativeGPUInput) == true, subtitleTracks.isEmpty {
                    noiseReduction = .gpu
                } else { noiseReduction = .ffmpeg }
            } else { noiseReduction = preferences.noiseReduction }
            if source.followsUpscalerRanking, source.enhancement != .original, let target = source.enhancement.targetHeight {
                let selection = try await resolveUpscalerRanking(video: videoForProcessing, targetHeight: target)
                source = source.withEnhancement(source.enhancement, upscaler: selection.backend)
                PreparationPrivacy.upscalerResolution?.set(selection)
            }
            let usesAppleProcessing = source.upscaler.isAI && source.enhancement != .original
                || source.enhancement.cleansUp && noiseReduction != .ffmpeg
            if usesAppleProcessing && (preferences.aiBeforePlayback || !subtitleInputs.isEmpty) { mode = .completeFile }
            // The inspect step copies HDR10/HLG and compatible Dolby Vision Main
            // 10 video unmodified at Original quality; it rejects encrypted,
            // attached-picture and unknown tracks, refuses HDR/Dolby Vision for
            // any re-encode (tone mapping stays out of scope), and otherwise
            // refuses video conversion unless the source explicitly allows it.
            if usesAppleProcessing, let video = videoForProcessing {
                _ = try AppleInputNormalization(stream: video)
            }
            let plan = try Self.plan(videoInput: videoInput, audioInput: audioInput,
                                     separateAudio: source.audio != nil, policy: source.conversionPolicy,
                                     enhancement: source.enhancement, appleProcessing: usesAppleProcessing,
                                     preserveSurround: !usesAppleProcessing)
            PreparationTrace.current?.update { $0.playbackPath = plan.path }
            if plan.videoAction == .convert && !subtitleTracks.isEmpty { mode = .completeFile }
            let videoDuration = source.isLive ? nil : try videoInput.finiteDuration
            let audioDuration = source.isLive ? nil : try audioInput.finiteDuration
            if let videoDuration, let audioDuration, abs(videoDuration - audioDuration) > 2 {
                throw PreparationFailure.unsupported
            }
            // Independently restartable chunks need precise video cut points.
            // Preserve stream-copy policy for remux/audio-only jobs, and retain
            // sequential delivery for HLS inputs or servers without byte ranges.
            var bounded = mode == .progressiveHLS && !source.isLive && !preferences.retainAll
                && plan.videoAction == .convert
                && videoInput.format.format_name != "hls"
                && audioInput.format.format_name != "hls"
            if bounded { bounded = try await Self.supportsRandomAccess(source.url, headers: source.headers) }
            if bounded, let audio = source.audio { bounded = try await Self.supportsRandomAccess(audio.url, headers: audio.headers) }
            var remuxTimeline: RemuxTimeline?
            var remuxIndexFailure: RemuxIndexFailure?
            if mode == .progressiveHLS, !source.isLive, !preferences.retainAll, preferences.remuxCache,
               plan.videoAction == .copy,
               ["h264", "hevc"].contains(plan.video.codec_name ?? ""),
               ["mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm"].contains(videoInput.format.format_name ?? "") {
                do {
                    PreparationTrace.mark(.index)
                    var randomAudio = true
                    if let audio = source.audio { randomAudio = try await Self.supportsRandomAccess(audio.url, headers: audio.headers) }
                    if randomAudio {
                        let localVolume = source.url.isFileURL
                            && (try? source.url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
                        if localVolume {
                            let arguments = ["-v", "error"] + (try Self.inputArguments(url: source.url, headers: [:]))
                                + ["-select_streams", String(plan.video.index), "-show_packets", "-show_entries",
                                   "packet=pts,dts,flags,pos,size", "-of", "compact=p=0"]
                            // Local inspection remains bounded; remote files use
                            // container indexes instead of scanning the media body.
                            let packets = try await HelperProcess.run(executable: ffprobe, arguments: arguments,
                                                                      timeout: .seconds(20), outputLimit: 64 * 1024 * 1024)
                            remuxTimeline = try RemuxTimeline(packets: packets, file: source.url,
                                codec: plan.video.codec_name!, videoTimeBase: plan.video.time_base,
                                audioTimeBase: plan.audio.time_base,
                                sourceStart: Double(videoInput.format.start_time ?? "") ?? 0,
                                duration: videoDuration!, matroska: videoInput.format.format_name == "matroska,webm",
                                reorderDelay: (plan.video.has_b_frames ?? 0) > 0)
                        } else {
                            // Mounted SMB is a file URL too: use its container
                            // index instead of scanning every packet over the NAS.
                            remuxTimeline = try await RemoteRemuxIndex.timeline(url: source.url, headers: source.headers,
                                stream: plan.video.index, codec: plan.video.codec_name!, videoTimeBase: plan.video.time_base,
                                audioTimeBase: plan.audio.time_base, sourceStart: Double(videoInput.format.start_time ?? "") ?? 0,
                                duration: videoDuration!, matroska: videoInput.format.format_name == "matroska,webm",
                                reorderDelay: (plan.video.has_b_frames ?? 0) > 0)
                        }
                        let audioOffset = (Double(videoInput.format.start_time ?? "") ?? 0)
                            - (Double(audioInput.format.start_time ?? "") ?? 0)
                        guard audioOffset.isFinite, abs(audioOffset) < 86_400 else { throw PreparationFailure.unsupported }
                        remuxTimeline?.audioOffset = audioOffset
                    }
                } catch is CancellationError { throw CancellationError() }
                catch let error as URLError {
                    try Task.checkCancellation()
                    throw AppFailure(.playbackFailed, "Could not read the remote media index (network error \(error.code.rawValue)). Check the connection and load the video again.")
                }
                catch let failure as RemuxIndexFailure {
                    try Task.checkCancellation(); remuxIndexFailure = failure; remuxTimeline = nil
                }
                catch { try Task.checkCancellation(); remuxTimeline = nil } // Unsupported indexes retain sequential remux.
            }
            bounded = bounded || remuxTimeline != nil
            if plan.stereoFallback != nil && remuxTimeline == nil { bounded = false }
            if !subtitleTracks.isEmpty && mode == .progressiveHLS && !bounded {
                let reason = remuxIndexFailure?.message ?? "Incremental remux does not support this container's seek layout."
                throw AppFailure(.unsupportedOperation, reason + " No complete-file preparation was started.")
            }
            let videoBytes = Int64(videoInput.format.size ?? "") ?? 0
            let audioBytes = source.audio == nil ? 0 : (Int64(audioInput.format.size ?? "") ?? 0)
            // MPEG-TS packetization and per-segment tables add overhead the source
            // container did not have. Reserve headroom so a source admitted here
            // still fits under the same prepared-media cap during progressive output.
            let sourceLimit = mode == .progressiveHLS ? maximumBytes - maximumBytes / 10 : maximumBytes
            func validateSequentialCopySize() throws {
                if !source.isLive && plan.videoAction == .copy && plan.audioAction == .copy {
                    guard videoBytes >= 0, audioBytes >= 0, videoBytes < sourceLimit, audioBytes < sourceLimit,
                          videoBytes + audioBytes < sourceLimit else { throw PreparationFailure.storageLimit }
                }
            }
            if !bounded { try validateSequentialCopySize() }
            await onPlan?(plan.path)
            let workspace = try PreparationWorkspace()
            let space = try FileManager.default.attributesOfFileSystem(forPath: workspace.directory.path)
            let liveLimit = min(maximumBytes, 512 * 1024 * 1024)
            // A budget is a ceiling, not a reservation of all those bytes.
            // Require working headroom and monitor actual free space thereafter.
            let workingSpace = min(maximumBytes, 64 * 1024 * 1024)
            guard let free = (space[.systemFreeSize] as? NSNumber)?.int64Value,
                  free > workingSpace + 64 * 1024 * 1024 else {
                throw PreparationFailure.diskSpace
            }
            let output = workspace.directory.appendingPathComponent("media.mp4")
            let temporalCleanup = source.enhancement.cleansUp && noiseReduction == .appleTemporal
            if temporalCleanup, let reason = TemporalNoiseFilterSupport.unavailableReason {
                throw AppFailure(.unsupportedOperation, reason)
            }
            if (source.upscaler.isAI && source.enhancement != .original) || (source.enhancement.cleansUp && noiseReduction != .ffmpeg) {
                let normalization = try AppleInputNormalization(stream: plan.video)
                let boxHeight = source.enhancement.targetHeight!
                let boxWidth = boxHeight == 2160 ? 3840 : 1920
                let cleanupOnly = source.enhancement.cleansUp
                    && (normalization.width == boxWidth || normalization.height == boxHeight)
                    && normalization.width <= boxWidth && normalization.height <= boxHeight
                let backend: VideoUpscaler = cleanupOnly ? .lanczos : source.upscaler.isAI ? source.upscaler : .lanczos
                let layout = try await SuperResolutionLayout.make(width: normalization.width, height: normalization.height,
                    targetHeight: boxHeight, backend: backend)
                if backend == .standard, await !SuperResolutionSupport.standardModelReady {
                    throw AppFailure(.unsupportedOperation, "Download the AI Standard model in Settings or Video options before using it.")
                }
                if Self.nativeGPUInput(plan.video), #available(macOS 26, *),
                   !(source.enhancement.cleansUp && noiseReduction == .ffmpeg), subtitleTracks.isEmpty {
                    return try await nativePrepared(workspace: workspace, source: source, plan: plan,
                        layout: layout, ffmpeg: ffmpeg, ffprobe: ffprobe, host: host, duration: videoDuration!,
                        cached: bounded && mode == .progressiveHLS, hlsInput: allowHLSInput, noiseReduction: noiseReduction)
                }
                if source.enhancement.cleansUp && noiseReduction == .gpu {
                    throw AppFailure(.unsupportedOperation, "GPU cleanup needs progressive, square-pixel BT.709 H.264 or HEVC video without text subtitles. Choose FFmpeg cleanup for this source.")
                }
                return try await superResolved(workspace: workspace, source: source, plan: plan,
                    layout: layout, normalization: normalization, ffmpeg: ffmpeg, ffprobe: ffprobe, host: host, duration: videoDuration!,
                    cached: bounded && mode == .progressiveHLS, hlsInput: allowHLSInput,
                    subtitles: subtitleTracks, noiseReduction: noiseReduction)
            }
            func conversionArguments(encoder: String, hardwareFrames: Bool = false,
                                     precise: Bool = false, alignRemux: Bool = false) throws -> [String] {
                let accelerate = hardwareFrames
                var videoInput = try Self.inputArguments(url: source.url, headers: source.headers, hls: allowHLSInput)
                if accelerate, let input = videoInput.lastIndex(of: "-i") {
                    // videotoolbox_vld is the frame format scale_vt and the hardware encoder share.
                    videoInput.insert(contentsOf: ["-hwaccel", "videotoolbox", "-hwaccel_output_format", "videotoolbox_vld"], at: input)
                }
                var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n"] + videoInput
                if let audio = source.audio {
                    if alignRemux, let remuxTimeline { arguments += ["-itsoffset", MediaClock.seconds(remuxTimeline.audioOffset)] }
                    arguments += try Self.inputArguments(url: audio.url, headers: audio.headers,
                                                         hls: allowHLSInput)
                }
                let separateDecodedAudio = alignRemux && remuxTimeline != nil && plan.audioAction == .convert && source.audio == nil
                if separateDecodedAudio {
                    arguments += try Self.inputArguments(url: source.url, headers: source.headers, hls: allowHLSInput)
                }
                arguments += ["-map", "0:\(plan.video.index)"]
                    + (separateDecodedAudio ? ["-map", "1:\(plan.audio.index)"] : Self.audioMaps(plan))
                if mode == .completeFile {
                    for subtitle in subtitleTracks {
                        arguments += ["-map", "\(subtitle.input):\(subtitle.stream.index)"]
                    }
                }
                arguments += Self.videoArguments(stream: plan.video, action: plan.videoAction,
                                                 encoder: encoder, enhancement: plan.enhancement,
                                                 hardwareFrames: accelerate)
                    + Self.audioCodecArguments(plan: plan, action: precise ? .convert : plan.audioAction)
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
                           !title.containsControlCharacters {
                            arguments += ["-metadata:s:s:\(index)", "title=\(title)"]
                        }
                    }
                }
                return arguments
            }
            // Each attempt completes startup before URL handoff. Fallback never
            // replaces an item which is already playing.
            func deliver(encoder: String, hardwareFrames: Bool = false) async throws -> PreparedMedia {
                if bounded {
                    do {
                        return try await cached(workspace: workspace,
                                                arguments: conversionArguments(encoder: encoder, hardwareFrames: hardwareFrames,
                                                    precise: plan.videoAction == .convert, alignRemux: true),
                                                executable: ffmpeg, host: host, duration: videoDuration!,
                                                plan: plan, ffprobe: ffprobe, startPosition: source.preparationPosition,
                                                source: source, subtitles: subtitleTracks,
                                                remuxTimeline: remuxTimeline)
                    } catch {
                        // Retry copy in the original delivery mode only before
                        // handing off a URL. Cancellation/quota/disk failures
                        // retain their specific meaning and never trigger retry.
                        var canFallBack = false
                        if let failure = error as? PreparationFailure {
                            canFallBack = [.failed, .unsupported, .stalled].contains(failure)
                        } else if case ResolutionFailure.failed = error { canFallBack = true }
                        guard remuxTimeline != nil, canFallBack, subtitleTracks.isEmpty, plan.audioAction == .copy, plan.stereoFallback == nil else { throw error }
                        try Task.checkCancellation()
                        try validateSequentialCopySize()
                    }
                }
                let arguments = try conversionArguments(encoder: encoder, hardwareFrames: hardwareFrames)
                if source.isLive {
                    PreparationTrace.mark(.liveMux)
                    return try await live(workspace: workspace, arguments: arguments, executable: ffmpeg,
                                          host: host, playbackPath: plan.path, plan: plan,
                                          maximumBytes: liveLimit, ffprobe: ffprobe,
                                          transportInput: videoInput.format.format_name == "mpegts")
                }
                if mode == .progressiveHLS {
                    do {
                        PreparationTrace.mark(.progressiveMux)
                        return try await progressive(workspace: workspace, arguments: arguments, executable: ffmpeg,
                                                     host: host, duration: videoDuration!, playbackPath: plan.path,
                                                     plan: plan, ffprobe: ffprobe)
                    } catch ProgressiveStartup.useCompleteFile {
                        // Do not retry a failed hardware job in a second container.
                        // Switch encoder first; software retains the bounded MP4 fallback.
                        if encoder.hasSuffix("_videotoolbox") { throw PreparationFailure.failed }
                        // No URL has reached the player. A bounded startup failure can
                        // safely use the existing complete-file path once.
                        try Task.checkCancellation()
                    }
                }
                // -n never overwrites, so clear a partial output from a prior attempt.
                PreparationTrace.mark(.completeMux)
                var attempt = 0
                while true {
                    try? FileManager.default.removeItem(at: output)
                    let started = ContinuousClock.now
                    do {
                        _ = try await HelperProcess.run(executable: ffmpeg,
                                                        arguments: arguments + ["-movflags", "+faststart", "-fs",
                                                                                String(maximumBytes), "-f", "mp4", output.path],
                                                        timeout: timeout, outputLimit: 64 * 1024,
                                                        monitor: { try workspace.checkSize(maximumBytes) })
                        break
                    } catch {
                        // A codec rejection fails immediately and would fail again.
                        // Retry only a remote failure that returns at once.
                        guard RemoteFailureRetry.allows(error: error, elapsed: started.duration(to: .now), attempt: attempt) else { throw error }
                        attempt += 1
                        try await Task.sleep(for: .milliseconds(600 * attempt))
                    }
                }
                try Task.checkCancellation()
                let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 0 else { throw PreparationFailure.failed }
                guard size < maximumBytes else { throw PreparationFailure.storageLimit }
                if plan.stereoFallback != nil { try Self.linkDolbyFallback(in: output) }
                let verified = try await probe(output, headers: [:], executable: ffprobe, local: true)
                try Self.validateConverted(verified, plan: plan)
                let duration = try verified.finiteDuration
                let expectedSubtitles = subtitleTracks.count
                let expectedAudio = plan.stereoFallback == nil ? 1 : 2
                guard verified.streams.count == 1 + expectedAudio + expectedSubtitles,
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
            if source.upscaler == .automatic,
               Self.hardwareFrames(stream: plan.video, encoder: encoder, enhancement: plan.enhancement),
               try await Self.canEncode(stream: plan.video, enhancement: plan.enhancement,
                                        encoder: encoder, executable: ffmpeg, hardwareFrames: true) {
                do { return try await deliver(encoder: encoder, hardwareFrames: true) }
                catch {
                    guard Self.retryableHardwareFailure(error) else { throw error }
                    try Task.checkCancellation()
                    // A failed decoder/filter need not discard a working
                    // hardware encoder. Retry CPU filters before software encode.
                }
            }
            do {
                return try await deliver(encoder: encoder)
            } catch {
                guard encoder.hasSuffix("_videotoolbox"), Self.retryableHardwareFailure(error) else { throw error }
                try Task.checkCancellation()
                return try await deliver(encoder: plan.enhancement.targetHeight == 2160 ? "libx265" : "libx264")
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as AppFailure { throw error }
        catch let error as RemuxIndexFailure { throw AppFailure(.playbackFailed, error.message) }
        catch let error as PreparationFailure { throw error }
        catch ResolutionFailure.timedOut { throw PreparationFailure.limit }
        catch { throw PreparationFailure.failed }
    }

    private static func supportsRandomAccess(_ url: URL, headers: [String: String]) async throws -> Bool {
        if url.isFileURL { return true }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            // Read response headers without downloading an entire body if a
            // server ignores Range. Cancellation also closes the probe stream.
            let (_, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { return false }
            return response.statusCode == 206
                && (response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-0/") ?? false)
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return false }
    }

    private static func nativeGPUInput(_ stream: Stream) -> Bool {
        ["h264", "hevc"].contains(stream.codec_name ?? "")
            && ["yuv420p", "nv12"].contains(stream.pix_fmt ?? "")
            && [nil, "progressive", "unknown"].contains(stream.field_order)
            && [nil, "tv", "mpeg"].contains(stream.color_range)
            && stream.color_transfer == "bt709" && stream.color_space == "bt709" && stream.color_primaries == "bt709"
            && [nil, "1:1", "0:1", "N/A"].contains(stream.sample_aspect_ratio)
            && (stream.side_data_list ?? []).allSatisfy { ($0.rotation ?? 0) == 0 }
            && stream.constantFrameRate
            && (stream.frameRate ?? 0) > 0 && (stream.frameRate ?? 61) <= 60.01
    }

    @available(macOS 26, *)
    private func nativePrepared(workspace: PreparationWorkspace, source: ResolvedSource, plan: PreparationPlan,
                                layout: SuperResolutionLayout, ffmpeg: String, ffprobe: String, host: String,
                                duration: Double, cached: Bool, hlsInput: Bool, noiseReduction: CleanupNoiseReduction) async throws -> PreparedMedia {
        let maximumBytes = maximumBytes
        let metrics = NativeVideoMetrics()
        let noise = source.enhancement.cleansUp ? noiseReduction : .ffmpeg
        let deadline = cached ? nil : ContinuousClock.now + timeout
        let monitor: @Sendable () throws -> Void = {
            try workspace.checkSize(maximumBytes)
            if let deadline, ContinuousClock.now >= deadline { throw PreparationFailure.stalled }
        }
        let inputs = NativeInputPrefetch(duration: duration) { _, start, length in
            let directory = workspace.directory.appendingPathComponent("input-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("compressed.mp4")
            var success = false
            defer { if !success { try? FileManager.default.removeItem(at: directory) } }
            let began = ContinuousClock.now
            var args = ["-v", "error", "-nostdin", "-n", "-ss", MediaClock.seconds(start)]
                + (try Self.inputArguments(url: source.url, headers: source.headers, hls: hlsInput))
            if cached, let audio = source.audio {
                args += ["-ss", MediaClock.seconds(start)] + (try Self.inputArguments(url: audio.url, headers: audio.headers, hls: hlsInput))
            }
            args += ["-map", "0:\(plan.video.index)", "-c:v", "copy"]
            if cached {
                args += ["-map", "\(plan.audioInput):\(plan.audio.index)"] + Self.audioArguments(stream: plan.audio, action: plan.audioAction)
                if plan.audioAction == .convert { args += ["-af", "asetpts=PTS-STARTPTS,apad"] }
            } else { args += ["-an"] }
            args += ["-t", MediaClock.seconds(length), "-avoid_negative_ts", "disabled", "-map_metadata", "0", "-movflags", "+faststart", file.path]
            _ = try await HelperProcess.run(executable: ffmpeg, arguments: args, timeout: .seconds(120), outputLimit: 4096, monitor: monitor)
            try Task.checkCancellation(); try monitor()
            let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            let elapsed = began.duration(to: .now).components
            metrics.fetched(seconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, bytes: bytes)
            success = true
            return NativeInputClip(file)
        }
        do {
            @Sendable func piece(index: Int, start: Double, length: Double, directory: URL, hls: Bool) async throws {
                let input = try await inputs.take(index: index)
                let video = directory.appendingPathComponent("gpu-video.mp4")
                defer { try? FileManager.default.removeItem(at: video) }
                metrics.beginProcessing()
                defer { metrics.endProcessing() }
                let result = try await NativeGPUVideoEncoder.export(input: input.url, output: video, layout: layout,
                    start: start, length: length, rate: plan.video.frameRate!, reorder: plan.video.has_b_frames ?? 0,
                    noiseReduction: noise, monitor: monitor)
                metrics.processed(result)
                var args = ["-v", "error", "-nostdin", "-n", "-i", video.path]
                if hls { args += ["-i", input.url.path, "-map", "0:v:0", "-map", "1:a:0"] }
                else { args += ["-map", "0:v:0", "-an"] }
                args += ["-c", "copy", "-t", MediaClock.seconds(length), "-map_metadata", "-1"]
                if plan.fragmentedHLS { args += ["-tag:v", "hvc1"] }
                if hls {
                    args += ["-f", "hls", "-hls_segment_type", plan.fragmentedHLS ? "fmp4" : "mpegts", "-hls_time", "86400",
                        "-hls_playlist_type", "vod", "-hls_flags", "temp_file", "-start_number", String(index),
                        "-hls_segment_filename", directory.appendingPathComponent(plan.fragmentedHLS ? "segment%06d.m4s" : "segment%06d.ts").path]
                    if plan.fragmentedHLS { args += ["-hls_fmp4_init_filename", String(format: "init%06d.mp4", index)] }
                    args += [directory.appendingPathComponent("part.m3u8").path]
                } else { args += ["-movflags", "+faststart", directory.appendingPathComponent("part.mp4").path] }
                _ = try await HelperProcess.run(executable: ffmpeg, arguments: args, timeout: .seconds(120), outputLimit: 4096, monitor: monitor)
            }
            if cached {
                let cache = try await CachedHLS(workspace: workspace, duration: duration, fragmented: plan.fragmentedHLS, preferences: preferences) { index, start, length, directory in
                    try await piece(index: index, start: start, length: length, directory: directory, hls: true)
                    let initialization = String(format: "init%06d.mp4", index)
                    PreparationTrace.mark(.chunkManifest)
                    let manifest = try HLSPlaylist(directory: directory, name: "part.m3u8", initialization: initialization)
                    PreparationTrace.current?.update { $0.producedSeconds = manifest.duration.isFinite ? manifest.duration : nil }
                    guard manifest.complete, manifest.count == 1, abs(manifest.duration - length) < 0.15,
                          let segment = manifest.segments.first else { throw PreparationFailure.failed }
                    let probe = try await self.probeSegment(segment, directory: directory, fragmented: plan.fragmentedHLS,
                        executable: ffprobe, initialization: initialization)
                    try Self.validateConverted(probe, plan: plan)
                    return (layout.outputHeight, plan.video.frameRate!)
                }
                let prepared = try await publish(cache: cache, workspace: workspace, host: host, duration: duration,
                    plan: plan, startPosition: source.preparationPosition)
                await prepared.retain(inputs, metrics: metrics)
                return prepared
            }
            let scratch = workspace.directory.appendingPathComponent("gpu-working", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            var parts: [String] = []
            var start = 0.0
            while start < duration {
                try Task.checkCancellation(); let length = min(6, duration - start)
                try await piece(index: parts.count, start: start, length: length, directory: scratch, hls: false)
                let name = String(format: "part%06d.mp4", parts.count)
                try FileManager.default.moveItem(at: scratch.appendingPathComponent("part.mp4"), to: scratch.appendingPathComponent(name))
                parts.append("file '\(name)'"); start += length
            }
            inputs.stop(); await inputs.wait()
            let list = scratch.appendingPathComponent("parts.ffconcat")
            try Data(("ffconcat version 1.0\n" + parts.joined(separator: "\n") + "\n").utf8).write(to: list)
            let joined = scratch.appendingPathComponent("joined.mp4")
            _ = try await HelperProcess.run(executable: ffmpeg, arguments: ["-v", "error", "-nostdin", "-n", "-f", "concat", "-safe", "1",
                "-i", list.path, "-c", "copy", joined.path], timeout: timeout, outputLimit: 4096, monitor: monitor)
            // Audio stays one continuous stream. Joining independently encoded
            // AAC clips would repeat encoder priming/padding at each boundary.
            let audioURL = source.audio?.url ?? source.url
            let audioHeaders = source.audio?.headers ?? source.headers
            let output = workspace.directory.appendingPathComponent("media.mp4")
            var mux = ["-v", "error", "-nostdin", "-n", "-i", joined.path]
                + (try Self.inputArguments(url: audioURL, headers: audioHeaders, hls: hlsInput))
                + ["-map", "0:v:0", "-map", "1:\(plan.audio.index)", "-c:v", "copy"]
                + Self.audioArguments(stream: plan.audio, action: plan.audioAction)
            if plan.audioAction == .convert { mux += ["-af", "asetpts=PTS-STARTPTS,apad"] }
            mux += ["-t", MediaClock.seconds(duration), "-map_metadata", "-1", "-movflags", "+faststart", output.path]
            _ = try await HelperProcess.run(executable: ffmpeg, arguments: mux, timeout: timeout, outputLimit: 4096, monitor: monitor)
            try FileManager.default.removeItem(at: scratch)
            let verified = try await probe(output, headers: [:], executable: ffprobe, local: true)
            try Self.validateConverted(verified, plan: plan)
            guard abs(try verified.finiteDuration - duration) <= completionTolerance(for: duration) else { throw PreparationFailure.failed }
            let server = try await MediaHTTPServer.start(file: output, host: host)
            do { try Task.checkCancellation() } catch { await server.stop(); throw error }
            let prepared = await PreparedMedia(server: server, workspace: workspace, sourceDuration: duration,
                playbackPath: .videoConversion, videoHeight: layout.outputHeight, videoFrameRate: plan.video.frameRate)
            await prepared.retain(inputs, metrics: metrics)
            return prepared
        } catch { inputs.stop(); await inputs.wait(); throw error }
    }

    /// AI uses the same storage lease, quota, delivery server and chunk cache as
    /// ordinary preparation. Only bounded raw intermediates are retained while
    /// processing a chunk; no additional lossy encode precedes the AI processor.
    private func superResolved(workspace: PreparationWorkspace, source: ResolvedSource, plan: PreparationPlan,
                               layout: SuperResolutionLayout, normalization: AppleInputNormalization, ffmpeg: String, ffprobe: String, host: String,
                               duration: Double, cached: Bool, hlsInput: Bool,
                               subtitles: [(input: Int, stream: Stream)], noiseReduction: CleanupNoiseReduction) async throws -> PreparedMedia {
        let maximumBytes = maximumBytes
        let processSeconds: Double = 600
        let rate = normalization.rate
        let noiseReduction = plan.enhancement.cleansUp ? noiseReduction : .ffmpeg
        let monitor: @Sendable () throws -> Void = { try workspace.checkSize(maximumBytes) }
        @Sendable func normalizedClip(start: Double, length: Double, directory: URL) async throws -> URL {
            let raw = directory.appendingPathComponent("input.mov")
            var filter = normalization.colorFilter + ","
            if plan.enhancement.cleansUp {
                if noiseReduction == .ffmpeg { filter += "hqdn3d=1.5:1.5:4:4," }
                filter += "deband=1thr=0.02:2thr=0.02:3thr=0.02,"
            }
            filter += "scale=w=\(layout.inputWidth):h=\(layout.inputHeight):flags=lanczos:out_color_matrix=bt709:out_range=tv,setsar=1,fps=\(rate),setpts=PTS-STARTPTS,setparams=range=limited:color_primaries=bt709:color_trc=bt709:colorspace=bt709"
            let arguments = ["-v", "error", "-nostdin", "-n", "-ss", String(start)]
                + (try Self.inputArguments(url: source.url, headers: source.headers, hls: hlsInput))
                + ["-map", "0:\(plan.video.index)", "-an", "-sn", "-dn", "-t", String(length), "-vf", filter,
                   "-c:v", "rawvideo", "-pix_fmt", "uyvy422", "-color_range", "tv", "-colorspace", "bt709",
                   "-color_primaries", "bt709", "-color_trc", "bt709", "-map_metadata", "-1", "-movflags", "+write_colr", raw.path]
            // A raw intermediate can be large. Fail before decoding if even its
            // working footprint cannot fit the configured preparation budget.
            guard Double(layout.inputWidth * layout.inputHeight * 2) * rate * length < Double(maximumBytes) * 0.8 else {
                throw PreparationFailure.storageLimit
            }
            _ = try await HelperProcess.run(executable: ffmpeg, arguments: arguments,
                timeout: timeout, outputLimit: 4096, monitor: monitor)
            try monitor()
            return raw
        }
        @Sendable func videoChunk(start: Double, length: Double, directory: URL) async throws -> URL {
            let raw = try await normalizedClip(start: start, length: length, directory: directory)
            defer { try? FileManager.default.removeItem(at: raw) }
            let video = directory.appendingPathComponent("video.mp4")
            try await SuperResolutionEncoder.export(input: raw, output: video, layout: layout,
                seconds: processSeconds, noiseReduction: noiseReduction, monitor: monitor)
            return video
        }
        @Sendable func muxArguments(video: URL, start: Double, length: Double, complete: Bool) throws -> [String] {
            var arguments = ["-v", "error", "-nostdin", "-n", "-i", video.path, "-ss", String(start)]
                + (try Self.inputArguments(url: source.url, headers: source.headers, hls: hlsInput))
            if let audio = source.audio {
                arguments += ["-ss", String(start)] + (try Self.inputArguments(url: audio.url, headers: audio.headers, hls: hlsInput))
            }
            arguments += ["-map", "0:v:0", "-map", "\(source.audio == nil ? 1 : 2):\(plan.audio.index)", "-c:v", "copy"]
                + Self.audioArguments(stream: plan.audio, action: .convert)
                + ["-af", "asetpts=PTS-STARTPTS,apad", "-t", String(length), "-map_metadata", "-1", "-map_chapters", "-1", "-dn"]
            if plan.fragmentedHLS { arguments += ["-tag:v", "hvc1"] }
            if complete && !subtitles.isEmpty {
                for subtitle in subtitles { arguments += ["-map", "\(subtitle.input + 1):\(subtitle.stream.index)"] }
                arguments += ["-c:s", "mov_text"]
                for (index, subtitle) in subtitles.enumerated() {
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
        if cached {
            let cache = try await CachedHLS(workspace: workspace, duration: duration, fragmented: plan.fragmentedHLS,
                preferences: preferences) { index, start, length, directory in
                let video = try await videoChunk(start: start, length: length, directory: directory)
                defer { try? FileManager.default.removeItem(at: video) }
                let initialization = String(format: "init%06d.mp4", index)
                var arguments = try muxArguments(video: video, start: start, length: length, complete: false)
                arguments += ["-f", "hls", "-hls_segment_type", plan.fragmentedHLS ? "fmp4" : "mpegts",
                    "-hls_time", "86400", "-hls_playlist_type", "vod", "-hls_flags", "temp_file",
                    "-start_number", String(index), "-hls_segment_filename",
                    directory.appendingPathComponent(plan.fragmentedHLS ? "segment%06d.m4s" : "segment%06d.ts").path]
                if plan.fragmentedHLS { arguments += ["-hls_fmp4_init_filename", initialization] }
                arguments += [directory.appendingPathComponent("part.m3u8").path]
                _ = try await HelperProcess.run(executable: ffmpeg, arguments: arguments,
                    timeout: timeout, outputLimit: 4096, monitor: monitor)
                let manifest = try HLSPlaylist(directory: directory, name: "part.m3u8", initialization: initialization)
                guard manifest.complete, manifest.count == 1, abs(manifest.duration - length) < 0.15,
                      let segment = manifest.segments.first else { throw PreparationFailure.failed }
                let inspected = try await probeSegment(segment, directory: directory, fragmented: plan.fragmentedHLS,
                    executable: ffprobe, initialization: initialization)
                try Self.validateConverted(inspected, plan: plan, normalization: normalization)
                return (layout.outputHeight, rate)
            }
            return try await publish(cache: cache, workspace: workspace, host: host, duration: duration, plan: plan, startPosition: source.preparationPosition)
        }
        let deadline = Date().addingTimeInterval(processSeconds)
        let scratch = workspace.directory.appendingPathComponent("working", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var entries: [String] = []
        var start = 0.0
        while start < duration {
            try Task.checkCancellation()
            guard Date() < deadline else { throw PreparationFailure.limit }
            let length = min(6, duration - start)
            let clip = try await videoChunk(start: start, length: length, directory: scratch)
            let name = String(format: "part%06d.mp4", entries.count)
            try FileManager.default.moveItem(at: clip, to: scratch.appendingPathComponent(name))
            entries.append("file '\(name)'")
            start += length
        }
        let list = scratch.appendingPathComponent("video.ffconcat")
        try Data(("ffconcat version 1.0\n" + entries.joined(separator: "\n") + "\n").utf8).write(to: list)
        let video = scratch.appendingPathComponent("joined.mp4")
        _ = try await HelperProcess.run(executable: ffmpeg, arguments: ["-v", "error", "-nostdin", "-n",
            "-f", "concat", "-safe", "1", "-i", list.path, "-c", "copy", video.path],
            timeout: timeout, outputLimit: 4096, monitor: monitor)
        for index in entries.indices { try FileManager.default.removeItem(at: scratch.appendingPathComponent(String(format: "part%06d.mp4", index))) }
        let output = workspace.directory.appendingPathComponent("media.mp4")
        _ = try await HelperProcess.run(executable: ffmpeg, arguments: try muxArguments(video: video, start: 0,
            length: duration, complete: true) + ["-movflags", "+faststart", output.path],
            timeout: timeout, outputLimit: 4096, monitor: monitor)
        try FileManager.default.removeItem(at: scratch)
        let verified = try await probe(output, headers: [:], executable: ffprobe, local: true)
        try Self.validateConverted(verified, plan: plan, normalization: normalization)
        guard verified.streams.count == 2 + subtitles.count,
              verified.streams.filter({ $0.codec_type == "subtitle" }).count == subtitles.count,
              abs(try verified.finiteDuration - duration) <= completionTolerance(for: duration) else { throw PreparationFailure.failed }
        let server = try await MediaHTTPServer.start(file: output, host: host)
        do { try Task.checkCancellation() } catch { await server.stop(); throw error }
        return await PreparedMedia(server: server, workspace: workspace, sourceDuration: duration,
            playbackPath: .videoConversion, videoHeight: layout.outputHeight, videoFrameRate: rate)
    }

    private func cached(workspace: PreparationWorkspace, arguments: [String], executable: String,
                        host: String, duration: Double, plan: PreparationPlan, ffprobe: String,
                        startPosition: Double? = nil,
                        source: ResolvedSource? = nil, subtitles: [(input: Int, stream: Stream)] = [],
                        remuxTimeline: RemuxTimeline? = nil) async throws -> PreparedMedia {
        let fragmented = remuxTimeline != nil || plan.fragmentedHLS || plan.stereoFallback != nil
        var subtitleSources: [(RemoteRemuxIndex.SubtitleIndex, Int)] = []
        for input in [0, 1] {
            let selected = subtitles.filter { $0.input == input }
            guard !selected.isEmpty else { continue }
            guard let source else { throw PreparationFailure.unsupported }
            let url = input == 0 ? source.url : source.audio!.url
            let headers = input == 0 ? source.headers : source.audio!.headers
            do {
                PreparationTrace.mark(.subtitleIndex)
                let index = try await RemoteRemuxIndex.subtitles(url: url, headers: headers, streams: selected.map { $0.stream.index })
                subtitleSources += selected.indices.map { (index, $0) }
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError {
                try Task.checkCancellation()
                throw AppFailure(.playbackFailed, "Could not read the remote subtitle index (network error \(error.code.rawValue)). Check the connection and load the video again.")
            }
            catch {
                throw AppFailure(.unsupportedOperation, "The subtitle track has no usable Matroska seek index. Incremental playback cannot preserve it safely; no complete-file download was started.")
            }
        }
        let trace = PreparationTrace.current
        let indexedSubtitles = subtitleSources
        let continuousRenditions = !subtitles.isEmpty || plan.stereoFallback != nil
            || ["h264", "hevc"].contains(plan.video.codec_name ?? "")
        var renditions = subtitles.enumerated().map { index, subtitle in
            CachedHLS.Rendition(prefix: "subtitle\(index)", label: subtitle.stream.tags?.title ?? subtitle.stream.tags?.language ?? "Subtitles \(index + 1)", language: subtitle.stream.tags?.language, subtitle: true)
        }
        if plan.stereoFallback != nil {
            renditions.append(.init(prefix: "audio0", label: "AAC Stereo", language: plan.audio.tags?.language, subtitle: false))
        }
        let cache = try await CachedHLS(workspace: workspace, duration: duration, fragmented: fragmented,
                                      preferences: preferences, starts: remuxTimeline?.starts, renditions: renditions,
                                      continuous: continuousRenditions && remuxTimeline != nil) { index, start, length, directory in
            return try await PreparationTrace.$current.withValue(trace) {
            trace?.update {
                $0.chunkIndex = index; $0.requestedSeconds = length; $0.producedSeconds = nil
                $0.videoCurrentDTS = nil; $0.videoNextDTS = nil; $0.videoTimeBase = nil
                $0.fragmentTracks = nil; $0.initializationBytes = nil; $0.segmentBytes = nil; $0.inspectionBytes = nil
            }
            trace?.mark(.chunkBoundaryProbe)
            var chunk = arguments
            var leadingPictureAllowance = plan.video.codec_name == "hevc"
                ? remuxTimeline?.presentationReorderAllowance ?? 0.15 : 0.15
            // The main rendition keeps original Dolby; its AAC alternative is
            // a separately selectable rendition generated under the same lease.
            if let fallback = plan.stereoFallback {
                let mapping = "\(plan.audioInput):\(fallback.index)"
                if let map = chunk.indices.reversed().first(where: { chunk[$0] == "-map" && $0 + 1 < chunk.count && chunk[$0 + 1] == mapping }) {
                    chunk.removeSubrange(map...map + 1)
                }
                for flag in ["-c:a:1", "-ac:a:1", "-ar:a:1", "-b:a:1"] {
                    if let at = chunk.firstIndex(of: flag) { chunk.removeSubrange(at...at + 1) }
                }
            }
            if let remuxTimeline {
                if plan.videoAction == .copy, plan.video.codec_name == "hevc" {
                    // Rebuild MP4's HEVC configuration from explicit Annex B
                    // framing before writing independent hvc1 initializations.
                    if let at = chunk.firstIndex(of: "-bsf:v") {
                        chunk[at + 1] += ",hevc_mp4toannexb"
                    } else {
                        chunk += ["-bsf:v", "hevc_mp4toannexb"]
                    }
                }
                try await remuxTimeline.remoteValidation?.validate(index: index)
                trace?.update {
                    $0.videoCurrentDTS = remuxTimeline.cuts[index].dts
                    $0.videoNextDTS = index + 1 < remuxTimeline.cuts.count ? remuxTimeline.cuts[index + 1].dts : nil
                    $0.videoTimeBase = remuxTimeline.videoTimeBase
                }
                let trim = remuxTimeline.arguments(index: index, length: length)
                let inputs = chunk.indices.filter { chunk[$0] == "-i" }
                for (nth, offset) in inputs.enumerated().reversed() {
                    chunk.insert(contentsOf: nth == 0 ? trim.input : trim.audio, at: offset)
                }
                var output = trim.output
                if continuousRenditions, let offset = output.firstIndex(of: "-output_ts_offset") {
                    // All renditions share one monotonic media clock. Restarted
                    // zero clocks make native alternate-audio seeks ambiguous.
                    let firstPTS = Double(remuxTimeline.cuts[0].pts) * remuxTimeline.videoTimeBase
                    output[offset + 1] = MediaClock.seconds(10 - firstPTS)
                }
                if plan.audioAction == .convert {
                    if let at = output.firstIndex(of: "-bsf:a") { output.removeSubrange(at...at + 1) }
                    let origin = Double(remuxTimeline.cuts[index].pts) * remuxTimeline.videoTimeBase
                    output += ["-af", "atrim=start=\(MediaClock.seconds(origin)):end=\(MediaClock.seconds(origin + length)),asetpts=PTS-STARTPTS+\(MediaClock.seconds(origin))/TB"]
                }
                if let incoming = output.firstIndex(of: "-bsf:v"), let existing = chunk.firstIndex(of: "-bsf:v") {
                    // FFmpeg keeps only the last -bsf:v option. Keep packet
                    // trimming in the same chain as HEVC framing/DV handling.
                    chunk[existing + 1] += "," + output[incoming + 1]
                    output.removeSubrange(incoming...incoming + 1)
                }
                chunk += output
            } else {
                // Apply accurate input seeking to video and separately selected audio.
                for offset in chunk.indices.reversed() where chunk[offset] == "-i" {
                    chunk.insert(contentsOf: ["-ss", MediaClock.seconds(start)], at: offset)
                }
                if let filter = chunk.firstIndex(of: "-vf") { chunk[filter + 1] += ",setpts=PTS-STARTPTS" }
                chunk += ["-af", "asetpts=PTS-STARTPTS,apad", "-t", MediaClock.seconds(length)]
            }
            let initialization = fragmented ? String(format: "init%06d.mp4", index) : "init.mp4"
            if remuxTimeline != nil, continuousRenditions {
                // Preserve absolute tfdt timestamps in each independent muxing
                // job. Edit-list offsets alone look correct to ffprobe but
                // reset AVPlayer's buffered timeline at every fragment.
                chunk += ["-hls_segment_options", "use_editlist=0:movflags=+frag_discont:avoid_negative_ts=disabled"]
            }
            chunk += ["-f", "hls", "-hls_segment_type", fragmented ? "fmp4" : "mpegts",
                      "-hls_time", "86400", "-hls_playlist_type", "vod", "-hls_flags", "temp_file",
                      "-start_number", String(index)]
                + Self.hlsSegmentFiles(in: directory, fragmented: fragmented, initialization: initialization)
                + [directory.appendingPathComponent("part.m3u8").path]
            trace?.mark(.chunkMux)
            do {
                _ = try await HelperProcess.run(executable: executable, arguments: chunk,
                                                timeout: index == 0 ? startupTimeout : timeout, outputLimit: 64 * 1024,
                                                monitor: { try workspace.checkSize(maximumBytes) })
            } catch ResolutionFailure.timedOut { throw PreparationFailure.stalled }
            trace?.mark(.chunkManifest)
            let manifest = try HLSPlaylist(directory: directory, name: "part.m3u8", initialization: initialization)
            trace?.update { $0.producedSeconds = manifest.duration.isFinite ? manifest.duration : nil }
            // CRA leading pictures belong to the following decode interval,
            // but precede its keyframe in presentation order. Keep all packets;
            // a continuous decoder presents them across the HLS boundary.
            guard manifest.complete, manifest.count == 1,
                  let segment = manifest.segments.first else { throw PreparationFailure.failed }
            trace?.mark(.chunkProbe)
            let inspectedProbe = try await probeSegment(segment, directory: directory, fragmented: fragmented,
                                              executable: ffprobe, initialization: initialization,
                                              inspectClocks: remuxTimeline != nil)
            if remuxTimeline != nil {
                leadingPictureAllowance = max(leadingPictureAllowance,
                    RemuxTimeline.reorderAllowance(delay: inspectedProbe.videoReorderDelay))
            }
            trace?.mark(.chunkValidation)
            guard ChunkOutputCheck.accepts(produced: manifest.duration, requested: length,
                                          final: start + length >= duration - 0.001,
                                          leadingPictureAllowance: leadingPictureAllowance) else { throw PreparationFailure.failed }
            try Self.validateConverted(inspectedProbe, plan: plan)
            let inspectedVideo = inspectedProbe.streams.first { $0.codec_type == "video" }
            let inspected = (height: inspectedVideo?.height, frameRate: inspectedVideo?.frameRate)
            let videoPTS = Double(inspectedVideo?.start_time ?? "") ?? 0
            guard videoPTS.isFinite, videoPTS >= 0, videoPTS < duration + 60 else { throw PreparationFailure.failed }
            if let source, let fallback = plan.stereoFallback {
                trace?.mark(.fallbackAudioMux)
                let input = source.audio?.url ?? source.url
                let headers = source.audio?.headers ?? source.headers
                let initName = String(format: "audio0-init%06d.mp4", index)
                let continuousAAC = remuxTimeline != nil && plan.stereoFallbackAction == .convert
                let frameSamples = 1024.0, sampleRate = 48_000.0
                func audioEdge(_ seconds: Double) -> Int64 {
                    Int64(max(0, ceil(seconds * sampleRate / frameSamples - 1e-7))) * 1024
                }
                let firstSample = audioEdge(start), endSample = audioEdge(start + length)
                let decodeSample = max(0, firstSample - 4096)
                let videoOrigin = remuxTimeline.map { Double($0.cuts[0].pts) * $0.videoTimeBase } ?? 0
                let inputOffset = remuxTimeline.map { videoOrigin - $0.sourceStart } ?? 0
                var audio = ["-v", "error", "-nostdin", "-n"]
                if continuousAAC {
                    audio += ["-copyts", "-ss", MediaClock.seconds(max(0, Double(decodeSample) / sampleRate + inputOffset)),
                              "-t", MediaClock.seconds(Double(endSample + 2048 - decodeSample) / sampleRate)]
                } else {
                    audio += ["-ss", MediaClock.seconds(start)]
                }
                audio += (try Self.inputArguments(url: input, headers: headers))
                    + ["-map", "0:\(fallback.index)", "-vn", "-sn", "-dn"]
                audio += Self.audioArguments(stream: fallback, action: plan.stereoFallbackAction ?? .convert)
                if continuousAAC {
                    // Encode with preceding PCM context, then keep whole AAC
                    // frames on one sample clock. Independent encoder priming
                    // must not overlap the previous fragment at each boundary.
                    let audioOffset = source.audio == nil ? 0 : remuxTimeline?.audioOffset ?? 0
                    audio += ["-af", "asetpts=PTS-\(MediaClock.seconds(videoOrigin))/TB+\(MediaClock.seconds(audioOffset))/TB,aresample=48000:first_pts=\(decodeSample),apad=pad_len=2048",
                              "-bsf:a", "noise=amount=0:drop='lt(pts,\(firstSample))+gte(pts,\(endSample))'"]
                }
                if remuxTimeline != nil {
                    audio += ["-hls_segment_options", "use_editlist=0:movflags=+frag_discont:avoid_negative_ts=disabled"]
                }
                if !continuousAAC { audio += ["-t", MediaClock.seconds(length)] }
                audio += ["-avoid_negative_ts", "disabled", "-output_ts_offset", MediaClock.seconds(continuousAAC ? 10 : videoPTS), "-f", "hls", "-hls_segment_type", "fmp4", "-hls_time", "86400",
                          "-hls_playlist_type", "vod", "-hls_fmp4_init_filename", initName,
                          "-hls_segment_filename", directory.appendingPathComponent("audio0-segment%06d.m4s").path,
                          "-start_number", String(index), directory.appendingPathComponent("audio0-part.m3u8").path]
                _ = try await HelperProcess.run(executable: executable, arguments: audio, timeout: timeout,
                    outputLimit: 4096, monitor: { try workspace.checkSize(maximumBytes) })
            }
            let origin = remuxTimeline.map { Double($0.cuts[index].pts) * $0.videoTimeBase } ?? start
            for (track, entry) in indexedSubtitles.enumerated() {
                trace?.mark(.subtitleRead)
                let file = directory.appendingPathComponent("subtitle\(track)-input.mkv")
                let output = directory.appendingPathComponent(String(format: "subtitle%d-segment%06d.vtt", track, index))
                if let data = try await entry.0.fragment(track: entry.1, start: origin, end: origin + length) {
                    try data.write(to: file)
                    try workspace.checkSize(maximumBytes)
                    defer { try? FileManager.default.removeItem(at: file) }
                    trace?.mark(.subtitleMux)
                    _ = try await HelperProcess.run(executable: executable,
                        arguments: ["-v", "error", "-nostdin", "-n", "-copyts", "-i", file.path, "-map", "0:s:0", "-c:s", "webvtt", output.path],
                        timeout: timeout, outputLimit: 4096, monitor: { try workspace.checkSize(maximumBytes) })
                } else { try Data("WEBVTT\n\n".utf8).write(to: output) }
                let text = try String(contentsOf: output, encoding: .utf8)
                guard text.hasPrefix("WEBVTT\n") else { throw PreparationFailure.failed }
                let millis = Int64((max(0, origin) * 1000).rounded())
                let stamp = String(format: "%02lld:%02lld:%02lld.%03lld", millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, millis % 1000)
                let mapped = "WEBVTT\nX-TIMESTAMP-MAP=LOCAL:\(stamp),MPEGTS:\(Int64((videoPTS * 90_000).rounded()))\n" + text.dropFirst(7)
                try Data(mapped.utf8).write(to: output, options: .atomic)
            }
            // CachedHLS prunes released chunks before checking the shared quota.
            return inspected
            }
        }
        return try await publish(cache: cache, workspace: workspace, host: host, duration: duration, plan: plan, startPosition: startPosition)
    }

    private func publish(cache: CachedHLS, workspace: PreparationWorkspace, host: String,
                         duration: Double, plan: PreparationPlan, startPosition: Double?) async throws -> PreparedMedia {
        do {
            try await withTaskCancellationHandler {
                try await cache.warmUp(at: startPosition ?? 0)
                try Task.checkCancellation()
            } onCancel: { Task { @MainActor in cache.stop() } }
            let server = try await MediaHTTPServer.start(file: workspace.directory.appendingPathComponent("media.m3u8"),
                host: host, hls: true, loadResource: { try await cache.resource($0) },
                releaseResource: { cache.release($0) })
            let prepared = await PreparedMedia(server: server, workspace: workspace, sourceDuration: duration,
                                               playbackPath: plan.path, videoHeight: cache.videoHeight,
                                               videoFrameRate: cache.videoFrameRate)
            await prepared.installCache(cache)
            do { try Task.checkCancellation() }
            catch { await prepared.discardAttempt(); await prepared.waitForProducer(); throw error }
            return prepared
        } catch {
            await cache.stop(); await cache.waitForJobs()
            workspace.removeGeneratedFiles()
            throw error
        }
    }

    private enum ProgressiveStartup: Error { case useCompleteFile }

    @MainActor
    private func live(workspace: PreparationWorkspace, arguments: [String], executable: String,
                      host: String, playbackPath: PlaybackPath, plan: PreparationPlan,
                      maximumBytes: Int64, ffprobe: String, transportInput: Bool) async throws -> PreparedMedia {
        let playlist = workspace.directory.appendingPathComponent("media.m3u8")
        let arguments = Self.appendingHLSOutput(to: arguments + ["-f", "hls", "-hls_segment_type", plan.fragmentedHLS ? "fmp4" : "mpegts", "-hls_time", "2",
            "-hls_list_size", "6", "-hls_delete_threshold", "3",
            "-hls_flags", "delete_segments+temp_file"],
            directory: workspace.directory, fragmented: plan.fragmentedHLS, playlist: playlist, plan: plan)
        let server = try await MediaHTTPServer.start(file: playlist, host: host, hls: true)
        let prepared = PreparedMedia(server: server, workspace: workspace, playbackPath: playbackPath,
                                     videoHeight: plan.video.height, videoFrameRate: plan.video.frameRate)
        prepared.liveInputIsTransportStream = transportInput
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
                    let elapsed = started.duration(to: .now).timeInterval
                    if plan.videoAction == .convert && !manifest.complete && elapsed - manifest.duration > 4 {
                        throw PreparationFailure.failed
                    }
                    try await verifyStartupSegment(manifest.segments.last, of: prepared, directory: workspace.directory,
                                                   plan: plan, executable: ffprobe)
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
            prepared.discardAttempt()
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
        // Apple HLS requires HEVC in fragmented MP4, including copied HEVC.
        let fragmented = plan.fragmentedHLS
        let arguments = Self.appendingHLSOutput(to: arguments + ["-f", "hls", "-hls_segment_type", fragmented ? "fmp4" : "mpegts", "-hls_time", "2",
            "-hls_playlist_type", "event", "-hls_list_size", "0", "-hls_flags", "temp_file"],
            directory: workspace.directory, fragmented: fragmented, playlist: playlist, plan: plan)
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
                    if !prepared.isProducing || (manifest.count >= 3 && manifest.duration >= 6) {
                        try await verifyStartupSegment(manifest.segments.first, of: prepared,
                                                       directory: workspace.directory, plan: plan, executable: ffprobe)
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
            prepared.discardAttempt()
            await prepared.waitForProducer()
            // The caller still holds the lease. Remove partial HLS before an MP4 fallback.
            // Cleanup must not replace the original failure, including cancellation.
            workspace.removeGeneratedFiles()
            if error is CancellationError { throw CancellationError() }
            if let failure = error as? PreparationFailure,
               [.limit, .storageLimit, .diskSpace, .stalled].contains(failure) { throw failure }
            throw ProgressiveStartup.useCompleteFile
        }
    }

    private enum TrackAction { case copy, convert }

    private static func hlsSegmentFiles(in directory: URL, fragmented: Bool,
                                        initialization: String = "init.mp4") -> [String] {
        ["-hls_segment_filename", directory.appendingPathComponent(fragmented ? "segment%06d.m4s" : "segment%06d.ts").path]
            + (fragmented ? ["-hls_fmp4_init_filename", initialization] : [])
    }

    /// One media playlist, or a master playlist whose audio group carries a
    /// copied AC-3/E-AC-3 rendition and an AAC stereo rendition. `%v` is the
    /// variant index, so segment names stay numeric and the HTTP allowlist
    /// does not have to grow a second pattern.
    private static func appendingHLSOutput(to arguments: [String], directory: URL, fragmented: Bool,
                                           playlist: URL, plan: PreparationPlan) -> [String] {
        guard plan.stereoFallback != nil else {
            return arguments + Self.hlsSegmentFiles(in: directory, fragmented: fragmented) + [playlist.path]
        }
        let ext = fragmented ? "m4s" : "ts"
        var result = arguments + ["-var_stream_map", Self.renditionMap(plan),
                                  "-master_pl_name", playlist.lastPathComponent,
                                  "-master_pl_publish_rate", "1",
                                  "-hls_segment_filename", directory.appendingPathComponent("segment%v%06d.\(ext)").path]
        if fragmented { result += ["-hls_fmp4_init_filename", "init%v.mp4"] }
        result.append(directory.appendingPathComponent("stream_%v.m3u8").path)
        return result
    }

    private static func renditionMap(_ plan: PreparationPlan) -> String {
        let language = [plan.audio, plan.stereoFallback].compactMap { stream -> String? in
            guard let stream, let language = stream.tags?.language?.lowercased(),
                  language.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil,
                  language != "und" else { return nil }
            return language
        }.first
        let lang = language.map { ",language:\($0)" } ?? ""
        return "v:0,agroup:aud a:0,agroup:aud\(lang),default:yes a:1,agroup:aud\(lang),default:no"
    }

    private static func audioMaps(_ plan: PreparationPlan) -> [String] {
        var maps = ["-map", "\(plan.audioInput):\(plan.audio.index)"]
        if let fallback = plan.stereoFallback {
            maps += ["-map", "\(plan.audioInput):\(fallback.index)"]
        }
        return maps
    }

    private static func audioCodecArguments(plan: PreparationPlan, action: TrackAction) -> [String] {
        guard let fallbackAction = plan.stereoFallbackAction else {
            return audioArguments(stream: plan.audio, action: action)
        }
        var arguments = ["-c:a:0"]
        if action == .copy { arguments.append("copy") }
        else { arguments += ["aac", "-ac:a:0", "2", "-ar:a:0", "48000", "-b:a:0", "160k"] }
        arguments += ["-c:a:1"]
        if fallbackAction == .copy { arguments.append("copy") }
        else { arguments += ["aac", "-ac:a:1", "2", "-ar:a:1", "48000", "-b:a:1", "160k"] }
        return arguments
    }

    /// Point the copied Dolby track at the AAC stereo track with the fallback
    /// reference Apple TV uses to choose a track it can decode. ffmpeg writes
    /// both audio tracks in one alternate group; this disables the Dolby track,
    /// leaves AAC enabled, and inserts a `tref`/`fall` box. Growing `moov`
    /// shifts every later byte, so chunk offsets past the insertion move with it.
    private static func linkDolbyFallback(in file: URL) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let fileSize = try input.seekToEnd()
        guard let moov = try locateBox(type: "moov", handle: input, fileSize: fileSize),
              moov.size >= 8, moov.size <= 32 * 1024 * 1024 else { throw PreparationFailure.failed }
        try input.seek(toOffset: moov.offset)
        guard let moovData = try input.read(upToCount: Int(moov.size)), moovData.count == Int(moov.size) else {
            throw PreparationFailure.failed
        }
        var patched = moovData
        try patchDolbyFallback(in: &patched, fileOffset: moov.offset)
        let temp = file.appendingPathExtension("fallback")
        if FileManager.default.fileExists(atPath: temp.path) { try FileManager.default.removeItem(at: temp) }
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let output = try FileHandle(forWritingTo: temp)
        try input.seek(toOffset: 0)
        try copyBytes(from: input, to: output, count: moov.offset)
        try output.write(contentsOf: patched)
        try input.seek(toOffset: moov.offset + moov.size)
        try copyBytes(from: input, to: output, count: fileSize - moov.offset - moov.size)
        try output.close()
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
    }

    private struct LocatedBox { let offset: UInt64; let size: UInt64 }

    private static func locateBox(type: String, handle: FileHandle, fileSize: UInt64) throws -> LocatedBox? {
        var position: UInt64 = 0
        while position + 8 <= fileSize {
            let box = try readBox(at: position, handle: handle, fileSize: fileSize)
            if box.type == type { return LocatedBox(offset: position, size: box.size) }
            guard box.size > 0 else { throw PreparationFailure.failed }
            position += box.size
        }
        return nil
    }

    private static func readBox(at offset: UInt64, handle: FileHandle, fileSize: UInt64) throws -> (size: UInt64, type: String) {
        try handle.seek(toOffset: offset)
        guard let header = try handle.read(upToCount: 8), header.count == 8 else { throw PreparationFailure.failed }
        let size32 = u32(header, 0)
        let type = String(bytes: header[4..<8], encoding: .ascii) ?? ""
        let size: UInt64
        if size32 == 1 {
            guard let extended = try handle.read(upToCount: 8), extended.count == 8 else { throw PreparationFailure.failed }
            size = u64(extended, 0)
        } else if size32 == 0 {
            size = fileSize - offset
        } else {
            size = UInt64(size32)
        }
        guard size >= 8, offset + size <= fileSize else { throw PreparationFailure.failed }
        return (size, type)
    }

    private static func patchDolbyFallback(in moov: inout Data, fileOffset: UInt64) throws {
        let children = try boxes(in: moov, from: 8, to: moov.count)
        struct AudioBox { let entry: String; let trak: Range<Int>; let tkhd: Range<Int> }
        var audio: [AudioBox] = []
        for child in children where child.type == "trak" {
            guard let tkhd = try firstBox(type: "tkhd", in: moov, within: child.range),
                  let stsd = try firstBox(type: "stsd", in: moov, within: child.range),
                  stsd.range.count >= 24 else { throw PreparationFailure.failed }
            let entry = String(bytes: moov[stsd.range.lowerBound + 20..<stsd.range.lowerBound + 24], encoding: .ascii) ?? ""
            if ["ac-3", "ec-3", "mp4a"].contains(entry) {
                audio.append(AudioBox(entry: entry, trak: child.range, tkhd: tkhd.range))
            }
        }
        guard let dolby = audio.first(where: { $0.entry == "ac-3" || $0.entry == "ec-3" }),
              let aac = audio.first(where: { $0.entry == "mp4a" }),
              dolby.tkhd.count >= 44 else { throw PreparationFailure.failed }
        for track in [dolby, aac] {
            let version = moov[track.tkhd.lowerBound + 8]
            guard version == 0 || version == 1 else { throw PreparationFailure.failed }
            var flags = u24(moov, track.tkhd.lowerBound + 9)
            if track.entry == "mp4a" { flags |= 1 } else { flags &= ~1 }
            setU24(&moov, track.tkhd.lowerBound + 9, flags)
            let alternate = track.tkhd.lowerBound + (version == 0 ? 42 : 54)
            guard alternate + 2 <= track.tkhd.upperBound else { throw PreparationFailure.failed }
            setU16(&moov, alternate, 1)
        }
        let idOffset = aac.tkhd.lowerBound + (moov[aac.tkhd.lowerBound + 8] == 0 ? 20 : 28)
        let aacID = u32(moov, idOffset)
        var tref = Data(count: 20)
        setU32(&tref, 0, 20); tref.replaceSubrange(4..<8, with: Data("tref".utf8))
        setU32(&tref, 8, 12); tref.replaceSubrange(12..<16, with: Data("fall".utf8))
        setU32(&tref, 16, aacID)
        let insert = dolby.tkhd.upperBound
        moov.insert(contentsOf: tref, at: insert)
        setU32(&moov, dolby.trak.lowerBound, u32(moov, dolby.trak.lowerBound) + 20)
        setU32(&moov, 0, u32(moov, 0) + 20)
        try shiftChunkOffsets(&moov, insertAt: fileOffset + UInt64(insert), delta: 20)
    }

    private struct ParsedBox { let type: String; let range: Range<Int> }

    private static func boxes(in data: Data, from start: Int, to end: Int) throws -> [ParsedBox] {
        var position = start
        var result: [ParsedBox] = []
        while position + 8 <= end {
            let size = Int(u32(data, position))
            guard size >= 8, position + size <= end else { throw PreparationFailure.failed }
            let type = String(bytes: data[position + 4..<position + 8], encoding: .ascii) ?? ""
            result.append(ParsedBox(type: type, range: position..<position + size))
            position += size
        }
        guard position == end else { throw PreparationFailure.failed }
        return result
    }

    private static func firstBox(type: String, in data: Data, within range: Range<Int>) throws -> ParsedBox? {
        let nested = try boxes(in: data, from: range.lowerBound + 8, to: range.upperBound)
        for box in nested {
            if box.type == type { return box }
            if ["trak", "mdia", "minf", "stbl", "edts"].contains(box.type),
               let found = try firstBox(type: type, in: data, within: box.range) { return found }
        }
        return nil
    }

    private static func shiftChunkOffsets(_ moov: inout Data, insertAt: UInt64, delta: UInt64) throws {
        func visit(_ start: Int, _ end: Int) throws {
            var position = start
            while position + 8 <= end {
                let size = Int(u32(moov, position))
                guard size >= 8, position + size <= end else { throw PreparationFailure.failed }
                let type = String(bytes: moov[position + 4..<position + 8], encoding: .ascii) ?? ""
                if type == "stco" {
                    let count = Int(u32(moov, position + 12))
                    guard position + 16 + count * 4 <= position + size else { throw PreparationFailure.failed }
                    for index in 0..<count {
                        let offset = position + 16 + index * 4
                        let value = UInt64(u32(moov, offset))
                        guard value < insertAt || value <= UInt64(UInt32.max) - delta else { throw PreparationFailure.failed }
                        if value >= insertAt { setU32(&moov, offset, UInt32(value + delta)) }
                    }
                } else if type == "co64" {
                    let count = Int(u32(moov, position + 12))
                    guard position + 16 + count * 8 <= position + size else { throw PreparationFailure.failed }
                    for index in 0..<count {
                        let offset = position + 16 + index * 8
                        let value = u64(moov, offset)
                        if value >= insertAt { setU64(&moov, offset, value + delta) }
                    }
                } else if ["trak", "mdia", "minf", "stbl", "edts"].contains(type) {
                    try visit(position + 8, position + size)
                }
                position += size
            }
        }
        try visit(8, moov.count)
    }

    private static func copyBytes(from input: FileHandle, to output: FileHandle, count: UInt64) throws {
        var remaining = count
        while remaining > 0 {
            let length = Int(min(remaining, 1024 * 1024))
            guard let chunk = try input.read(upToCount: length), !chunk.isEmpty else { throw PreparationFailure.failed }
            try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
    }

    private static func u24(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        u24(data, offset) << 8 | UInt32(data[offset + 3])
    }
    private static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(u32(data, offset)) << 32 | UInt64(u32(data, offset + 4))
    }
    private static func setU16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
        data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 0xff)
    }
    private static func setU24(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        data[offset] = UInt8((value >> 16) & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8(value & 0xff)
    }
    private static func setU32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        setU24(&data, offset, value >> 8)
        data[offset + 3] = UInt8(value & 0xff)
    }
    private static func setU64(_ data: inout Data, _ offset: Int, _ value: UInt64) {
        setU32(&data, offset, UInt32(value >> 32))
        setU32(&data, offset + 4, UInt32(value & 0xffff_ffff))
    }

    /// Converted tracks are verified against a completed segment before the
    /// URL is handed off. A copy remux reuses source packets and is validated
    /// by the caller's fixtures.
    @MainActor
    private func verifyStartupSegment(_ segment: String?, of prepared: PreparedMedia, directory: URL,
                                      plan: PreparationPlan, executable: String) async throws {
        guard plan.fragmentedHLS || plan.videoAction == .convert || plan.audioAction == .convert
                || plan.stereoFallback != nil else { return }
        guard let segment else { throw PreparationFailure.failed }
        if plan.stereoFallback != nil {
            let initialization = plan.fragmentedHLS ? "init0.mp4" : "init.mp4"
            let probed = try await probeSegment(segment, directory: directory, fragmented: plan.fragmentedHLS,
                                                executable: executable, initialization: initialization)
            try Self.validateConverted(probed, plan: plan, requireAudio: false)
            try await validateAudioRendition("stream_1.m3u8", initialization: plan.fragmentedHLS ? "init1.mp4" : "init.mp4",
                                             directory: directory, plan: plan, executable: executable, surround: true)
            try await validateAudioRendition("stream_2.m3u8", initialization: plan.fragmentedHLS ? "init2.mp4" : "init.mp4",
                                             directory: directory, plan: plan, executable: executable, surround: false)
            if plan.videoAction == .convert {
                let video = probed.streams.first(where: { $0.codec_type == "video" })
                prepared.recordInspectedVideo(height: video?.height, frameRate: video?.frameRate)
            }
            return
        }
        let video = try await inspectConverted(segment, directory: directory, fragmented: plan.fragmentedHLS,
                                               executable: executable, plan: plan)
        if plan.videoAction == .convert { prepared.recordInspectedVideo(height: video.height, frameRate: video.frameRate) }
    }

    private func validateAudioRendition(_ name: String, initialization: String, directory: URL,
                                        plan: PreparationPlan, executable: String, surround: Bool) async throws {
        let playlist = try HLSPlaylist(directory: directory, name: name, initialization: initialization, followMaster: false)
        guard let segment = playlist.segments.first else { throw PreparationFailure.failed }
        let probed = try await probeSegment(segment, directory: directory, fragmented: plan.fragmentedHLS,
                                            executable: executable, initialization: initialization)
        guard let audio = probed.streams.first(where: { $0.codec_type == "audio" }) else { throw PreparationFailure.failed }
        if surround {
            guard audio.codec_name == plan.audio.codec_name else { throw PreparationFailure.failed }
        } else {
            guard audio.codec_name == "aac", (1...2).contains(audio.channels ?? 0),
                  let rate = Int(audio.sample_rate ?? ""), (1...48000).contains(rate) else { throw PreparationFailure.failed }
        }
    }

    private func inspectConverted(_ segment: String, directory: URL, fragmented: Bool, executable: String,
                                  initialization: String = "init.mp4",
                                  plan: PreparationPlan) async throws -> (height: Int?, frameRate: Double?) {
        let probed = try await probeSegment(segment, directory: directory, fragmented: fragmented,
                                            executable: executable, initialization: initialization)
        try Self.validateConverted(probed, plan: plan)
        let video = probed.streams.first(where: { $0.codec_type == "video" })
        return (video?.height, video?.frameRate)
    }

    private func probeSegment(_ name: String, directory: URL, fragmented: Bool, executable: String,
                              initialization: String = "init.mp4", inspectClocks: Bool = false) async throws -> Probe {
        let inspected = directory.appendingPathComponent(fragmented ? "inspection.mp4" : name)
        defer { if fragmented { try? FileManager.default.removeItem(at: inspected) } }
        if fragmented {
            // A fragment needs its initialization section to be inspected.
            // This private file is never served, even while being written.
            let initURL = directory.appendingPathComponent(initialization)
            let segmentURL = directory.appendingPathComponent(name)
            try Self.joinFragment(initialization: initURL, segment: segmentURL, to: inspected)
            func bytes(_ file: URL) -> Int64? {
                (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
            }
            PreparationTrace.current?.update {
                $0.initializationBytes = bytes(initURL); $0.segmentBytes = bytes(segmentURL); $0.inspectionBytes = bytes(inspected)
                $0.fragmentTracks = try? Self.fragmentTrackSummary(segmentURL)
            }
        }
        return try await probe(inspected, headers: [:], executable: executable, local: true,
                               mpegts: !fragmented, inspectClocks: inspectClocks)
    }

    /// Read only bounded fMP4 box headers and numeric fragment tables. Skip
    /// mdat payloads and all descriptive/container metadata.
    private static func fragmentTrackSummary(_ url: URL) throws -> [PreparationDiagnostics.FragmentTrack] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = Int64(try handle.seekToEnd())
        func number(_ offset: Int64, _ count: Int) throws -> UInt64 {
            guard count <= 8, offset >= 0, offset <= end - Int64(count) else { throw PreparationFailure.failed }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw PreparationFailure.failed }
            return data.reduce(0) { $0 << 8 | UInt64($1) }
        }
        struct Box { let kind: UInt64; let start: Int64; let end: Int64 }
        var budget = 512
        func boxes(_ start: Int64, _ limit: Int64) throws -> [Box] {
            var at = start, result: [Box] = []
            while at < limit {
                guard budget > 0, at <= limit - 8 else { throw PreparationFailure.failed }
                budget -= 1
                var size = try number(at, 4); let kind = try number(at + 4, 4)
                var header: Int64 = 8
                if size == 1 { size = try number(at + 8, 8); header = 16 }
                if size == 0 { size = UInt64(limit - at) }
                guard size >= UInt64(header), size <= UInt64(limit - at) else { throw PreparationFailure.failed }
                result.append(Box(kind: kind, start: at + header, end: at + Int64(size)))
                at += Int64(size)
            }
            return result
        }
        var result: [PreparationDiagnostics.FragmentTrack] = []
        for moof in try boxes(0, end) where moof.kind == 0x6d6f6f66 {
            for traf in try boxes(moof.start, moof.end) where traf.kind == 0x74726166 {
                let children = try boxes(traf.start, traf.end)
                guard let tfhd = children.first(where: { $0.kind == 0x74666864 }), tfhd.end - tfhd.start >= 8 else { continue }
                let id = UInt32(try number(tfhd.start + 4, 4))
                var samples: UInt64 = 0, time: UInt64?
                for box in children {
                    if box.kind == 0x7472756e, box.end - box.start >= 8 { samples += try number(box.start + 4, 4) }
                    if box.kind == 0x74666474, box.end - box.start >= 8 {
                        let version = try number(box.start, 1)
                        time = try number(box.start + 4, version == 1 ? 8 : 4)
                    }
                }
                result.append(.init(id: id, samples: samples, decodeTime: time))
            }
        }
        return result
    }

    /// Bound memory even when copied HEVC has unusually long GOPs/segments.
    private static func joinFragment(initialization: URL, segment: URL, to output: URL) throws {
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw PreparationFailure.failed }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        for url in [initialization, segment] {
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            while let data = try reader.read(upToCount: 64 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                try writer.write(contentsOf: data)
            }
        }
    }

    private struct PreparationPlan {
        let video: Stream
        let audio: Stream
        let audioInput: Int
        let videoAction: TrackAction
        let audioAction: TrackAction
        /// AAC stereo kept beside a copied AC-3/E-AC-3 track so a receiver that
        /// cannot decode Dolby still has audio. The same stream as `audio` when
        /// the fallback is encoded from it; a different stream when the file
        /// already has AAC.
        let stereoFallback: Stream?
        let stereoFallbackAction: TrackAction?
        let enhancement: VideoEnhancement
        var fragmentedHLS: Bool {
            enhancement.targetHeight == 2160 || (videoAction == .copy && video.codec_name == "hevc")
        }
        var path: PlaybackPath {
            if videoAction == .convert { return .videoConversion }
            if audioAction == .convert || stereoFallbackAction == .convert { return .audioConversion }
            return .remux
        }
    }

    /// Chooses the copied tracks first and only falls back to encoding what is
    /// missing. Video encoding requires an explicit `.allowVideo` policy.
    private static func plan(videoInput: Probe, audioInput: Probe, separateAudio: Bool,
                             policy: ConversionPolicy, enhancement: VideoEnhancement,
                             appleProcessing: Bool = false, preserveSurround: Bool = true) throws -> PreparationPlan {
        // A Dolby Vision enhancement layer muxed as its own track (profile 7
        // dual-track files) is never a candidate: it has no base layer of its
        // own and isn't a displayable picture.
        let videoCandidates = videoInput.streams.filter { !$0.isDolbyVisionEnhancementLayerOnly }
        let video = videoCandidates.first(where: { $0.copyableVideo })
            ?? videoCandidates.first(where: { $0.convertibleVideo })
        guard let video else { throw PreparationFailure.unsupported }
        let dolby = audioInput.streams.first(where: { $0.codec_name == "eac3" && $0.copyableDolbyAudio })
            ?? audioInput.streams.first(where: \.copyableDolbyAudio)
        let aac = audioInput.streams.first(where: \.copyableAudio)
        let audio: Stream
        let audioAction: TrackAction
        let stereoFallback: Stream?
        let stereoFallbackAction: TrackAction?
        if preserveSurround, let dolby {
            audio = dolby
            audioAction = .copy
            if let aac, aac.index != dolby.index {
                stereoFallback = aac
                stereoFallbackAction = .copy
            } else {
                // No AAC track to copy. Encode the stereo fallback from the
                // Dolby stream; the surround packets themselves stay copied.
                stereoFallback = dolby
                stereoFallbackAction = .convert
            }
        } else if let aac {
            audio = aac
            audioAction = .copy
            stereoFallback = nil
            stereoFallbackAction = nil
        } else if let convertible = audioInput.streams.first(where: \.convertibleAudio) {
            audio = convertible
            audioAction = .convert
            stereoFallback = nil
            stereoFallbackAction = nil
        } else {
            throw PreparationFailure.unsupported
        }
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
            // picture. Odd input dimensions are valid when enlarged; verify
            // the actual even-sized output below to catch rounding that shrinks.
            guard let width = video.width, let height = video.height,
                  appleProcessing || (width <= maxWidth && height <= maxHeight) else {
                throw PreparationFailure.conversionWouldDownscale
            }
        }
        return PreparationPlan(video: video, audio: audio, audioInput: separateAudio ? 1 : 0,
                               videoAction: videoAction, audioAction: audioAction,
                               stereoFallback: stereoFallback, stereoFallbackAction: stereoFallbackAction,
                               enhancement: enhancement)
    }

    /// Bounded SDR output shared by the preflight and real job. Automatic
    /// conversion stays at or below 1080p H.264; explicit presets target 1080p
    /// H.264 or 4K HEVC. All cap frame rate at 60 and use a two-second GOP.
    private static func videoArguments(stream: Stream, action: TrackAction, encoder: String,
                                       enhancement: VideoEnhancement, hardwareFrames: Bool = false) -> [String] {
        guard action == .convert else {
            guard stream.codec_name == "hevc" else { return ["-c:v", "copy"] }
            var arguments = ["-c:v", "copy", "-tag:v", "hvc1"]
            // A profile 7 single-track file multiplexes its enhancement layer
            // and RPU into this same bitstream as extra NAL units a non-Dolby
            // -Vision-aware receiver can't use; `dovi_split=mode=bl` drops them
            // packet-by-packet, which is still a copy, not a re-encode. It is a
            // no-op (verified byte-for-byte) on a stream that has no such NAL
            // units, so it's safe to leave off outside this specific case.
            if stream.hasMultiplexedDolbyVisionEnhancementLayer {
                arguments += ["-bsf:v", "dovi_split=mode=bl"]
            }
            return arguments
        }
        let fourK = enhancement.targetHeight == 2160
        let bitrate = fourK ? "14000k" : "4000k"
        let buffer = fourK ? "28000k" : "8000k"
        let filter = hardwareFrames ? Self.hardwareScaleFilter(for: stream, enhancement: enhancement)
            : Self.scaleFilter(for: stream, enhancement: enhancement)
        var arguments = ["-c:v", encoder]
        // A software pixel format pulls VideoToolbox frames back to the CPU.
        if !hardwareFrames { arguments += ["-pix_fmt", "yuv420p"] }
        arguments += ["-profile:v", fourK ? "main" : "high",
                      "-b:v", bitrate, "-maxrate", bitrate, "-bufsize", buffer,
                      "-color_range", "tv", "-g", "120", "-keyint_min", "120", "-sc_threshold", "0",
                      "-force_key_frames", "expr:gte(t,n_forced*2)", "-vf", filter]
        if fourK { arguments += ["-tag:v", "hvc1"] }
        else { arguments += ["-level:v", "4.2"] }
        arguments += encoder.hasSuffix("_videotoolbox") ? ["-allow_sw", "0"] : ["-preset", "veryfast"]
        return arguments
    }

    /// Decode and scale stay on the video engine only when no CPU filter is required.
    private static func hardwareFrames(stream: Stream, encoder: String, enhancement: VideoEnhancement) -> Bool {
        HardwareDecode.enabled(encoder: encoder, enhancement: enhancement,
                               frameRate: stream.frameRate, colorRange: stream.color_range)
            && [.upscale1080, .upscale4K].contains(enhancement)
            && ["h264", "hevc"].contains(stream.codec_name ?? "")
            && ["yuv420p", "nv12"].contains(stream.pix_fmt ?? "")
            && (stream.width ?? 1) % 2 == 0 && (stream.height ?? 1) % 2 == 0
    }

    private static func hardwareScaleFilter(for stream: Stream, enhancement: VideoEnhancement) -> String {
        let size = HardwareScale.outputSize(width: stream.width ?? 2, height: stream.height ?? 2, enhancement: enhancement)
        return "scale_vt=w=\(size.width):h=\(size.height)"
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
                                  encoder: String, executable: String, hardwareFrames: Bool = false) async throws -> Bool {
        do {
            _ = try await HelperProcess.run(executable: executable,
                                            arguments: Self.encoderPreflightArguments(stream: stream,
                                                enhancement: enhancement, encoder: encoder, hardwareFrames: hardwareFrames),
                                            timeout: .seconds(30), outputLimit: 4096)
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    private static func encoderPreflightArguments(stream: Stream, enhancement: VideoEnhancement,
                                                  encoder: String, hardwareFrames: Bool = false) -> [String] {
        let width = max(2, min(3840, stream.width ?? 1920))
        let height = max(2, min(2160, stream.height ?? 1080))
        let rate = min(60, max(1, stream.frameRate ?? 30))
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin"]
        if hardwareFrames { arguments += ["-init_hw_device", "videotoolbox=preflightVT", "-filter_hw_device", "preflightVT"] }
        arguments += ["-f", "lavfi",
                         "-i", "color=c=black:s=\(width)x\(height):r=\(rate):d=0.1",
                         "-frames:v", "1"]
        arguments += Self.videoArguments(stream: stream, action: .convert,
                                         encoder: encoder, enhancement: enhancement, hardwareFrames: hardwareFrames)
        if hardwareFrames, let filter = arguments.firstIndex(of: "-vf") {
            arguments[filter + 1] = "format=nv12,hwupload," + arguments[filter + 1]
        }
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
    private static func validateConverted(_ probe: Probe, plan: PreparationPlan,
                                          normalization: AppleInputNormalization? = nil,
                                          requireAudio: Bool = true) throws {
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
            guard let inputWidth = normalization?.width ?? plan.video.width,
                  let inputHeight = normalization?.height ?? plan.video.height,
                  (video.width ?? 0) >= inputWidth, (video.height ?? 0) >= inputHeight else {
                throw PreparationFailure.conversionWouldDownscale
            }
        } else {
            // Video is copied: it must still match the inspected source stream.
            guard video.codec_name == plan.video.codec_name else { throw PreparationFailure.failed }
            // A multiplexed Dolby Vision enhancement layer was stripped via
            // `dovi_split`; the muxed output carries no DOVI configuration
            // record at all once it's gone (verified empirically), so its
            // absence here confirms the filter actually ran.
            if plan.video.hasMultiplexedDolbyVisionEnhancementLayer {
                guard !video.hasMultiplexedDolbyVisionEnhancementLayer else { throw PreparationFailure.failed }
            }
        }
        let audios = probe.streams.filter { $0.codec_type == "audio" }
        if audios.isEmpty {
            guard !requireAudio else { throw PreparationFailure.failed }
            return
        }
        if plan.stereoFallback != nil, audios.count >= 2 {
            guard audios.contains(where: { $0.codec_name == plan.audio.codec_name }),
                  audios.contains(where: { $0.copyableAudio }) else { throw PreparationFailure.failed }
            return
        }
        guard let audio = audios.first else { throw PreparationFailure.failed }
        if plan.stereoFallback != nil, audio.codec_name == plan.audio.codec_name { return }
        if plan.audioAction == .convert || plan.stereoFallbackAction == .convert {
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
                && value.utf8.count <= 4096 && !value.containsControlCharacters
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
                       mpegts: Bool = false, hls: Bool = false, inspectClocks: Bool = false) async throws -> Probe {
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
            "format=duration,size,format_name,start_time:stream=time_base,start_time,index,codec_type,codec_name,has_b_frames,codec_tag_string,pix_fmt,width,height,profile,channels,sample_rate,color_range,color_transfer,color_primaries,color_space,avg_frame_rate,r_frame_rate,field_order,sample_aspect_ratio:stream_disposition=attached_pic:stream_side_data:stream_tags=language,title"
                + (inspectClocks ? ":packet=stream_index,pts,dts" : ""),
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
            let started = ContinuousClock.now
            do {
                return try await HelperProcess.run(executable: executable, arguments: arguments, timeout: timeout)
            } catch {
                guard retry, RemoteFailureRetry.allows(error: error, elapsed: started.duration(to: .now), attempt: attempt) else { throw error }
                attempt += 1
                try await Task.sleep(for: .milliseconds(600 * attempt))
            }
        }
    }

    private struct Probe: Decodable {
        let streams: [Stream]
        let format: Format
        let packets: [Packet]?
        struct Packet: Decodable { let stream_index: Int; let pts: Int64?; let dts: Int64? }
        var videoReorderDelay: Double {
            guard let video = streams.first(where: { $0.codec_type == "video" }),
                  let timeBase = try? RemuxTimeline.timeBase(video.time_base) else { return 0 }
            return (packets ?? []).filter { $0.stream_index == video.index }.reduce(0) { delay, packet in
                guard let pts = packet.pts, let dts = packet.dts else { return delay }
                return max(delay, (Double(pts) - Double(dts)) * timeBase)
            }
        }
        struct Format: Decodable { let duration: String?; let size: String?; let format_name: String?; let start_time: String? }
        var finiteDuration: Double {
            get throws {
                guard let duration = Double(format.duration ?? ""), duration.isFinite, duration > 0 else { throw PreparationFailure.unsupported }
                guard duration <= 4 * 60 * 60 else { throw PreparationFailure.limit }
                return duration
            }
        }
    }
    /// Walk the saved ranking once the probed picture is known. An explicit
    /// backend never reaches here. A picture AI cannot read falls through to
    /// the first traditional model instead of failing the load.
    @MainActor
    private func resolveUpscalerRanking(video: Stream?, targetHeight: Int) throws -> VideoUpscaler.Selection {
        let order = preferences.upscalerRanking
        if let video {
            do {
                let picture = try AppleInputNormalization(stream: video)
                return try VideoUpscaler.select(order: order, pictureWidth: picture.width, pictureHeight: picture.height,
                                                 targetHeight: targetHeight)
            } catch let error as AppFailure where error.message.hasPrefix(AppleInputNormalization.failurePrefix) {
                return try VideoUpscaler.select(order: order, pictureWidth: nil, pictureHeight: nil, targetHeight: targetHeight)
            }
        }
        return try VideoUpscaler.select(order: order, pictureWidth: nil, pictureHeight: nil, targetHeight: targetHeight)
    }

    /// The Apple processors receive upright, square-pixel, limited-range BT.709
    /// frames. FFmpeg performs autorotation and the actual color conversion.
    private struct AppleInputNormalization: Sendable {
        static let failurePrefix = "Apple AI processing: "
        let width: Int
        let height: Int
        let rate: Double
        let colorFilter: String

        init(stream: Stream) throws {
            func unsupported(_ detail: String) -> AppFailure {
                AppFailure(.unsupportedOperation, Self.failurePrefix + detail)
            }
            guard !stream.isHDR else {
                throw unsupported("HDR and Dolby Vision conversion are not supported by the current 8-bit SDR pipeline.")
            }
            guard let w = stream.width, let h = stream.height, w > 0, h > 0,
                  let fps = stream.frameRate, fps.isFinite, fps > 0 else {
                throw unsupported("the source has invalid dimensions or frame rate.")
            }
            guard [nil, "progressive", "unknown"].contains(stream.field_order) else {
                throw unsupported("interlaced video needs deinterlacing before it can be processed.")
            }
            let rotation = (stream.side_data_list ?? []).compactMap(\.rotation).first ?? 0
            guard rotation % 90 == 0 else {
                throw unsupported("this display rotation is not supported; use a multiple of 90 degrees.")
            }
            var sar = 1.0
            if let value = stream.sample_aspect_ratio, !["N/A", "0:1"].contains(value) {
                let parts = value.split(separator: ":").compactMap { Double($0) }
                guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
                    throw unsupported("the source has an invalid pixel aspect ratio.")
                }
                sar = parts[0] / parts[1]
            }
            // Expand one axis to square pixels without discarding source detail.
            // Round upward before passing dimensions to the processor configuration.
            let squareWidth = Double(w) * max(1, sar)
            let squareHeight = Double(h) / min(1, sar)
            guard squareWidth.isFinite, squareHeight.isFinite,
                  squareWidth <= 3840, squareHeight <= 3840 else {
                throw unsupported("square-pixel normalization exceeds the supported output dimensions.")
            }
            let x = Int(ceil(squareWidth / 2)) * 2
            let y = Int(ceil(squareHeight / 2)) * 2
            width = abs(rotation % 180) == 90 ? y : x
            height = abs(rotation % 180) == 90 ? x : y
            rate = min(60, fps) // Same delivery ceiling as ordinary video conversion.

            func known(_ value: String?) -> String? {
                guard let value, !["unknown", "unspecified", ""].contains(value) else { return nil }
                return value
            }
            // VP8's legacy YUV format uses the BT.601 convention (RFC 6386,
            // section 9.2). Missing container tags are normal for WebM. Use a
            // conventional SMPTE 170M interpretation only for its 8-bit 4:2:0
            // layout; explicit metadata always takes precedence.
            let vp8Default = stream.codec_name == "vp8" && stream.pix_fmt == "yuv420p"
                ? "smpte170m" : nil
            guard let transfer = known(stream.color_transfer) ?? vp8Default else {
                throw unsupported("the source is missing color transfer metadata, so its SDR colors cannot be determined reliably. Choose Lanczos with FFmpeg cleanup.")
            }
            let transfers = ["bt709", "smpte170m", "smpte240m", "gamma22", "gamma28", "iec61966-2-1"]
            let matrices = ["bt709", "fcc", "bt470bg", "smpte170m", "smpte240m", "gbr", "ycgco"]
            let primaries = ["bt709", "bt470m", "bt470bg", "smpte170m", "smpte240m", "film", "smpte431", "smpte432", "jedec-p22", "ebu3213"]
            guard transfers.contains(transfer) else {
                throw unsupported("the source color transfer (\(transfer)) is not supported by the SDR pipeline.")
            }
            // Only unambiguous BT.709 can supply missing companion tags. Other
            // SDR transfers need explicit primaries and matrix for a real conversion.
            let taggedMatrix = known(stream.color_space)
            let taggedPrimary = known(stream.color_primaries)
            let infer709 = transfer == "bt709" && [nil, "bt709"].contains(taggedMatrix)
                && [nil, "bt709"].contains(taggedPrimary)
            let matrix = taggedMatrix ?? (infer709 ? "bt709" : vp8Default)
            let primary = taggedPrimary ?? (infer709 ? "bt709" : vp8Default)
            guard let matrix, let primary else {
                throw unsupported("the source is missing color primaries or matrix metadata needed for SDR conversion.")
            }
            guard matrices.contains(matrix), primaries.contains(primary) else {
                throw unsupported("the source color matrix or primaries are not supported by the SDR converter.")
            }
            let range: String
            switch stream.color_range {
            case "pc", "jpeg": range = "pc"
            case "tv", "mpeg": range = "tv"
            case nil, "unknown", "unspecified":
                range = (stream.pix_fmt ?? "").hasPrefix("yuvj") || matrix == "gbr" ? "pc" : "tv"
            default: throw unsupported("the source color range is not supported.")
            }
            colorFilter = "scale=w=ceil(iw/2)*2:h=ceil(ih/2)*2,colorspace=ispace=\(matrix):itrc=\(transfer):iprimaries=\(primary):irange=\(range):all=bt709:range=tv:format=yuv444p"
        }
    }

    private struct Stream: Decodable {
        let start_time: String?
        let index: Int
        let time_base: String?
        let codec_type: String?
        let codec_name: String?
        let has_b_frames: Int?
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
        let field_order: String?
        let sample_aspect_ratio: String?
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
        /// `bl_present_flag`/`el_present_flag`/`dv_bl_signal_compatibility_id`
        /// come from the "DOVI configuration record" side data (the container's
        /// own Dolby Vision signaling, ref. the Dolby ISOBMFF mapping spec) and
        /// are what tells a profile 7 base layer apart from its enhancement
        /// layer; see `isDolbyVisionEnhancementLayerOnly` and
        /// `hasMultiplexedDolbyVisionEnhancementLayer`. `rotation` is the
        /// stream's display rotation side data.
        struct SideData: Decodable {
            let side_data_type: String?
            let dv_profile: Int?
            let bl_present_flag: Int?
            let el_present_flag: Int?
            let dv_bl_signal_compatibility_id: Int?
            let rotation: Int?
        }
        var frameRate: Double? {
            for value in [avg_frame_rate, r_frame_rate] {
                let parts = (value ?? "").split(separator: "/").compactMap { Double($0) }
                if parts.count == 2, parts[1] > 0, parts[0] > 0 { return parts[0] / parts[1] }
            }
            return nil
        }
        var constantFrameRate: Bool {
            guard let actual = frameRate, let value = r_frame_rate else { return false }
            let parts = value.split(separator: "/").compactMap { Double($0) }
            return parts.count == 2 && parts[1] > 0 && abs(parts[0] / parts[1] - actual) < 0.001
        }
        private var encrypted: Bool { codec_tag_string == "encv" || codec_tag_string == "enca" }
        private var attachedPicture: Bool { disposition?.attached_pic == 1 }
        /// The stream's own DOVI configuration record, when ffprobe exposes
        /// one as side data.
        private var dolbyVisionConfig: SideData? {
            (side_data_list ?? []).first { ($0.side_data_type ?? "").lowercased() == "dovi configuration record" }
        }
        /// A Dolby Vision enhancement layer muxed as its own stream (the
        /// second track of a profile 7 dual-track file). It has no base layer
        /// of its own, is not an independently displayable picture, and must
        /// never be picked as the video track, copied or converted.
        var isDolbyVisionEnhancementLayerOnly: Bool {
            guard let config = dolbyVisionConfig else { return false }
            return config.el_present_flag == 1 && config.bl_present_flag != 1
        }
        /// A Dolby Vision base layer whose enhancement layer (and RPU) are
        /// multiplexed into this same stream, as with a profile 7 single-track
        /// file. The base layer underneath is an ordinary, independently
        /// decodable HEVC Main 10 HDR10/HLG picture; only the extra NAL units
        /// need to be dropped before a receiver sees it. When the enhancement
        /// layer instead lives in a separate track (the dual-track case), this
        /// is false and the plain base-layer stream already has nothing to
        /// strip; see `videoArguments`.
        var hasMultiplexedDolbyVisionEnhancementLayer: Bool { dolbyVisionConfig?.el_present_flag == 1 }
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
        /// A Main 10 base layer tagged with a real PQ (HDR10/HDR10+) or HLG
        /// transfer and BT.2020 primaries. This also covers a Dolby Vision
        /// base layer that is independently decodable as HDR10/HLG (profiles
        /// 7 and 8.1/8.2/8.4): the DV RPU and any enhancement layer ride along
        /// as extra, separable NAL units/tracks (stripped via
        /// `hasMultiplexedDolbyVisionEnhancementLayer`/
        /// `isDolbyVisionEnhancementLayerOnly`) and the base layer's own
        /// picture survives an unmodified copy, while a non-backward-compatible
        /// layer (profile 5) reports no standard transfer here and stays
        /// unsupported. Re-encoding this picture would require tone mapping,
        /// which stays out of scope; only an unmodified copy is accepted.
        private var main10HDR: Bool {
            guard codec_name == "hevc", profile == "Main 10", pix_fmt == "yuv420p10le" else { return false }
            if Self.hdrTransfers.contains((color_transfer ?? "").lowercased())
                && (color_primaries ?? "").lowercased() == "bt2020" { return true }
            // dv_bl_signal_compatibility_id of 1 (HDR10) or 4 (HLG) is the DOVI
            // config's own declaration that this base layer is a valid
            // standalone picture of that kind, even if the stream's own
            // transfer/primaries tags are missing or inconsistent (2 is SDR,
            // 0 is "none", i.e. profile 5's non-backward-compatible layer).
            if let id = dolbyVisionConfig?.dv_bl_signal_compatibility_id, [1, 4].contains(id) { return true }
            return false
        }
        var copyableVideo: Bool {
            guard let fps = frameRate, fps.isFinite, fps > 0 else { return false }
            // Apple receivers support Main 10 SDR and HDR10/HLG/compatible
            // Dolby Vision. Copy either into hvc1/fMP4; neither makes a
            // 10-bit input eligible for video conversion.
            let main10SDR = codec_name == "hevc" && profile == "Main 10" && pix_fmt == "yuv420p10le"
                && Self.sdrTransfers.contains((color_transfer ?? "").lowercased())
            let main10 = main10SDR || main10HDR
            let supportedProfile = (codec_name == "h264"
                && ["Constrained Baseline", "Baseline", "Main", "High"].contains(profile ?? ""))
                || (codec_name == "hevc" && profile == "Main") || main10
            return codec_type == "video" && supportedProfile && !encrypted
                && (["yuv420p", "yuvj420p"].contains(pix_fmt ?? "") || main10)
                && (1...3840).contains(width ?? 0) && (1...2160).contains(height ?? 0)
                && (main10HDR || !isHDR) && !attachedPicture && (understoodSDR || main10) && fps <= 60
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
        /// PQ (HDR10/HDR10+/Dolby Vision base layer) and HLG transfer tags.
        /// Both describe an image that a compatible receiver can display
        /// without re-encoding; see `main10HDR`.
        private static let hdrTransfers: Set<String> = ["smpte2084", "arib-std-b67"]
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
        /// Dolby Digital or Dolby Digital Plus, including Atmos carried as
        /// E-AC-3 JOC. Apple's HLS authoring spec accepts both, so the packets
        /// are copied instead of downmixed. 48 kHz is the rate those receivers play.
        var copyableDolbyAudio: Bool {
            codec_type == "audio" && !encrypted && ["ac3", "eac3"].contains(codec_name ?? "")
                && (1...8).contains(channels ?? 0) && Int(sample_rate ?? "") == 48000
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
            "aac", "flac", "opus", "vorbis", "mp3", "mp2", "ac3", "eac3", "alac", "truehd", "dts",
            "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f64le",
            "pcm_u8", "pcm_s16be", "pcm_s24be", "pcm_mulaw", "pcm_alaw",
            "pcm_s16le_planar", "pcm_s24le_planar", "pcm_f32le_planar"
        ]
    }
}

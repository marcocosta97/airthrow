import Foundation

/// Opt-in diagnostic samples. Never encode a complete PlaybackSnapshot: it
/// contains titles, source choices and arbitrary provider/error text.
@MainActor
public final class PlaybackLog {
    public static let preferenceKey = "recordPlaybackLog"
    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/AirThrow/playback.jsonl")
    }

    public let fileURL: URL
    public private(set) var enabled = false
    public var onFailure: (@MainActor () -> Void)?
    private let sink: Sink
    private var lastSample: ContinuousClock.Instant?
    private var lastTransition: Transition?

    public init(fileURL: URL = PlaybackLog.defaultFileURL, maximumBytes: Int = 2 * 1024 * 1024) {
        self.fileURL = fileURL
        sink = Sink(fileURL: fileURL, maximumBytes: max(4096, maximumBytes))
    }

    public func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        lastSample = nil; lastTransition = nil
        submit(Record(event: value ? .started : .stopped))
        if !value { sink.close() }
    }

    public func record(_ snapshot: PlaybackSnapshot, session: UUID) {
        guard enabled else { return }
        let transition = Transition(snapshot, session: session)
        let now = ContinuousClock.now
        guard transition != lastTransition || lastSample.map({ $0.duration(to: now) >= .seconds(1) }) != false else { return }
        lastTransition = transition; lastSample = now
        submit(Record(event: .sample, session: session, values: Values(snapshot)))
    }

    /// Drains queued writes; used by shutdown and local diagnostic checks.
    public func flush() async { await sink.flush() }

    private func submit(_ record: Record) {
        sink.append(record) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.enabled = false
                self.onFailure?()
            }
        }
    }

    private struct Transition: Equatable {
        let session: UUID
        let state: PlaybackState
        let phase: Phase?
        let failure: MediaFailureReason?
        let stage: PreparationDiagnostics.Stage?
        let chunk: Int?
        let seeking: Bool?
        let audio: Int?
        init(_ value: PlaybackSnapshot, session: UUID) {
            self.session = session; state = value.state
            phase = value.loadingPhase.flatMap(Phase.init(rawValue:))
            failure = value.errorReason; stage = value.diagnostics?.preparation?.stage
            chunk = value.diagnostics?.preparation?.chunkIndex; seeking = value.seekInProgress
            audio = value.audioOptions?.firstIndex { $0.id == value.selectedAudioID }
        }
    }

    private enum Phase: String, Encodable { case resolving, preparing, authentication, restoring }
    private enum NativeStatus: String, Encodable { case unknown, ready, failed, paused, playing, waiting }
    private struct Record: Encodable, Sendable {
        enum Event: String, Encodable { case started, sample, stopped }
        let schema = 1
        let timestamp = Date()
        let event: Event
        var session: UUID?
        var values: Values?
    }
    private struct Values: Encodable, Sendable {
        let state: PlaybackState
        let phase: Phase?
        let failure: MediaFailureReason?
        let local: Bool?
        let external: Bool
        let position: Double?
        let duration: Double?
        let live: Bool
        let seekInProgress: Bool?
        let preparationSpeed: Double?
        let preparedRanges: [SeekRange]?
        let bufferedRanges: [SeekRange]?
        let path: PlaybackPath?
        let selectedAudioIndex: Int?
        let itemStatus: NativeStatus?
        let playerStatus: NativeStatus?
        let timeControlStatus: NativeStatus?
        let waitingReason: PlaybackWaitingReason?
        let bufferEmpty: Bool?
        let likelyToKeepUp: Bool?
        let observedBitrate: Double?
        let indicatedBitrate: Double?
        let stalls: Int?
        let videoCodecTypes: [UInt32]?
        let audioCodecTypes: [UInt32]?
        let videoWidth: Int?
        let videoHeight: Int?
        let itemErrorCode: Int?
        let assetErrorCode: Int?
        let errorStatusCodes: [Int]?
        let failureCodes: [Int]?
        // These types contain only fixed enums, booleans and numeric fields.
        let preparation: PreparationDiagnostics?
        let pipeline: LivePipelineDiagnostics?
        let nativeMetrics: NativePlaybackMetrics?
        init(_ value: PlaybackSnapshot) {
            let d = value.diagnostics
            state = value.state; phase = value.loadingPhase.flatMap(Phase.init(rawValue:))
            failure = value.errorReason; local = value.localPlaybackActive; external = value.externalPlaybackActive
            position = value.position; duration = value.duration; live = value.isLive
            seekInProgress = value.seekInProgress; preparationSpeed = value.preparationSpeed
            preparedRanges = value.preparedRanges.map { Array($0.suffix(16)) }
            bufferedRanges = d.map { Array($0.bufferedRanges.suffix(16)) }; path = value.playbackPath
            selectedAudioIndex = value.audioOptions?.firstIndex { $0.id == value.selectedAudioID }
            itemStatus = d?.itemStatus.flatMap(NativeStatus.init(rawValue:))
            playerStatus = d?.playerStatus.flatMap(NativeStatus.init(rawValue:))
            timeControlStatus = d?.timeControlStatus.flatMap(NativeStatus.init(rawValue:))
            waitingReason = d?.waitingReason; bufferEmpty = d?.bufferEmpty; likelyToKeepUp = d?.likelyToKeepUp
            observedBitrate = d?.observedBitrate; indicatedBitrate = d?.indicatedBitrate; stalls = d?.stalls
            videoCodecTypes = d?.videoCodecTypes.map { Array($0.prefix(16)) }
            audioCodecTypes = d?.audioCodecTypes.map { Array($0.prefix(16)) }
            videoWidth = d?.videoWidth; videoHeight = d?.videoHeight
            itemErrorCode = d?.itemErrorCode; assetErrorCode = d?.assetErrorCode
            errorStatusCodes = d?.errorStatusCodes.map { Array($0.suffix(16)) }
            failureCodes = d?.failureErrors.map { Array($0.suffix(16)).map(\.code) }
            var preparation = d?.preparation
            let tracks = preparation?.fragmentTracks.map { Array($0.prefix(32)) }
            preparation?.fragmentTracks = tracks
            self.preparation = preparation; pipeline = d?.livePipeline; nativeMetrics = d?.nativeMetrics
        }
    }

    /// All disk work stays on this serial queue, away from the playback thread.
    private final class Sink: @unchecked Sendable {
        let fileURL: URL
        let maximumBytes: Int
        let queue = DispatchQueue(label: "it.mcosta.airthrow.playback-log", qos: .utility)
        private var handle: FileHandle?
        private var size: UInt64 = 0
        private var failed = false
        init(fileURL: URL, maximumBytes: Int) { self.fileURL = fileURL; self.maximumBytes = maximumBytes }
        func append(_ record: Record, failure: @escaping @Sendable () -> Void) {
            queue.async {
                do {
                    if record.event == .started { self.failed = false }
                    guard !self.failed else { return }
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
                    var data = try encoder.encode(record); data.append(10)
                    guard data.count <= self.maximumBytes else { return }
                    try self.open()
                    if self.size + UInt64(data.count) > UInt64(self.maximumBytes) {
                        try self.handle?.close(); self.handle = nil
                        let previous = self.fileURL.deletingLastPathComponent().appendingPathComponent("playback-previous.jsonl")
                        if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                        try FileManager.default.moveItem(at: self.fileURL, to: previous)
                        try self.open()
                    }
                    try self.handle?.write(contentsOf: data)
                    self.size += UInt64(data.count)
                } catch {
                    self.failed = true
                    try? self.handle?.close(); self.handle = nil
                    failure()
                }
            }
        }
        private func open() throws {
            guard handle == nil else { return }
            let manager = FileManager.default
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            if !manager.fileExists(atPath: fileURL.path) {
                guard manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            handle = try FileHandle(forWritingTo: fileURL)
            size = try handle!.seekToEnd()
        }
        func close() { queue.async { try? self.handle?.close(); self.handle = nil } }
        func flush() async {
            await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        }
    }
}

import Foundation

/// End-to-end cost includes fetching, encoding and output validation, but not
/// time waiting behind another chunk. Smooth the samples to avoid reacting to
/// every remote connection's latency.
struct PreparationPacing {
    private(set) var secondsPerMediaSecond: Double?
    private(set) var largestChunkBytes: Int64 = 0
    var canBuildSurplus: Bool { (secondsPerMediaSecond ?? 1) < 1 }

    mutating func record(mediaSeconds: Double, elapsedSeconds: Double, bytes: Int64) {
        guard mediaSeconds > 0, elapsedSeconds.isFinite, elapsedSeconds >= 0 else { return }
        let sample = elapsedSeconds / mediaSeconds
        secondsPerMediaSecond = secondsPerMediaSecond.map { $0 * 0.75 + sample * 0.25 } ?? sample
        largestChunkBytes = max(largestChunkBytes, bytes)
    }
}

/// A finite VOD timeline backed by regenerable, independently decodable chunks.
/// Player requests, rather than an unbounded encoder, drive production. Chunk
/// discontinuities keep independently restarted encoders' timestamps explicit.
@MainActor
final class CachedHLS {
    static let chunkSeconds = 6.0
    let workspace: PreparationWorkspace
    let duration: Double
    let fragmented: Bool
    private let maximumBytes: Int64
    private let windowSeconds: Double
    private let generate: @Sendable (Int, Double, Double, URL) async throws -> (height: Int?, frameRate: Double?)
    private var jobs: [Int: Task<Void, Error>] = [:]
    private var tail: Task<Void, Error>?
    private var prefetch: Task<Void, Never>?
    private var retained: [Int: Date] = [:]
    private var pins: [Int: Int] = [:]
    private var position = 0.0
    private var playing = false
    private(set) var pacing = PreparationPacing()
    // Favor upcoming video while retaining part of the configured window for rewinds.
    private var aheadSeconds: Double { windowSeconds * 0.75 }
    private var behindSeconds: Double { windowSeconds * 0.25 }
    private var productionReserve: Int64 {
        // Fragment inspection can temporarily need a second copy. Keep enough
        // space for a chunk like the largest one observed, including its files.
        let observed = min(maximumBytes / 2, pacing.largestChunkBytes) * 2
        return min(maximumBytes / 2, max(24 * 1024 * 1024, observed))
    }
    private var stopped = false
    private var productionCancelled = false
    var onActivity: ((Bool) -> Void)?
    var onFailure: ((PreparationFailure) -> Void)?
    private(set) var videoHeight: Int?
    private(set) var videoFrameRate: Double?
    private let starts: [Double]
    var count: Int { starts.count }

    init(workspace: PreparationWorkspace, duration: Double, fragmented: Bool,
         preferences: PreparationPreferences, starts: [Double]? = nil,
         generate: @escaping @Sendable (Int, Double, Double, URL) async throws -> (height: Int?, frameRate: Double?)) throws {
        self.workspace = workspace; self.duration = duration; self.fragmented = fragmented
        if let starts {
            guard starts.first == 0, starts.count <= 100_000,
                  starts.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < duration }),
                  zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }) else { throw PreparationFailure.unsupported }
            self.starts = starts
        } else {
            var count = Int(ceil(duration / Self.chunkSeconds))
            // Avoid a final chunk containing only the container's fractional audio tail.
            if count > 1 && duration - Double(count - 1) * Self.chunkSeconds < 0.25 { count -= 1 }
            self.starts = (0..<count).map { Double($0) * Self.chunkSeconds }
        }
        maximumBytes = preferences.maximumBytes; windowSeconds = preferences.windowSeconds
        self.generate = generate
        let target = Int(ceil(max(Self.chunkSeconds, (0..<count).map { length($0) }.max() ?? Self.chunkSeconds)))
        var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n"
        for index in 0..<count {
            if index > 0 { playlist += "#EXT-X-DISCONTINUITY\n" }
            if fragmented { playlist += "#EXT-X-MAP:URI=\"\(initName(index))\"\n" }
            playlist += String(format: "#EXTINF:%.6f,\n", locale: Locale(identifier: "en_US_POSIX"), length(index))
            playlist += segmentName(index) + "\n"
        }
        playlist += "#EXT-X-ENDLIST\n"
        try Data(playlist.utf8).write(to: workspace.directory.appendingPathComponent("media.m3u8"), options: .atomic)
    }

    deinit { prefetch?.cancel(); for job in jobs.values { job.cancel() } }

    private func length(_ index: Int) -> Double {
        (index == count - 1 ? duration : starts[index + 1]) - starts[index]
    }
    private func directory(_ index: Int) -> URL { workspace.directory.appendingPathComponent("chunk\(index)", isDirectory: true) }
    private func segmentName(_ index: Int) -> String { String(format: "segment%06d.%@", index, fragmented ? "m4s" : "ts") }
    private func initName(_ index: Int) -> String { String(format: "init%06d.mp4", index) }

    private func index(for name: String) -> Int? {
        let digits: Substring
        if name.hasPrefix("segment"), name.hasSuffix(fragmented ? ".m4s" : ".ts") {
            digits = name.dropFirst(7).dropLast(fragmented ? 4 : 3)
        } else if fragmented, name.hasPrefix("init"), name.hasSuffix(".mp4") {
            digits = name.dropFirst(4).dropLast(4)
        } else { return nil }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let index = Int(digits), (0..<count).contains(index),
              name == segmentName(index) || name == initName(index) else { return nil }
        return index
    }

    /// The HTTP server holds a pin until its file descriptor has been closed.
    func resource(_ name: String) async throws -> URL {
        guard !stopped else { throw CancellationError() }
        guard let index = index(for: name) else { throw MediaResourceFailure.notFound }
        pins[index, default: 0] += 1
        do {
            try await withTaskCancellationHandler {
                try await ensure(index)
            } onCancel: {
                Task { @MainActor in
                    if self.pins[index] == 1 { self.jobs[index]?.cancel() }
                }
            }
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            retained[index] = Date()
            return directory(index).appendingPathComponent(name)
        } catch {
            unpin(index)
            throw error
        }
    }

    func release(_ resource: URL) {
        if let index = index(for: resource.lastPathComponent) { unpin(index) }
        prune()
    }

    private func unpin(_ index: Int) {
        let count = (pins[index] ?? 1) - 1
        if count > 0 { pins[index] = count } else { pins.removeValue(forKey: index) }
    }

    func warmUp() async throws { try await ensure(0) }

    private func ensure(_ index: Int) async throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        if retained[index] != nil { return }
        guard !productionCancelled else { throw CancellationError() }
        if let job = jobs[index] { try await job.value; return }
        let previous = tail
        let workspace = workspace
        let generate = generate
        let directory = directory(index)
        let start = starts[index]
        let length = length(index)
        let job = Task { [weak self] in
            defer {
                self?.jobs.removeValue(forKey: index)
                self?.onActivity?(!(self?.jobs.isEmpty ?? true))
                self?.schedulePrefetch()
            }
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            guard let self, !self.stopped, !self.productionCancelled else { throw CancellationError() }
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                                 reason: "Preparing requested video")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                // Preserve the lease until the helper has been terminated/reaped.
                self.prune(toBudget: true, reserving: self.productionReserve)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let started = ContinuousClock.now
                let output = try await generate(index, start, length, directory)
                self.videoHeight = output.height; self.videoFrameRate = output.frameRate
                try Task.checkCancellation()
                self.retained[index] = Date()
                let elapsed = started.duration(to: .now).components
                self.pacing.record(mediaSeconds: length,
                                   elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
                                   bytes: try PreparationWorkspace.size(of: directory))
                self.prune(toBudget: true, protecting: index)
                try workspace.checkSize(self.maximumBytes)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                self.retained.removeValue(forKey: index)
                if !(error is CancellationError), !self.stopped {
                    self.productionCancelled = true
                    let failure = (error as? PreparationFailure) ?? .failed
                    self.onFailure?(failure)
                }
                throw error
            }
        }
        jobs[index] = job; tail = job; onActivity?(true)
        try await job.value
    }

    func updatePosition(_ seconds: Double, playing: Bool = false) {
        guard !stopped, !productionCancelled, seconds.isFinite, seconds >= 0 else { return }
        position = min(seconds, duration)
        self.playing = playing
        prune()
        if !playing {
            // A paused player can request its own buffer, but we do not keep
            // filling the configured look-ahead on its behalf.
            prefetch?.cancel()
            for (index, job) in jobs where pins[index] == nil { job.cancel() }
            return
        }
        schedulePrefetch()
    }

    private func schedulePrefetch() {
        guard playing, !stopped, !productionCancelled, jobs.isEmpty, prefetch == nil else { return }
        let first = chunkIndex(at: position)
        // The configured time window is the baseline. A producer that can
        // outrun playback may bank surplus all the way to the byte budget.
        let last = pacing.canBuildSurplus ? count - 1 : chunkIndex(at: position + aheadSeconds)
        guard let next = (first...last).first(where: { retained[$0] == nil }) else { return }
        // Speculation must not evict the buffer it just built to make room for
        // more speculation. HTTP demand can still prune and use the full budget.
        guard (try? workspace.checkSize(maximumBytes - productionReserve)) != nil else { return }
        prefetch = Task { [weak self] in
            guard let self else { return }
            defer { self.prefetch = nil; self.schedulePrefetch() }
            guard !Task.isCancelled, self.playing else { return }
            _ = try? await self.ensure(next)
        }
    }

    private func chunkIndex(at seconds: Double) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= seconds { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    private func prune(toBudget: Bool = false, protecting protected: Int? = nil, reserving reserve: Int64 = 0) {
        let low = max(0, position - behindSeconds)
        let now = Date()
        // Keep recently advertised chunks briefly, including AVPlayer prefetch.
        // Active HTTP clients are pinned regardless of age or playback position.
        for (index, used) in retained where pins[index] == nil && jobs[index] == nil && index != protected {
            let start = starts[index]
            // Keep surplus ahead even if the next timing sample is slower.
            // Discarding it at the old time-window edge would undo prefetch.
            if start + length(index) < low, now.timeIntervalSince(used) >= 15 {
                remove(index)
            }
        }
        if toBudget {
            // Favor the immediate playback window over speculative distant
            // chunks. Played chunks go first, then the farthest future chunks.
            let candidates = retained.keys.sorted { lhs, rhs in
                let leftBehind = starts[lhs] + length(lhs) <= position
                let rightBehind = starts[rhs] + length(rhs) <= position
                if leftBehind != rightBehind { return leftBehind }
                return leftBehind ? starts[lhs] < starts[rhs] : starts[lhs] > starts[rhs]
            }
            for index in candidates
                where pins[index] == nil && jobs[index] == nil && index != protected {
                if (try? workspace.checkSize(maximumBytes - reserve)) != nil { break }
                remove(index)
            }
        }
    }

    private func remove(_ index: Int) {
        try? FileManager.default.removeItem(at: directory(index))
        retained.removeValue(forKey: index)
    }

    func cancelProduction() {
        productionCancelled = true; onFailure = nil
        prefetch?.cancel()
        for job in jobs.values { job.cancel() }
    }
    func stop() { stopped = true; cancelProduction() }
    func waitForJobs() async {
        let pending = Array(jobs.values)
        for job in pending { _ = try? await job.value }
    }
}

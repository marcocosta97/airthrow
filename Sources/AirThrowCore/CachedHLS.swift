import Foundation

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
    private var retained: [Int: Date] = [:]
    private var pins: [Int: Int] = [:]
    private var position = 0.0
    private var stopped = false
    private var productionCancelled = false
    var onActivity: ((Bool) -> Void)?
    var onFailure: ((PreparationFailure) -> Void)?
    private(set) var videoHeight: Int?
    private(set) var videoFrameRate: Double?
    var count: Int {
        let chunks = Int(ceil(duration / Self.chunkSeconds))
        // Container audio can outlast the final video frame by milliseconds.
        // Fold that tail into the last real chunk, rather than making an empty
        // video segment that fails only at the end of a long viewing session.
        return chunks > 1 && duration - Double(chunks - 1) * Self.chunkSeconds < 0.25 ? chunks - 1 : chunks
    }

    init(workspace: PreparationWorkspace, duration: Double, fragmented: Bool,
         preferences: PreparationPreferences,
         generate: @escaping @Sendable (Int, Double, Double, URL) async throws -> (height: Int?, frameRate: Double?)) throws {
        self.workspace = workspace; self.duration = duration; self.fragmented = fragmented
        maximumBytes = preferences.maximumBytes; windowSeconds = preferences.windowSeconds
        self.generate = generate
        let target = Int(ceil(max(Self.chunkSeconds, duration - Double(count - 1) * Self.chunkSeconds)))
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

    deinit { for job in jobs.values { job.cancel() } }

    private func length(_ index: Int) -> Double {
        index == count - 1 ? duration - Double(index) * Self.chunkSeconds : Self.chunkSeconds
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
        let start = Double(index) * Self.chunkSeconds
        let length = length(index)
        let job = Task { [weak self] in
            defer { self?.jobs.removeValue(forKey: index); self?.onActivity?(!(self?.jobs.isEmpty ?? true)) }
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            guard let self, !self.stopped else { throw CancellationError() }
            let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                                 reason: "Preparing requested video")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                // Preserve the lease until the helper has been terminated/reaped.
                self.prune(toBudget: true, reserving: min(self.maximumBytes / 2, 24 * 1024 * 1024))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let output = try await generate(index, start, length, directory)
                self.videoHeight = output.height; self.videoFrameRate = output.frameRate
                try Task.checkCancellation()
                self.retained[index] = Date()
                self.prune(toBudget: true, protecting: index)
                try workspace.checkSize(self.maximumBytes)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                self.retained.removeValue(forKey: index)
                if !(error is CancellationError), !self.stopped {
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
        prune()
        if !playing {
            // A paused player can request its own buffer, but we do not keep
            // filling the configured look-ahead on its behalf.
            for (index, job) in jobs where pins[index] == nil { job.cancel() }
            return
        }
        guard jobs.isEmpty else { return }
        let first = min(count - 1, Int(position / Self.chunkSeconds))
        let last = min(count - 1, Int((position + windowSeconds / 2) / Self.chunkSeconds))
        guard let next = (first...last).first(where: { retained[$0] == nil }) else { return }
        Task { [weak self] in _ = try? await self?.ensure(next) }
    }

    private func prune(toBudget: Bool = false, protecting protected: Int? = nil, reserving reserve: Int64 = 0) {
        let low = max(0, position - windowSeconds / 2)
        let high = min(duration, position + windowSeconds / 2)
        let now = Date()
        // Keep recently advertised chunks briefly, including AVPlayer prefetch.
        // Active HTTP clients are pinned regardless of age or playback position.
        for (index, used) in retained where pins[index] == nil && jobs[index] == nil && index != protected {
            let start = Double(index) * Self.chunkSeconds
            if (start + length(index) < low || start > high), now.timeIntervalSince(used) >= 15 {
                remove(index)
            }
        }
        if toBudget {
            for (index, _) in retained.sorted(by: { $0.value < $1.value })
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
        for job in jobs.values { job.cancel() }
    }
    func stop() { stopped = true; cancelProduction() }
    func waitForJobs() async {
        let pending = Array(jobs.values)
        for job in pending { _ = try? await job.value }
    }
}

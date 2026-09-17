import Foundation
import Darwin

public enum PreparationFailure: Error, Sendable {
    case unavailable, unsupported, failed, limit, delivery
    public var reason: MediaFailureReason {
        switch self {
        case .unavailable: .preparerUnavailable
        case .unsupported: .preparationRequired
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
    public private(set) var productionFailure: PreparationFailure?
    public private(set) var isProducing = false
    public var onFailure: (@MainActor (PreparationFailure) -> Void)?
    private var producer: Task<Void, Never>?
    private let server: MediaHTTPServer
    private var workspace: PreparationWorkspace?
    fileprivate init(server: MediaHTTPServer, workspace: PreparationWorkspace, sourceDuration: Double? = nil) {
        self.server = server; self.workspace = workspace; self.sourceDuration = sourceDuration; url = server.url!
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
                guard playlist.complete, playlist.duration >= duration - 0.5,
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

    public func waitForProducer() async { await producer?.value }
    deinit { producer?.cancel() }
    public func stop() {
        onFailure = nil
        server.stop()
        producer?.cancel()
        workspace = nil
    }
}

/// An advisory lease prevents startup cleanup from deleting another active session's files.
private final class PreparationWorkspace: @unchecked Sendable {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("airplayer-prepared-v1", isDirectory: true)
    let directory: URL
    private let lease: Int32
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
    init(directory: URL) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("media.m3u8"))
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#EXTM3U") else { throw PreparationFailure.failed }
        let lines = text.split(separator: "\n").map(String.init)
        let durations = lines.filter { $0.hasPrefix("#EXTINF:") }.compactMap {
            $0.dropFirst(8).split(separator: ",").first.flatMap { Double($0) }
        }
        let segments = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty }
        guard !segments.isEmpty, segments.count == durations.count,
              durations.allSatisfy({ $0.isFinite && $0 > 0 }),
              segments.allSatisfy({ name in
                  MediaHTTPServer.isSegmentName(name)
                      && ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size]
                           as? NSNumber)?.int64Value ?? 0) > 0
              }) else { throw PreparationFailure.failed }
        duration = durations.reduce(0, +)
        count = segments.count
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

    public func prepare(_ source: ResolvedSource, mode: PreparationMode? = nil) async throws -> PreparedMedia {
        let mode = mode ?? (environment["AIRPLAYER_PREPARATION_MODE"] == "complete-file" ? .completeFile : .progressiveHLS)
        let finder = HelperExecutables(environment: environment)
        guard let ffmpeg = finder.executable("ffmpeg", override: "AIRPLAYER_FFMPEG"),
              let ffprobe = finder.executable("ffprobe", override: "AIRPLAYER_FFPROBE") else {
            throw PreparationFailure.unavailable
        }
        try Task.checkCancellation()
        // Resolve a LAN address before downloading. Loopback requires an explicit test override.
        let host = try environment["AIRPLAYER_MEDIA_HOST"] ?? MediaHTTPServer.localAddress()
        do {
            let videoInput = try await probe(source.url, headers: source.headers, executable: ffprobe)
            let audioInput: Probe
            if let audio = source.audio {
                audioInput = try await probe(audio.url, headers: audio.headers, executable: ffprobe)
            } else { audioInput = videoInput }
            guard let video = videoInput.streams.first(where: { $0.compatibleVideo }),
                  let audio = audioInput.streams.first(where: { $0.compatibleAudio }) else {
                throw PreparationFailure.unsupported
            }
            let videoDuration = try videoInput.finiteDuration
            let audioDuration = try audioInput.finiteDuration
            guard abs(videoDuration - audioDuration) <= 2 else { throw PreparationFailure.unsupported }
            let videoBytes = Int64(videoInput.format.size ?? "") ?? 0
            let audioBytes = source.audio == nil ? 0 : (Int64(audioInput.format.size ?? "") ?? 0)
            // MPEG-TS packetization and per-segment tables add overhead the source
            // container did not have. Reserve headroom so a source admitted here
            // still fits under the same prepared-media cap during progressive output.
            let sourceLimit = mode == .progressiveHLS ? maximumBytes - maximumBytes / 10 : maximumBytes
            guard videoBytes >= 0, audioBytes >= 0, videoBytes < sourceLimit, audioBytes < sourceLimit,
                  videoBytes + audioBytes < sourceLimit else { throw PreparationFailure.limit }
            let workspace = try PreparationWorkspace()
            let space = try FileManager.default.attributesOfFileSystem(forPath: workspace.directory.path)
            guard let free = (space[.systemFreeSize] as? NSNumber)?.int64Value,
                  free > maximumBytes + 64 * 1024 * 1024 else { throw PreparationFailure.limit }
            let output = workspace.directory.appendingPathComponent("media.mp4")
            var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n"]
                + (try Self.inputOptions(headers: source.headers)) + ["-i", source.url.absoluteString]
            if let audio = source.audio {
                arguments += try Self.inputOptions(headers: audio.headers) + ["-i", audio.url.absoluteString]
            }
            arguments += ["-map", "0:\(video.index)", "-map", "\(source.audio == nil ? 0 : 1):\(audio.index)",
                          "-c", "copy", "-map_metadata", "-1", "-map_chapters", "-1", "-sn", "-dn"]
            if mode == .progressiveHLS {
                do {
                    return try await progressive(workspace: workspace, arguments: arguments, executable: ffmpeg,
                                                 host: host, duration: videoDuration)
                } catch ProgressiveStartup.useCompleteFile {
                    // No URL has reached the player. A bounded startup failure can
                    // safely use the existing complete-file path once.
                    try Task.checkCancellation()
                }
            }
            arguments += ["-movflags", "+faststart", "-fs", String(maximumBytes), "-f", "mp4", output.path]
            _ = try await HelperProcess.run(executable: ffmpeg, arguments: arguments, timeout: timeout,
                                            outputLimit: 64 * 1024)
            try Task.checkCancellation()
            let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size < maximumBytes else { throw PreparationFailure.limit }
            let verified = try await probe(output, headers: [:], executable: ffprobe, local: true)
            let duration = try verified.finiteDuration
            guard verified.streams.count == 2,
                  verified.streams.contains(where: { $0.compatibleVideo }),
                  verified.streams.contains(where: { $0.compatibleAudio }),
                  duration >= videoDuration - 0.5, duration <= videoDuration + 2 else { throw PreparationFailure.failed }
            let server = try await MediaHTTPServer.start(file: output, host: host)
            do { try Task.checkCancellation() }
            catch { await server.stop(); throw error }
            return await PreparedMedia(server: server, workspace: workspace)
        } catch is CancellationError { throw CancellationError() }
        catch let error as PreparationFailure { throw error }
        catch ResolutionFailure.timedOut { throw PreparationFailure.limit }
        catch { throw PreparationFailure.failed }
    }

    private enum ProgressiveStartup: Error { case useCompleteFile }

    @MainActor
    private func progressive(workspace: PreparationWorkspace, arguments: [String], executable: String,
                             host: String, duration: Double) async throws -> PreparedMedia {
        let playlist = workspace.directory.appendingPathComponent("media.m3u8")
        let arguments = arguments + ["-f", "hls", "-hls_segment_type", "mpegts", "-hls_time", "2",
            "-hls_playlist_type", "event", "-hls_list_size", "0", "-hls_flags", "temp_file",
            "-hls_segment_filename", workspace.directory.appendingPathComponent("segment%06d.ts").path,
            playlist.path]
        let server = try await MediaHTTPServer.start(file: playlist, host: host, hls: true)
        let prepared = PreparedMedia(server: server, workspace: workspace, sourceDuration: duration)
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

    private static func inputOptions(headers: [String: String]) throws -> [String] {
        // Only simple HTTP files are prepared in this slice; playlist/proxy handling is separate work.
        var options = ["-protocol_whitelist", "http,https,tcp,tls", "-format_whitelist", "mov,matroska,webm",
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

    private func probe(_ url: URL, headers: [String: String], executable: String, local: Bool = false) async throws -> Probe {
        if !local { _ = try MediaInput.url(url.absoluteString) }
        let options = local ? ["-protocol_whitelist", "file", "-format_whitelist", "mov"] : try Self.inputOptions(headers: headers)
        let arguments = ["-v", "error"] + options + ["-show_entries",
            "format=duration,size:stream=index,codec_type,codec_name,codec_tag_string,pix_fmt,width,height,profile,channels,sample_rate,color_transfer,avg_frame_rate,r_frame_rate:stream_disposition=attached_pic",
            "-of", "json", "-i", local ? url.path : url.absoluteString]
        let data = try await HelperProcess.run(executable: executable, arguments: arguments)
        return try JSONDecoder().decode(Probe.self, from: data)
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
        let avg_frame_rate: String?
        let r_frame_rate: String?
        let disposition: Disposition?
        struct Disposition: Decodable { let attached_pic: Int? }
        var frameRate: Double? {
            for value in [avg_frame_rate, r_frame_rate] {
                let parts = (value ?? "").split(separator: "/").compactMap { Double($0) }
                if parts.count == 2, parts[1] > 0, parts[0] > 0 { return parts[0] / parts[1] }
            }
            return nil
        }
        var compatibleVideo: Bool {
            guard let fps = frameRate else { return false }
            return codec_type == "video" && codec_name == "h264" && codec_tag_string != "encv"
                && ["yuv420p", "yuvj420p"].contains(pix_fmt ?? "")
                && ["Constrained Baseline", "Baseline", "Main", "High"].contains(profile ?? "")
                && (1...1920).contains(width ?? 0) && (1...1080).contains(height ?? 0)
                && !["smpte2084", "arib-std-b67"].contains(color_transfer ?? "")
                && fps <= 60
                && disposition?.attached_pic != 1
        }
        var compatibleAudio: Bool {
            codec_type == "audio" && codec_name == "aac" && codec_tag_string != "enca" && profile == "LC"
                && (1...2).contains(channels ?? 0) && (1...48000).contains(Int(sample_rate ?? "") ?? 0)
        }
    }
}

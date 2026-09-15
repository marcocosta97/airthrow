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
    private let server: MediaHTTPServer
    private var workspace: PreparationWorkspace?
    fileprivate init(server: MediaHTTPServer, workspace: PreparationWorkspace) {
        self.server = server; self.workspace = workspace; url = server.url!
    }
    public func stop() {
        server.stop()
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

public struct MediaPreparer: Sendable {
    private let environment: [String: String]
    private let maximumBytes: Int64
    private let timeout: Duration
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment; maximumBytes = 2 * 1024 * 1024 * 1024; timeout = .seconds(600)
    }
    init(environment: [String: String], maximumBytes: Int64, timeout: Duration = .seconds(600)) {
        self.environment = environment; self.maximumBytes = maximumBytes; self.timeout = timeout
    }
    public static func cleanAbandonedFiles() { PreparationWorkspace.cleanAbandoned() }

    public func prepare(_ source: ResolvedSource) async throws -> PreparedMedia {
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
            guard videoBytes >= 0, audioBytes >= 0, videoBytes < maximumBytes, audioBytes < maximumBytes,
                  videoBytes + audioBytes < maximumBytes else { throw PreparationFailure.limit }
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
                          "-c", "copy", "-map_metadata", "-1", "-map_chapters", "-1", "-sn", "-dn",
                          "-movflags", "+faststart", "-fs", String(maximumBytes), "-f", "mp4", output.path]
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

import AVFoundation
import Foundation
#if SWIFT_PACKAGE
import AirThrowCore
#endif

/// A silent live interstitial on the session's existing player. It never
/// restarts itself after a receiver disconnect, Stop, or remote dismissal.
@MainActor
final class ReceiverWaitingScreen {
    private let player: AVPlayer
    private let mediaURL: () -> URL?
    private let changed: () -> Void
    private let failed: () -> Void
    private var preparation: Task<Void, Never>?
    private var connectionDeadline: Task<Void, Never>?
    private var observation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var server: MediaHTTPServer?
    private var stream: WaitingScreenStream?
    private var item: AVPlayerItem?
    private var generation = UUID()
    private var connected = false
    private(set) var isActive = false

    init(player: AVPlayer, mediaURL: @escaping () -> URL?,
         changed: @escaping () -> Void, failed: @escaping () -> Void) {
        self.player = player
        self.mediaURL = mediaURL
        self.changed = changed
        self.failed = failed
    }

    func start() {
        guard !isActive else { return }
        stop()
        guard let file = mediaURL() else { failed(); return }
        isActive = true
        let id = generation
        preparation = Task { [weak self] in
            do {
                let stream = try WaitingScreenStream(assets: file)
                let server: MediaHTTPServer
                do { server = try await MediaHTTPServer.start(file: stream.playlist, hls: true) }
                catch { stream.stop(); throw error }
                guard let self, !Task.isCancelled, self.generation == id, self.isActive,
                      let url = server.url else { server.stop(); stream.stop(); return }
                self.stream = stream
                self.server = server
                let item = AVPlayerItem(url: url)
                self.item = item
                self.observation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.itemReady(generation: id) }
                }
                self.endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.generation == id else { return }
                            self.stop()
                            self.changed()
                        }
                    }
                self.player.isMuted = true
                self.player.replaceCurrentItem(with: item)
                self.preparation = nil
                self.changed()
            } catch {
                guard let self, self.generation == id, !Task.isCancelled else { return }
                self.stop()
                self.failed()
                self.changed()
            }
        }
        connectionDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, self.generation == id, !self.connected else { return }
            self.stop()
            self.changed()
        }
        changed()
    }

    private func itemReady(generation id: UUID) {
        guard generation == id, isActive, let item, player.currentItem === item else { return }
        switch item.status {
        case .readyToPlay:
            player.isMuted = true
            player.play()
        case .failed:
            stop()
            failed()
        default: break
        }
        changed()
    }

    /// Called from the controller's player observations. No callback here:
    /// its refresh continues into the ordinary idle state after a disconnect.
    func reconcile() {
        if isActive {
            if player.isExternalPlaybackActive {
                connected = true
                connectionDeadline?.cancel()
                connectionDeadline = nil
            } else if connected {
                stop()
            }
        } else if let item, player.currentItem !== item {
            self.item = nil
            server?.stop()
            server = nil
            stream?.stop(); stream = nil
        }
    }

    func stop(keepingItemForReplacement: Bool = false) {
        generation = UUID()
        isActive = false
        connected = false
        preparation?.cancel(); preparation = nil
        connectionDeadline?.cancel(); connectionDeadline = nil
        observation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        let installed = item != nil && player.currentItem === item
        if installed {
            player.isMuted = true
            player.pause()
            if keepingItemForReplacement { return }
            player.replaceCurrentItem(with: nil)
        }
        item = nil
        server?.stop()
        server = nil
        stream?.stop(); stream = nil
    }
}


/// Reuses pre-encoded still segments as a sliding live HLS stream. The playlist
/// advances with monotonic time; memory, disk use, and encoding cost stay bounded.
@MainActor
final class WaitingScreenStream {
    static let segmentCount = 20
    static let segmentDuration = 6
    let directory: URL
    var playlist: URL { directory.appendingPathComponent("media.m3u8") }
    private let assets: URL
    private var publishing: Task<Void, Never>?

    init(assets: URL, automaticallyAdvance: Bool = true) throws {
        self.assets = assets
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirThrow-waiting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try publish(latest: 5) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        if automaticallyAdvance {
            let start = ProcessInfo.processInfo.systemUptime
            publishing = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(Self.segmentDuration)) }
                    catch { return }
                    guard let self else { return }
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    do { try self.publish(latest: 5 + Int(elapsed) / Self.segmentDuration) }
                    catch { self.stop(); return }
                }
            }
        }
    }

    func publish(latest: Int) throws {
        let first = max(0, latest - 5)
        var text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA-SEQUENCE:\(first)
        #EXT-X-DISCONTINUITY-SEQUENCE:\(max(0, first - 1) / Self.segmentCount)

        """
        for sequence in first...latest {
            let name = String(format: "segment%06d.ts", sequence)
            let target = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: target.path) {
                let source = assets.appendingPathComponent(String(format: "segment%06d.ts", sequence % Self.segmentCount))
                try FileManager.default.copyItem(at: source, to: target)
            }
            if sequence > 0 && sequence % Self.segmentCount == 0 { text += "#EXT-X-DISCONTINUITY\n" }
            text += "#EXTINF:6.000,\n\(name)\n"
        }
        try Data(text.utf8).write(to: playlist, options: .atomic)
        // Keep two extra playlist windows for clients still fetching an old index.
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = file.deletingPathExtension().lastPathComponent
            if file.pathExtension == "ts", let sequence = Int(name.dropFirst(7)), sequence < first - 12 {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    func stop() {
        publishing?.cancel(); publishing = nil
        try? FileManager.default.removeItem(at: directory)
    }

    deinit {
        publishing?.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

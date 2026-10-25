import AirThrowCore
import AVFoundation
import Foundation

@main
@MainActor
struct SuperResolutionChecks {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw AppFailure(.playbackFailed, message) }
    }
    static func main() async {
        do { try await run() }
        catch { print("FAIL AI integration: \(error)"); exit(1) }
    }
    static func run() async throws {
        for backend in VideoUpscaler.allCases {
            guard case .run(let parsed) = try CLIArguments.parse(["enhance", "upscale_1080", backend.rawValue]) else {
                throw AppFailure(.invalidRequest, "Missing parsed enhancement")
            }
            let request = try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(parsed.request))
            try check(request.enhancement == .upscale1080 && request.upscaler == backend, "CLI/backend protocol round trip")
        }
        do {
            _ = try CLIArguments.parse(["enhance", "upscale_1080", "unknown"])
            throw AppFailure(.playbackFailed, "Unknown backend accepted")
        } catch let error as AppFailure { try check(error.code == .invalidRequest, "Unknown backend not rejected") }
        let defaults = UserDefaults(suiteName: "app.airthrow.checks.\(UUID().uuidString)")!
        try check(VideoUpscaler.preferred(defaults) == .automatic && !PreparationPreferences.current(defaults).aiBeforePlayback
                  && PreparationPreferences.current(defaults).noiseReduction == .defaultBackend,
                  "Fresh defaults changed native/direct behavior")
        try check(!VideoUpscaler.automatic.isAI && !VideoUpscaler.lanczos.isAI,
                  "Traditional processing unexpectedly selects an AI backend")
        defaults.set(VideoUpscaler.lanczos.rawValue, forKey: VideoUpscaler.preferenceKey)
        try check(VideoUpscaler.preferred(defaults) == .lanczos, "Saved Lanczos selection was replaced by Automatic")
        try check(VideoUpscaler.ranking(defaults) == [.lanczos, .automatic, .lowLatency, .standard],
                  "A saved backend did not become the first ranking entry")
        defaults.set(["ai_standard", "bogus", "ai_standard", "lanczos"], forKey: VideoUpscaler.rankingKey)
        try check(VideoUpscaler.ranking(defaults) == [.standard, .lanczos, .automatic, .lowLatency],
                  "Ranking did not drop unknown entries and append missing models")
        try check(VideoUpscaler.preferred(defaults) == .standard, "Ranking did not outrank the legacy single choice")
        VideoUpscaler.saveRanking([.lowLatency, .lanczos], defaults: defaults)
        try check(VideoUpscaler.ranking(defaults) == [.lowLatency, .lanczos, .automatic, .standard]
                  && VideoUpscaler.preferred(defaults) == .lowLatency, "Saving a ranking did not keep its order")
        let automaticFirst = try VideoUpscaler.select(order: VideoUpscaler.defaultRanking, pictureWidth: 1001,
                                                       pictureHeight: 720, targetHeight: 1080)
        try check(automaticFirst.backend == .automatic && automaticFirst.fellBackFrom == nil,
                  "Automatic did not stay first when a later model cannot read the picture")
        let unreadable = try VideoUpscaler.select(order: [.lowLatency, .standard, .automatic], pictureWidth: nil,
                                                   pictureHeight: nil, targetHeight: 1080)
        let runnableAI = [VideoUpscaler.lowLatency, .standard].filter { SuperResolutionSupport.unavailableReason($0) == nil }
        if let firstAI = runnableAI.first {
            try check(unreadable.backend == .automatic && unreadable.fellBackFrom == firstAI,
                      "A picture AI cannot read did not fall back from \(String(describing: unreadable.fellBackFrom))")
        } else {
            try check(unreadable.backend == .automatic && unreadable.fellBackFrom == nil,
                      "Architecture-skipped models were reported as a video fallback")
        }
        let odd = try VideoUpscaler.select(order: [.lowLatency, .standard, .automatic], pictureWidth: 1001,
                                            pictureHeight: 720, targetHeight: 1080)
        if runnableAI.isEmpty {
            try check(odd.backend == .automatic && odd.fellBackFrom == nil, "Odd frames used an unavailable AI model")
        } else {
            try check(odd.backend == .automatic && odd.fellBackFrom == runnableAI[0],
                      "Odd frames did not fall back from the first available AI model")
        }
        defaults.removeObject(forKey: VideoUpscaler.rankingKey)
        let fixture = URL(fileURLWithPath: "/tmp/airthrow-synthetic-backend.mp4")
        let ranked = ResolvedSource(url: fixture).withEnhancement(.upscale1080, upscaler: .lowLatency, followsUpscalerRanking: true)
        try check(ranked.followsUpscalerRanking && ranked.withConversionPolicy(.allowVideo).followsUpscalerRanking
                  && ranked.withTransportRemux(isLive: false).followsUpscalerRanking,
                  "Ranking request was dropped while copying a source")
        try check(!ranked.withEnhancement(.upscale1080).followsUpscalerRanking, "A plain enhancement kept the ranking request")
        for backend in VideoUpscaler.allCases {
            var source = ResolvedSource(url: fixture).withEnhancement(.upscale1080, upscaler: backend)
            source.preparationPosition = 12
            for transformed in [source.withConversionPolicy(.allowVideo), source.withTransportRemux(isLive: false),
                                source.withLivePresentation(), source.withPreparationInput(fixture)] {
                try check(transformed.upscaler == backend && transformed.preparationPosition == 12,
                          "Source replacement lost the selected processing backend or preparation position")
            }
        }
        defaults.set(VideoUpscaler.standard.rawValue, forKey: VideoUpscaler.preferenceKey)
        defaults.set(true, forKey: PreparationPreferences.aiBeforePlaybackKey)
        try check(VideoUpscaler.preferred(defaults) == .standard && PreparationPreferences.current(defaults).aiBeforePlayback,
                  "Settings preferences not read")
        defaults.set(CleanupNoiseReduction.appleTemporal.rawValue, forKey: PreparationPreferences.noiseReductionKey)
        let snapshot = PreparationPreferences.current(defaults)
        try check(snapshot.noiseReduction == .appleTemporal, "Cleanup preference not read")
        defaults.set("unknown", forKey: PreparationPreferences.noiseReductionKey)
        try check(PreparationPreferences.current(defaults).noiseReduction == .defaultBackend
                  && snapshot.noiseReduction == .appleTemporal, "Invalid cleanup preference or session snapshot changed")
        defaults.removeObject(forKey: PreparationPreferences.noiseReductionKey)
        defaults.removeObject(forKey: VideoUpscaler.preferenceKey)
        defaults.removeObject(forKey: VideoUpscaler.rankingKey)
        defaults.removeObject(forKey: PreparationPreferences.aiBeforePlaybackKey)
        print("PASS backend CLI/protocol and settings defaults")
        guard (2...3).contains(CommandLine.arguments.count) else { return }
        if let reason = SuperResolutionSupport.unavailableReason(.lowLatency) {
            print("SKIP native preparation: \(reason)"); return
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var environment = ProcessInfo.processInfo.environment
        environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func fetch(_ url: URL) async throws -> Data {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            try check([200, 206].contains((response as? HTTPURLResponse)?.statusCode ?? 0), "Delivery response failed")
            return data
        }
        // Standard requires a larger scale than 720p -> 1080p supports. Verify
        // that an actual preparation job walks the preference order and reports
        // the chosen fallback, instead of testing the selector in isolation.
        let rankedSource = ResolvedSource(url: directory.appendingPathComponent("ranking-fallback.mp4"),
            needsDelivery: true, delivery: .file, conversionPolicy: .allowVideo)
            .withEnhancement(.upscale1080, upscaler: .standard, followsUpscalerRanking: true)
        let rankedPrepared = try await MediaPreparer(environment: environment,
            preferences: PreparationPreferences(upscalerRanking: [.standard, .lanczos, .automatic, .lowLatency]))
            .prepare(rankedSource, mode: .completeFile)
        do {
            try check(rankedPrepared.resolvedUpscaler == .lanczos
                      && rankedPrepared.upscalerFellBackFrom == (SuperResolutionSupport.unavailableReason(.standard) == nil ? .standard : nil)
                      && rankedPrepared.videoHeight == 1080,
                      "Preparation lost the ranked fallback or its reported output")
            try await fetch(rankedPrepared.url).write(to: directory.appendingPathComponent("ranked-fallback.mp4"))
        } catch { rankedPrepared.stop(); await rankedPrepared.waitForProducer(); throw error }
        rankedPrepared.stop(); await rankedPrepared.waitForProducer()
        print("PASS ranked AI-to-Lanczos fallback prepares and delivers 1080p")
        let cleanupSource = ResolvedSource(url: directory.appendingPathComponent("short.mp4"), needsDelivery: true, delivery: .file, conversionPolicy: .allowVideo)
            .withEnhancement(.cleanup1080, upscaler: .lanczos)
        let temporalPreferences = PreparationPreferences(noiseReduction: .appleTemporal)
        if let reason = TemporalNoiseFilterSupport.unavailableReason {
            do {
                let unexpected = try await MediaPreparer(environment: environment, preferences: temporalPreferences).prepare(cleanupSource)
                unexpected.stop(); await unexpected.waitForProducer()
                throw AppFailure(.playbackFailed, "Unsupported Apple cleanup silently fell back")
            } catch let failure as AppFailure {
                try check(failure.code == .unsupportedOperation && failure.message == reason,
                          "Unsupported cleanup error was lost")
            }
            print("PASS unsupported temporal cleanup rejected without fallback")
        } else {
            let temporal = try await MediaPreparer(environment: environment, preferences: temporalPreferences).prepare(cleanupSource, mode: .completeFile)
            do {
                try check(temporal.videoHeight == 1080, "Temporal cleanup output lost")
                try await fetch(temporal.url).write(to: directory.appendingPathComponent("temporal-cleanup.mp4"))
            } catch { temporal.stop(); await temporal.waitForProducer(); throw error }
            temporal.stop(); await temporal.waitForProducer()
            print("PASS temporal cleanup with Lanczos (supported host)")
        }
        // A cleanup-only preference must never touch an Original/direct load.
        let original = try await MediaPreparer(environment: environment, preferences: temporalPreferences)
            .prepare(ResolvedSource(url: directory.appendingPathComponent("short.mp4"), needsDelivery: true, delivery: .file, conversionPolicy: .allowVideo))
        try check(original.playbackPath != .videoConversion, "Apple cleanup preference changed Original playback")
        original.stop(); await original.waitForProducer()
        print("PASS Original ignores cleanup preference")
        for backend in [VideoUpscaler.lowLatency, .standard] {
            if let reason = SuperResolutionSupport.unavailableReason(backend) { print("SKIP \(backend): \(reason)"); continue }
            if backend == .standard && !SuperResolutionSupport.standardModelReady { print("SKIP Standard: model not ready; no download requested"); continue }
            for before in [false, true] {
                let file = directory.appendingPathComponent(backend == .standard ? "short.mp4" : "long.mp4")
                let source = ResolvedSource(url: file, needsDelivery: true, delivery: .file, conversionPolicy: .allowVideo)
                    .withEnhancement(.upscale1080, upscaler: backend)
                try check(source.withConversionPolicy(.avoidVideo).upscaler == backend, "Backend lost during policy copy")
                let prepared = try await MediaPreparer(environment: environment,
                    preferences: PreparationPreferences(aiBeforePlayback: before)).prepare(source)
                do {
                    try check(prepared.videoHeight == 1080 && prepared.playbackPath == .videoConversion,
                              "AI output quality/path lost")
                    try check(prepared.usesBoundedCache == !before, "AI preparation setting ignored")
                    if before {
                        let data = try await fetch(prepared.url)
                        try data.write(to: directory.appendingPathComponent("\(backend.rawValue)-complete.mp4"))
                    } else {
                        let text = String(decoding: try await fetch(prepared.url), as: UTF8.self)
                        try check(text.contains("#EXT-X-ENDLIST"), "Missing finite AI timeline")
                        let names = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init)
                        try check(!names.isEmpty, "Missing AI chunks")
                        for (index, name) in names.enumerated() {
                            prepared.updatePlaybackPosition(Double(index) * 6)
                            let data = try await fetch(URL(string: name, relativeTo: prepared.url)!)
                            try data.write(to: directory.appendingPathComponent("\(backend.rawValue)-chunk\(index).ts"))
                        }
                    }
                    let item = AVPlayerItem(url: prepared.url)
                    let player = AVPlayer(playerItem: item)
                    player.isMuted = true
                    let deadline = Date().addingTimeInterval(30)
                    while item.status == .unknown && Date() < deadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    try check(item.status == .readyToPlay, "Native AI item did not become ready")
                    if before {
                        try check(try await !item.asset.loadTracks(withMediaType: .video).isEmpty, "Native video track missing")
                        try check(try await !item.asset.loadTracks(withMediaType: .audio).isEmpty, "Native audio track missing")
                    }
                    player.replaceCurrentItem(with: nil)
                    print("PASS \(backend.rawValue) \(before ? "complete" : "cached") audio/video delivery")
                } catch { prepared.stop(); await prepared.waitForProducer(); throw error }
                prepared.stop(); await prepared.waitForProducer()
            }
        }
        // Real normalization jobs, including complete-file and cached delivery.
        for (name, backend, complete) in [
            ("rotated", VideoUpscaler.lowLatency, true), ("portrait-rotated", .lowLatency, true),
            ("anamorphic", .lowLatency, true), ("narrow-pixels", .lowLatency, true),
            ("fps50", .lowLatency, true), ("fps60", .lowLatency, false),
            ("fps5994", .lowLatency, true), ("fps60", .standard, true),
            ("sdr601", .lowLatency, true), ("sdr601-reference", .lowLatency, true),
            ("partial-color", .lowLatency, true),
            ("vp8-untagged", .lowLatency, true), ("vp8-reference", .lowLatency, true)
        ] {
            if SuperResolutionSupport.unavailableReason(backend) != nil
                || backend == .standard && !SuperResolutionSupport.standardModelReady { continue }
            let source = ResolvedSource(url: directory.appendingPathComponent("\(name).\(name == "vp8-untagged" ? "webm" : "mp4")"), needsDelivery: true, delivery: .file, conversionPolicy: .allowVideo)
                .withEnhancement(.upscale1080, upscaler: backend)
            let prepared = try await MediaPreparer(environment: environment,
                preferences: PreparationPreferences(aiBeforePlayback: complete)).prepare(source)
            do {
                if complete {
                    try await fetch(prepared.url).write(to: directory.appendingPathComponent("normalized-\(name)-\(backend.rawValue).mp4"))
                } else {
                    let text = String(decoding: try await fetch(prepared.url), as: UTF8.self)
                    let name = text.split(separator: "\n").first { !$0.hasPrefix("#") }!
                    try await fetch(URL(string: String(name), relativeTo: prepared.url)!).write(
                        to: directory.appendingPathComponent("normalized-fps60-cached.ts"))
                }
                print("PASS normalized \(name) \(backend.rawValue) \(complete ? "complete" : "cached")")
            } catch { prepared.stop(); await prepared.waitForProducer(); throw error }
            prepared.stop(); await prepared.waitForProducer()
        }
        // Quota and source restrictions fail without producing receiver media.
        let small = ResolvedSource(url: directory.appendingPathComponent("short.mp4"), needsDelivery: true, delivery: .file, conversionPolicy: .allowVideo)
            .withEnhancement(.upscale1080, upscaler: .lowLatency)
        do {
            _ = try await MediaPreparer(environment: environment, preferences: PreparationPreferences(maximumBytes: 1024)).prepare(small)
            throw AppFailure(.playbackFailed, "Tiny quota was ignored")
        } catch let failure as PreparationFailure { try check(failure == .storageLimit, "Quota failure flattened") }
        let invalid = ResolvedSource(url: directory.appendingPathComponent("unknown.mp4"), needsDelivery: true, delivery: .file, conversionPolicy: .allowVideo)
            .withEnhancement(.upscale1080, upscaler: .lowLatency)
        do {
            _ = try await MediaPreparer(environment: environment).prepare(invalid)
            throw AppFailure(.playbackFailed, "Unknown color was accepted for AI")
        } catch let failure as AppFailure { try check(failure.code == .unsupportedOperation && failure.message.contains("missing color transfer metadata"), "Missing color metadata error is not specific") }
        for (name, message) in [("hdr", "HDR and Dolby Vision"), ("interlaced", "interlaced video"),
                                ("ambiguous-color", "missing color primaries or matrix"),
                                ("arbitrary-rotation", "display rotation")] {
            let source = ResolvedSource(url: directory.appendingPathComponent("\(name).mp4"), needsDelivery: true, delivery: .file, conversionPolicy: .allowVideo)
                .withEnhancement(.upscale1080, upscaler: .lowLatency)
            do {
                let unexpected = try await MediaPreparer(environment: environment).prepare(source)
                unexpected.stop(); await unexpected.waitForProducer()
                throw AppFailure(.playbackFailed, "Unsupported \(name) was accepted")
            } catch let failure as AppFailure {
                try check(failure.code == .unsupportedOperation && failure.message.contains(message),
                          "Unsupported \(name) did not report its actual condition")
            }
            print("PASS specific \(name) rejection")
        }
        let job = Task { try await MediaPreparer(environment: environment).prepare(small) }
        job.cancel()
        do { _ = try await job.value; throw AppFailure(.playbackFailed, "Cancelled AI load completed") }
        catch is CancellationError { }
        if SuperResolutionSupport.unavailableReason(.standard) == nil && SuperResolutionSupport.standardModelReady {
            let source = ResolvedSource(url: directory.appendingPathComponent("long.mp4"), needsDelivery: true, delivery: .file, conversionPolicy: .allowVideo)
                .withEnhancement(.upscale1080, upscaler: .standard)
            let running = Task { try await MediaPreparer(environment: environment,
                preferences: PreparationPreferences(aiBeforePlayback: true)).prepare(source) }
            try await Task.sleep(for: .milliseconds(750))
            running.cancel()
            do {
                let prepared = try await running.value
                prepared.stop(); await prepared.waitForProducer()
                throw AppFailure(.playbackFailed, "In-flight AI cancellation was ignored")
            } catch is CancellationError { }
            print("PASS in-flight AI Standard cancellation")
        }
        if CommandLine.arguments.count == 3 {
            let base = CommandLine.arguments[2]
            for name in ["short.mp4", "hls/stream.m3u8"] {
                let source = ResolvedSource(url: URL(string: base + "/" + name)!,
                    audio: name == "short.mp4" ? MediaTrack(url: URL(string: base + "/short.mp4")!) : nil,
                    delivery: name.hasSuffix("m3u8") ? .hls : .file, conversionPolicy: .allowVideo)
                    .withEnhancement(.cleanup1080, upscaler: .lowLatency)
                let prepared = try await MediaPreparer(environment: environment).prepare(source)
                do {
                    try check(!prepared.usesBoundedCache && prepared.videoHeight == 1080,
                              "Non-seekable remote source did not use complete AI preparation")
                    let asset = AVURLAsset(url: prepared.url)
                    try check(try await asset.load(.isPlayable), "Remote AI file not natively playable")
                    try await fetch(prepared.url).write(to: directory.appendingPathComponent(
                        name.hasSuffix("m3u8") ? "remote-hls-complete.mp4" : "paired-audio-complete.mp4"))
                } catch { prepared.stop(); await prepared.waitForProducer(); throw error }
                prepared.stop(); await prepared.waitForProducer()
            }
            print("PASS remote finite HLS, paired audio and cleanup")
        }
        for backend in [VideoUpscaler.lowLatency, .standard] {
            if SuperResolutionSupport.unavailableReason(backend) != nil
                || (backend == .standard && !SuperResolutionSupport.standardModelReady) { continue }
            let source = ResolvedSource(url: directory.appendingPathComponent("short.mp4"), needsDelivery: true, delivery: .file, conversionPolicy: .allowVideo)
                .withEnhancement(.upscale4K, upscaler: backend)
            let prepared: PreparedMedia
            do { prepared = try await MediaPreparer(environment: environment).prepare(source) }
            catch let error as AppFailure where error.code == .unsupportedOperation {
                print("PASS \(backend.rawValue) unsupported 4K combination rejected: \(error.message)"); continue
            }
            do {
                let text = String(decoding: try await fetch(prepared.url), as: UTF8.self)
                try check(text.contains("#EXT-X-MAP"), "HEVC AI cache omitted initialization")
                let initialization = text.components(separatedBy: "URI=\"")[1].components(separatedBy: "\"")[0]
                let segment = text.split(separator: "\n").first { !$0.hasPrefix("#") }!
                let data = try await fetch(URL(string: initialization, relativeTo: prepared.url)!)
                    + fetch(URL(string: String(segment), relativeTo: prepared.url)!)
                try data.write(to: directory.appendingPathComponent("\(backend.rawValue)-4k-fragment.mp4"))
                try check(prepared.videoHeight == 2160, "HEVC AI output is not 4K")
            } catch { prepared.stop(); await prepared.waitForProducer(); throw error }
            prepared.stop(); await prepared.waitForProducer()
            print("PASS \(backend.rawValue) 4K HEVC AI cache and initialization")
        }
        print("PASS AI quota, color rejection and cancellation; receiver untested")
    }
}

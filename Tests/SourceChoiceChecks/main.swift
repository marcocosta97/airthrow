import Foundation
import AVFoundation

// Deterministic candidate resolution for controller checks. No live website,
// helper executable or metadata service is involved; only the loopback fixture
// server is used, so real AVPlayer loading is still exercised.
actor ScriptedResolver {
    struct Response: Sendable {
        let candidates: [MediaCandidate]
        var delay: Duration = .zero
    }

    private var scripts: [String: [Response]]
    private var consumed: [String: Int] = [:]
    private(set) var requests: [URL] = []

    init(_ scripts: [String: [Response]]) { self.scripts = scripts }

    func candidates(for url: URL) async throws -> [MediaCandidate] {
        requests.append(url)
        let key = url.absoluteString
        guard let list = scripts[key], !list.isEmpty else { return [] }
        // Later calls keep returning the final scripted response so a load can be
        // repeated without the harness having to guess how many times it runs.
        let index = min(consumed[key] ?? 0, list.count - 1)
        consumed[key] = index + 1
        let response = list[index]
        if response.delay > .zero {
            // Deliberately finish even when the caller cancels, exercising the
            // controller's generation guard rather than cooperative cancellation.
            await Task.detached { try? await Task.sleep(for: response.delay) }.value
        }
        return response.candidates
    }

    func count() -> Int { requests.count }
}

private func candidate(_ url: URL, title: String, id: String, height: Double,
                       plannedPath: PlaybackPath? = nil) -> MediaCandidate {
    MediaCandidate(source: ResolvedSource(url: url, title: title, delivery: .unknown, plannedPath: plannedPath),
                   id: id, height: height)
}

@main
@MainActor
struct SourceChoiceChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "SourceChoiceChecks", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func failure(_ code: FailureCode, _ body: () throws -> Void) throws {
        do {
            try body()
            throw NSError(domain: "SourceChoiceChecks", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Expected \(code.rawValue) to be thrown"])
        } catch let error as AppFailure {
            try check(error.code == code, "Wrong failure code \(error.code.rawValue): \(error.message)")
        }
    }

    static func settle(_ controller: PlaybackController, states: [PlaybackState] = [.awaitingReceiver],
                       seconds: Double = 25) async throws -> PlaybackSnapshot {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            controller.refresh()
            if states.contains(controller.snapshot.state) {
                // Let observers publish sources and the selected ID before reading.
                try await Task.sleep(for: .milliseconds(50))
                controller.refresh()
                return controller.snapshot
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "SourceChoiceChecks", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(states): \(controller.snapshot)"])
    }

    static func settleQueue(_ controller: PlaybackController, index: Int, seconds: Double = 25) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            controller.refresh()
            if controller.snapshot.queue?.currentIndex == index,
               controller.snapshot.state == .awaitingReceiver {
                try await Task.sleep(for: .milliseconds(50))
                controller.refresh()
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "SourceChoiceChecks", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for queue item \(index): \(controller.snapshot)"])
    }

    static func main() async throws {
        let previousPreference = UserDefaults.standard.object(forKey: "allowVideoConversion")
        defer {
            if let previousPreference { UserDefaults.standard.set(previousPreference, forKey: "allowVideoConversion") }
            else { UserDefaults.standard.removeObject(forKey: "allowVideoConversion") }
        }
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "SourceChoiceChecks", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Expected the fixture base URL and local video path"])
        }
        let base = URL(string: CommandLine.arguments[1])!
        let localVideo = URL(fileURLWithPath: CommandLine.arguments[2])
        let secret = "source-choice-do-not-log"
        let website = URL(string: "https://www.youtube.com/watch?v=BaW_jenozKc")!
        let videoURL = base.appendingPathComponent("video.mp4")
        let audioURL = base.appendingPathComponent("audio.mp4")

        let native720 = candidate(videoURL, title: "Native 720", id: "native-720", height: 720)
        let native1080 = candidate(audioURL, title: "Native 1080", id: "native-1080", height: 1080)
        let remux1080 = candidate(audioURL, title: "Remux 1080", id: "remux-1080", height: 1080, plannedPath: .remux)
        let conversion1080 = candidate(audioURL, title: "Conversion 1080", id: "convert-1080", height: 1080,
                                       plannedPath: .videoConversion)

        // A real in-place delivery session for the preparation path. It avoids a
        // live remux/convert while still giving the controller a genuine
        // PreparedMedia, never a fabricated one.
        let preparer = MediaPreparer(environment: ["AIRPLAYER_MEDIA_HOST": "127.0.0.1"])
        let prepareSource: @Sendable (ResolvedSource) async throws -> PreparedMedia = { _ in
            try await preparer.prepare(ResolvedSource(url: localVideo, title: localVideo.lastPathComponent,
                                                      needsDelivery: true))
        }

        try await automaticPrefersNative(website: website, remux: remux1080, native: native720)
        try await explicitChoiceReResolves(website: website, high: native1080, low: native720)
        try await expiredIDsRejected(website: website, high: native1080, low: native720)
        try await queueResetsOverride(videoURL: videoURL, audioURL: audioURL)
        try await snapshotIsPrivate(base: base, website: website, secret: secret)
        try await conversionToggle(website: website, conversion: conversion1080, native: native720,
                                   prepareSource: prepareSource)
        try await missingCandidateFails(website: website, high: native1080, low: native720)
        try await staleResolutionRejected(website: website, videoURL: videoURL, native: native720)
        try await conversionScope(conversion: conversion1080, native: native720, prepareSource: prepareSource)
        try await collisionOnReResolution(website: website, high: native1080, low: native720)
        try await directLoadMidLoadRejected(videoURL: videoURL, native: native720)
        try await fallbackIdentityJitter(website: website, videoURL: videoURL, audioURL: audioURL)
        print("12/12 source-choice controller checks passed (no physical receiver)")
    }

    // Automatic selection prefers native playback even when a remux candidate
    // advertises higher quality, and both presentations stay published.
    static func automaticPrefersNative(website: URL, remux: MediaCandidate, native: MediaCandidate) async throws {
        let resolver = ScriptedResolver([website.absoluteString: [.init(candidates: [remux, native])]])
        let controller = PlaybackController(resolveCandidates: { try await resolver.candidates(for: $0) },
                                            prepareSource: nil)
        try controller.load(website.absoluteString)
        let status = try await settle(controller)
        try check(status.sources?.count == 2, "Both presentations were not published")
        try check(status.sources?.first?.playbackPath == .remux && status.sources?.first?.quality == "1080p"
                  && status.sources?.first?.unavailableReason == nil, "Higher-quality remux option was misreported")
        try check(status.sources?.last?.playbackPath == .direct && status.sources?.last?.quality == "720p",
                  "Native option was misreported")
        try check(status.title == "Native 720" && status.playbackPath == .direct,
                  "Automatic selection did not prefer native over higher-quality remux")
        try check(status.selectedSourceID == nil, "Automatic selection claimed an explicit choice")
        try check(controller.player.rate == 0 && controller.player.isMuted && controller.player.currentItem != nil,
                  "Automatic native load started playback or produced no item")
        print("PASS automatic selection prefers native over a higher-quality remux candidate")
        await controller.shutdownAndWait()
    }

    // An explicit choice re-resolves candidates at use time, swaps the item on the
    // same paused player and reports the chosen option.
    static func explicitChoiceReResolves(website: URL, high: MediaCandidate, low: MediaCandidate) async throws {
        let resolver = ScriptedResolver([website.absoluteString: [.init(candidates: [high, low])]])
        let controller = PlaybackController(resolveCandidates: { try await resolver.candidates(for: $0) },
                                            prepareSource: nil)
        try controller.load(website.absoluteString)
        let automatic = try await settle(controller)
        try check(automatic.title == "Native 1080", "Higher-quality native candidate was not chosen automatically")
        guard let firstItem = controller.player.currentItem else {
            throw NSError(domain: "SourceChoiceChecks", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Automatic load produced no item"])
        }
        guard let lowOption = automatic.sources?.first(where: { $0.quality == "720p" }) else {
            throw NSError(domain: "SourceChoiceChecks", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Lower-quality option was not published"])
        }
        let sharedPlayer = controller.player
        let callsBefore = await resolver.count()
        try controller.selectSource(lowOption.id)
        try check(controller.player === sharedPlayer, "Explicit choice replaced the shared player")
        try check(controller.player.rate == 0 && controller.player.isMuted,
                  "Explicit choice resumed visible playback")
        let chosen = try await settle(controller)
        try check(await resolver.count() == callsBefore + 1, "Explicit choice reused cached candidates")
        try check(chosen.title == "Native 720", "Explicit choice did not switch to the requested candidate")
        try check(chosen.selectedSourceID == chosen.sources?.first(where: { $0.quality == "720p" })?.id,
                  "Explicit choice was not reported as selected")
        try check(controller.player.currentItem !== firstItem && controller.player === sharedPlayer,
                  "Explicit choice did not swap the item on the shared player")
        try check(controller.player.rate == 0 && controller.player.isMuted, "Explicit choice resumed playback")
        print("PASS explicit source choice re-resolves near use, stays paused and preserves the player")
        await controller.shutdownAndWait()
    }

    // Session-scoped option IDs expire after Stop and after a replacement load.
    static func expiredIDsRejected(website: URL, high: MediaCandidate, low: MediaCandidate) async throws {
        let resolver = ScriptedResolver([website.absoluteString: [.init(candidates: [high, low])]])
        let controller = PlaybackController(resolveCandidates: { try await resolver.candidates(for: $0) },
                                            prepareSource: nil)
        try controller.load(website.absoluteString)
        _ = try await settle(controller)
        guard let stale = controller.snapshot.sources?.first?.id else {
            throw NSError(domain: "SourceChoiceChecks", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "No option to expire"])
        }
        controller.stop()
        try failure(.unsupportedOperation) { try controller.selectSource(stale) }

        try controller.load(website.absoluteString)
        _ = try await settle(controller)
        guard let replaced = controller.snapshot.sources?.first?.id else {
            throw NSError(domain: "SourceChoiceChecks", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "Replacement published no options"])
        }
        try check(replaced != stale, "Replacement reused a session-scoped option ID")
        try controller.load(website.absoluteString)
        _ = try await settle(controller)
        try failure(.invalidRequest) { try controller.selectSource(replaced) }
        print("PASS session-scoped source IDs are rejected after Stop and replacement")
        await controller.shutdownAndWait()
    }

    // A per-item source override must not survive playlist navigation.
    static func queueResetsOverride(videoURL: URL, audioURL: URL) async throws {
        let itemOne = URL(string: "https://www.youtube.com/watch?v=ITEMONE")!
        let itemTwo = URL(string: "https://www.youtube.com/watch?v=ITEMTWO")!
        let oneHigh = candidate(audioURL, title: "Item One 1080", id: "one-1080", height: 1080)
        let oneLow = candidate(videoURL, title: "Item One 720", id: "one-720", height: 720)
        let twoHigh = candidate(audioURL, title: "Item Two 1080", id: "two-1080", height: 1080)
        let twoLow = candidate(videoURL, title: "Item Two 720", id: "two-720", height: 720)
        let resolver = ScriptedResolver([
            itemOne.absoluteString: [.init(candidates: [oneHigh, oneLow])],
            itemTwo.absoluteString: [.init(candidates: [twoHigh, twoLow])]
        ])
        let controller = PlaybackController(
            resolveCandidates: { try await resolver.candidates(for: $0) },
            resolvePlaylist: { _ in
                ResolvedPlaylist(title: "Choice queue", entries: [
                    PlaylistEntry(url: itemOne, title: "Item One"),
                    PlaylistEntry(url: itemTwo, title: "Item Two")
                ], truncated: false)
            }, prepareSource: nil)
        try controller.load("https://www.youtube.com/playlist?list=PLSOURCECHOICES")
        try await settleQueue(controller, index: 0)
        try check(controller.snapshot.title == "Item One 1080", "First item did not select its own candidate")
        guard let low = controller.snapshot.sources?.first(where: { $0.quality == "720p" }) else {
            throw NSError(domain: "SourceChoiceChecks", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "First item published no override option"])
        }
        try controller.selectSource(low.id)
        try await settleQueue(controller, index: 0)
        try check(controller.snapshot.selectedSourceID
                  == controller.snapshot.sources?.first(where: { $0.quality == "720p" })?.id,
                  "Per-item override was not selected")
        try controller.next()
        try await settleQueue(controller, index: 1)
        try check(controller.snapshot.selectedSourceID == nil, "Per-item source override leaked into the next item")
        try check(controller.snapshot.title == "Item Two 1080", "Queue navigation lost the item identity")
        // A choice captured for the previous item must not mutate the current one.
        try failure(.invalidRequest) { try controller.selectSource(low.id) }
        try check(controller.snapshot.queue?.currentIndex == 1 && controller.snapshot.title == "Item Two 1080",
                  "A stale item's source choice mutated the current item")
        try controller.previous()
        try await settleQueue(controller, index: 0)
        try check(controller.snapshot.selectedSourceID == nil, "Override survived returning to an item")
        print("PASS queue navigation resets the per-item source override")
        await controller.shutdownAndWait()
    }

    // The published status must never expose media URLs, headers or provider IDs.
    static func snapshotIsPrivate(base: URL, website: URL, secret: String) async throws {
        let privateURL = URL(string: base.absoluteString + "/video.mp4?token=\(secret)&signature=\(secret)")!
        let privateCandidate = MediaCandidate(
            source: ResolvedSource(url: privateURL, title: "Privacy Native",
                                   headers: ["Authorization": secret], delivery: .unknown),
            id: "provider-format-299", height: 720)
        let resolver = ScriptedResolver([website.absoluteString: [.init(candidates: [privateCandidate])]])
        let controller = PlaybackController(resolveCandidates: { try await resolver.candidates(for: $0) },
                                            prepareSource: nil)
        try controller.load(website.absoluteString)
        let status = try await settle(controller)
        let json = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
        for leaked in [secret, "token", "signature", "Authorization", "provider-format-299", "://", "127.0.0.1"] {
            try check(!json.contains(leaked), "Snapshot leaked \(leaked)")
        }
        try check(status.sources?.first?.id != "provider-format-299",
                  "Opaque option reused the provider identifier")
        print("PASS status serialization omits media URLs, headers and provider identifiers")
        await controller.shutdownAndWait()
    }

    // A video-conversion presentation is refused while conversion is disallowed,
    // then becomes selectable once the preference is toggled.
    static func conversionToggle(website: URL, conversion: MediaCandidate, native: MediaCandidate,
                                 prepareSource: @escaping @Sendable (ResolvedSource) async throws -> PreparedMedia) async throws {
        let resolver = ScriptedResolver([website.absoluteString: [.init(candidates: [conversion, native])]])
        let controller = PlaybackController(resolveCandidates: { try await resolver.candidates(for: $0) },
                                            allowVideoConversion: false, prepareSource: prepareSource)
        try controller.load(website.absoluteString)
        let gated = try await settle(controller)
        try check(gated.title == "Native 720" && gated.playbackPath == .direct && gated.allowVideoConversion == false,
                  "Video conversion preference did not gate automatic selection")
        guard let forbidden = gated.sources?.first(where: { $0.playbackPath == .videoConversion }) else {
            throw NSError(domain: "SourceChoiceChecks", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Conversion option was not published"])
        }
        try check(forbidden.unavailableReason != nil, "Disallowed conversion option was offered")
        try failure(.unsupportedOperation) { try controller.selectSource(forbidden.id) }
        controller.setVideoConversionAllowed(true)
        controller.refresh()
        guard let allowed = controller.snapshot.sources?.first(where: { $0.playbackPath == .videoConversion }) else {
            throw NSError(domain: "SourceChoiceChecks", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "Conversion option disappeared after toggling"])
        }
        try check(controller.snapshot.allowVideoConversion == true && allowed.unavailableReason == nil,
                  "Toggling conversion did not make the option selectable")
        try controller.selectSource(allowed.id)
        let converted = try await settle(controller)
        try check(converted.title == "Conversion 1080", "Allowed conversion candidate was not selected")
        try check(converted.selectedSourceID
                  == converted.sources?.first(where: { $0.playbackPath == .videoConversion })?.id,
                  "Conversion selection was not reported")
        print("PASS video conversion is gated until allowed, then selectable")
        await controller.shutdownAndWait()
    }

    // If a refreshed candidate disappears, an explicit choice must fail rather
    // than silently downgrade to automatic selection.
    static func missingCandidateFails(website: URL, high: MediaCandidate, low: MediaCandidate) async throws {
        let resolver = ScriptedResolver([website.absoluteString: [
            .init(candidates: [high, low]),
            .init(candidates: [low])
        ]])
        let controller = PlaybackController(resolveCandidates: { try await resolver.candidates(for: $0) },
                                            prepareSource: nil)
        try controller.load(website.absoluteString)
        let before = try await settle(controller)
        try check(before.title == "Native 1080", "Automatic selection was wrong before the refresh")
        guard let vanished = before.sources?.first(where: { $0.quality == "1080p" }) else {
            throw NSError(domain: "SourceChoiceChecks", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "No high-quality option to expire"])
        }
        try controller.selectSource(vanished.id)
        let failed = try await settle(controller, states: [.failed])
        try check(failed.error?.contains("no longer available") == true, "Missing refreshed candidate did not explain recovery")
        try check(controller.player.currentItem == nil && failed.playbackPath == nil,
                  "Missing candidate silently chose automatic")
        print("PASS a missing refreshed candidate fails instead of falling back to automatic")
        await controller.shutdownAndWait()
    }

    // A delayed resolver completion must not republish candidates after Stop or a
    // replacement load, even though the work itself was not cancelled.
    static func staleResolutionRejected(website: URL, videoURL: URL, native: MediaCandidate) async throws {
        let stale = candidate(videoURL, title: "Stale 4321", id: "stale-4321", height: 4321)
        let slow: [ScriptedResolver.Response] = [.init(candidates: [stale], delay: .seconds(1))]

        let stopResolver = ScriptedResolver([website.absoluteString: slow])
        let stopped = PlaybackController(resolveCandidates: { try await stopResolver.candidates(for: $0) },
                                         prepareSource: nil)
        try stopped.load(website.absoluteString)
        try await Task.sleep(for: .milliseconds(120))
        stopped.stop()
        try await Task.sleep(for: .milliseconds(1400))
        stopped.refresh()
        try check(stopped.snapshot.state == .idle && stopped.snapshot.sources == nil
                  && stopped.snapshot.selectedSourceID == nil && stopped.player.currentItem == nil,
                  "Stale resolution republished candidates after Stop")
        await stopped.shutdownAndWait()

        let replaceResolver = ScriptedResolver([
            website.absoluteString: slow,
            videoURL.absoluteString: [.init(candidates: [native])]
        ])
        let replaced = PlaybackController(resolveCandidates: { try await replaceResolver.candidates(for: $0) },
                                          prepareSource: nil)
        try replaced.load(website.absoluteString)
        try await Task.sleep(for: .milliseconds(120))
        try replaced.load(videoURL.absoluteString)
        let replacement = try await settle(replaced)
        try check(replacement.sources?.contains(where: { $0.quality == "4321p" }) == false,
                  "Stale resolution republished candidates after replacement")
        try await Task.sleep(for: .milliseconds(1400))
        replaced.refresh()
        try check(replaced.snapshot.title == "Native 720" && replaced.snapshot.sources?.count == 1
                  && replaced.snapshot.sources?.first?.quality == "720p",
                  "Stale resolution mutated the replacement session")
        print("PASS stale resolver completions cannot republish candidates")
        await replaced.shutdownAndWait()
    }

    // The conversion preference is captured per load: it gates the next load but
    // never retroactively switches an item that is already loaded.
    static func conversionScope(conversion: MediaCandidate, native: MediaCandidate,
                                prepareSource: @escaping @Sendable (ResolvedSource) async throws -> PreparedMedia) async throws {
        let convertOnly = URL(string: "https://www.youtube.com/watch?v=CONVERTONE")!
        let nativeOnly = URL(string: "https://www.youtube.com/watch?v=NATIVEONE")!
        let resolver = ScriptedResolver([
            convertOnly.absoluteString: [.init(candidates: [conversion])],
            nativeOnly.absoluteString: [.init(candidates: [native])]
        ])
        let controller = PlaybackController(resolveCandidates: { try await resolver.candidates(for: $0) },
                                            allowVideoConversion: false, prepareSource: prepareSource)
        try controller.load(convertOnly.absoluteString)
        let refused = try await settle(controller, states: [.failed])
        try check(refused.errorReason == .preparationRequired, "Disallowed conversion was not refused before loading")
        controller.setVideoConversionAllowed(true)
        try controller.load(convertOnly.absoluteString)
        let allowed = try await settle(controller)
        try check(allowed.title == "Conversion 1080", "New conversion preference did not apply to the next load")
        try controller.load(nativeOnly.absoluteString)
        _ = try await settle(controller)
        controller.setVideoConversionAllowed(false)
        controller.refresh()
        try check(controller.snapshot.title == "Native 720" && controller.snapshot.playbackPath == .direct
                  && controller.snapshot.allowVideoConversion == false,
                  "Conversion preference retroactively changed the loaded item")
        print("PASS conversion preference applies to the next load, not the current item")
        await controller.shutdownAndWait()
    }

    // A choice that was unique when it was presented must be revalidated against
    // the freshly resolved candidates. A newly duplicated identity fails closed
    // with the dedicated ambiguity message instead of letting the selector guess.
    static func collisionOnReResolution(website: URL, high: MediaCandidate, low: MediaCandidate) async throws {
        let colliding = candidate(low.source.url, title: "Colliding 1080", id: high.id, height: 1080)
        let resolver = ScriptedResolver([website.absoluteString: [
            .init(candidates: [high, low]),
            .init(candidates: [high, colliding])
        ]])
        let controller = PlaybackController(resolveCandidates: { try await resolver.candidates(for: $0) },
                                            prepareSource: nil)
        try controller.load(website.absoluteString)
        let before = try await settle(controller)
        try check(before.title == "Native 1080", "Automatic selection was wrong before the collision")
        guard let chosen = before.sources?.first(where: { $0.quality == "1080p" }) else {
            throw NSError(domain: "SourceChoiceChecks", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "No 1080p option to collide"])
        }
        try controller.selectSource(chosen.id)
        let failed = try await settle(controller, states: [.failed])
        try check(failed.error?.contains("cannot be identified uniquely") == true,
                  "A newly colliding refreshed candidate did not explain the ambiguity")
        try check(controller.player.currentItem == nil && failed.playbackPath == nil,
                  "A newly colliding refreshed candidate silently chose a presentation")
        print("PASS a newly colliding refreshed candidate fails closed with the ambiguity message")
        await controller.shutdownAndWait()
    }

    // A non-website direct load re-resolves without a discovery phase. While that
    // delayed load is in flight another selection must be refused instead of
    // launching a competing load, and the eventual item must stay paused on the
    // same shared player.
    static func directLoadMidLoadRejected(videoURL: URL, native: MediaCandidate) async throws {
        let resolver = ScriptedResolver([videoURL.absoluteString: [
            .init(candidates: [native]),
            .init(candidates: [native], delay: .seconds(1))
        ]])
        let controller = PlaybackController(resolveCandidates: { try await resolver.candidates(for: $0) },
                                            prepareSource: nil)
        try controller.load(videoURL.absoluteString)
        let ready = try await settle(controller)
        guard let option = ready.sources?.first else {
            throw NSError(domain: "SourceChoiceChecks", code: 15,
                          userInfo: [NSLocalizedDescriptionKey: "Direct load published no option"])
        }
        let sharedPlayer = controller.player
        try controller.selectSource(option.id)
        // The chosen load is now resolving with a deliberate delay. Selecting
        // again must be rejected while loading rather than starting a competing
        // load; before the guard covered `loading`, this surfaced as an expired
        // choice instead.
        try failure(.unsupportedOperation) { try controller.selectSource(option.id) }
        try failure(.unsupportedOperation) { try controller.selectSource("automatic") }
        let reloaded = try await settle(controller)
        try check(reloaded.title == "Native 720" && reloaded.playbackPath == .direct,
                  "The delayed direct reload did not settle on the chosen candidate")
        try check(controller.player === sharedPlayer && controller.player.rate == 0
                  && controller.player.isMuted && controller.player.currentItem != nil,
                  "The rejected mid-load selection disturbed the shared paused player")
        print("PASS a direct load cannot be reselected while it is still loading")
        await controller.shutdownAndWait()
    }

    // The fallback identity is hashed from metadata, so a float jitter between
    // resolutions changes it. An explicit choice captured before the jitter must
    // then fail closed rather than selecting a different presentation.
    static func fallbackIdentityJitter(website: URL, videoURL: URL, audioURL: URL) async throws {
        let original = MediaCandidate(source: ResolvedSource(url: videoURL, delivery: .unknown),
                                      height: 720, bitrate: 1000)
        let other = MediaCandidate(source: ResolvedSource(url: audioURL, delivery: .unknown),
                                   height: 1080, bitrate: 2000)
        let jittered = MediaCandidate(source: ResolvedSource(url: videoURL, delivery: .unknown),
                                      height: 720.000_000_1, bitrate: 1000)
        try check(original.id != jittered.id, "Float metadata jitter did not change the fallback identity")
        try check(original.id.hasPrefix("cand-") && original.id != other.id,
                  "The fallback identity was not derived from candidate metadata")
        let resolver = ScriptedResolver([website.absoluteString: [
            .init(candidates: [original, other]),
            .init(candidates: [jittered, other])
        ]])
        let controller = PlaybackController(resolveCandidates: { try await resolver.candidates(for: $0) },
                                            prepareSource: nil)
        try controller.load(website.absoluteString)
        let before = try await settle(controller)
        guard let chosen = before.sources?.first(where: { $0.quality == "720p" }) else {
            throw NSError(domain: "SourceChoiceChecks", code: 16,
                          userInfo: [NSLocalizedDescriptionKey: "No 720p fallback option to refresh"])
        }
        try controller.selectSource(chosen.id)
        let failed = try await settle(controller, states: [.failed])
        try check(failed.error?.contains("no longer available") == true,
                  "A jittered fallback identity did not fail closed")
        try check(controller.player.currentItem == nil,
                  "A jittered fallback identity silently selected another presentation")
        print("PASS a float metadata jitter changes the fallback identity and the refreshed choice fails closed")
        await controller.shutdownAndWait()
    }
}

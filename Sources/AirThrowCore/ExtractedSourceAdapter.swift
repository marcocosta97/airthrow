import Foundation

/// Provider-neutral yt-dlp metadata parsing and bounded media candidates.
enum ExtractedSourceAdapter {
    /// yt-dlp flattens alternate-audio HLS into video-only and audio-only
    /// formats. Their shared master URL can still be a complete presentation.
    static func candidatesWithHLS(_ data: Data,
        fetch: @Sendable (URL) async throws -> Data = HLSMaster.fetch) async throws -> [MediaCandidate] {
        let info = try validatedInfo(data)
        var candidates = try candidates(data)

        // A master is a repeat only when its URL and headers both match, so two
        // masters that share a format signature but differ in request headers are
        // both inspected and left for the selector to disambiguate.
        var seen = Set<String>()
        for format in info.formats ?? [] {
            let headers = (info.http_headers ?? [:]).merging(format.http_headers ?? [:]) { _, rhs in rhs }
            guard format.has_drm != true,
                  ["m3u8", "m3u8_native"].contains(format.protocol ?? ""),
                  format.vcodec == "h264" || format.vcodec?.hasPrefix("avc1") == true,
                  let raw = format.manifest_url, let master = try? MediaInput.url(raw),
                  headers.keys.allSatisfy({ defaultHeaders.contains($0.lowercased()) }),
                  seen.insert(MediaCandidate.signature([master.absoluteString,
                                                        headerSignature(headers)])).inserted else { continue }
            // Bound the total extra work even when an extractor reports many masters.
            if seen.count > 2 { break }
            try Task.checkCancellation()
            do {
                let manifest = try await fetch(master)
                try Task.checkCancellation()
                if let quality = HLSMaster.quality(manifest, at: master) {
                    candidates.append(MediaCandidate(
                        source: ResolvedSource(url: master, title: cleanTitle(info.title),
                                               hlsAudioOptions: HLSMaster.audioOptions(manifest, at: master), delivery: .hls,
                                               videoKnownPresent: true, isLive: info.isIndefiniteLive),
                        id: formatIdentifier(format, role: "hls"),
                        height: quality.height, bitrate: quality.bitrate,
                        audioDescription: audioDescription(format)))
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                // Expired/unavailable/malformed masters must not remove the
                // existing compatible MP4 fallback or expose network error text.
            }
        }
        try Task.checkCancellation()
        if info.isIndefiniteLive,
           !candidates.contains(where: { $0.unavailableReason(for: .allowVideo) == nil }) {
            throw ResolutionFailure.liveUnsupported
        }
        return candidates
    }

    // yt-dlp reports these defaults even for public URLs that need no custom headers.
    // All other headers require a future Mac-side delivery path. No private AVURLAsset options.
    private static let defaultHeaders: Set<String> = ["user-agent", "accept", "accept-language", "sec-fetch-mode"]

    private static func validatedInfo(_ data: Data) throws -> Info {
        let info: Info
        do { info = try JSONDecoder().decode(Info.self, from: data) }
        catch { throw ResolutionFailure.failed }
        guard info._type == nil || info._type == "video", info.entries == nil,
              info.live_status != "is_upcoming",
              info.availability == nil || info.availability == "public" || info.availability == "unlisted" else {
            throw ResolutionFailure.unsupportedPage
        }
        guard info.has_drm != true else { throw ResolutionFailure.protectedMedia }
        return info
    }

    /// Bound extra work: extractors can report dozens of overlapping formats.
    private static let maximumPairedVideos = 8
    private static let maximumAudioLanguages = 4
    private static let maximumDirectCombined = 12
    private static let maximumConversionCombined = 12
    private static let maximumCandidates = 40

    static func candidates(_ data: Data) throws -> [MediaCandidate] {
        let info = try validatedInfo(data)
        guard let formats = info.formats, !formats.isEmpty else { throw ResolutionFailure.failed }
        let title = cleanTitle(info.title)
        let infoHeaders = info.http_headers ?? [:]
        let live = info.isIndefiniteLive
        // Info-level custom request headers would apply to every presentation.
        guard infoHeaders.keys.allSatisfy({ defaultHeaders.contains($0.lowercased()) }) else { return [] }

        func wholePresentation(_ format: Format) -> (url: URL, headers: [String: String])? {
            guard let url = format.url.flatMap({ try? MediaInput.url($0) }) else { return nil }
            return (url, infoHeaders.merging(format.http_headers ?? [:]) { _, rhs in rhs })
        }

        // Each category is ordered by the shared cost-first policy before its
        // bound is applied, so a bounded candidate set never depends on the
        // order in which an extractor reports formats.
        let direct = formats
            .filter(isDirectCombined)
            .compactMap { format -> MediaCandidate? in
                guard let whole = wholePresentation(format) else { return nil }
                return MediaCandidate(
                    source: ResolvedSource(url: whole.url, title: title, headers: whole.headers,
                                           delivery: isHLSContainer(format) ? .hls : .file,
                                           videoKnownPresent: true, isLive: live),
                    id: formatIdentifier(format, role: "direct"),
                    height: format.height, bitrate: format.tbr,
                    frameRate: format.fps,
                    audioDescription: audioDescription(format))
            }
            .sorted(by: costFirst)
            .prefix(maximumDirectCombined)

        // Live presentations use the same processing tiers as finite media;
        // the selector still requires explicit permission for video conversion.
        let conversions = formats
            .filter { !isDirectCombined($0) && isConversionCombined($0)
                && (live || !isHLSContainer($0)) }
            .compactMap { format -> MediaCandidate? in
                guard let whole = wholePresentation(format) else { return nil }
                return MediaCandidate(
                    source: ResolvedSource(url: whole.url, title: title, headers: whole.headers,
                                           needsPreparation: true, delivery: .file,
                                           videoKnownPresent: true, isLive: live, plannedPath: combinedPlan(format)),
                    id: formatIdentifier(format, role: "convert"),
                    height: format.height, bitrate: format.tbr,
                    frameRate: format.fps,
                    audioDescription: audioDescription(format),
                    unavailableReason: preparationLimitReason(format))
            }
            .sorted(by: costFirst)
            .prefix(maximumConversionCombined)

        // Separate video and audio presentations combined into one plan. Actual
        // codecs/profile and stream indices are re-verified by ffprobe. Videos
        // rank by plan cost before resolution so a compatible H.264 remux
        // survives a flood of high-resolution AV1/VP9 conversion videos.
        var pairs: [MediaCandidate] = []
        let videos = formats
            .filter { isSimpleVideoOnly($0) && (live || !isHLSContainer($0)) }
            .sorted(by: videoCostFirst)
            .prefix(maximumPairedVideos)
        var audioByLanguage: [String: [Format]] = [:]
        for format in formats where isSimpleAudioOnly(format) && (live || !isHLSContainer(format)) {
            audioByLanguage[languageKey(format.language), default: []].append(format)
        }
        let languages = audioByLanguage.keys.sorted { left, right in
            languagePriority(left, right, tracks: audioByLanguage)
        }.prefix(maximumAudioLanguages)
        for video in videos {
            guard let videoURL = try? MediaInput.url(video.url ?? "") else { continue }
            let videoHeaders = infoHeaders.merging(video.http_headers ?? [:]) { _, rhs in rhs }
            for key in languages {
                guard let audio = preferredAudio(audioByLanguage[key] ?? []),
                      let audioURL = try? MediaInput.url(audio.url ?? "") else { continue }
                let audioHeaders = infoHeaders.merging(audio.http_headers ?? [:]) { _, rhs in rhs }
                pairs.append(MediaCandidate(
                    source: ResolvedSource(url: videoURL, title: title, headers: videoHeaders,
                                           audio: MediaTrack(url: audioURL, headers: audioHeaders),
                                           needsPreparation: true,
                                           delivery: isHLSContainer(video) || isHLSContainer(audio) ? .hls : .file,
                                           videoKnownPresent: true, isLive: live,
                                           plannedPath: pairedPlan(video, audio: audio)),
                    id: pairIdentifier(video, audio),
                    height: video.height, bitrate: video.tbr,
                    frameRate: video.fps,
                    audioDescription: audioDescription(audio),
                    unavailableReason: preparationLimitReason(video)))
            }
        }

        // Assemble cost-first across every category within the total bound. Only
        // a byte-for-byte repeat of the same presentation, including both header
        // sets, is dropped. A genuine identity collision between different
        // presentations is preserved so the selector refuses an ambiguous
        // explicit choice instead of silently overriding one of them.
        var presentations = Set<String>()
        var result: [MediaCandidate] = []
        for candidate in (Array(direct) + Array(conversions) + pairs).sorted(by: costFirst) {
            guard result.count < maximumCandidates else { break }
            guard presentations.insert(sourceKey(candidate)).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    /// Lower processing tiers rank first, then resolution and bitrate. The
    /// identifier breaks exact ties, so both per-category caps and the total
    /// bound retain the same presentations regardless of extractor order.
    private static func costFirst(_ left: MediaCandidate, _ right: MediaCandidate) -> Bool {
        if (left.unavailableReason == nil) != (right.unavailableReason == nil) {
            return left.unavailableReason == nil
        }
        if MediaSelector.rankedBelow(right, left) { return true }
        if MediaSelector.rankedBelow(left, right) { return false }
        return left.id < right.id
    }

    /// Videos that need a video encode rank below cheaper plans before the
    /// paired-video bound is applied; resolution only breaks ties in a tier.
    private static func videoCostFirst(_ left: Format, _ right: Format) -> Bool {
        if (preparationLimitReason(left) == nil) != (preparationLimitReason(right) == nil) {
            return preparationLimitReason(left) == nil
        }
        let leftTier = needsVideoConversion(left) ? 4 : 2
        let rightTier = needsVideoConversion(right) ? 4 : 2
        if leftTier != rightTier { return leftTier < rightTier }
        if (left.height ?? 0) != (right.height ?? 0) { return (left.height ?? 0) > (right.height ?? 0) }
        if (left.tbr ?? 0) != (right.tbr ?? 0) { return (left.tbr ?? 0) > (right.tbr ?? 0) }
        return formatSignature(left) < formatSignature(right)
    }

    /// Prefer a language that already offers AAC (a remux plan) over one that
    /// would force an audio encode, then order by the cleaned language key.
    private static func languagePriority(_ left: String, _ right: String,
                                         tracks: [String: [Format]]) -> Bool {
        let leftAAC = (tracks[left] ?? []).contains { isAAC(audioCodec($0)) }
        let rightAAC = (tracks[right] ?? []).contains { isAAC(audioCodec($0)) }
        if leftAAC != rightAAC { return leftAAC }
        return left < right
    }

    /// Identical-source key: identity, URLs and both header sets must all match
    /// before a presentation is treated as a repeat. Different headers never
    /// collapse into one candidate.
    private static func sourceKey(_ candidate: MediaCandidate) -> String {
        MediaCandidate.signature([
            candidate.id,
            candidate.source.url.absoluteString,
            candidate.source.audio?.url.absoluteString ?? "",
            headerSignature(candidate.source.headers),
            headerSignature(candidate.source.audio?.headers ?? [:])
        ])
    }

    private static func headerSignature(_ headers: [String: String]) -> String {
        MediaCandidate.signature(headers.sorted { lhs, rhs in
            let leftKey = lhs.key.lowercased(), rightKey = rhs.key.lowercased()
            if leftKey != rightKey { return leftKey < rightKey }
            return lhs.key < rhs.key
        }.flatMap { [$0.key.lowercased(), $0.value] })
    }

    private static func videoCodec(_ format: Format) -> String? {
        guard let codec = format.vcodec?.lowercased(), !codec.isEmpty, codec != "none" else { return nil }
        return codec
    }

    private static func audioCodec(_ format: Format) -> String? {
        guard let codec = format.acodec?.lowercased(), !codec.isEmpty, codec != "none" else { return nil }
        return codec
    }

    private static func isH264(_ format: Format) -> Bool {
        guard let codec = videoCodec(format) else { return false }
        return codec == "h264" || codec.hasPrefix("avc1")
    }

    private static func isHEVC(_ format: Format) -> Bool {
        guard let codec = videoCodec(format) else { return false }
        return codec == "hevc" || codec.hasPrefix("hvc1") || codec.hasPrefix("hev1")
    }

    private static func isAAC(_ codec: String?) -> Bool {
        guard let codec else { return false }
        return codec == "aac" || codec.hasPrefix("mp4a")
    }

    private static func isHLSContainer(_ format: Format) -> Bool {
        ["m3u8", "m3u8_native"].contains(format.protocol ?? "")
    }

    private static func isSimpleHTTP(_ format: Format) -> Bool {
        ["https", "http"].contains(format.protocol ?? "")
    }

    private static func isDemuxable(_ format: Format) -> Bool {
        isHLSContainer(format) || (["mp4", "m4a", "webm", "mkv"].contains(format.ext ?? "")
            && isSimpleHTTP(format))
    }

    private static func headersAreDefault(_ format: Format) -> Bool {
        (format.http_headers ?? [:]).keys.allSatisfy { defaultHeaders.contains($0.lowercased()) }
    }

    /// HDR video cannot be prepared without tone mapping, so it is exposed as a
    /// disabled candidate rather than silently dropped. Prefer the video-specific
    /// fields; a free-form note may mention Dolby audio on an SDR stream.
    private static func isHDR(_ format: Format) -> Bool {
        let videoRange = [format.dynamic_range, format.video_range].compactMap { $0?.lowercased() }
        if videoRange.contains(where: { $0.contains("hdr") || $0.contains("dolby") || $0.contains("hlg") }) {
            return true
        }
        guard let note = format.format_note?.lowercased() else { return false }
        return note.contains("hdr") || note.contains("dolby vision")
    }

    /// A preparation candidate is disabled only when no supported conversion can
    /// rescue it. Resolution and frame rate above the output profile are handled
    /// by downscaling under `.allowVideo`, not rejected here. The input bound is
    /// deliberately conservative until the preparer states its own limits.
    private static func preparationLimitReason(_ format: Format) -> String? {
        if isHDR(format) { return "HDR video is not supported." }
        if let width = format.width, width > 3840 {
            return "Video wider than 4K is not supported for preparation."
        }
        if let height = format.height, height > 2160 {
            return "Video above 4K is not supported for preparation."
        }
        if let fps = format.fps, fps > 120 {
            return "Video above 120 fps is not supported for preparation."
        }
        return nil
    }

    private static func isDirectCombined(_ format: Format) -> Bool {
        format.has_drm != true && (format.fragments == nil || isHLSContainer(format))
            && (format.ext == "mp4" && isSimpleHTTP(format) || isHLSContainer(format))
            && isH264(format) && isAAC(audioCodec(format))
            && format.url.flatMap { try? MediaInput.url($0) } != nil
            && headersAreDefault(format)
    }

    private static func isConversionCombined(_ format: Format) -> Bool {
        format.has_drm != true && (format.fragments == nil || isHLSContainer(format))
            && isDemuxable(format)
            && videoCodec(format) != nil && audioCodec(format) != nil
            && format.url.flatMap { try? MediaInput.url($0) } != nil
            && headersAreDefault(format)
    }

    private static func isSimpleVideoOnly(_ format: Format) -> Bool {
        format.has_drm != true && (format.fragments == nil || isHLSContainer(format))
            && isDemuxable(format)
            && videoCodec(format) != nil && audioCodec(format) == nil
            && format.url.flatMap { try? MediaInput.url($0) } != nil
            && headersAreDefault(format)
    }

    private static func isSimpleAudioOnly(_ format: Format) -> Bool {
        format.has_drm != true && (format.fragments == nil || isHLSContainer(format))
            && isDemuxable(format)
            && videoCodec(format) == nil && audioCodec(format) != nil
            && format.url.flatMap { try? MediaInput.url($0) } != nil
            && headersAreDefault(format)
    }

    /// Video outside the copy profile needs an encode. The preparer separately
    /// refuses a conversion that would reduce either source dimension. Direct
    /// native candidates never pass through preparation.
    private static func needsVideoConversion(_ video: Format) -> Bool {
        if !isH264(video) && !isHEVC(video) { return true }
        if let width = video.width, width > 3840 { return true }
        if let height = video.height, height > 2160 { return true }
        if let fps = video.fps, fps > 60 { return true }
        return false
    }

    private static func combinedPlan(_ format: Format) -> PlaybackPath {
        if needsVideoConversion(format) { return .videoConversion }
        return isAAC(audioCodec(format)) ? .remux : .audioConversion
    }

    private static func pairedPlan(_ video: Format, audio: Format) -> PlaybackPath {
        if needsVideoConversion(video) { return .videoConversion }
        return isAAC(audioCodec(audio)) ? .remux : .audioConversion
    }

    private static func audioBitrate(_ format: Format) -> Double {
        format.abr ?? format.tbr ?? 0
    }

    /// AAC first so receivers avoid an audio encode; otherwise the best track.
    private static func preferredAudio(_ formats: [Format]) -> Format? {
        let aac = formats.filter { isAAC(audioCodec($0)) }
        let pool = aac.isEmpty ? formats : aac
        return pool.max {
            if audioBitrate($0) != audioBitrate($1) { return audioBitrate($0) < audioBitrate($1) }
            return formatSignature($0) < formatSignature($1)
        }
    }

    private static let maximumLanguageLength = 32
    private static let maximumAudioDescriptionLength = 80

    /// Clean a status-visible label: drop control characters, bound its length,
    /// and refuse URL-like values so request detail never reaches status.
    private static func cleanLabel(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        let withoutControl = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(withoutControl)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered.contains("://") || lowered.hasPrefix("http") || lowered.contains("/")
            || lowered.contains("?") || lowered.contains("@") {
            return nil
        }
        return String(trimmed.prefix(maxLength))
    }

    private static func languageKey(_ value: String?) -> String {
        cleanLabel(value, maxLength: maximumLanguageLength) ?? ""
    }

    /// A complete, order-independent metadata signature. It never contains a
    /// media URL, so hashing it yields a stable identity across re-resolution and
    /// format reordering. Distinct presentations that share a signature are kept
    /// and left for the selector to reject as ambiguous.
    private static func formatSignature(_ format: Format) -> String {
        MediaCandidate.signature([
            format.format_id ?? "", videoCodec(format) ?? "", audioCodec(format) ?? "", format.ext ?? "",
            format.protocol ?? "", MediaCandidate.stableNumber(format.width),
            MediaCandidate.stableNumber(format.height), MediaCandidate.stableNumber(format.fps),
            MediaCandidate.stableNumber(format.tbr), MediaCandidate.stableNumber(format.abr),
            format.audio_channels.map { String($0) } ?? "", languageKey(format.language),
            format.dynamic_range ?? "", format.video_range ?? "", format.format_note ?? ""])
    }

    private static func formatIdentifier(_ format: Format, role: String) -> String {
        "\(role)-" + MediaCandidate.stableHash(formatSignature(format))
    }

    private static func pairIdentifier(_ video: Format, _ audio: Format) -> String {
        "pair-" + MediaCandidate.stableHash(
            MediaCandidate.signature([formatSignature(video), formatSignature(audio)]))
    }

    private static func audioDescription(_ format: Format) -> String? {
        var parts: [String] = []
        if let language = cleanLabel(format.language, maxLength: maximumLanguageLength) { parts.append(language) }
        if let codec = audioCodec(format) { parts.append(displayName(for: codec)) }
        if let channels = format.audio_channels, channels > 0 {
            parts.append(channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(min(channels, 32))ch")
        }
        guard !parts.isEmpty else { return nil }
        return cleanLabel(parts.joined(separator: " · "), maxLength: maximumAudioDescriptionLength)
    }

    private static func displayName(for codec: String) -> String {
        if isAAC(codec) { return "AAC" }
        if codec.hasPrefix("opus") { return "Opus" }
        if codec.hasPrefix("flac") { return "FLAC" }
        if codec.hasPrefix("vorbis") { return "Vorbis" }
        if codec.hasPrefix("mp3") { return "MP3" }
        if codec.hasPrefix("eac3") || codec.hasPrefix("ec-3") { return "E-AC-3" }
        if codec.hasPrefix("ac3") || codec.hasPrefix("ac-3") { return "AC-3" }
        let cleaned = MediaCandidate.sanitizedIdentifier(codec).uppercased()
        return String(cleaned.prefix(12))
    }

    static func cleanTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let title = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(200))
    }

    private struct Info: Decodable {
        let _type: String?
        let entries: [Ignored]?
        let formats: [Format]?
        let has_drm: Bool?
        let is_live: Bool?
        let live_status: String?
        let availability: String?
        let http_headers: [String: String]?
        let title: String?
        /// Indefinite live presentations use rolling HLS when preparation is
        /// needed. `was_live` replays are finite on-demand sources.
        var isIndefiniteLive: Bool {
            is_live == true || live_status == "is_live" || live_status == "post_live"
        }
    }
    private struct Ignored: Decodable {}
    private struct Format: Decodable {
        let format_id: String?
        let format_note: String?
        let url: String?
        let manifest_url: String?
        let vcodec: String?
        let acodec: String?
        let ext: String?
        let `protocol`: String?
        let has_drm: Bool?
        let width: Double?
        let height: Double?
        let fps: Double?
        let tbr: Double?
        let abr: Double?
        let audio_channels: Int?
        let language: String?
        let dynamic_range: String?
        let video_range: String?
        let http_headers: [String: String]?
        let fragments: [Ignored]?
    }
}

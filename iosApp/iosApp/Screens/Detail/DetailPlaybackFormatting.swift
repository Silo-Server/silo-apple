import Foundation

enum DetailPlaybackFormatting {
    struct AudioOption: Identifiable, Hashable {
        let ordinal: Int
        let title: String
        let detail: String
        let isSelected: Bool
        var id: Int { ordinal }
    }

    struct SubtitleOption: Identifiable, Hashable {
        let selectionIndex: Int?
        let title: String
        let detail: String
        let isSelected: Bool
        let isSelectable: Bool
        let stableId: String
        var id: String { stableId }
    }

    static func versionShortLabel(_ version: FileVersion?) -> String {
        guard let version else { return "Auto" }
        let tokens = [
            nonEmpty(version.resolution),
            nonEmpty(normalizedVideoCodec(version.codecVideo)),
            dynamicRangeLabel(version),
            nonEmpty(normalizedAudioCodec(version.codecAudio)),
        ].compactMap { $0 }
        return tokens.isEmpty ? "Auto" : tokens.joined(separator: " · ")
    }

    /// Resting-state video summary for the compact tvOS selector segment.
    /// Keep the two facts viewers need at a glance (resolution + HDR family),
    /// while the focused segment expands to ``versionShortLabel(_:)``.
    static func versionCompactLabel(_ version: FileVersion?) -> String {
        guard let version else { return "Auto" }
        let tokens = [
            nonEmpty(version.resolution),
            dynamicRangeLabel(version),
        ].compactMap { $0 }
        return tokens.isEmpty ? "Auto" : tokens.joined(separator: " · ")
    }

    static func versionDetailLabel(_ version: FileVersion) -> String {
        let tokens = [
            nonEmpty(normalizedVideoCodec(version.codecVideo)),
            nonEmpty(version.container)?.uppercased(),
            version.fileSize.map(formatFileSize),
        ].compactMap { $0 }
        return tokens.joined(separator: " · ")
    }

    static func versionPrimaryText(_ version: FileVersion) -> String {
        let tokens = [
            nonEmpty(version.resolution),
            nonEmpty(normalizedVideoCodec(version.codecVideo)),
            dynamicRangeLabel(version),
            nonEmpty(normalizedAudioCodec(version.codecAudio)),
        ].compactMap { $0 }
        if !tokens.isEmpty {
            return tokens.joined(separator: " · ")
        }
        if let fileName = normalizedFileName(version.fileName) {
            return fileName
        }
        return "Version \(version.fileId)"
    }

    static func versionSecondaryText(_ version: FileVersion) -> String? {
        let tokens = [
            nonEmpty(versionDetailLabel(version)),
        ].compactMap { $0 }
        return tokens.isEmpty ? nil : tokens.joined(separator: " · ")
    }

    static func currentEdition(
        versions: [FileVersion],
        currentVersion: FileVersion?
    ) -> PlaybackEditions.Edition? {
        PlaybackEditions.edition(forFileId: currentVersion?.fileId, in: versions)
            ?? PlaybackEditions.editions(from: versions).first
    }

    static func versionSelectorVersions(
        versions: [FileVersion],
        currentVersion: FileVersion?
    ) -> [FileVersion] {
        let editions = PlaybackEditions.editions(from: versions)
        if editions.count > 1,
           let currentEdition = currentEdition(versions: versions, currentVersion: currentVersion) {
            return currentEdition.versions
        }
        return versions
    }

    static func shouldEnableVersionSelector(
        versions: [FileVersion],
        currentVersion: FileVersion?
    ) -> Bool {
        versionSelectorVersions(versions: versions, currentVersion: currentVersion).count > 1
    }

    static func shouldShowAudioValue(version: FileVersion?) -> Bool {
        !(version?.audioTracks ?? []).isEmpty
    }

    static func shouldEnableAudioSelector(version: FileVersion?) -> Bool {
        (version?.audioTracks ?? []).count > 1
    }

    static func shouldShowSubtitleValue(version: FileVersion?) -> Bool {
        !(version?.subtitleTracks ?? []).isEmpty
    }

    static func shouldEnableSubtitleSelector(version: FileVersion?) -> Bool {
        (version?.subtitleTracks ?? []).count > 1
    }

    static func audioOptions(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?
    ) -> [AudioOption] {
        guard let version else { return [] }
        let selectedOrdinal = resolvedAudioOrdinal(
            version: version,
            selectedAudioTrackIndex: selectedAudioTrackIndex
        )
        return (version.audioTracks ?? []).enumerated().map { ordinal, track in
            AudioOption(
                ordinal: ordinal,
                title: audioTitle(track, ordinal: ordinal),
                detail: audioDetail(track, ordinal: ordinal, version: version),
                isSelected: selectedOrdinal == ordinal
            )
        }
    }

    static func resolvedAudioOrdinal(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?
    ) -> Int? {
        guard let version,
              let tracks = version.audioTracks,
              !tracks.isEmpty else {
            return nil
        }
        if let selectedAudioTrackIndex, tracks.indices.contains(selectedAudioTrackIndex) {
            return selectedAudioTrackIndex
        }
        if let effective = version.effectiveAudioTrackIndex, tracks.indices.contains(effective) {
            return effective
        }
        if let defaultIndex = tracks.firstIndex(where: { $0.isDefault == true }) {
            return defaultIndex
        }
        return tracks.startIndex
    }

    static func audioValueLabel(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?,
        annotateAuto: Bool = false
    ) -> String {
        guard let version,
              let ordinal = resolvedAudioOrdinal(
                  version: version,
                  selectedAudioTrackIndex: selectedAudioTrackIndex
              ),
              let track = version.audioTracks?[safe: ordinal] else {
            return "Unknown"
        }
        let summary = audioSummary(track, ordinal: ordinal)
        // With no explicit pick, the shown track is whatever Auto resolved to
        // (preferred/default). Prefix "Auto:" so the row makes clear the
        // choice was automatic rather than user-selected.
        if annotateAuto, selectedAudioTrackIndex == nil {
            return "Auto: \(summary)"
        }
        return summary
    }

    /// Compact codec/layout disclosure for a passive UI readout. Unlike the
    /// interactive selector value, this intentionally omits language and the
    /// "Auto" prefix (for example, "EAC3 5.1").
    static func audioTechnicalSummary(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?
    ) -> String? {
        guard let version,
              let ordinal = resolvedAudioOrdinal(
                  version: version,
                  selectedAudioTrackIndex: selectedAudioTrackIndex
              ),
              let track = version.audioTracks?[safe: ordinal] else {
            return normalizedAudioCodec(version?.codecAudio)
        }
        return [
            normalizedAudioCodec(track.codec) ?? normalizedAudioCodec(version.codecAudio),
            compactAudioLayout(track),
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    /// Language of the track that `audioValueLabel` would display, used to
    /// feed the subtitle auto-resolver (Auto mode hides subs when the audio
    /// is already in the preferred subtitle language).
    static func resolvedAudioLanguage(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?
    ) -> String? {
        guard let version,
              let ordinal = resolvedAudioOrdinal(
                  version: version,
                  selectedAudioTrackIndex: selectedAudioTrackIndex
              ),
              let track = version.audioTracks?[safe: ordinal] else {
            return nil
        }
        return track.language
    }

    static func audioTitle(_ track: AudioTrack, ordinal: Int) -> String {
        if let language = languageDisplayName(track.language) { return language }
        if let title = usefulAudioTitle(track) { return title }
        return "Track \(ordinal + 1)"
    }

    static func audioDetail(_ track: AudioTrack, ordinal: Int, version: FileVersion?) -> String {
        var tokens: [String] = []
        if let title = usefulAudioTitle(track), title != audioTitle(track, ordinal: ordinal) {
            tokens.append(title)
        }
        if let codec = normalizedAudioCodec(track.codec) {
            tokens.append(codec)
        }
        if let layout = compactAudioLayout(track) {
            tokens.append(layout)
        }
        if track.isDefault == true {
            tokens.append("Default")
        }
        if version?.effectiveAudioTrackIndex == ordinal {
            tokens.append("Preferred")
        }
        return tokens.joined(separator: " · ")
    }

    private static func audioSummary(_ track: AudioTrack, ordinal: Int) -> String {
        let tokens = [
            languageDisplayName(track.language),
            nonEmpty(normalizedAudioCodec(track.codec)),
            compactAudioLayout(track),
        ].compactMap { $0 }
        return tokens.isEmpty ? audioTitle(track, ordinal: ordinal) : tokens.joined(separator: " · ")
    }

    /// Resolve the server-remembered subtitle override for display /
    /// launch seeding. Audio gets this for free via the per-version
    /// `effectiveAudioTrackIndex`; subtitles have no index field on the
    /// wire, so the stored signature is re-matched against this
    /// version's track list. Returns the ffmpeg stream index to
    /// pre-select, `-1` for "Off", or nil when nothing points at a
    /// track in this file ("Auto" — the player's resolver decides).
    static func serverPreferredSubtitleIndex(
        version: FileVersion?,
        signature: SubtitleTrackSignature?,
        mode: String?
    ) -> Int? {
        if let signature,
           let tracks = version?.subtitleTracks,
           let match = bestSignatureMatch(signature, in: tracks) {
            return match.selectionIndex
        }
        if SubtitleMode(rawValue: mode ?? "") == .off {
            return -1
        }
        return nil
    }

    /// A server-remembered track is useful for reflecting the server policy
    /// in the pre-play selector, but it is not a manual choice made during
    /// this visit. Device-settings mode must start on Apple's caption policy
    /// instead of forwarding that seed as an explicit player override.
    static func launchPreferredSubtitleIndex(
        version: FileVersion?,
        signature: SubtitleTrackSignature?,
        mode: String?,
        usesDeviceSettings: Bool
    ) -> Int? {
        guard !usesDeviceSettings else { return nil }
        return serverPreferredSubtitleIndex(
            version: version,
            signature: signature,
            mode: mode
        )
    }

    /// Mirrors `SubtitleAutoResolver.bestSignatureMatch` scoring, applied
    /// to the detail payload's `SubtitleTrack` metadata, so the selector
    /// shows the same track the player would restore on its own.
    private static func bestSignatureMatch(
        _ sig: SubtitleTrackSignature,
        in tracks: [SubtitleTrack]
    ) -> SubtitleTrack? {
        var best: (SubtitleTrack, Int)?
        // Every row is a candidate, external ones included, exactly as the
        // player's `SubtitleAutoResolver.bestSignatureMatch` scores them.
        for track in tracks {
            var score = 0
            var strongSignal = false
            if let sigLang = sig.language, !sigLang.isEmpty,
               let lang = track.language,
               SubtitleAutoResolver.languagesMatch(lang, sigLang) {
                score += 5
                strongSignal = true
            }
            if sig.forced == (track.forced ?? false) {
                score += 1
            }
            if sig.hearingImpaired == (track.hearingImpaired ?? false) {
                score += 1
            }
            if let sigCodec = sig.codec, let codec = track.codec,
               sigCodec.caseInsensitiveCompare(codec) == .orderedSame {
                score += 1
            }
            if let sigLabel = sig.label, !sigLabel.isEmpty,
               let title = track.title ?? track.embeddedTitle,
               title.localizedCaseInsensitiveContains(sigLabel) {
                score += 2
                strongSignal = true
            }
            // Forced/HI/codec equality alone is meaningless (`false ==
            // false` holds for nearly every track); require a language or
            // label hit so a weak "match" can't override Auto.
            if strongSignal, score > (best?.1 ?? 0) {
                best = (track, score)
            }
        }
        return best?.0
    }

    /// Preview the track the player's `SubtitleAutoResolver` would auto-select
    /// for the "Auto" (no explicit override) case, applied to the detail
    /// payload's `SubtitleTrack` list. Returns nil when Auto resolves to no
    /// subtitles (mode off, no preference, or audio already in the preferred
    /// language). Mirrors `SubtitleAutoResolver.resolve` branch-for-branch
    /// with the inputs the detail page can supply, including where
    /// `showForced` does and does not apply.
    private static func autoResolvedSubtitle(
        version: FileVersion?,
        context: SubtitleAutoContext
    ) -> (track: SubtitleTrack, ordinal: Int)? {
        let catalog = Array((version?.subtitleTracks ?? []).enumerated())
        guard !catalog.isEmpty else { return nil }
        // Search in the Protocol V3 combined order (externals first) that
        // `SubtitleTrackCandidates` and the plan inventory use, so a first-match
        // tie resolves to the same track playback will start. The returned
        // ordinal stays the catalog offset so "Track N" labels line up with
        // `subtitleOptions`.
        // Same candidate set and order as `SubtitleTrackCandidates`: externals
        // first, then embedded. An embedded row with no index is FFmpeg stream
        // 0 (the wire omits a zero index), so it stays selectable.
        let ordered = catalog.filter { $0.element.external == true }
            + catalog.filter { $0.element.external != true }
        guard let pick = autoResolvedSubtitle(in: ordered.map(\.element), context: context) else {
            return nil
        }
        return (pick.track, ordered[pick.ordinal].offset)
    }

    /// `autoResolvedSubtitle(version:context:)` over an already ordered list;
    /// `ordinal` is the position in `tracks`.
    private static func autoResolvedSubtitle(
        in tracks: [SubtitleTrack],
        context: SubtitleAutoContext
    ) -> (track: SubtitleTrack, ordinal: Int)? {
        guard !tracks.isEmpty else { return nil }

        let mode = SubtitleMode(rawValue: context.mode ?? "") ?? .auto
        if mode == .off { return nil }

        if let signature = context.signature,
           let match = bestSignatureMatch(signature, in: tracks),
           let ordinal = tracks.firstIndex(where: { $0.id == match.id }) {
            return (match, ordinal)
        }

        guard let rawLang = context.preferredLanguage else {
            if mode == .always {
                return bestLanguageMatch(nil, in: tracks, preferForced: context.showForced)
            }
            return nil
        }

        if rawLang.isEmpty { return nil }

        // Auto mode hides subs when the audio already matches the preferred
        // subtitle language (e.g. English audio + English sub preference) —
        // unless forced subs are wanted, in which case the language-matching
        // forced (signs-only) track is exactly what plays.
        if mode == .auto, let audio = context.audioLanguage,
           SubtitleAutoResolver.languagesMatch(audio, rawLang) {
            if context.showForced,
               let forced = tracks.enumerated().first(where: { _, track in
                   (track.forced ?? false)
                       && track.language.map { SubtitleAutoResolver.languagesMatch($0, rawLang) } == true
               }) {
                return (forced.element, forced.offset)
            }
            return nil
        }

        // The user wants readable subs in this language: always the
        // full-dialogue track — `showForced` must NOT steal this pick
        // (mirrors the resolver's preferForced: false here).
        if let pick = bestLanguageMatch(rawLang, in: tracks, preferForced: false) {
            return pick
        }

        if context.showForced,
           let forced = tracks.enumerated().first(where: { $0.element.forced == true }) {
            return (forced.element, forced.offset)
        }
        return nil
    }

    /// Language-scored pick mirroring `SubtitleAutoResolver.bestLanguageMatch`
    /// over `SubtitleTrack`. Prefers full-dialogue (non-forced, non-SDH) unless
    /// `preferForced` is set. Carries the array offset through as the ordinal.
    private static func bestLanguageMatch(
        _ language: String?,
        in tracks: [SubtitleTrack],
        preferForced: Bool
    ) -> (track: SubtitleTrack, ordinal: Int)? {
        let pool = tracks.enumerated().filter { _, track in
            guard let language else { return true }
            guard let trackLang = track.language else { return false }
            return SubtitleAutoResolver.languagesMatch(trackLang, language)
        }
        guard !pool.isEmpty else { return nil }
        if preferForced, let forced = pool.first(where: { $0.element.forced == true }) {
            return (forced.element, forced.offset)
        }
        if let full = pool.first(where: {
            !($0.element.forced ?? false)
                && !($0.element.hearingImpaired ?? false)
                && !SubtitleAutoResolver.titleIndicatesHearingImpaired(
                    $0.element.title ?? $0.element.embeddedTitle
                )
        }) {
            return (full.element, full.offset)
        }
        if let nonForced = pool.first(where: { !($0.element.forced ?? false) }) {
            return (nonForced.element, nonForced.offset)
        }
        return (pool[0].element, pool[0].offset)
    }

    static func subtitleOptions(
        version: FileVersion?,
        selectedSubtitleTrackIndex: Int?,
        preferredLanguage: String?
    ) -> [SubtitleOption] {
        // Group by language + sort by preferred format. The original array
        // index is carried through as `ordinal` so the stable id and any
        // "Track N" fallback label stay put regardless of display order —
        // selection keys off the FFmpeg `index`, never the position.
        let indexed = Array((version?.subtitleTracks ?? []).enumerated())
        let ordered = SubtitleDisplayOrder.order(
            indexed,
            preferredLanguage: preferredLanguage
        ) { ordinal, track in
            let type = subtitleType(track, ordinal: ordinal)
            return SubtitleDisplayOrder.Descriptor(
                language: track.language,
                codec: track.codec,
                isForced: track.forced ?? false,
                isHearingImpaired: type == "SDH" || type == "CC",
                isDefault: track.isDefault ?? false
            )
        }
        return ordered.map { ordinal, track in
            // `selectionIndex` reads an embedded nil index as stream 0, so
            // only external sidecars without a stream index are unselectable.
            let index = track.selectionIndex
            let isSelectable = index != nil
            return SubtitleOption(
                selectionIndex: index,
                title: subtitleTitle(track, ordinal: ordinal),
                detail: subtitleDetail(track, isSelectable: isSelectable),
                isSelected: index != nil && selectedSubtitleTrackIndex == index,
                isSelectable: isSelectable,
                stableId: "\(ordinal)|\(track.id)"
            )
        }
    }

    /// Inputs needed to preview what the player's subtitle auto-resolver
    /// would land on, so the selector can annotate "Auto" with the concrete
    /// track (or "None"). Mirrors `SubtitleAutoResolver.Inputs` with the
    /// subset the detail payload can supply.
    struct SubtitleAutoContext {
        var preferredLanguage: String?
        var mode: String?
        var signature: SubtitleTrackSignature?
        var audioLanguage: String?
        var showForced: Bool = false
    }

    static func subtitleValueLabel(
        version: FileVersion?,
        selectedSubtitleTrackIndex: Int?,
        autoContext: SubtitleAutoContext? = nil
    ) -> String {
        if selectedSubtitleTrackIndex == nil {
            // When we can preview the auto-resolution, always spell it out as
            // "Auto: <track>" (or "Auto: Off"), even for a single track, so
            // the row shows what will actually play rather than a bare "Auto".
            if let autoContext {
                if let resolved = autoResolvedSubtitle(version: version, context: autoContext) {
                    return "Auto: \(subtitlePillSummary(resolved.track, ordinal: resolved.ordinal))"
                }
                return "Auto: Off"
            }
            let tracks = version?.subtitleTracks ?? []
            if tracks.count == 1, let track = tracks.first {
                return subtitlePillSummary(track, ordinal: 0)
            }
            return "Auto"
        }
        if selectedSubtitleTrackIndex == -1 { return "Off" }
        guard let selectedSubtitleTrackIndex,
              let match = (version?.subtitleTracks ?? []).enumerated().first(where: { _, track in
                  track.selectionIndex == selectedSubtitleTrackIndex
              }) else {
            // An explicit positive selection that doesn't resolve in this
            // version's track list (e.g. the displayed version was re-scoped):
            // a subtitle IS requested, so don't mislabel it as "Auto" (no
            // selection). "On" reflects the active-but-unnamed selection.
            return "On"
        }
        return subtitlePillSummary(match.element, ordinal: match.offset)
    }

    static func subtitleTitle(_ track: SubtitleTrack, ordinal: Int) -> String {
        if let language = languageDisplayName(track.language) { return language }
        if let title = meaningfulSubtitleTitle(track) { return title }
        return "Track \(ordinal + 1)"
    }

    static func subtitleDetail(_ track: SubtitleTrack, isSelectable: Bool) -> String {
        var tokens: [String] = []
        if let title = meaningfulSubtitleTitle(track) {
            tokens.append(title)
        }
        if let codec = normalizedSubtitleCodec(track.codec) {
            tokens.append(codec)
        }
        if isForced(track) {
            tokens.append("Forced")
        }
        if isHearingImpaired(track) {
            tokens.append("SDH")
        }
        if track.isDefault == true {
            tokens.append("Default")
        }
        if track.external == true {
            tokens.append("External")
        }
        if !isSelectable {
            tokens.append("Available in player")
        }
        return tokens.joined(separator: " · ")
    }

    private static func subtitlePillSummary(_ track: SubtitleTrack, ordinal: Int) -> String {
        var name = subtitleTitle(track, ordinal: ordinal)
        if isHearingImpaired(track), !containsAccessibilityMarker(name) {
            name += " (SDH)"
        }
        if isForced(track), !name.localizedCaseInsensitiveContains("forced") {
            name += " (Forced)"
        }
        guard let codec = normalizedSubtitleCodec(track.codec) else { return name }
        return "\(name) · \(codec)"
    }

    static func normalizedVideoCodec(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        if codec.contains("hevc") || codec.contains("h265") { return "HEVC" }
        if codec.contains("av1") { return "AV1" }
        if codec.contains("avc") || codec.contains("h264") { return "H.264" }
        return codec.uppercased()
    }

    private static func dynamicRangeLabel(_ version: FileVersion) -> String? {
        if (version.videoTracks ?? []).contains(where: { nonEmpty($0.dolbyVision) != nil }) {
            return "DV"
        }
        return version.hdr == true ? "HDR" : nil
    }

    static func normalizedAudioCodec(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        if codec.contains("eac3") || codec.contains("e-ac-3") || codec.contains("ec-3") {
            return "EAC3"
        }
        if codec.contains("ac3") || codec.contains("ac-3") { return "AC3" }
        if codec.contains("aac") { return "AAC" }
        if codec.contains("mp3") { return "MP3" }
        if codec.contains("truehd") { return "TrueHD" }
        if codec.contains("dts") { return "DTS" }
        if codec.contains("flac") { return "FLAC" }
        return codec.uppercased()
    }

    static func normalizedSubtitleCodec(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        if codec == "srt" || codec.contains("subrip") { return "SRT" }
        if codec == "ass" || codec.contains("ass") { return "ASS" }
        if codec == "ssa" || codec.contains("ssa") { return "SSA" }
        if codec == "vtt" || codec.contains("webvtt") { return "WebVTT" }
        if codec.contains("pgs") || codec.contains("hdmv") { return "PGS" }
        if codec.contains("dvd") || codec.contains("vobsub") { return "VobSub" }
        if codec.contains("mov_text") || codec.contains("tx3g") { return "TX3G" }
        return codec.uppercased()
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    private static func compactAudioLayout(_ track: AudioTrack) -> String? {
        if let layout = nonEmpty(track.channelLayout) {
            let lowered = layout.lowercased()
            if lowered.contains("atmos") { return "Atmos" }
            if lowered.contains("7.1") { return "7.1" }
            if lowered.contains("5.1") { return "5.1" }
            if lowered.contains("stereo") { return "Stereo" }
            return layout
        }
        switch track.channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        case let channels?: return "\(channels)ch"
        case nil: return nil
        }
    }

    private static func subtitleType(_ track: SubtitleTrack, ordinal: Int) -> String? {
        if let title = nonEmpty(track.title) {
            let lowered = title.lowercased()
            if lowered.contains("sdh") || lowered.contains("hearing") {
                return "SDH"
            }
            if lowered.contains("closed caption") || lowered == "cc" {
                return "CC"
            }
            if lowered.contains("forced") {
                return "Forced"
            }
            if !isRedundantSubtitleTitle(title, track: track) {
                return displayTitle(title)
            }
        }
        if track.forced == true {
            return "Forced"
        }
        if let codec = normalizedSubtitleCodec(track.codec) {
            return codec
        }
        return nil
    }

    private static func usefulAudioTitle(_ track: AudioTrack) -> String? {
        guard let title = nonEmpty(track.title) ?? nonEmpty(track.embeddedTitle) else { return nil }
        let lowered = title.lowercased()
        let technicalTerms = [
            "atsc",
            "a/52",
            "ac-3",
            "e-ac-3",
            "eac3",
            "truehd",
            "dts",
            "aac",
            "flac",
        ]
        if technicalTerms.contains(where: { lowered.contains($0) }) {
            return nil
        }
        return displayTitle(title)
    }

    private static func meaningfulSubtitleTitle(_ track: SubtitleTrack) -> String? {
        guard let title = nonEmpty(track.title) ?? nonEmpty(track.embeddedTitle),
              !isRedundantSubtitleTitle(title, track: track) else {
            return nil
        }
        let lowered = title.lowercased()
        if lowered == "forced" || ["sdh", "cc", "hi", "hearing impaired"].contains(lowered) {
            return nil
        }
        return displayTitle(title)
    }

    private static func isHearingImpaired(_ track: SubtitleTrack) -> Bool {
        (track.hearingImpaired ?? false)
            || SubtitleAutoResolver.titleIndicatesHearingImpaired(track.title ?? track.embeddedTitle)
    }

    private static func isForced(_ track: SubtitleTrack) -> Bool {
        (track.forced ?? false)
            || (track.title ?? track.embeddedTitle)?.localizedCaseInsensitiveContains("forced") == true
    }

    private static func containsAccessibilityMarker(_ value: String) -> Bool {
        let lowered = value.lowercased()
        let words = lowered
            .split { !$0.isLetter }
            .map(String.init)
        return words.contains("sdh")
            || words.contains("cc")
            || words.contains("hi")
            || lowered.contains("hearing impaired")
    }

    private static func isRedundantSubtitleTitle(_ title: String, track: SubtitleTrack) -> Bool {
        let lowered = title.lowercased()
        let language = languageDisplayName(track.language)?.lowercased()
        let languageCode = nonEmpty(track.language)?.lowercased()
        if lowered == "subtitle" || lowered == "subtitles" {
            return true
        }
        if let language, lowered == language {
            return true
        }
        if let languageCode, lowered == languageCode {
            return true
        }
        if let codec = normalizedSubtitleCodec(track.codec)?.lowercased(),
           lowered == codec.lowercased() || lowered == track.codec?.lowercased() {
            return true
        }
        return false
    }

    private static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "sdh": return "SDH"
        case "cc": return "CC"
        case "srt", "subrip": return "SubRip"
        case "webvtt", "vtt": return "WebVTT"
        default: return trimmed
        }
    }

    private static func languageDisplayName(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        let primary = value
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init) ?? ""
        // A token longer than a 3-letter ISO tag is already a spelled-out
        // name (e.g. free-text metadata); show it as-is.
        if primary.count > 3 {
            return value.capitalized
        }
        // Share the canonical ISO 639 folding + English display-name table
        // with the track-ordering core so the detail page's grouping and
        // its row labels never disagree on a language.
        if let key = SubtitleDisplayOrder.canonicalLanguageKey(value) {
            return SubtitleDisplayOrder.languageDisplayName(key)
        }
        return value.uppercased()
    }

    private static func normalizedFileName(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        let name = URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
        return nonEmpty(name)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

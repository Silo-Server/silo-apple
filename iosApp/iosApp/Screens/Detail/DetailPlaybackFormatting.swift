import Foundation

/// The version/track policy the phone and tvOS detail screens share: which
/// version a set of picks resolves to, which fileId the play route has to
/// carry, and whether a candidate track index survives that version. Each
/// screen owns only the storage its picks live in (`@State` on phone, the
/// cached view model on tvOS) and builds one of these per use.
struct DetailPlaybackSelection {
    let versions: [FileVersion]
    /// The item's last-played fileId — `displayVersion`'s second rung.
    let lastFileId: Int?
    /// This visit's explicit Version pick, or nil for "Auto".
    let versionFileId: Int?
    let audioTrackIndex: Int?
    let subtitleTrackIndex: Int?

    init(
        versions: [FileVersion],
        lastFileId: Int?,
        versionFileId: Int?,
        audioTrackIndex: Int? = nil,
        subtitleTrackIndex: Int? = nil
    ) {
        self.versions = versions
        self.lastFileId = lastFileId
        self.versionFileId = versionFileId
        self.audioTrackIndex = audioTrackIndex
        self.subtitleTrackIndex = subtitleTrackIndex
    }

    init(
        detail: ItemDetail?,
        versionFileId: Int?,
        audioTrackIndex: Int? = nil,
        subtitleTrackIndex: Int? = nil
    ) {
        self.init(
            versions: detail?.versions ?? [],
            lastFileId: detail?.userData?.lastFileId,
            versionFileId: versionFileId,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex
        )
    }

    init(
        detail: WatchDetail?,
        versionFileId: Int?,
        audioTrackIndex: Int? = nil,
        subtitleTrackIndex: Int? = nil
    ) {
        self.init(
            versions: detail?.versions ?? [],
            lastFileId: detail?.userData?.lastFileId,
            versionFileId: versionFileId,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex
        )
    }

    /// The version the selector displays and the play route resolves to.
    var effectiveVersion: FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: versions,
            selectedFileId: versionFileId,
            lastFileId: lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    /// FileId the play route must carry for this item.
    var playbackFileId: Int? {
        playbackFileId(resolvedFileId: versionFileId)
    }

    /// Next-up analogue: the season/series layout already resolved a fileId
    /// from its own Version pick (non-nil only when the user changed
    /// Version). When that is nil but an audio/subtitle override is set,
    /// resolve the effective version's fileId so the chosen tracks can still
    /// be carried through `.playerWithFile(...)` instead of being dropped by
    /// `.player`.
    func playbackFileId(resolvedFileId: Int?) -> Int? {
        if let resolvedFileId { return resolvedFileId }
        if audioTrackIndex != nil || subtitleTrackIndex != nil {
            return effectiveVersion?.fileId
        }
        return nil
    }

    /// Drop an audio pick the resolved version cannot satisfy.
    func sanitizedAudioIndex(_ candidate: Int?) -> Int? {
        DetailPlaybackFormatting.sanitizedAudioIndex(
            version: effectiveVersion,
            candidate: candidate
        )
    }

    /// Drop a subtitle pick the resolved version cannot satisfy. The
    /// negative "off" sentinel always survives.
    func sanitizedSubtitleIndex(_ candidate: Int?) -> Int? {
        DetailPlaybackFormatting.sanitizedSubtitleIndex(
            version: effectiveVersion,
            candidate: candidate
        )
    }
}

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

    // MARK: - Resume

    /// Resume offset the play button should use: only past the 30s mark,
    /// and never within the last 5s (that reads as finished, so restart).
    static func playableResumePosition(position: Double?, duration: Double?) -> Double? {
        guard let position, position.isFinite, position > 30 else { return nil }
        if let duration, duration.isFinite, duration > 0, position >= duration - 5 {
            return nil
        }
        return position
    }

    /// Resume offset for an item's own play button.
    static func playableResumePosition(for detail: ItemDetail) -> Double? {
        playableResumePosition(
            position: detail.userData?.positionSeconds,
            duration: detail.userData?.durationSeconds
        )
    }

    // MARK: - Track index sanitizing

    /// Drop an audio pick the resolved version cannot satisfy.
    static func sanitizedAudioIndex(version: FileVersion?, candidate: Int?) -> Int? {
        guard let candidate else { return nil }
        guard let version else { return nil }
        let tracks = version.audioTracks ?? []
        return tracks.indices.contains(candidate) ? candidate : nil
    }

    /// Drop a subtitle pick the resolved version cannot satisfy. Negative
    /// candidates are the "off" sentinel and always survive.
    static func sanitizedSubtitleIndex(version: FileVersion?, candidate: Int?) -> Int? {
        guard let candidate else { return nil }
        if candidate < 0 { return candidate }
        guard let version else { return nil }
        let available = version.subtitleTracks?.compactMap(\.index) ?? []
        return available.contains(candidate) ? candidate : nil
    }

    // MARK: - Version labels

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
           let match = signatureMatch(signature, in: version?.subtitleTracks ?? []),
           let ffmpegStreamIndex = match.ffIndex {
            return ffmpegStreamIndex
        }
        if SubtitleMode(rawValue: mode ?? "") == .off {
            return -1
        }
        return nil
    }

    /// The stored per-item signature resolved against this version's tracks by
    /// the player's own resolver. Language and mode are left neutral so only
    /// the signature rung can fire.
    private static func signatureMatch(
        _ signature: SubtitleTrackSignature,
        in tracks: [SubtitleTrack]
    ) -> PlayerTrack? {
        guard case .select(let track) = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: nil,
            mode: .auto,
            showForced: false,
            trackSignature: signature,
            availableSubtitles: SubtitleTrackCandidates.playerTracks(from: tracks),
            currentAudioLanguage: nil
        )) else { return nil }
        return track
    }

    /// Selector seed for the subtitle override the server remembers, applied
    /// on entry and after a pick made inside the player is persisted.
    /// Returns the index the selector should hold — `current` whenever
    /// nothing should change, so the caller can skip a redundant write.
    ///
    /// `preferredSubtitleTrackIndex` is per-visit state, so without this the
    /// selector always reopens on "Auto" even though the pick was persisted;
    /// audio doesn't need an equivalent because `resolvedAudioOrdinal` falls
    /// back to `effectiveAudioTrackIndex`.
    static func seededSubtitleIndex(
        current: Int?,
        wasManuallySelected: Bool,
        detail: ItemDetail?,
        version: FileVersion?
    ) -> Int? {
        let usesDeviceSettings = PlayerSettings.shared.subtitleMatchesSystemAppearance
        if usesDeviceSettings {
            // Device-settings mode starts from Apple's caption policy, so a
            // server seed must not linger in the selector.
            return wasManuallySelected ? current : nil
        }
        guard !wasManuallySelected, current == nil, let detail else { return current }
        return launchPreferredSubtitleIndex(
            version: version,
            signature: detail.effectiveSubtitleTrackSignature,
            mode: detail.effectiveSubtitleMode,
            usesDeviceSettings: usesDeviceSettings
        )
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

    /// Preview the track the player's `SubtitleAutoResolver` would auto-select
    /// for the "Auto" (no explicit override) case, over the detail payload's
    /// track list. Runs the real resolver rather than restating its policy, so
    /// the pill cannot drift from what the player does — including the
    /// `.noChange` case, which the session bridge freezes into the plan the
    /// same way. Returns nil when Auto resolves to no subtitles.
    private static func autoResolvedSubtitle(
        version: FileVersion?,
        context: SubtitleAutoContext
    ) -> (track: SubtitleTrack, ordinal: Int)? {
        let tracks = version?.subtitleTracks ?? []
        let candidates = SubtitleTrackCandidates.indexedPlayerTracks(from: tracks)
        guard !candidates.isEmpty else { return nil }
        let available = candidates.map(\.track)

        let resolution = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: context.preferredLanguage,
            mode: SubtitleMode(rawValue: context.mode ?? ""),
            showForced: context.showForced,
            trackSignature: context.signature,
            availableSubtitles: available,
            currentAudioLanguage: context.audioLanguage
        ))

        let selected: PlayerTrack?
        switch resolution {
        case .select(let track):
            selected = track
        case .disable:
            selected = nil
        case .noChange:
            // "Leave the player alone" means its demuxer keeps the media's
            // default track; the sidecar route also promotes a forced one.
            // `PlaybackSessionBridge` freezes that deterministic choice into
            // the plan, so preview the same track here.
            selected = available.first(where: { $0.isDefault })
                ?? available.first(where: { $0.isForced })
        }

        guard let selected,
              let match = candidates.first(where: { $0.track.trackId == selected.trackId })
        else { return nil }
        return (tracks[match.ordinal], match.ordinal)
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
            let index = track.index
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

    /// The subset of `SubtitleAutoResolver.Inputs` the detail payload can
    /// supply, so the selector can annotate "Auto" with the concrete track
    /// (or "Off").
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
                  track.index == selectedSubtitleTrackIndex
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

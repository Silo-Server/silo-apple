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
        guard let version else { return AppLanguage.string(.detailAuto) }
        let tokens = qualityTokens(version)
        return tokens.isEmpty ? AppLanguage.string(.detailAuto) : tokens.joined(separator: " · ")
    }

    /// Resolution, video codec, HDR family and audio codec, when known.
    private static func qualityTokens(_ version: FileVersion) -> [String] {
        [
            nonEmpty(version.resolution),
            nonEmpty(normalizedVideoCodec(version.codecVideo)),
            dynamicRangeLabel(version),
            nonEmpty(normalizedAudioCodec(version.codecAudio)),
        ].compactMap { $0 }
    }

    /// Resting-state video summary for the compact tvOS selector segment.
    /// Keep the two facts viewers need at a glance (resolution + HDR family),
    /// while the focused segment expands to ``versionShortLabel(_:)``.
    static func versionCompactLabel(_ version: FileVersion?) -> String {
        let tokens = versionCompactTokens(version)
        return tokens.isEmpty ? AppLanguage.string(.detailAuto) : tokens.joined(separator: " · ")
    }

    /// The facts ``versionCompactLabel(_:)`` joins; empty when it shows "Auto".
    static func versionCompactTokens(_ version: FileVersion?) -> [String] {
        guard let version else { return [] }
        return [
            nonEmpty(version.resolution),
            dynamicRangeLabel(version),
        ].compactMap { $0 }
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
        let tokens = qualityTokens(version)
        if !tokens.isEmpty {
            return tokens.joined(separator: " · ")
        }
        if let fileName = normalizedFileName(version.fileName) {
            return fileName
        }
        return AppLanguage.string(.detailVersionFileId(String(version.fileId)))
    }

    static func versionSecondaryText(_ version: FileVersion) -> String? {
        nonEmpty(versionDetailLabel(version))
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

    /// Unlike audio, one subtitle track is still a choice: Auto may resolve
    /// to Off, so the viewer needs the selector to turn that track on.
    static func shouldEnableSubtitleSelector(version: FileVersion?) -> Bool {
        !(version?.subtitleTracks ?? []).isEmpty
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
            return AppLanguage.string(.detailUnknown)
        }
        let summary = audioSummary(track, ordinal: ordinal)
        // With no explicit pick, the shown track is whatever Auto resolved to
        // (preferred/default). Prefix "Auto:" so the row makes clear the
        // choice was automatic rather than user-selected.
        if annotateAuto, selectedAudioTrackIndex == nil {
            return AppLanguage.string(.detailAutoSelectorValue(summary))
        }
        return summary
    }

    /// Language of the track that `audioValueLabel` would display, used to
    /// feed the subtitle auto-resolver. Resolved as the start request does
    /// (`PlaybackSessionBridge.startAudioLanguage`), so an unlabelled track
    /// reads as the server's effective audio language here too and the Auto
    /// preview names the track playback starts on.
    static func resolvedAudioLanguage(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?
    ) -> String? {
        PlaybackSessionBridge.startAudioLanguage(
            version: version,
            audioOrdinal: resolvedAudioOrdinal(
                version: version,
                selectedAudioTrackIndex: selectedAudioTrackIndex
            )
        )
    }

    static func audioTitle(_ track: AudioTrack, ordinal: Int) -> String {
        TrackLabels.name(
            language: track.language,
            meaningfulTitle: usefulAudioTitle(track),
            fallback: AppLanguage.string(.detailTrack(LocaleFormat.integer(ordinal + 1)))
        )
    }

    static func audioDetail(_ track: AudioTrack, ordinal: Int, version: FileVersion?) -> String {
        var tokens: [String] = []
        let layout = compactAudioLayout(track)
        // A title of "Atmos" says nothing a layout of "Atmos" doesn't. Server
        // titles are English, so compare with the English layout word too.
        let englishLayout = AppLanguage.inEnglish { compactAudioLayout(track) }
        if let title = TrackLabels.qualifier(usefulAudioTitle(track), name: audioTitle(track, ordinal: ordinal)),
           title.caseInsensitiveCompare(layout ?? "") != .orderedSame,
           title.caseInsensitiveCompare(englishLayout ?? "") != .orderedSame {
            tokens.append(title)
        }
        if let codec = normalizedAudioCodec(track.codec) {
            tokens.append(codec)
        }
        if let layout {
            tokens.append(layout)
        }
        if track.isDefault == true {
            tokens.append(AppLanguage.string(.detailTrackDefault))
        }
        if version?.effectiveAudioTrackIndex == ordinal {
            tokens.append(AppLanguage.string(.detailTrackPreferred))
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
    ///
    /// A server mode of "off" (the profile's, or a series Off) with "show
    /// forced subtitles" on is not an explicit Off: playback starts on the
    /// forced track in the audio language, as it does on every other entry
    /// path and on web. So it returns nil and lets the player's
    /// resolver pick that track. The mode wins over a stored signature, as it
    /// does in the resolver.
    static func serverPreferredSubtitleIndex(
        version: FileVersion?,
        signature: SubtitleTrackSignature?,
        mode: String?,
        showForced: Bool
    ) -> Int? {
        if SubtitleMode(rawValue: mode ?? "") == .off {
            return showForced ? nil : -1
        }
        // The player's resolver never restores a track the server can't
        // deliver, so the selector doesn't show one either.
        if let signature,
           let tracks = version?.subtitleTracks?.filter({ !$0.hasUnsupportedFormat }),
           let match = bestSignatureMatch(signature, in: tracks) {
            return match.selectionIndex
        }
        return nil
    }

    /// The subtitle selection once Auto's file has changed under the page.
    /// Auto (nil) and Off (negative) mean the same on any file, so they stay.
    /// A track index names a stream of the old file, so it gives way to
    /// `reseed`, what Auto picks on the new one.
    static func subtitleIndexAfterFileChange(_ index: Int?, reseed: () -> Int?) -> Int? {
        guard let index, index >= 0 else { return index }
        return reseed()
    }

    /// Whether a subtitle picked in the detail selector survives the page
    /// reloading, as it does when the viewer returns from the player. Off and
    /// Auto always do. A track index belongs to one file, so a track pick
    /// stays only while the reloaded page shows the file it was picked on and
    /// that file still offers it. Matches tvOS, whose selector state outlives
    /// the player.
    static func keepsManualSubtitlePick(
        _ index: Int?,
        pickedFileId: Int?,
        reloadedFileId: Int?,
        isAvailable: (Int) -> Bool
    ) -> Bool {
        guard let index, index >= 0 else { return true }
        guard let pickedFileId, pickedFileId == reloadedFileId else { return false }
        return isAvailable(index)
    }

    /// The subtitle to keep when a Version or Edition pick moves the page from
    /// one file to another. A track index belongs to one file, so the same
    /// index on the next file can be another language. Auto and Off carry
    /// over. A track the server preference chose is chosen again on the next
    /// file, as a fresh page would. A track the viewer picked becomes the next
    /// file's track in the same language, with the same forced and SDH flags,
    /// preferring the same title; with none, the pick falls back to Auto.
    /// When the file changes without a pick, see `subtitleIndexAfterFileChange`.
    static func subtitleIndexAfterVersionPick(
        _ index: Int?,
        movingFrom previous: FileVersion?,
        to next: FileVersion?,
        signature: SubtitleTrackSignature?,
        mode: String?,
        showForced: Bool,
        usesDeviceSettings: Bool
    ) -> Int? {
        guard let index, index >= 0, previous?.fileId != next?.fileId else { return index }
        func seeded(_ version: FileVersion?) -> Int? {
            launchPreferredSubtitleIndex(
                version: version,
                signature: signature,
                mode: mode,
                showForced: showForced,
                usesDeviceSettings: usesDeviceSettings
            )
        }
        if seeded(previous) == index { return seeded(next) }

        guard let picked = previous?.subtitleTracks?.first(where: { $0.selectionIndex == index }),
              let language = nonEmpty(picked.language) else { return nil }
        let matches = (next?.subtitleTracks ?? []).filter { track in
            guard track.selectionIndex != nil, !track.hasUnsupportedFormat,
                  let trackLanguage = nonEmpty(track.language) else { return false }
            return SubtitleAutoResolver.languagesMatch(trackLanguage, language)
                && isForced(track) == isForced(picked)
                && isHearingImpaired(track) == isHearingImpaired(picked)
        }
        func title(_ track: SubtitleTrack) -> String? {
            nonEmpty(track.title) ?? nonEmpty(track.embeddedTitle)
        }
        // "Latin American" and "Spanish (Latin American)" name the same track.
        if let wanted = title(picked),
           let match = matches.first(where: { title($0)?.caseInsensitiveCompare(wanted) == .orderedSame })
            ?? matches.first(where: { title($0).map {
                $0.localizedCaseInsensitiveContains(wanted) || wanted.localizedCaseInsensitiveContains($0)
            } == true }) {
            return match.selectionIndex
        }
        return matches.first?.selectionIndex
    }

    /// A server-remembered track is useful for reflecting the server policy
    /// in the pre-play selector, but it is not a manual choice made during
    /// this visit. Device-settings mode must start on Apple's caption policy
    /// instead of forwarding that seed as an explicit player override.
    static func launchPreferredSubtitleIndex(
        version: FileVersion?,
        signature: SubtitleTrackSignature?,
        mode: String?,
        showForced: Bool,
        usesDeviceSettings: Bool
    ) -> Int? {
        guard !usesDeviceSettings else { return nil }
        return serverPreferredSubtitleIndex(
            version: version,
            signature: signature,
            mode: mode,
            showForced: showForced
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
            if let sigLang = sig.language, !sigLang.isEmpty,
               let lang = track.language, !lang.isEmpty,
               !SubtitleAutoResolver.languagesMatch(lang, sigLang) {
                continue
            }
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
    /// subtitles (mode off with no forced track in the audio language, or
    /// audio already in the preferred language). When the resolver leaves the
    /// choice to the file, this names the default or forced track playback
    /// starts on. Runs the
    /// resolver itself, with the inputs the detail page can supply, over the
    /// candidates the start request resolves (V3 combined order, externals
    /// first), so the preview names the track playback starts on. The returned ordinal stays the catalog offset so "Track N" labels
    /// match subtitleOptions. An embedded row with no index is FFmpeg stream 0
    /// (the wire omits a zero index), so it stays selectable.
    private static func autoResolvedSubtitle(
        version: FileVersion?,
        context: SubtitleAutoContext
    ) -> (track: SubtitleTrack, ordinal: Int)? {
        let catalog = Array((version?.subtitleTracks ?? []).enumerated())
        guard !catalog.isEmpty else { return nil }
        let ordered = catalog.filter { $0.element.external == true }
            + catalog.filter { $0.element.external != true }
        let candidates = SubtitleTrackCandidates.playerTracks(from: ordered.map(\.element))
        let resolution = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: context.preferredLanguage,
            mode: SubtitleMode(rawValue: context.mode ?? ""),
            showForced: context.showForced,
            trackSignature: context.signature,
            availableSubtitles: candidates,
            currentAudioLanguage: context.audioLanguage,
            sourceContainer: version?.container
        ))
        let pick: PlayerTrack?
        switch resolution {
        case .select(let track):
            pick = track
        case .disable:
            pick = nil
        case .noChange:
            // Playback then starts the file's default track, else a forced
            // one (`PlaybackSessionBridge.initialProtocolV3SubtitleIntent`),
            // skipping one the server can't deliver.
            let deliverable = candidates.filter { !$0.hasUnsupportedFormat }
            pick = deliverable.first(where: { $0.isDefault })
                ?? deliverable.first(where: { $0.isForced })
        }
        guard let pick, let position = candidates.firstIndex(of: pick) else {
            return nil
        }
        return (ordered[position].element, ordered[position].offset)
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
        ) { _, track in
            let type = subtitleType(track)
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
            // only external sidecars without a stream index, and tracks the
            // server can't deliver, are unselectable.
            let index = track.selectionIndex
            let isSelectable = index != nil && !track.hasUnsupportedFormat
            return SubtitleOption(
                selectionIndex: index,
                title: subtitleTitle(track, ordinal: ordinal),
                detail: subtitleDetail(track, ordinal: ordinal, isSelectable: isSelectable),
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

    /// What Auto subtitles would play, as the track's summary, or nil when
    /// Auto resolves to Off.
    static func autoSubtitlePreview(version: FileVersion?, context: SubtitleAutoContext) -> String? {
        autoResolvedSubtitle(version: version, context: context)
            .map { subtitlePillSummary($0.track, ordinal: $0.ordinal) }
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
                    return AppLanguage.string(.detailAutoSelectorValue(subtitlePillSummary(resolved.track, ordinal: resolved.ordinal)))
                }
                return AppLanguage.string(.detailAutoSelectorValue(AppLanguage.string(.detailOff)))
            }
            // Without a preview, never name a track: the only track on a file
            // does not play unless the preferences or the file pick it.
            return AppLanguage.string(.detailAuto)
        }
        if selectedSubtitleTrackIndex == -1 { return AppLanguage.string(.detailOff) }
        guard let selectedSubtitleTrackIndex,
              let match = (version?.subtitleTracks ?? []).enumerated().first(where: { _, track in
                  track.selectionIndex == selectedSubtitleTrackIndex
              }) else {
            // An explicit positive selection that doesn't resolve in this
            // version's track list (e.g. the displayed version was re-scoped):
            // a subtitle IS requested, so don't mislabel it as "Auto" (no
            // selection). "On" reflects the active-but-unnamed selection.
            return AppLanguage.string(.detailSubtitlesOn)
        }
        return subtitlePillSummary(match.element, ordinal: match.offset)
    }

    static func subtitleTitle(_ track: SubtitleTrack, ordinal: Int) -> String {
        TrackLabels.name(
            language: track.language,
            meaningfulTitle: meaningfulSubtitleTitle(track),
            fallback: AppLanguage.string(.detailTrack(LocaleFormat.integer(ordinal + 1)))
        )
    }

    static func subtitleDetail(_ track: SubtitleTrack, ordinal: Int, isSelectable: Bool) -> String {
        var tokens: [String] = []
        if let title = TrackLabels.qualifier(meaningfulSubtitleTitle(track), name: subtitleTitle(track, ordinal: ordinal)) {
            tokens.append(title)
        }
        if let codec = normalizedSubtitleCodec(track.codec) {
            tokens.append(codec)
        }
        if isForced(track) {
            tokens.append(AppLanguage.string(.detailTrackForced))
        }
        if isHearingImpaired(track) {
            tokens.append(AppLanguage.string(.detailTrackSdh))
        }
        if track.isDefault == true {
            tokens.append(AppLanguage.string(.detailTrackDefault))
        }
        if track.external == true {
            tokens.append(AppLanguage.string(.detailTrackExternal))
        }
        if track.hasUnsupportedFormat {
            tokens.append(AppLanguage.string(.subtitleTrackUnsupportedFormat))
        } else if !isSelectable {
            tokens.append(AppLanguage.string(.detailTrackAvailableInPlayer))
        }
        return tokens.joined(separator: " · ")
    }

    private static func subtitlePillSummary(_ track: SubtitleTrack, ordinal: Int) -> String {
        var name = subtitleTitle(track, ordinal: ordinal)
        if isHearingImpaired(track), !containsAccessibilityMarker(name) {
            name = AppLanguage.string(.detailTrackWithFlag(name, AppLanguage.string(.detailTrackSdh)))
        }
        // "forced" is matched against the track's own (server) title, so it stays English.
        if isForced(track), !name.localizedCaseInsensitiveContains("forced") {
            name = AppLanguage.string(.detailTrackWithFlag(name, AppLanguage.string(.detailTrackForced)))
        }
        guard let codec = normalizedSubtitleCodec(track.codec) else { return name }
        return "\(name) · \(codec)"
    }

    static func normalizedVideoCodec(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        if codec.contains("hevc") || codec.contains("h265") { return "HEVC" } // i18n-ignore: codec name
        if codec.contains("av1") { return "AV1" } // i18n-ignore: codec name
        if codec.contains("avc") || codec.contains("h264") { return "H.264" } // i18n-ignore: codec name
        return codec.uppercased()
    }

    private static func dynamicRangeLabel(_ version: FileVersion) -> String? {
        if (version.videoTracks ?? []).contains(where: { nonEmpty($0.dolbyVision) != nil }) {
            return "DV" // i18n-ignore: Dolby Vision technical token
        }
        return version.hdr == true ? "HDR" : nil // i18n-ignore: technical token
    }

    static func normalizedAudioCodec(_ codec: String?) -> String? {
        TrackLabels.audioCodec(codec)
    }

    static func normalizedSubtitleCodec(_ codec: String?) -> String? {
        TrackLabels.subtitleCodec(codec)
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        LocaleFormat.bytes(bytes, megabytesAndUp: true)
    }

    private static func compactAudioLayout(_ track: AudioTrack) -> String? {
        TrackLabels.audioLayout(channelLayout: track.channelLayout, channels: track.channels)
    }

    private static func subtitleType(_ track: SubtitleTrack) -> String? {
        if let title = nonEmpty(track.title) {
            let lowered = title.lowercased()
            if lowered.contains("sdh") || lowered.contains("hearing") {
                return "SDH" // i18n-ignore: type tag compared below, never shown
            }
            if lowered.contains("closed caption") || lowered == "cc" {
                return "CC" // i18n-ignore: type tag compared below, never shown
            }
            if lowered.contains("forced") {
                return "Forced" // i18n-ignore: type tag compared below, never shown
            }
            if let meaningful = TrackLabels.subtitleTitle(
                title,
                language: track.language,
                codec: track.codec,
                showsHearingImpaired: isHearingImpaired(track)
            ) {
                return meaningful
            }
        }
        if track.forced == true {
            return "Forced" // i18n-ignore: type tag compared below, never shown
        }
        if let codec = normalizedSubtitleCodec(track.codec) {
            return codec
        }
        return nil
    }

    private static func usefulAudioTitle(_ track: AudioTrack) -> String? {
        TrackLabels.audioTitle(nonEmpty(track.title) ?? nonEmpty(track.embeddedTitle), language: track.language)
    }

    private static func meaningfulSubtitleTitle(_ track: SubtitleTrack) -> String? {
        TrackLabels.subtitleTitle(
            nonEmpty(track.title) ?? nonEmpty(track.embeddedTitle),
            language: track.language,
            codec: track.codec,
            showsHearingImpaired: isHearingImpaired(track)
        )
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

    private static func languageDisplayName(_ value: String?) -> String? {
        TrackLabels.languageName(value)
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

extension DetailPlaybackFormatting.SubtitleAutoContext {
    /// The "Auto" subtitle preview context for the selected version and audio
    /// track.
    init(
        version: FileVersion?,
        selectedAudioTrackIndex: Int?,
        preferredLanguage: String?,
        mode: String?,
        signature: SubtitleTrackSignature?,
        showForced: Bool
    ) {
        self.init(
            preferredLanguage: preferredLanguage,
            mode: mode,
            signature: signature,
            audioLanguage: DetailPlaybackFormatting.resolvedAudioLanguage(
                version: version,
                selectedAudioTrackIndex: selectedAudioTrackIndex
            ),
            showForced: showForced
        )
    }
}

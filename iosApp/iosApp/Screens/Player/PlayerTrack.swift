import Foundation

/// An app-facing projection of an Aether media track. `trackId` is the
/// per-kind id passed back through the Aether controller; `ffIndex` is the
/// source stream index used to match server-supplied preferences.
///
/// Fields beyond id/title/lang are optional because not every codec populates
/// every field — e.g. PGS subtitle tracks report no `audio-channels`.
struct PlayerTrack: Identifiable, Equatable, Hashable {
    enum Kind: String {
        case audio
        case sub
        case video
        case unknown
    }

    let trackId: Int64
    let kind: Kind
    let title: String?
    let lang: String?
    let codec: String?
    /// Numeric channel count when the demuxer reported it.
    let audioChannelCount: Int?
    /// Demuxed bitrate in bits per second (0 if unknown).
    let bitrate: Int64?
    let isDefault: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    let isExternal: Bool
    let isSelected: Bool
    let ffIndex: Int?
    let srcId: Int?
    /// A subtitle the server downloaded for this file (the V3 inventory's
    /// `downloaded` source), as opposed to a sidecar next to the media. Such a
    /// track is also `isExternal`.
    var isDownloaded = false

    var id: String { "\(kind.rawValue)-\(trackId)" }

    var normalizedTitle: String? {
        Self.normalizedText(title)
    }

    var normalizedLanguageCode: String? {
        guard let code = Self.normalizedText(lang),
              code.caseInsensitiveCompare("und") != .orderedSame else {
            return nil
        }
        return code
    }

    /// The row name, in the detail page's vocabulary (`TrackLabels`): the
    /// language, else a meaningful title, else "Track N". A subtitle falls
    /// back to its format ("SRT"), as on Android, because sidecar and server
    /// inventory ids aren't ordinals ("Track 1073741825").
    var primaryLabel: String {
        switch kind {
        case .audio, .sub:
            let format = kind == .sub ? subtitleFormat : nil
            return TrackLabels.name(
                language: normalizedLanguageCode,
                meaningfulTitle: meaningfulTitle,
                fallback: format ?? "Track \(trackId)"
            )
        case .video, .unknown:
            return normalizedTitle ?? TrackLabels.languageName(normalizedLanguageCode) ?? "Track \(trackId)"
        }
    }

    /// The track's own title when it says something the name, codec, and
    /// flags don't — e.g. "Commentary" or "Signs & Songs", never "ASS".
    var detailLabel: String? {
        TrackLabels.qualifier(meaningfulTitle, name: primaryLabel)
    }

    /// `detailLabel` followed by the attribute pills, for rows that show one
    /// secondary line.
    var attributesLabel: String? {
        let parts = [detailLabel].compactMap { $0 } + attributePillLabels()
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// `primaryLabel` plus what tells same-language tracks apart, for
    /// surfaces that show only a name, such as the phone remote's menus:
    /// "English", "English (Commentary)", "English (Signs & Songs, Forced)".
    var singleLineLabel: String {
        singleLineLabel(includingFormat: false)
    }

    /// `singleLineLabel` for each track, adding the codec and layout where
    /// two tracks would otherwise read the same: "English (EAC3 5.1)" and
    /// "English (AAC Stereo)" rather than "English" twice. Tracks that still
    /// match are numbered in order ("SRT 1", "SRT 2"), since a remote shows
    /// only this name.
    static func singleLineLabels(_ tracks: [PlayerTrack]) -> [String] {
        let labels = tracks.map(\.singleLineLabel)
        let counts = Dictionary(labels.map { ($0, 1) }, uniquingKeysWith: +)
        let formatted = zip(tracks, labels).map { track, label in
            counts[label, default: 0] > 1 ? track.singleLineLabel(includingFormat: true) : label
        }
        let formattedCounts = Dictionary(formatted.map { ($0, 1) }, uniquingKeysWith: +)
        var seen: [String: Int] = [:]
        return formatted.map { label in
            guard formattedCounts[label, default: 0] > 1 else { return label }
            let number = seen[label, default: 0] + 1
            seen[label] = number
            return "\(label) \(number)"
        }
    }

    private func singleLineLabel(includingFormat: Bool) -> String {
        var qualifiers = [detailLabel].compactMap { $0 }
        if includingFormat {
            let format: [String?]
            switch kind {
            case .audio: format = [TrackLabels.audioCodec(Self.normalizedText(codec)), channelCountLabel]
            case .sub: format = [subtitleFormatPill]
            case .video, .unknown: format = []
            }
            let joined = format.compactMap { $0 }.joined(separator: " ")
            if !joined.isEmpty { qualifiers.append(joined) }
        }
        if showsForced { qualifiers.append("Forced") }
        if showsHearingImpaired { qualifiers.append("SDH") }
        guard !qualifiers.isEmpty else { return primaryLabel }
        return "\(primaryLabel) (\(qualifiers.joined(separator: ", ")))"
    }

    /// Codec, channel layout, and flags, unjoined, for UIs that render each
    /// attribute as its own pill. Same order and names as the detail page.
    func attributePillLabels() -> [String] {
        var parts: [String] = []
        switch kind {
        case .audio:
            if let codec = TrackLabels.audioCodec(Self.normalizedText(codec)) { parts.append(codec) }
            if let layout = channelCountLabel { parts.append(layout) }
        case .sub:
            if let format = subtitleFormatPill { parts.append(format) }
        case .video, .unknown:
            if let codec = Self.normalizedText(codec) { parts.append(codec.uppercased()) }
        }
        if isDefault {
            parts.append("Default")
        }
        if showsForced {
            parts.append("Forced")
        }
        if showsHearingImpaired {
            parts.append("SDH")
        }
        if isExternal {
            parts.append("External")
        }
        return parts
    }

    // Like the detail page, a subtitle titled "Forced" or "SDH" shows the
    // flag even when the container did not set it.
    private var showsForced: Bool {
        isForced || (kind == .sub && title?.localizedCaseInsensitiveContains("forced") == true)
    }

    private var showsHearingImpaired: Bool {
        isHearingImpaired || (kind == .sub && SubtitleAutoResolver.titleIndicatesHearingImpaired(title))
    }

    /// Human-readable channel layout for audio tracks (e.g. "5.1"), or nil
    /// when the demuxer reported no usable count.
    var channelCountLabel: String? {
        TrackLabels.audioLayout(channelLayout: nil, channels: audioChannelCount)
    }

    private var subtitleFormat: String? {
        TrackLabels.subtitleCodec(Self.normalizedText(codec))
    }

    /// The format pill, left out when the format already names the row.
    private var subtitleFormatPill: String? {
        subtitleFormat == primaryLabel ? nil : subtitleFormat
    }

    private var meaningfulTitle: String? {
        // An untitled stream reaches us as the demuxer's "ENG (eac3)", which
        // only restates the language and codec.
        if OfflinePreparedTrackInventory.hasSynthesizedName(self) { return nil }
        switch kind {
        case .audio: return TrackLabels.audioTitle(normalizedTitle, language: normalizedLanguageCode)
        case .sub:
            return TrackLabels.subtitleTitle(
                normalizedTitle,
                language: normalizedLanguageCode,
                codec: codec,
                showsHearingImpaired: showsHearingImpaired
            )
        case .video, .unknown: return normalizedTitle
        }
    }

    static func normalizedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// What to do with a track selection the app is holding on behalf of the user
/// (a persisted pick, a detail-screen pick, a resumed selection) when Aether's
/// inventory arrives.
///
/// Split out as a pure decision because the hazard it exists to prevent is
/// invisible in the happy path: Aether publishes its track inventory during
/// startup, before it has dispatched the source onto a decode backend, and an
/// audio switch applied there makes the engine rebuild its pipeline against a
/// route it has not chosen yet. On a software-decode source that rebuild lands
/// on the native path, is rejected for the codec, and takes the in-flight load
/// down with it.
enum DeferredTrackSelectionGate {
    enum Outcome: Equatable {
        /// Keep holding the selection: the load is not established yet.
        case deferUntilEstablished
        /// Adopt it as the published selection without touching the engine —
        /// the engine is already on this track.
        case adoptWithoutEngineCall
        /// Establish and different: drive the engine.
        case applyToEngine
    }

    static func outcome(
        isLoadEstablished: Bool,
        engineAlreadyMatches: Bool
    ) -> Outcome {
        guard isLoadEstablished else { return .deferUntilEstablished }
        return engineAlreadyMatches ? .adoptWithoutEngineCall : .applyToEngine
    }
}

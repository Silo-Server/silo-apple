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
    /// language, else a meaningful title, else "Track N".
    var primaryLabel: String {
        switch kind {
        case .audio, .sub:
            return TrackLabels.name(
                language: normalizedLanguageCode,
                meaningfulTitle: meaningfulTitle,
                fallback: "Track \(trackId)"
            )
        case .video, .unknown:
            return normalizedTitle ?? TrackLabels.languageName(normalizedLanguageCode) ?? "Track \(trackId)"
        }
    }

    /// The track's own title when it says something the name, codec, and
    /// flags don't — e.g. "Commentary" or "Signs & Songs", never "ASS".
    var detailLabel: String? {
        guard let title = meaningfulTitle, title != primaryLabel else { return nil }
        return title
    }

    /// `detailLabel` followed by the attribute pills, for rows that show one
    /// secondary line.
    var attributesLabel: String? {
        let parts = [detailLabel].compactMap { $0 } + attributePillLabels()
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            if let codec = TrackLabels.subtitleCodec(Self.normalizedText(codec)) { parts.append(codec) }
        case .video, .unknown:
            if let codec = Self.normalizedText(codec) { parts.append(codec.uppercased()) }
        }
        if isDefault {
            parts.append("Default")
        }
        // Like the detail page, a subtitle titled "Forced" or "SDH" shows the
        // flag even when the container did not set it.
        if isForced || (kind == .sub && title?.localizedCaseInsensitiveContains("forced") == true) {
            parts.append("Forced")
        }
        if isHearingImpaired || (kind == .sub && SubtitleAutoResolver.titleIndicatesHearingImpaired(title)) {
            parts.append("SDH")
        }
        if isExternal {
            parts.append("External")
        }
        return parts
    }

    /// Human-readable channel layout for audio tracks (e.g. "5.1"), or nil
    /// when the demuxer reported no usable count.
    var channelCountLabel: String? {
        TrackLabels.audioLayout(channelLayout: nil, channels: audioChannelCount)
    }

    private var meaningfulTitle: String? {
        switch kind {
        case .audio: return TrackLabels.audioTitle(normalizedTitle)
        case .sub: return TrackLabels.subtitleTitle(normalizedTitle, language: normalizedLanguageCode, codec: codec)
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

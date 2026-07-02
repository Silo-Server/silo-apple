import Foundation

/// A track exposed by the player core. `trackId` is the per-kind id used with
/// `setAudioTrack`/`setSubtitleTrack`; `ffIndex` is the underlying FFmpeg
/// stream index, useful for matching against server-supplied preferred indices.
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
    /// Channel layout string (e.g. "stereo", "5.1(side)").
    let audioChannelsLayout: String?
    /// Numeric channel count when the demuxer reported it.
    let audioChannelCount: Int?
    /// Demuxed bitrate in bits per second (0 if unknown).
    let bitrate: Int64?
    let isDefault: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    let isVisualImpaired: Bool
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

    var primaryLabel: String {
        if let title = normalizedTitle {
            return title
        }
        if let lang = normalizedLanguageCode {
            return languageDisplayName(lang)
        }
        return "Track \(trackId)"
    }

    var attributesLabel: String? {
        let parts = attributeParts()
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Same attributes as `attributesLabel`, unjoined — for UIs that render
    /// each attribute as its own pill instead of a dot-separated line.
    var attributePillLabels: [String] {
        attributeParts()
    }

    private func attributeParts() -> [String] {
        var parts: [String] = []

        if let lang = normalizedLanguageCode,
           let title = normalizedTitle,
           !title.localizedCaseInsensitiveContains(lang) {
            parts.append(languageDisplayName(lang))
        }

        if kind == .audio {
            if let layout = Self.normalizedText(audioChannelsLayout) {
                parts.append(layout)
            } else if let count = audioChannelCount, count > 0 {
                parts.append(formatChannelCount(count))
            }
        }

        if let codec = Self.normalizedText(codec) {
            parts.append(codec.uppercased())
        }
        if isDefault {
            parts.append("Default")
        }
        if isForced {
            parts.append("Forced")
        }
        if isHearingImpaired {
            parts.append("SDH")
        }
        if isExternal {
            parts.append("External")
        }

        return parts
    }

    /// Rich human-readable label for track pickers,
    /// e.g. "English · 5.1 · EAC3 · default".
    var displayLabel: String {
        var parts: [String] = []

        if let title = normalizedTitle {
            parts.append(title)
        }
        if let lang = normalizedLanguageCode,
           !(normalizedTitle?.localizedCaseInsensitiveContains(lang) ?? false) {
            parts.append(languageDisplayName(lang))
        }
        if kind == .audio {
            if let layout = Self.normalizedText(audioChannelsLayout) {
                parts.append(layout)
            } else if let count = audioChannelCount, count > 0 {
                parts.append(formatChannelCount(count))
            }
        }
        if let codec = Self.normalizedText(codec) {
            parts.append(codec.uppercased())
        }
        if isDefault {
            parts.append("default")
        }
        if isForced {
            parts.append("forced")
        }
        if isHearingImpaired {
            parts.append("SDH")
        }
        if isExternal {
            parts.append("external")
        }

        if parts.isEmpty {
            parts.append("Track \(trackId)")
        }
        return parts.joined(separator: " · ")
    }

    private func formatChannelCount(_ count: Int) -> String {
        switch count {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(count)ch"
        }
    }

    private func languageDisplayName(_ code: String) -> String {
        let locale = Locale(identifier: "en")
        return locale.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

import Foundation

/// One label vocabulary for audio and subtitle tracks, shared by the detail
/// page's selectors and the player's track lists so a track reads the same
/// before and during playback.
///
/// As on Android, the language leads; a track's own title follows only when
/// it says something the language, codec, and flags don't; codecs use the
/// short names people know ("EAC3", "TrueHD", "SRT", "PGS").
enum TrackLabels {
    /// A row's name: the language, else a meaningful title, else `fallback`.
    static func name(language: String?, meaningfulTitle: String?, fallback: String) -> String {
        languageName(language) ?? meaningfulTitle ?? fallback
    }

    /// English display name for a language tag ("eng", "fre", "pt-BR"), or nil
    /// when it is missing or undetermined.
    static func languageName(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        let primary = value
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init) ?? ""
        if primary == "und" { return nil }
        // A token longer than a 3-letter ISO tag is already a spelled-out
        // name (e.g. free-text metadata); show it as-is.
        if primary.count > 3 {
            return value.capitalized
        }
        // Share the canonical ISO 639 folding + English display-name table
        // with the track-ordering core so grouping and row labels never
        // disagree on a language.
        if let key = SubtitleDisplayOrder.canonicalLanguageKey(value) {
            return SubtitleDisplayOrder.languageDisplayName(key)
        }
        return value.uppercased()
    }

    static func audioCodec(_ codec: String?) -> String? {
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

    static func subtitleCodec(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        if codec == "srt" || codec.contains("subrip") { return "SRT" }
        if codec.contains("ass") { return "ASS" }
        if codec.contains("ssa") { return "SSA" }
        if codec == "vtt" || codec.contains("webvtt") { return "WebVTT" }
        if codec == "sup" || codec.contains("pgs") || codec.contains("hdmv") { return "PGS" }
        if codec.contains("dvd") || codec.contains("vobsub") { return "VobSub" }
        if codec.contains("mov_text") || codec.contains("tx3g") { return "TX3G" }
        return codec.uppercased()
    }

    /// "Atmos", "7.1", "5.1", "Stereo", "Mono" from a layout name, else from
    /// the channel count.
    static func audioLayout(channelLayout: String?, channels: Int?) -> String? {
        if let layout = nonEmpty(channelLayout) {
            let lowered = layout.lowercased()
            if lowered.contains("atmos") { return "Atmos" }
            if lowered.contains("7.1") { return "7.1" }
            if lowered.contains("5.1") { return "5.1" }
            if lowered.contains("stereo") { return "Stereo" }
            return layout
        }
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        case let channels? where channels > 0: return "\(channels)ch"
        default: return nil
        }
    }

    /// An audio title worth showing, or nil when it only restates the codec.
    static func audioTitle(_ title: String?) -> String? {
        guard let title = nonEmpty(title) else { return nil }
        // Whole words only, so "Commentary by Isaac" keeps its title while
        // "AAC2.0" and "DTSHD" still count as codec names.
        let technicalTerm = #"\b(atsc|a/52|e?-?ac-?3|truehd|dts(-?hd)?|aac|flac)(?![a-z])"#
        if title.range(of: technicalTerm, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        return displayTitle(title)
    }

    /// A subtitle title worth showing: not a format name, the codec, the
    /// language, or a flag the row already shows (Forced, SDH). "Signs &
    /// Songs" or "Dub (SDH)" survive; "ASS", "SubRip", or "English" don't.
    static func subtitleTitle(_ title: String?, language: String?, codec: String?) -> String? {
        guard let title = nonEmpty(title) else { return nil }
        let lowered = title.lowercased()
        let formatNames: Set<String> = [
            "ass", "ssa", "srt", "subrip", "pgs", "sup", "sub",
            "vtt", "webvtt", "vobsub", "dvdsub", "mov_text",
        ]
        let flagNames: Set<String> = ["forced", "sdh", "cc", "hi", "hearing impaired"]
        if formatNames.contains(lowered) || flagNames.contains(lowered) { return nil }
        if lowered == "subtitle" || lowered == "subtitles" { return nil }
        if let name = languageName(language)?.lowercased(), lowered == name { return nil }
        if let code = nonEmpty(language)?.lowercased(), lowered == code { return nil }
        if let codec = nonEmpty(codec)?.lowercased(),
           lowered == codec || lowered == subtitleCodec(codec)?.lowercased() {
            return nil
        }
        return displayTitle(title)
    }

    static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "sdh": return "SDH"
        case "cc": return "CC"
        case "srt", "subrip": return "SubRip"
        case "webvtt", "vtt": return "WebVTT"
        default: return trimmed
        }
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

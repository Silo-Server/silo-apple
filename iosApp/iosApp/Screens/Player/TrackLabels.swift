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

    /// A title worth a secondary line: nil when it is missing or only repeats
    /// the row's name.
    static func qualifier(_ title: String?, name: String) -> String? {
        guard let title, title.caseInsensitiveCompare(name) != .orderedSame else { return nil }
        return title
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

    /// An audio title without the codec, channel layout, and language the
    /// row already shows: "Director Commentary AAC" reads "Director
    /// Commentary"; "DTS-HD MA 5.1", "English 5.1", or "ENG (eac3)" for an
    /// English track leave nothing, so they are nil.
    static func audioTitle(_ title: String?, language: String? = nil) -> String? {
        guard let title = nonEmpty(title), !looksLikeReleaseName(title) else { return nil }
        var remainder = title
            .replacingOccurrences(of: audioTechnicalTerm, with: " ", options: [.regularExpression, .caseInsensitive])
        if let language = languageName(language) {
            remainder = removingWords(from: remainder) { word in
                word.caseInsensitiveCompare(language) == .orderedSame
                    || ((2...3).contains(word.count) && languageName(word) == language)
            }
        }
        remainder = remainder
            .replacingOccurrences(of: #"\([^\p{L}\p{N}]*\)|\[[^\p{L}\p{N}]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_:/|,.+·").union(.whitespaces))
        // A lone leftover letter ("X" from "DTS:X") says nothing, nor does
        // the "Track 2" left of a name the demuxer made up.
        guard remainder.filter(\.isLetter).count > 1,
              remainder.range(of: #"^(?:audio\s+)?track\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }
        return displayTitle(remainder)
    }

    /// Codec names and their qualifiers as whole words, so "Commentary by
    /// Isaac" keeps its title while "AAC2.0" and "DTSHD" still match; and
    /// channel layouts such as "5.1" or "6ch".
    private static let audioTechnicalTerm = #"(?<![0-9.])(?:\d\.\d(?:ch)?|\d+ch)(?![0-9a-z])"#
        + #"|\b(?:atsc|a/52b?|e?-?ac-?3|ec-?3|true[\s-]?hd|aac|flac|alac|opus|vorbis|mp3|pcm(?:_[a-z0-9]+)?"#
        + #"|atmos|joc|dd\+?|ddp|stereo|mono|surround|dolby|digital(?:\s*plus)?"#
        + #"|dts(?:-?hd)?(?:[\s:-]*(?:ma|master\s+audio|hra?|high\s+resolution(?:\s+audio)?|es|x))?)(?![a-z])"#

    /// `text` with every whole word that `matches` replaced by a space.
    private static func removingWords(from text: String, where matches: (String) -> Bool) -> String {
        let result = NSMutableString(string: text)
        let words = wordPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for word in words.reversed() where matches(result.substring(with: word.range)) {
            result.replaceCharacters(in: word.range, with: " ")
        }
        return result as String
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"\p{L}+"#)

    /// Release groups often stamp every track with the release name
    /// ("Movie (2026) [Remux-2160p HEVC DV …]"), which says nothing about the
    /// track.
    private static func looksLikeReleaseName(_ title: String) -> Bool {
        let lowered = title.lowercased()
        let markers = [
            "2160p", "1080p", "720p", "480p", "remux", "bluray", "blu-ray",
            "web-dl", "webrip", "hdtv", "x264", "x265", "h.264", "h.265",
            "hevc", "10-bit", "hdr10", ".mkv", ".mp4",
        ]
        return markers.contains { lowered.contains($0) }
    }

    /// A subtitle title worth showing: not a format name, the codec, the
    /// language, or a flag the row already shows (Forced, SDH). "Signs &
    /// Songs" or "Dub (SDH)" survive; "ASS", "SubRip", "English", or a
    /// release name don't. `showsHearingImpaired` says whether the row shows
    /// the SDH flag.
    static func subtitleTitle(
        _ title: String?,
        language: String?,
        codec: String?,
        showsHearingImpaired: Bool
    ) -> String? {
        guard let title = nonEmpty(title), !looksLikeReleaseName(title) else { return nil }
        let lowered = title.lowercased()
        let formatNames: Set<String> = [
            "ass", "ssa", "srt", "subrip", "pgs", "sup", "sub",
            "vtt", "webvtt", "vobsub", "dvdsub", "mov_text",
        ]
        var flagNames: Set<String> = ["forced", "sdh", "cc", "hearing impaired"]
        // A title of "HI" alone doesn't set the SDH flag, so it only repeats
        // the flag when the track's disposition sets it.
        if showsHearingImpaired { flagNames.insert("hi") }
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

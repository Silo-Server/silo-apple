//
//  SubtitleDisplayOrder.swift
//  Silo (iOS + tvOS + macOS)
//
//  Canonical language grouping + format-priority ordering for subtitle
//  track lists, shared by every surface that lists subtitles:
//    - the detail-page selector (`DetailPlaybackFormatting.subtitleOptions`)
//    - the in-player picker (`PlayerViewModel.orderedSubtitleTracks`)
//
//  The rules, in priority order:
//    1. Group by language. A language never splits into two groups —
//       2-letter and 3-letter ISO codes ("en"/"eng") collapse to one key.
//    2. Order the groups: the user's preferred subtitle language first,
//       then the remaining languages alphabetically by English display
//       name. Tracks with no usable language sort into a final group.
//    3. Within a group, order by preferred format (SubRip › ASS › SSA ›
//       WebVTT › TX3G › PGS/VobSub › unknown), then full-dialogue before
//       forced before SDH, then default-flagged first, then original order.
//
//  The sort is stable: tracks that compare equal keep their incoming
//  relative order. Reordering only changes *display* position — callers
//  select tracks by a stable id (FFmpeg `index` on the detail page,
//  `trackId` in the player) that travels with each row, so ordering never
//  affects which track gets picked.
//

import Foundation

enum SubtitleDisplayOrder {

    /// The minimal slice of a track the ordering needs. Both the
    /// server-side `SubtitleTrack` and the runtime `PlayerTrack` map onto
    /// this via a small closure at the call site, so one ordering pass
    /// serves both worlds.
    struct Descriptor {
        let language: String?
        let codec: String?
        let isForced: Bool
        let isHearingImpaired: Bool
        let isDefault: Bool
    }

    /// Stable reorder. `preferredLanguage` (if any) floats its language
    /// group to the top; pass nil for plain alphabetical grouping.
    static func order<T>(
        _ items: [T],
        preferredLanguage: String?,
        descriptor: (T) -> Descriptor
    ) -> [T] {
        guard items.count > 1 else { return items }

        let annotated: [(item: T, descriptor: Descriptor, key: String?)] =
            items.map { item in
                let d = descriptor(item)
                return (item, d, canonicalLanguageKey(d.language))
            }

        let preferredKey = canonicalLanguageKey(preferredLanguage)

        // Distinct named language keys, ordered: preferred first, then by
        // English display name (case-insensitive), then by key as a final
        // tiebreaker so the order is fully deterministic.
        let sortedNamedKeys = Array(Set(annotated.compactMap(\.key))).sorted { a, b in
            if let preferredKey {
                if a == preferredKey, b != preferredKey { return true }
                if b == preferredKey, a != preferredKey { return false }
            }
            let cmp = languageDisplayName(a).localizedCaseInsensitiveCompare(languageDisplayName(b))
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return a < b
        }

        var groupRank: [String: Int] = [:]
        for (rank, key) in sortedNamedKeys.enumerated() {
            groupRank[key] = rank
        }
        // Tracks with no usable language code sort after every named group.
        let unknownGroupRank = sortedNamedKeys.count

        // Precompute each element's sort key once. The trailing original
        // index keeps the order total and tie-free, so equal-ranked tracks
        // keep their incoming relative order (stable).
        return annotated
            .enumerated()
            .map { index, entry -> (item: T, sortKey: (Int, Int, Int, Int, Int)) in
                let group = entry.key.flatMap { groupRank[$0] } ?? unknownGroupRank
                let d = entry.descriptor
                // full dialogue (0) < forced (1) < SDH (2)
                let variant = d.isHearingImpaired ? 2 : (d.isForced ? 1 : 0)
                let defaultRank = d.isDefault ? 0 : 1
                return (entry.item, (group, formatRank(d.codec), variant, defaultRank, index))
            }
            .sorted { $0.sortKey < $1.sortKey }
            .map(\.item)
    }

    // MARK: - Ranking helpers

    /// Lower comes first. SubRip leads; bitmap formats trail; unknown last.
    static func formatRank(_ codec: String?) -> Int {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return 7 }
        if codec == "srt" || codec.contains("subrip") { return 0 }
        if codec.contains("ass") { return 1 }
        if codec.contains("ssa") { return 2 }
        if codec == "vtt" || codec.contains("webvtt") { return 3 }
        if codec.contains("mov_text") || codec.contains("movtext") || codec.contains("tx3g") { return 4 }
        if codec.contains("pgs") || codec.contains("hdmv") { return 5 }
        if codec.contains("dvd") || codec.contains("vobsub") || codec.contains("dvb") { return 6 }
        return 7
    }

    /// Canonical lowercased grouping key: primary subtag, with known
    /// 3-letter ISO 639-2 codes folded onto their 2-letter 639-1 form so
    /// "en" and "eng" land in the same group. Returns nil for empty /
    /// "und" so those tracks form the trailing unknown group.
    static func canonicalLanguageKey(_ code: String?) -> String? {
        guard let trimmed = code?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let normalized = trimmed.lowercased().replacingOccurrences(of: "_", with: "-")
        let primary = normalized.split(separator: "-").first.map(String.init) ?? normalized
        if primary.isEmpty || primary == "und" { return nil }
        return iso639Alias[primary] ?? primary
    }

    /// English display name for a canonical key, used for alphabetical
    /// group ordering. Falls back to the uppercased code.
    static func languageDisplayName(_ key: String) -> String {
        if let name = Locale(identifier: "en_US_POSIX").localizedString(forLanguageCode: key) {
            return name.capitalized
        }
        return key.uppercased()
    }

    // MARK: - Private

    /// 3-letter ISO 639-2 (B and T) → 2-letter ISO 639-1, for the
    /// languages that realistically appear in subtitle metadata. The
    /// server passes through whatever the source codec carried, mixing
    /// both forms, so grouping has to canonicalize.
    private static let iso639Alias: [String: String] = [
        "ara": "ar",
        "ben": "bn",
        "bul": "bg",
        "chi": "zh", "zho": "zh",
        "cze": "cs", "ces": "cs",
        "dan": "da",
        "dut": "nl", "nld": "nl",
        "eng": "en",
        "est": "et",
        "fin": "fi",
        "fra": "fr", "fre": "fr",
        "ger": "de", "deu": "de",
        "gre": "el", "ell": "el",
        "heb": "he",
        "hin": "hi",
        "hun": "hu",
        "ice": "is", "isl": "is",
        "ind": "id",
        "ita": "it",
        "jpn": "ja",
        "kor": "ko",
        "lav": "lv",
        "lit": "lt",
        "may": "ms", "msa": "ms",
        "nor": "no", "nob": "no", "nno": "no",
        "pol": "pl",
        "por": "pt",
        "rum": "ro", "ron": "ro",
        "rus": "ru",
        "slo": "sk", "slk": "sk",
        "slv": "sl",
        "spa": "es",
        "swe": "sv",
        "tha": "th",
        "tur": "tr",
        "ukr": "uk",
        "vie": "vi",
    ]
}

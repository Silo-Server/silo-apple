//
//  PlaybackPrefsResolver.swift
//  Continuum (iOS + tvOS)
//
//  Pure resolution logic that turns the server-provided
//  `effective_subtitle_*` fields (carried on `WatchDetail`) into a
//  concrete subtitle-track selection once FFmpeg has reported the
//  available tracks. No I/O, no actor isolation — testable in
//  isolation from the player.
//
//  Audio resolution is *not* done here: the server's `/playback/start`
//  endpoint already picks an audio track based on per-series and
//  per-library prefs and returns it as `session.audioTrackIndex`.
//  PlayerViewModel feeds that index in as `pendingAudioFfIndex` and
//  the existing pending-match path applies it.
//

import Foundation

enum SubtitleAutoSelection: Equatable {
    /// User had no preferences that point at a track, or already had
    /// an explicit override, or `mode == off`. Caller should leave the
    /// subtitle slot however the player started it.
    case noChange
    /// User wants subs disabled for this content.
    case disable
    /// Auto-select this track from the list.
    case select(PlayerTrack)
}

struct SubtitleAutoResolver {

    struct Inputs {
        /// `subtitle_language` cascaded down to this content. `nil`
        /// means the user has no preference at any level. Empty
        /// string means "no subs" — distinct from no preference.
        let preferredLanguage: String?
        /// `subtitle_mode` from the cascade. `nil` → fall back to "auto".
        let mode: SubtitleMode?
        /// Whether forced subs should be auto-selected when available.
        let showForced: Bool
        /// Per-series sticky pick. Highest priority signal — if a track
        /// matches the signature, select it regardless of language /
        /// mode.
        let trackSignature: SubtitleTrackSignature?
        /// Tracks we can choose from (already-discovered embedded +
        /// sidecar entries).
        let availableSubtitles: [PlayerTrack]
        /// Language of the audio track currently playing. Used by
        /// "auto" mode to skip subs when audio matches the user's
        /// preferred subtitle language (e.g. English audio + English
        /// sub preference → no subs).
        let currentAudioLanguage: String?
    }

    /// Resolve a subtitle pick. Caller is expected to skip this when
    /// the user already chose something explicit (e.g. via the route
    /// arguments) — the resolver is for the "no override" case.
    static func resolve(_ inputs: Inputs) -> SubtitleAutoSelection {
        if inputs.availableSubtitles.isEmpty {
            return .noChange
        }

        let mode = inputs.mode ?? .auto

        if mode == .off {
            return .disable
        }

        if let signature = inputs.trackSignature,
           let match = bestSignatureMatch(signature, in: inputs.availableSubtitles) {
            return .select(match)
        }

        guard let rawLang = inputs.preferredLanguage else {
            // No language preference recorded anywhere. Honour `always`
            // by trying any default forced track but otherwise leave
            // alone — auto-enabling a random language would surprise.
            if mode == .always, let any = bestLanguageMatch(nil, in: inputs.availableSubtitles, preferForced: inputs.showForced) {
                return .select(any)
            }
            return .noChange
        }

        if rawLang.isEmpty {
            // User explicitly said "no subs" at this level.
            return .disable
        }

        // Auto mode skips subs when the audio is already in the
        // preferred subtitle language — the one case where the forced
        // (signs/foreign-dialogue-only) track is what "show forced
        // subtitles" is FOR. Mirrors the Android resolver.
        if mode == .auto, let audio = inputs.currentAudioLanguage,
           languagesMatch(audio, rawLang) {
            if inputs.showForced,
               let forced = inputs.availableSubtitles.first(where: { track in
                   track.isForced
                       && track.lang.map { languagesMatch($0, rawLang) } == true
               }) {
                return .select(forced)
            }
            return .disable
        }

        // The user wants readable subs in this language: always the
        // full-dialogue track. `showForced` must NOT steal this pick —
        // a forced track is signs-only and reads as "subtitles stopped
        // working" minutes into any dialogue scene.
        if let pick = bestLanguageMatch(rawLang, in: inputs.availableSubtitles, preferForced: false) {
            return .select(pick)
        }

        // No matching language. `always` could fall back to anything,
        // but unless forced subs are wanted we'd rather show nothing
        // than a random language the user can't read.
        if inputs.showForced, let forced = inputs.availableSubtitles.first(where: { $0.isForced }) {
            return .select(forced)
        }
        return .noChange
    }

    // MARK: - Matching helpers

    /// Score-based signature match. Higher score = better. Returns the
    /// top scorer, or nil when no track matched a strong signal
    /// (language or label) — forced/HI/codec equality alone is
    /// meaningless since `false == false` holds for nearly every track,
    /// and a weak "match" would hijack the Auto path.
    private static func bestSignatureMatch(
        _ sig: SubtitleTrackSignature,
        in tracks: [PlayerTrack]
    ) -> PlayerTrack? {
        var best: (PlayerTrack, Int)?
        for track in tracks {
            var score = 0
            var strongSignal = false
            if let sigLang = sig.language, !sigLang.isEmpty,
               let trackLang = track.lang, languagesMatch(trackLang, sigLang) {
                score += 5
                strongSignal = true
            }
            if sig.forced == track.isForced {
                score += 1
            }
            if sig.hearingImpaired == track.isHearingImpaired {
                score += 1
            }
            if let sigCodec = sig.codec, let trackCodec = track.codec,
               sigCodec.caseInsensitiveCompare(trackCodec) == .orderedSame {
                score += 1
            }
            if let sigLabel = sig.label, !sigLabel.isEmpty,
               let title = track.title,
               title.localizedCaseInsensitiveContains(sigLabel) {
                score += 2
                strongSignal = true
            }
            if strongSignal, score > (best?.1 ?? 0) {
                best = (track, score)
            }
        }
        return best?.0
    }

    /// Pick the best language-matched track. Prefers non-forced
    /// (full-dialogue) when `preferForced` is false; otherwise the
    /// first forced match if any. Falls back to the first language
    /// match in either category.
    private static func bestLanguageMatch(
        _ language: String?,
        in tracks: [PlayerTrack],
        preferForced: Bool
    ) -> PlayerTrack? {
        let pool: [PlayerTrack]
        if let lang = language {
            pool = tracks.filter {
                guard let trackLang = $0.lang else { return false }
                return languagesMatch(trackLang, lang)
            }
        } else {
            pool = tracks
        }
        guard !pool.isEmpty else { return nil }
        if preferForced, let forced = pool.first(where: { $0.isForced }) {
            return forced
        }
        if let nonForced = pool.first(where: {
            !$0.isForced && !$0.isHearingImpaired && !titleIndicatesHearingImpaired($0.title)
        }) {
            return nonForced
        }
        if let nonForced = pool.first(where: { !$0.isForced }) {
            return nonForced
        }
        return pool.first
    }

    /// CC/SDH detection from the track title, for files that label the
    /// track ("English (CC)", "English SDH") without setting the ffmpeg
    /// hearing-impaired disposition flag. "cc"/"sdh" must match as whole
    /// tokens — a bare substring check would hit words like "soccer".
    static func titleIndicatesHearingImpaired(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        let lowered = title.lowercased()
        if lowered.contains("hearing impaired") || lowered.contains("closed caption") {
            return true
        }
        let tokens = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return tokens.contains("cc") || tokens.contains("sdh")
    }

    /// Loose ISO 639 comparison. Accepts mixed 2-letter / 3-letter
    /// codes by mapping known pairs ("en"↔"eng", "es"↔"spa", etc.).
    /// Falls back to case-insensitive prefix match for codes outside
    /// the table.
    static func languagesMatch(_ a: String, _ b: String) -> Bool {
        let la = a.lowercased()
        let lb = b.lowercased()
        if la == lb { return true }
        if let alt = isoEquivalent[la], alt == lb { return true }
        if let alt = isoEquivalent[lb], alt == la { return true }
        // Some mux tools emit hyphenated forms like "en-us"; compare on
        // the primary subtag.
        let primaryA = la.split(separator: "-").first.map(String.init) ?? la
        let primaryB = lb.split(separator: "-").first.map(String.init) ?? lb
        if primaryA == primaryB { return true }
        if let alt = isoEquivalent[primaryA], alt == primaryB { return true }
        if let alt = isoEquivalent[primaryB], alt == primaryA { return true }
        return false
    }

    /// 2-letter ↔ 3-letter ISO 639 mapping for the languages our prefs
    /// editor exposes. Server uses both forms interchangeably depending
    /// on the source codec metadata, so the client has to match either.
    private static let isoEquivalent: [String: String] = [
        "en": "eng", "eng": "en",
        "es": "spa", "spa": "es",
        "fr": "fre", "fre": "fr", "fra": "fr",
        "de": "ger", "ger": "de", "deu": "de",
        "it": "ita", "ita": "it",
        "pt": "por", "por": "pt",
        "ja": "jpn", "jpn": "ja",
        "ko": "kor", "kor": "ko",
        "zh": "chi", "chi": "zh", "zho": "zh",
        "ru": "rus", "rus": "ru",
        "ar": "ara", "ara": "ar",
        "hi": "hin", "hin": "hi",
    ]
}

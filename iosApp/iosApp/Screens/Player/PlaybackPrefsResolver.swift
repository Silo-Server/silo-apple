//
//  PlaybackPrefsResolver.swift
//  Silo (iOS + tvOS)
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
//  PlayerViewModel feeds that index in as the track selection's
//  `AudioSelection.planIndex` rung and the track-list funnel applies it.
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
        /// Additional ordered language fallbacks. Used by Apple's caption
        /// profile, which exposes a stack rather than one server value.
        let additionalPreferredLanguages: [String]
        /// `subtitle_mode` from the cascade. `nil` → fall back to "auto".
        let mode: SubtitleMode?
        /// Whether forced subs should be auto-selected when available.
        let showForced: Bool
        /// Apple's Forced Only display mode.
        let forcedOnly: Bool
        /// Prefer CC/SDH over plain subtitles when Apple requests the
        /// accessibility media characteristics.
        let preferAccessibilityTracks: Bool
        /// An explicit device language stack is authoritative. If none of
        /// those languages exists, clear any server-selected subtitle rather
        /// than leaking the server profile back into device-settings mode.
        let disableWhenNoLanguageMatch: Bool
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

        init(
            preferredLanguage: String?,
            additionalPreferredLanguages: [String] = [],
            mode: SubtitleMode?,
            showForced: Bool,
            forcedOnly: Bool = false,
            preferAccessibilityTracks: Bool = false,
            disableWhenNoLanguageMatch: Bool = false,
            trackSignature: SubtitleTrackSignature?,
            availableSubtitles: [PlayerTrack],
            currentAudioLanguage: String?
        ) {
            self.preferredLanguage = preferredLanguage
            self.additionalPreferredLanguages = additionalPreferredLanguages
            self.mode = mode
            self.showForced = showForced
            self.forcedOnly = forcedOnly
            self.preferAccessibilityTracks = preferAccessibilityTracks
            self.disableWhenNoLanguageMatch = disableWhenNoLanguageMatch
            self.trackSignature = trackSignature
            self.availableSubtitles = availableSubtitles
            self.currentAudioLanguage = currentAudioLanguage
        }
    }

    /// Resolve a subtitle pick. Caller is expected to skip this when
    /// the user already chose something explicit (e.g. via the route
    /// arguments) — the resolver is for the "no override" case.
    static func resolve(_ inputs: Inputs) -> SubtitleAutoSelection {
        if inputs.availableSubtitles.isEmpty {
            return inputs.disableWhenNoLanguageMatch ? .disable : .noChange
        }

        let mode = inputs.mode ?? .auto

        if mode == .off {
            return .disable
        }

        let preferredLanguages = orderedLanguages(from: inputs)

        if inputs.forcedOnly {
            if let forced = bestLanguageMatch(
                preferredLanguages,
                in: inputs.availableSubtitles.filter(\.isForced),
                preferForced: true,
                preferAccessibility: inputs.preferAccessibilityTracks
            ) {
                return .select(forced)
            }
            return .disable
        }

        if let signature = inputs.trackSignature,
           let match = bestSignatureMatch(signature, in: inputs.availableSubtitles) {
            return .select(match)
        }

        guard let rawLang = inputs.preferredLanguage else {
            // No language preference recorded anywhere. Honour `always`
            // by choosing the best available track, but otherwise leave
            // alone — auto-enabling a random language would surprise.
            if mode == .always, let any = bestLanguageMatch(
                nil,
                in: inputs.availableSubtitles,
                preferForced: inputs.showForced,
                preferAccessibility: inputs.preferAccessibilityTracks
            ) {
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
           preferredLanguages.contains(where: { languagesMatch(audio, $0) }) {
            if inputs.showForced,
               let matchingLanguage = preferredLanguages.first(where: {
                   normalizedLanguageIdentifier(audio) == normalizedLanguageIdentifier($0)
               }) ?? preferredLanguages.first(where: { languagesMatch(audio, $0) }),
               let forced = bestLanguageMatch(
                   matchingLanguage,
                   in: inputs.availableSubtitles.filter(\.isForced),
                   preferForced: true,
                   preferAccessibility: inputs.preferAccessibilityTracks
               ) {
                return .select(forced)
            }
            return .disable
        }

        // The user wants readable subs in this language: always the
        // full-dialogue track. `showForced` must NOT steal this pick —
        // a forced track is signs-only and reads as "subtitles stopped
        // working" minutes into any dialogue scene.
        if let pick = bestLanguageMatch(
            preferredLanguages,
            in: inputs.availableSubtitles,
            preferForced: false,
            preferAccessibility: inputs.preferAccessibilityTracks
        ) {
            return .select(pick)
        }

        // No matching language. `always` could fall back to anything,
        // but unless forced subs are wanted we'd rather show nothing
        // than a random language the user can't read.
        if !inputs.disableWhenNoLanguageMatch,
           inputs.showForced,
           let forced = inputs.availableSubtitles.first(where: { $0.isForced }) {
            return .select(forced)
        }
        return inputs.disableWhenNoLanguageMatch ? .disable : .noChange
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
        preferForced: Bool,
        preferAccessibility: Bool = false
    ) -> PlayerTrack? {
        guard let language else {
            return bestTrackClass(in: tracks, preferForced: preferForced,
                                  preferAccessibility: preferAccessibility)
        }
        return bestLanguageMatch(
            [language],
            in: tracks,
            preferForced: preferForced,
            preferAccessibility: preferAccessibility
        )
    }

    /// Apply track-class priority before regional exactness: a full-dialogue
    /// generic-language track must beat an exact signs-only track. Within the
    /// same class, exhaust Apple's ordered exact locale matches before falling
    /// back to primary-language equivalence.
    private static func bestLanguageMatch(
        _ languages: [String],
        in tracks: [PlayerTrack],
        preferForced: Bool,
        preferAccessibility: Bool
    ) -> PlayerTrack? {
        let predicates = trackClassPredicates(
            preferForced: preferForced,
            preferAccessibility: preferAccessibility
        )
        for predicate in predicates {
            for language in languages {
                let normalized = normalizedLanguageIdentifier(language)
                if let exact = tracks.first(where: { track in
                    predicate(track)
                        && track.lang.map(normalizedLanguageIdentifier) == normalized
                }) {
                    return exact
                }
            }
            for language in languages {
                if let fallback = tracks.first(where: { track in
                    predicate(track)
                        && track.lang.map { languagesMatch($0, language) } == true
                }) {
                    return fallback
                }
            }
        }
        return nil
    }

    private static func bestTrackClass(
        in tracks: [PlayerTrack],
        preferForced: Bool,
        preferAccessibility: Bool
    ) -> PlayerTrack? {
        for predicate in trackClassPredicates(
            preferForced: preferForced,
            preferAccessibility: preferAccessibility
        ) {
            if let track = tracks.first(where: predicate) { return track }
        }
        return nil
    }

    private static func trackClassPredicates(
        preferForced: Bool,
        preferAccessibility: Bool
    ) -> [(PlayerTrack) -> Bool] {
        let accessible: (PlayerTrack) -> Bool = {
            !$0.isForced && ($0.isHearingImpaired || titleIndicatesHearingImpaired($0.title))
        }
        let plain: (PlayerTrack) -> Bool = {
            !$0.isForced && !$0.isHearingImpaired && !titleIndicatesHearingImpaired($0.title)
        }
        let nonForced: (PlayerTrack) -> Bool = { !$0.isForced }
        let forced: (PlayerTrack) -> Bool = { $0.isForced }

        if preferForced { return [forced, accessible, plain, nonForced, { _ in true }] }
        if preferAccessibility { return [accessible, plain, nonForced, forced, { _ in true }] }
        return [plain, nonForced, forced, { _ in true }]
    }

    private static func orderedLanguages(from inputs: Inputs) -> [String] {
        guard let first = inputs.preferredLanguage, !first.isEmpty else { return [] }
        var result: [String] = []
        for language in [first] + inputs.additionalPreferredLanguages where !language.isEmpty {
            let normalized = normalizedLanguageIdentifier(language)
            if !result.contains(where: {
                normalizedLanguageIdentifier($0) == normalized
            }) {
                result.append(language)
            }
        }
        return result
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

    /// Loose ISO 639 comparison. Foundation canonicalizes arbitrary alpha-2,
    /// alpha-3 terminology, and alpha-3 bibliographic spellings before the
    /// primary language subtags are compared. This keeps Apple locale tags
    /// such as `nl-NL` equivalent to mux metadata such as `nld` without a
    /// hand-maintained language allowlist.
    static func languagesMatch(_ a: String, _ b: String) -> Bool {
        let la = normalizedLanguageIdentifier(a)
        let lb = normalizedLanguageIdentifier(b)
        if la == lb { return true }
        return canonicalPrimaryLanguage(la) == canonicalPrimaryLanguage(lb)
    }

    private static func normalizedLanguageIdentifier(_ identifier: String) -> String {
        identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func canonicalPrimaryLanguage(_ identifier: String) -> String {
        let primary = identifier.split(separator: "-").first.map(String.init) ?? identifier
        let languageCode = Locale(identifier: primary).language.languageCode
        return languageCode?.identifier(.alpha2)
            ?? languageCode?.identifier(.alpha3)
            ?? primary
    }
}

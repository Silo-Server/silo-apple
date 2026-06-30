//
//  SubtitleTrackIdentity.swift
//  Continuum (iOS + tvOS)
//
//  Shared identity types used by the libass-backed subtitle pipeline.
//  No libass dependency — consumed by both the renderer layer and the
//  source-coordination layer.
//

import Foundation

/// Primary vs secondary subtitle slot. Matches the user-facing notion of
/// a main caption line + an optional second line (e.g. dual-language
/// learning setups).
enum SubtitleSlot: Int, CaseIterable, Hashable {
    case primary = 0
    case secondary = 1
}

/// AVPlayer-controlled embedded tracks and sidecar tracks don't use the
/// native AVFoundation media-selection ids, so we synthesise `trackId`
/// values for them that can't collide with real FFmpeg stream indices or
/// AVFoundation's small per-kind ids. FFmpeg stream indices realistically
/// fit in the bottom 16 bits; shifting into high ranges is collision-free.
///
/// Three disjoint synthetic partitions, each carrying an ordinal in its
/// low bits:
///   - `avPlayerEmbeddedBase` (`0x2000_0000 ..< 0x4000_0000`): AVPlayer
///     FFmpeg-extracted embedded subtitle, ordinal = FFmpeg stream index.
///   - `sidecarBase` (`0x4000_0000 ..< 0x6000_0000`): server-provided
///     sidecar URL, ordinal = `subtitle_urls[].index`.
///   - `aiLiveBase` (`0x6000_0000 ..< 0x8000_0000`): synthetic live AI
///     subtitle track (cues streamed in over the playback websocket and
///     injected via `ass_process_chunk`), ordinal = a controller-assigned
///     slot ordinal (the `track_key` string → ordinal mapping lives in the
///     controller, since `track_key` is not numeric).
///
/// Used by `PlayerViewModel.selectSubtitle` and both player backends'
/// subtitle-switch paths to dispatch on which partition an id falls in.
/// All partitions stay below `0x8000_0000` so an `Int64` id never goes
/// negative when narrowed to `Int32` for the embedded-stream path.
enum SubtitleTrackIdSpace {
    static let avPlayerEmbeddedBase: Int64 = 0x2000_0000
    static let sidecarBase: Int64 = 0x4000_0000
    static let aiLiveBase: Int64 = 0x6000_0000

    static func makeAVPlayerEmbeddedTrackId(streamIndex: Int32) -> Int64 {
        Self.avPlayerEmbeddedBase | Int64(streamIndex)
    }

    static func makeSidecarTrackId(urlIndex: Int) -> Int64 {
        Self.sidecarBase | Int64(urlIndex)
    }

    /// Build a live AI subtitle track id from a controller-assigned slot
    /// ordinal. The ordinal must fit in the low bits below `aiLiveBase`
    /// (realistically a handful of live tracks per session).
    static func makeAILiveTrackId(_ ordinal: Int) -> Int64 {
        precondition(
            ordinal >= 0 && Int64(ordinal) < (Self.aiLiveBase - Self.sidecarBase),
            "AI-live subtitle ordinal is outside the synthetic partition"
        )
        return Self.aiLiveBase | Int64(ordinal)
    }

    static func isAVPlayerEmbedded(_ trackId: Int64) -> Bool {
        trackId >= Self.avPlayerEmbeddedBase && trackId < Self.sidecarBase
    }

    static func avPlayerEmbeddedStreamIndex(from trackId: Int64) -> Int32 {
        Int32(trackId & (Self.avPlayerEmbeddedBase - 1))
    }

    /// Sidecar ids occupy `[sidecarBase, aiLiveBase)` — the upper bound
    /// keeps AI-live ids from being misclassified as sidecar.
    static func isSidecar(_ trackId: Int64) -> Bool {
        trackId >= Self.sidecarBase && trackId < Self.aiLiveBase
    }

    static func sidecarIndex(from trackId: Int64) -> Int {
        Int(trackId & (Self.sidecarBase - 1))
    }

    /// Live AI subtitle ids occupy `[aiLiveBase, 0x8000_0000)`.
    static func isAILive(_ trackId: Int64) -> Bool {
        trackId >= Self.aiLiveBase && trackId < 0x8000_0000
    }

    /// True for any synthetic id that is NOT a real embedded FFmpeg /
    /// AVFoundation track — i.e. sidecar or AI-live. Used by the
    /// selection-recovery snapshots, which must never re-establish such an
    /// id as an embedded track after a route/quality switch (sidecar has
    /// its own recovery path; AI-live recovery is M4's responsibility).
    static func isSyntheticNonEmbedded(_ trackId: Int64) -> Bool {
        isSidecar(trackId) || isAILive(trackId)
    }
}

/// The result of fetching a sidecar subtitle URL. Used by the fetcher
/// to tell the session which codepath to take.
enum SubtitleFormat: Hashable {
    /// Full ASS/SSA file (server returns `text/x-ssa`).
    case ass
    /// WebVTT (server default for all other text codecs). Converted to
    /// ASS client-side before feeding libass.
    case vtt
    /// SRT (not produced by the server today, but handled so we're not
    /// brittle against future server changes — libass parses SRT natively).
    case srt
}

/// Status of a subtitle slot's content loading. Published by
/// `PlayerViewModel` so UI can show a spinner or a silent-failure
/// indicator when needed.
enum SubtitleLoadStatus: Equatable {
    case idle
    case fetching
    case ready
    case error(String)
}

/// Subtitle auto-selection policy. Today this only owns one rule —
/// "show forced subtitles when the active audio is foreign to the user's
/// preferred audio language" — but the rule is non-trivial enough to
/// deserve a typed home rather than being inlined into `PlayerViewModel`.
enum SubtitleAutoSelectionPolicy {
    /// Picks the best forced subtitle track to surface when audio is
    /// foreign relative to the user's preferred audio language. Returns
    /// nil when no forced track applies (audio matches the preferred
    /// language, or no forced track exists for the chosen subtitle
    /// language).
    ///
    /// The policy is intentionally conservative: it only fires when the
    /// user has not already chosen a subtitle, the audio language is
    /// known, and the audio language is not already in the user's
    /// preferred-audio set. The selected forced track must be in the
    /// user's preferred-subtitle language (or a fallback list).
    ///
    /// - Parameters:
    ///   - audioLanguage: ISO 639 language tag of the active audio track,
    ///     normalized to lowercase (e.g. `"jpn"`, `"en"`).
    ///   - preferredAudioLanguages: User's preferred audio languages, in
    ///     order, normalized to lowercase.
    ///   - preferredSubtitleLanguages: User's preferred subtitle
    ///     languages, in order, normalized to lowercase.
    ///   - subtitleTracks: Candidate tracks to choose from.
    /// - Returns: The trackId of the recommended forced subtitle track,
    ///   or nil if the policy doesn't apply.
    static func recommendedForcedSubtitle(
        audioLanguage: String?,
        preferredAudioLanguages: [String],
        preferredSubtitleLanguages: [String],
        subtitleTracks: [(trackId: Int64, language: String?, isForced: Bool, isHearingImpaired: Bool)]
    ) -> Int64? {
        guard let audioLanguage = audioLanguage?.lowercased(), !audioLanguage.isEmpty else {
            return nil
        }
        let audioIsForeign = !preferredAudioLanguages.contains(audioLanguage)
        guard audioIsForeign else { return nil }
        // Score forced tracks by how well their language matches the
        // user's preferred subtitle order. Skip SDH tracks — users who
        // want SDH choose them explicitly; force-on auto-selection should
        // not surprise non-SDH users with an SDH track.
        let forced = subtitleTracks.filter { $0.isForced && !$0.isHearingImpaired }
        guard !forced.isEmpty else { return nil }
        for preferred in preferredSubtitleLanguages {
            if let match = forced.first(where: { $0.language?.lowercased() == preferred }) {
                return match.trackId
            }
        }
        // No exact preferred-language match — fall back to a forced track
        // in the same language as the rest of the audio's natural
        // companion (English by convention for foreign-audio dubs is the
        // typical localization expectation). The caller can override.
        if let englishForced = forced.first(where: { $0.language?.lowercased() == "en" || $0.language?.lowercased() == "eng" }) {
            return englishForced.trackId
        }
        return nil
    }
}

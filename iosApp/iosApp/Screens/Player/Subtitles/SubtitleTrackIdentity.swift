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

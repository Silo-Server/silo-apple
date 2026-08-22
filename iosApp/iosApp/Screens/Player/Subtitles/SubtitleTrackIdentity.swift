//
//  SubtitleTrackIdentity.swift
//  Continuum (iOS + tvOS)
//
//  Product identity shared by Aether-backed subtitle selection and Silo's
//  realtime AI cue overlay.
//

import Foundation

/// Primary vs secondary subtitle slot. Matches the user-facing notion of
/// a main caption line + an optional second line (e.g. dual-language
/// learning setups).
enum SubtitleSlot: Int, CaseIterable, Hashable {
    case primary = 0
    case secondary = 1
}

/// Aether embedded tracks use their published media-stream ids directly.
/// Server sidecars and app-owned realtime tracks need stable product ids that
/// cannot collide with that engine namespace, so they occupy high partitions.
///
/// Two disjoint synthetic partitions, each carrying an ordinal in its low
/// bits:
///   - `sidecarBase` (`0x4000_0000 ..< 0x6000_0000`): server-provided
///     sidecar URL, ordinal = `subtitle_urls[].index`.
///   - `aiLiveBase` (`0x6000_0000 ..< 0x8000_0000`): synthetic live AI
///     subtitle track (cues streamed over the playback websocket into Silo's
///     Aether-clocked overlay), ordinal = a controller-assigned
///     slot ordinal (the `track_key` string → ordinal mapping lives in the
///     controller, since `track_key` is not numeric).
enum SubtitleTrackIdSpace {
    static let sidecarBase: Int64 = 0x4000_0000
    static let aiLiveBase: Int64 = 0x6000_0000

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

}

//
//  AppleQualityAxes.swift
//  Silo (iOS + tvOS + macOS)
//
//  Translation between the single quality id the Apple UI picks from and the
//  two orthogonal values the settings contract stores.
//
//  The contract has no compound quality. `playback.preferred_quality` is an
//  enum of bare resolutions (auto, 480p, 720p, 1080p, 2160p, original) and
//  `playback.max_bitrate_kbps` is a separate nullable bandwidth cap. Apple's
//  ladder — "1080p-high", "720p-medium", "328p" — was never a third axis, only
//  a bitrate written into the resolution string, and the legacy string-only
//  registry stored it verbatim because it validated nothing.
//
//  The canonical endpoint does validate, so sending "1080p-high" now fails the
//  enum with `invalid_value`. Splitting it here is what keeps the preference
//  syncing at all — and it is also what lets a quality chosen on the web or on
//  Android read back correctly here, since those clients have always stored the
//  two axes (web/src/lib/qualityPresets.ts, Android's QualityPresets.kt).
//
//  The Apple bitrate ladder deliberately stays as it is rather than being
//  retuned to match the web's presets: the tiers are what the in-player
//  switcher already offers, and changing what "1080p High" means to a user mid
//  migration would be a silent quality change. The two clients agree on the
//  *axes*; the rungs stay a client-side table on each, which is exactly why the
//  contract keeps them apart.
//
//  Because the ladders differ, rejoining has to decide what to do with a pair
//  that lands between two Apple rungs. The resolution wins — see ``join``. The
//  bitrate axis is not lost; it is carried separately to the one request shape
//  that can express it.
//

import Foundation

/// The contract's two quality axes, as one value.
struct AppleQualityAxes: Equatable {
    /// A member of the contract's `playback.preferred_quality` enum.
    let resolution: String
    /// The `playback.max_bitrate_kbps` cap, or nil for uncapped.
    let bitrateKbps: Int?

    static let auto = AppleQualityAxes(resolution: "auto", bitrateKbps: nil)

    /// Contract enum members, most to least constrained. `original` is absent
    /// on purpose: `ApplePlaybackQuality.normalizeStoredId` collapses it into
    /// `auto`, so this client never stores it.
    static let resolutionMembers = ["auto", "480p", "720p", "1080p", "2160p", "original"]

    /// Split one of this client's stored quality ids into the two axes.
    ///
    /// `328p` has no enum member — it predates the contract's ladder. It maps
    /// to `480p` and keeps its 700 kbps cap on the bitrate axis rather than
    /// widening to `auto`: the user asked for the tightest tier, and dropping
    /// the cap would silently uncap their connection.
    static func split(_ qualityId: String) -> AppleQualityAxes {
        let normalized = ApplePlaybackQuality.normalizeStoredId(qualityId)
        guard let option = ApplePlaybackQuality.settingsOptions.first(where: { $0.id == normalized }),
              !option.isAuto, !option.isOriginal else {
            return .auto
        }
        let resolution = resolutionMembers.contains(option.resolution) ? option.resolution : "480p"
        return AppleQualityAxes(resolution: resolution, bitrateKbps: option.bitrateKbps)
    }

    /// Recompose the two stored axes into the id this client's pickers use.
    ///
    /// The **resolution axis is authoritative**: the returned tier always names
    /// the resolution that was stored. The bitrate axis only chooses *which
    /// rung of that resolution* — the highest one within the cap, or the
    /// smallest one when the cap sits under all of them.
    ///
    /// It has to work that way because the resolution is the only half of the
    /// pair that reaches the server. The V3 start request reduces this id back
    /// to a bare resolution (`PlaybackSessionBridge.protocolV3QualityPreference`)
    /// and the cap is not a field on it, so a join that traded a resolution
    /// tier away to stay under the cap would give the cap up *and* the
    /// resolution: "1080p at 6 Mbps" — a shared preset, stored identically by
    /// the web and Android clients — used to answer `720p-high` here and send
    /// `720p` while the other two clients sent `1080p` from the same stored
    /// pair. Apple's ladder simply has no 1080p rung below 8 Mbps; that is a
    /// fact about this client's rung table, not about the user's choice.
    ///
    /// The cap is not discarded. It is applied where it is actually
    /// expressible: ``ApplePlaybackQuality/targetBitrateKbps(for:selectedVersion:capKbps:)``
    /// and ``ApplePlaybackQuality/shouldForceTranscode(preferredQualityId:selectedVersion:capKbps:)``
    /// clamp the legacy `/transcode/start` encode target to it, so a stored
    /// 6 Mbps cap transcodes 1080p at 6 Mbps rather than at the rung's 8.
    ///
    /// Only a pair naming a resolution this client has no ladder for — 2160p,
    /// `original`, `auto`, or a member added by a newer server — falls back to
    /// `auto`, which here means "do not cap, direct-play first".
    static func join(resolution: String?, bitrateKbps: Int?) -> String {
        let resolution = (resolution?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "auto"
        if resolution == "auto" || resolution == "original" {
            // A bandwidth cap with no resolution cap has no tier to name: this
            // client's picker is keyed on the resolution axis.
            return ApplePlaybackQuality.autoId
        }

        // Matched on each tier's *contract* resolution rather than its own
        // label, so 328p — whose contract member is 480p — stays a candidate
        // for a stored 480p and round-trips instead of widening to the 480p
        // tier above it. 2160p and any member this build has never seen match
        // nothing, which is the `auto` fallback: the ladder tops out at 1080p
        // and normalizeStoredId has always folded 4K into direct play.
        let atResolution = ApplePlaybackQuality.tiers.filter {
            split($0.id).resolution == resolution
        }
        guard !atResolution.isEmpty else { return ApplePlaybackQuality.autoId }

        guard let cap = bitrateKbps, cap > 0 else {
            // Uncapped: the best rung this resolution offers.
            return atResolution.max(by: { $0.bitrateKbps < $1.bitrateKbps })?.id
                ?? ApplePlaybackQuality.autoId
        }
        if let withinCap = atResolution.filter({ $0.bitrateKbps <= cap })
            .max(by: { $0.bitrateKbps < $1.bitrateKbps }) {
            return withinCap.id
        }
        // The cap is under every rung this resolution has. The resolution is
        // still what the user asked for and what the request carries, so keep
        // it and take the smallest rung; the cap itself is enforced at request
        // time rather than by silently shrinking the picture.
        return atResolution.min(by: { $0.bitrateKbps < $1.bitrateKbps })?.id
            ?? ApplePlaybackQuality.autoId
    }
}

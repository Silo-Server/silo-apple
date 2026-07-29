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

    /// Rank of a contract resolution member, for "no taller than" comparisons.
    private static func rank(_ resolution: String) -> Int? {
        ["480p": 0, "720p": 1, "1080p": 2, "2160p": 3][resolution]
    }

    /// Recompose the two stored axes into the id this client's pickers use.
    ///
    /// Both axes are honoured, not just the resolution. A pair authored on the
    /// web or on Android need not match an Apple tier — the ladders are
    /// deliberately per-client — so this picks the highest tier that is within
    /// *both* caps. "1080p at 6 Mbps" (a web preset with no Apple equivalent)
    /// becomes Apple's 720p High at 4 Mbps rather than its 1080p at 8 Mbps:
    /// exceeding a bandwidth cap the user set is the one outcome that is
    /// actually harmful, since it is usually a metered or slow connection.
    ///
    /// Only a pair below this client's smallest tier, or one naming a
    /// resolution it has no ladder for, falls back to `auto`.
    static func join(resolution: String?, bitrateKbps: Int?) -> String {
        let resolution = (resolution?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "auto"
        if resolution == "auto" || resolution == "original" {
            // A bandwidth cap with no resolution cap has no tier to name: this
            // client's picker is keyed on the resolution axis.
            return ApplePlaybackQuality.autoId
        }
        // 2160p has no tier — the ladder tops out at 1080p, and
        // normalizeStoredId has always folded 4K into auto (direct play).
        guard resolution != "2160p", let ceiling = rank(resolution) else {
            return ApplePlaybackQuality.autoId
        }

        // Compared on each tier's *contract* resolution rather than its own
        // label, so 328p — whose contract member is 480p — stays a candidate
        // and round-trips instead of widening to the 480p tier above it.
        let withinResolution = ApplePlaybackQuality.tiers.filter {
            guard let tierRank = rank(split($0.id).resolution) else { return false }
            return tierRank <= ceiling
        }
        guard !withinResolution.isEmpty else { return ApplePlaybackQuality.autoId }

        guard let cap = bitrateKbps, cap > 0 else {
            // Uncapped: the best tier this resolution allows.
            return best(of: withinResolution, at: resolution) ?? ApplePlaybackQuality.autoId
        }
        let withinBitrate = withinResolution.filter { $0.bitrateKbps <= cap }
        guard !withinBitrate.isEmpty else {
            // The cap is below every tier this client offers, so its smallest
            // is the closest it can get.
            return withinResolution.min(by: { $0.bitrateKbps < $1.bitrateKbps })?.id
                ?? ApplePlaybackQuality.autoId
        }
        return withinBitrate.max(by: { $0.bitrateKbps < $1.bitrateKbps })?.id
            ?? ApplePlaybackQuality.autoId
    }

    /// The highest-bitrate tier, preferring one whose own contract resolution
    /// is the requested one so an uncapped `1080p` does not answer with a 720p
    /// tier that merely happens to sit under it.
    private static func best(
        of tiers: [ApplePlaybackQualityOption],
        at resolution: String
    ) -> String? {
        let exact = tiers.filter { split($0.id).resolution == resolution }
        let candidates = exact.isEmpty ? tiers : exact
        return candidates.max(by: { $0.bitrateKbps < $1.bitrateKbps })?.id
    }
}

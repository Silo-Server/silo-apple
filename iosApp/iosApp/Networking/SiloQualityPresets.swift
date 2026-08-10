//
//  SiloQualityPresets.swift
//  Silo (iOS + tvOS + macOS)
//
//  The quality picker's presets, as every Silo client offers them.
//
//  The server stores two orthogonal values — `playback.preferred_quality` (a
//  resolution cap) and `playback.max_bitrate_kbps` (a bandwidth cap, null for
//  uncapped). This table composes them into the single list a user picks from,
//  and is a field-for-field port of web/src/lib/qualityPresets.ts and Android's
//  QualityPresets.kt so a preset chosen on one platform reads back with the
//  same label on the others.
//
//  Presets live here rather than in the contract on purpose. Baking "high" into
//  an enum member would freeze what it means: retuning 1080p High from 10 to 12
//  Mbps would be a contract change every client has to agree to. As a
//  client-side table it is a one-line edit, and older servers keep working
//  because they only ever see the two axes they already understand.
//
//  This table is the *settings* vocabulary. The in-player quality switcher
//  keeps its own finer-grained ladder (``ApplePlaybackQuality/tiers``), which is
//  what the transcoder's rungs are tuned for and which a user reaches for mid
//  playback rather than as a stored default. The two coexist because a stored
//  preference is a *pair*, never an id — so the two tables can disagree about
//  labels without any stored value being reinterpreted.
//

import Foundation

/// One entry in the shared quality picker.
struct SiloQualityPreset: Identifiable, Hashable {
    let id: String
    let label: String
    let description: String
    /// A member of the contract's `playback.preferred_quality` enum.
    let resolution: String
    /// The `playback.max_bitrate_kbps` cap; nil is uncapped.
    let bitrateKbps: Int?
}

enum SiloQualityPresets {

    static let resolutionAuto = "auto"
    static let resolutionOriginal = "original"

    /// The contract's `playback.preferred_quality` members that name a real
    /// resolution, i.e. everything except the two sentinels.
    private static let concreteResolutions = ["480p", "720p", "1080p", "2160p"]

    static let all: [SiloQualityPreset] = [
        .init(
            id: "auto",
            label: "Auto",
            description: "Silo picks based on your connection.",
            resolution: resolutionAuto,
            bitrateKbps: nil
        ),
        .init(
            id: "original",
            label: "Original",
            description: "Never transcode. Needs bandwidth to match the file.",
            resolution: resolutionOriginal,
            bitrateKbps: nil
        ),
        .init(
            id: "2160p",
            label: "4K",
            description: "Up to 2160p.",
            resolution: "2160p",
            bitrateKbps: nil
        ),
        .init(
            id: "1080p-high",
            label: "1080p High",
            description: "1080p at up to 10 Mbps.",
            resolution: "1080p",
            bitrateKbps: 10_000
        ),
        .init(
            id: "1080p",
            label: "1080p",
            description: "1080p at up to 6 Mbps.",
            resolution: "1080p",
            bitrateKbps: 6_000
        ),
        .init(
            id: "1080p-low",
            label: "1080p Low",
            description: "1080p at up to 3 Mbps, for a slower link.",
            resolution: "1080p",
            bitrateKbps: 3_000
        ),
        .init(
            id: "720p-high",
            label: "720p High",
            description: "720p at up to 4 Mbps.",
            resolution: "720p",
            bitrateKbps: 4_000
        ),
        .init(
            id: "720p",
            label: "720p",
            description: "720p at up to 2 Mbps.",
            resolution: "720p",
            bitrateKbps: 2_000
        ),
        .init(
            id: "480p",
            label: "480p",
            description: "480p at up to 1.5 Mbps, for the tightest connections.",
            resolution: "480p",
            bitrateKbps: 1_500
        ),
    ]

    /// The preset for a stored (resolution, bitrate) pair, or nil for a
    /// combination no preset covers.
    static func preset(resolution: String?, bitrateKbps: Int?) -> SiloQualityPreset? {
        let normalizedResolution = normalizeResolution(resolution)
        let normalizedBitrate = bitrateKbps.flatMap { $0 > 0 ? $0 : nil }
        return all.first {
            $0.resolution == normalizedResolution && $0.bitrateKbps == normalizedBitrate
        }
    }

    static func preset(id: String?) -> SiloQualityPreset? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// A label for any stored pair, including combinations no preset covers —
    /// someone who set the two axes independently through the API, or whose
    /// values came from a client whose own ladder has a rung this table does
    /// not. Shown instead of silently snapping the picker to a nearby preset,
    /// which would misreport what the profile actually has stored.
    static func describe(resolution: String?, bitrateKbps: Int?) -> String {
        if let preset = preset(resolution: resolution, bitrateKbps: bitrateKbps) {
            return preset.label
        }

        let normalized = normalizeResolution(resolution)
        let resolutionLabel: String
        switch normalized {
        case resolutionAuto: resolutionLabel = "Auto"
        case resolutionOriginal: resolutionLabel = "Original"
        case "2160p": resolutionLabel = "4K"
        default: resolutionLabel = normalized
        }

        guard let capped = bitrateKbps, capped > 0 else { return resolutionLabel }
        return "\(resolutionLabel) at \(formatMbps(kbps: capped)) Mbps"
    }

    /// Reduces any stored resolution — including the compound transcode-ladder
    /// spellings older builds wrote (`1080p-high`, `720p-8`, `4k`) — to a
    /// member of the contract's enum.
    ///
    /// The bitrate half of a compound value is dropped rather than guessed at:
    /// the bitrate axis carries it now, and inventing a cap the user never
    /// chose would silently throttle playback.
    static func normalizeResolution(_ value: String?) -> String {
        let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if trimmed.isEmpty { return resolutionAuto }
        if trimmed == resolutionAuto || trimmed == resolutionOriginal { return trimmed }
        if trimmed == "4k" || trimmed == "uhd" { return "2160p" }

        let head = String(trimmed.prefix(while: { $0 != "-" }))
        if concreteResolutions.contains(head) { return head }
        if head == "4k" { return "2160p" }
        return resolutionAuto
    }

    /// Mbps with collapsed integers ("6" not "6.0"), matching the web's and
    /// Android's preset descriptions so the three read identically.
    private static func formatMbps(kbps: Int) -> String {
        if kbps % 1000 == 0 { return String(kbps / 1000) }
        let tenths = Int((Double(kbps) / 100.0).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }
}

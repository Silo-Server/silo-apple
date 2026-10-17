import Foundation

struct ApplePlaybackQualityOption: Identifiable, Hashable {
    let id: String
    let label: String
    let resolution: String
    let bitrateKbps: Int
    let isAuto: Bool

    var subtitle: String? {
        if isAuto {
            return "Original file when possible"
        }
        guard bitrateKbps > 0 else { return nil }
        return "Maximum bitrate: \(bitrateLabel)"
    }

    var bitrateLabel: String {
        ApplePlaybackQuality.formatBitrate(kbps: bitrateKbps)
    }

    /// Bitrate shown beside a capped rung; nil for Auto and rungs without a
    /// bitrate cap.
    var bitrateText: String? {
        guard !isAuto, bitrateKbps > 0 else { return nil }
        return bitrateLabel
    }

    var labelWithBitrate: String {
        bitrateText.map { "\(label) (\($0))" } ?? label
    }
}

struct ApplePlaybackV3QualitySelection: Equatable {
    let clientQualityId: String
    let serverPreference: String
    let bandwidthCapKbps: Int?
    let isServerOwned: Bool
}

enum ApplePlaybackQuality {
    static let autoId = "auto"
    /// Contract-supported resolution with no fabricated local bitrate rung.
    static let ultraHDId = "2160p"
    /// Spellings of the removed Original choice, read as Auto: Auto with no
    /// cap already plays the original file whenever the device can. Older
    /// servers still store them and list an "original" plan entry.
    static let legacySourceIds: Set<String> = ["original", "source", "max"]

    static let auto = ApplePlaybackQualityOption(
        id: autoId,
        label: "Auto",
        resolution: "",
        bitrateKbps: 0,
        isAuto: true
    )

    /// A contract resolution cap without an invented bandwidth rung. A zero
    /// bitrate is a local sentinel for "uncapped" and is never sent as a cap.
    static let ultraHD = ApplePlaybackQualityOption(
        id: ultraHDId,
        label: "4K",
        resolution: ultraHDId,
        bitrateKbps: 0,
        isAuto: false
    )

    static let tiers: [ApplePlaybackQualityOption] = [
        .init(id: "1080p-high", label: "Up to 1080p HD (High)", resolution: "1080p", bitrateKbps: 20_000, isAuto: false),
        .init(id: "1080p-medium", label: "Up to 1080p HD (Medium)", resolution: "1080p", bitrateKbps: 12_000, isAuto: false),
        .init(id: "1080p", label: "Up to 1080p HD", resolution: "1080p", bitrateKbps: 10_000, isAuto: false),
        .init(id: "1080p-8", label: "Up to 1080p HD", resolution: "1080p", bitrateKbps: 8_000, isAuto: false),
        .init(id: "720p-high", label: "Up to 720p HD (High)", resolution: "720p", bitrateKbps: 4_000, isAuto: false),
        .init(id: "720p-medium", label: "Up to 720p HD (Medium)", resolution: "720p", bitrateKbps: 3_000, isAuto: false),
        .init(id: "720p", label: "Up to 720p HD", resolution: "720p", bitrateKbps: 2_000, isAuto: false),
        .init(id: "480p", label: "Up to 480p", resolution: "480p", bitrateKbps: 1_500, isAuto: false),
        .init(id: "328p", label: "Up to 328p", resolution: "328p", bitrateKbps: 700, isAuto: false),
    ]

    static let settingsOptions: [ApplePlaybackQualityOption] = [auto, ultraHD] + tiers

    static func normalizeStoredId(_ raw: String?) -> String {
        let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if value.isEmpty || legacySourceIds.contains(value) {
            return autoId
        }
        switch value {
        case autoId:
            return autoId
        case ultraHDId, "4k", "uhd":
            return ultraHDId
        case "420p":
            return "328p"
        default:
            if settingsOptions.contains(where: { $0.id == value }) {
                return value
            }
            return autoId
        }
    }

    static func displayName(for raw: String) -> String {
        let id = normalizeStoredId(raw)
        if id == ultraHDId { return "4K" }
        return settingsOptions.first(where: { $0.id == id })?.label ?? id
    }

    static func displayNameWithBitrate(for raw: String) -> String {
        let id = normalizeStoredId(raw)
        if id == ultraHDId { return "4K" }
        return settingsOptions.first(where: { $0.id == id })?.labelWithBitrate ?? id
    }

    /// Build the in-player menu from the server's V3 plan. The server owns
    /// which rungs are executable for this source; showing the wider Settings
    /// catalog here would let the user request qualities the active plan never
    /// offered. An "original" entry from an older server is dropped: Auto is
    /// the way back to the source.
    static func playbackOptions(
        serverQualities: [PlaybackV3AvailableQuality]
    ) -> [ApplePlaybackQualityOption] {
        guard !serverQualities.isEmpty else {
            return [auto]
        }
        var seen = Set<String>()
        let planned = serverQualities.compactMap { quality -> ApplePlaybackQualityOption? in
            let id = protocolV3QualityId(quality.label)
            guard id != autoId, seen.insert(id).inserted else { return nil }
            let height = quality.height ?? 0
            return ApplePlaybackQualityOption(
                id: id,
                label: playbackLabel(
                    serverDisplayName: quality.displayName,
                    id: id,
                    height: height
                ),
                resolution: height <= 0 ? "" : "\(height)p",
                bitrateKbps: max(0, quality.bitrateKbps),
                isAuto: false
            )
        }
        return [auto] + planned
    }

    /// Whether the plan offers a fixed quality to pick. Auto is added by the
    /// client, so a menu holding only Auto is no choice.
    static func hasChoice(among options: [ApplePlaybackQualityOption]) -> Bool {
        options.contains { !$0.isAuto }
    }

    /// Quality labels in an active V3 plan are server-owned identifiers. Keep
    /// unknown additive rungs instead of coercing them to Auto; only Settings
    /// persistence uses the closed local catalog in `normalizeStoredId`. The
    /// legacy source spellings are the exception, so "original" is never sent.
    static func protocolV3QualityId(_ raw: String?) -> String {
        let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !value.isEmpty, !legacySourceIds.contains(value) else { return autoId }
        switch value {
        case "4k", "uhd":
            return ultraHDId
        case "420p":
            return "328p"
        default:
            return value
        }
    }

    /// Resolve an in-player V3 choice without confusing a server-owned rung
    /// with a same-named Settings preset. Compound rung labels are exact plan
    /// identities, and their bitrate comes from that plan rather than Apple's
    /// independently maintained Settings ladder.
    ///
    /// Auto keeps `autoBandwidthCapKbps`, the saved cap for the connection
    /// playback is on (nil for "No limit"): picking Auto hands the choice back
    /// to the server without lifting a cap the viewer saved.
    static func protocolV3Selection(
        requestedQualityId: String,
        availableQualities: [PlaybackV3AvailableQuality],
        autoBandwidthCapKbps: Int?
    ) -> ApplePlaybackV3QualitySelection {
        let clientQualityId = protocolV3QualityId(requestedQualityId)
        if clientQualityId == autoId {
            return ApplePlaybackV3QualitySelection(
                clientQualityId: autoId,
                serverPreference: autoId,
                bandwidthCapKbps: autoBandwidthCapKbps.flatMap(positiveBitrate),
                isServerOwned: true
            )
        }
        if let offered = availableQualities.first(where: {
            protocolV3QualityId($0.label) == clientQualityId
        }) {
            return ApplePlaybackV3QualitySelection(
                clientQualityId: clientQualityId,
                serverPreference: clientQualityId,
                bandwidthCapKbps: offered.preservesSource ? nil : positiveBitrate(offered.bitrateKbps),
                isServerOwned: true
            )
        }

        let axes = AppleQualityAxes.split(clientQualityId)
        let serverPreference = settingsOptions.contains(where: { $0.id == clientQualityId })
            ? axes.resolution
            : clientQualityId
        return ApplePlaybackV3QualitySelection(
            clientQualityId: clientQualityId,
            serverPreference: serverPreference,
            bandwidthCapKbps: axes.bitrateKbps,
            isServerOwned: false
        )
    }

    /// A stored settings pair, sent as stored: its resolution is the
    /// preference and its cap the bandwidth cap. Used when the connection
    /// changes and playback moves to the other pair.
    static func protocolV3Selection(axes: AppleQualityAxes) -> ApplePlaybackV3QualitySelection {
        let resolution = SiloQualityPresets.normalizeResolution(axes.resolution)
        let bitrateKbps = axes.bitrateKbps.flatMap(positiveBitrate)
        return ApplePlaybackV3QualitySelection(
            clientQualityId: AppleQualityAxes.join(resolution: resolution, bitrateKbps: bitrateKbps),
            serverPreference: resolution,
            bandwidthCapKbps: bitrateKbps,
            isServerOwned: false
        )
    }

    private static func positiveBitrate(_ bitrateKbps: Int) -> Int? {
        bitrateKbps > 0 ? bitrateKbps : nil
    }

    private static func playbackLabel(
        serverDisplayName: String?,
        id: String,
        height: Int
    ) -> String {
        if let serverDisplayName {
            let normalized = serverDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { return normalized }
        }
        switch height {
        case 2_160: return "Up to 4K"
        case 1_080: return "Up to 1080p HD"
        case 720: return "Up to 720p HD"
        case 480: return "Up to 480p"
        default:
            return settingsOptions.first(where: { $0.id == id })?.label
                ?? (height > 0 ? "Up to \(height)p" : id)
        }
    }

    static func formatBitrate(kbps: Int) -> String {
        if kbps >= 1000 {
            let mbps = Double(kbps) / 1000.0
            if mbps.rounded(.towardZero) == mbps {
                return "\(Int(mbps)) Mbps"
            }
            return String(format: "%.1f Mbps", mbps)
        }
        return "\(kbps) kbps"
    }
}

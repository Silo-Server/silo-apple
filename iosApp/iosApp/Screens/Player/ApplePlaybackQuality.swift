import Foundation

struct ApplePlaybackQualityOption: Identifiable, Hashable {
    let id: String
    let label: String
    let resolution: String
    let bitrateKbps: Int
    let isOriginal: Bool
    let isAuto: Bool

    var subtitle: String? {
        if isOriginal {
            return nil
        }
        if isAuto {
            return "Best available, direct-play first"
        }
        guard bitrateKbps > 0 else { return nil }
        return "Maximum bitrate: \(bitrateLabel)"
    }

    var bitrateLabel: String {
        ApplePlaybackQuality.formatBitrate(kbps: bitrateKbps)
    }

    var labelWithBitrate: String {
        guard !isOriginal, !isAuto, bitrateKbps > 0 else { return label }
        return "\(label) (\(bitrateLabel))"
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
    static let originalId = "original"
    /// Contract-supported resolution with no fabricated local bitrate rung.
    static let ultraHDId = "2160p"

    static let original = ApplePlaybackQualityOption(
        id: originalId,
        label: "Original",
        resolution: "",
        bitrateKbps: 0,
        isOriginal: true,
        isAuto: false
    )

    static let auto = ApplePlaybackQualityOption(
        id: autoId,
        label: "Auto",
        resolution: "",
        bitrateKbps: 0,
        isOriginal: false,
        isAuto: true
    )

    /// A contract resolution cap without an invented bandwidth rung. A zero
    /// bitrate is a local sentinel for "uncapped" and is never sent as a cap.
    static let ultraHD = ApplePlaybackQualityOption(
        id: ultraHDId,
        label: "4K",
        resolution: ultraHDId,
        bitrateKbps: 0,
        isOriginal: false,
        isAuto: false
    )

    static let tiers: [ApplePlaybackQualityOption] = [
        .init(id: "1080p-high", label: "Up to 1080p HD (High)", resolution: "1080p", bitrateKbps: 20_000, isOriginal: false, isAuto: false),
        .init(id: "1080p-medium", label: "Up to 1080p HD (Medium)", resolution: "1080p", bitrateKbps: 12_000, isOriginal: false, isAuto: false),
        .init(id: "1080p", label: "Up to 1080p HD", resolution: "1080p", bitrateKbps: 10_000, isOriginal: false, isAuto: false),
        .init(id: "1080p-8", label: "Up to 1080p HD", resolution: "1080p", bitrateKbps: 8_000, isOriginal: false, isAuto: false),
        .init(id: "720p-high", label: "Up to 720p HD (High)", resolution: "720p", bitrateKbps: 4_000, isOriginal: false, isAuto: false),
        .init(id: "720p-medium", label: "Up to 720p HD (Medium)", resolution: "720p", bitrateKbps: 3_000, isOriginal: false, isAuto: false),
        .init(id: "720p", label: "Up to 720p HD", resolution: "720p", bitrateKbps: 2_000, isOriginal: false, isAuto: false),
        .init(id: "480p", label: "Up to 480p", resolution: "480p", bitrateKbps: 1_500, isOriginal: false, isAuto: false),
        .init(id: "328p", label: "Up to 328p", resolution: "328p", bitrateKbps: 700, isOriginal: false, isAuto: false),
    ]

    static let settingsOptions: [ApplePlaybackQualityOption] = [auto, original, ultraHD] + tiers

    static func normalizeStoredId(_ raw: String?) -> String {
        let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch value {
        case "", autoId:
            return autoId
        case ultraHDId, "4k", "uhd":
            return ultraHDId
        case originalId:
            return originalId
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
    /// offered.
    static func playbackOptions(
        serverQualities: [PlaybackV3AvailableQuality],
        fallbackVersion: FileVersion?
    ) -> [ApplePlaybackQualityOption] {
        guard !serverQualities.isEmpty else {
            return [auto]
        }
        var seen = Set<String>()
        let planned = serverQualities.compactMap { quality -> ApplePlaybackQualityOption? in
            let id = protocolV3QualityId(quality.label)
            guard id != autoId, seen.insert(id).inserted else { return nil }
            let isOriginal = quality.preservesSource || id == originalId
            let height = quality.height ?? 0
            return ApplePlaybackQualityOption(
                id: id,
                label: playbackLabel(
                    serverDisplayName: quality.displayName,
                    id: id,
                    height: height,
                    isOriginal: isOriginal
                ),
                resolution: isOriginal || height <= 0 ? "" : "\(height)p",
                bitrateKbps: max(0, quality.bitrateKbps),
                isOriginal: isOriginal,
                isAuto: false
            )
        }
        return [auto] + planned
    }

    /// Quality labels in an active V3 plan are server-owned identifiers. Keep
    /// unknown additive rungs instead of coercing them to Auto; only Settings
    /// persistence uses the closed local catalog in `normalizeStoredId`.
    static func protocolV3QualityId(_ raw: String?) -> String {
        let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !value.isEmpty else { return autoId }
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
    static func protocolV3Selection(
        requestedQualityId: String,
        availableQualities: [PlaybackV3AvailableQuality]
    ) -> ApplePlaybackV3QualitySelection {
        let clientQualityId = protocolV3QualityId(requestedQualityId)
        if clientQualityId == autoId {
            return ApplePlaybackV3QualitySelection(
                clientQualityId: autoId,
                serverPreference: autoId,
                bandwidthCapKbps: nil,
                isServerOwned: true
            )
        }
        if let offered = availableQualities.first(where: {
            protocolV3QualityId($0.label) == clientQualityId
        }) {
            let preservesSource = offered.preservesSource || clientQualityId == originalId
            return ApplePlaybackV3QualitySelection(
                clientQualityId: clientQualityId,
                serverPreference: clientQualityId,
                bandwidthCapKbps: preservesSource ? nil : positiveBitrate(offered.bitrateKbps),
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

    private static func positiveBitrate(_ bitrateKbps: Int) -> Int? {
        bitrateKbps > 0 ? bitrateKbps : nil
    }

    private static func playbackLabel(
        serverDisplayName: String?,
        id: String,
        height: Int,
        isOriginal: Bool
    ) -> String {
        if isOriginal { return "Original" }
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

    static func activeProtocolV3QualityId(
        requestedQualityId: String?,
        availableQualities: [PlaybackV3AvailableQuality]
    ) -> String {
        let requested = protocolV3QualityId(requestedQualityId)
        guard requested != autoId else { return autoId }
        let requestedResolution = settingsOptions.contains(where: { $0.id == requested })
            ? AppleQualityAxes.split(requested).resolution
            : nil
        return availableQualities.contains(where: { quality in
            let offered = protocolV3QualityId(quality.label)
            return offered == requested
                || requestedResolution.map {
                    AppleQualityAxes.split(offered).resolution == $0
                } == true
        }) ? requested : autoId
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

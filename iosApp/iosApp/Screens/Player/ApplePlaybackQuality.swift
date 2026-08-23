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
                label: playbackLabel(id: id, height: height, isOriginal: isOriginal),
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

    private static func playbackLabel(id: String, height: Int, isOriginal: Bool) -> String {
        if isOriginal { return "Original" }
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

    static func resolvedRequestOption(
        preferredQualityId: String?,
        selectedVersion: FileVersion,
        delivery: PlaybackDeliveryStrategy
    ) -> ApplePlaybackQualityOption {
        let id = normalizeStoredId(preferredQualityId)
        if id == autoId {
            return delivery == .transcode ? auto : original
        }
        return settingsOptions.first(where: { $0.id == id })
            ?? (delivery == .transcode ? auto : original)
    }

    static func activeQualityId(
        requestedQualityId: String?,
        selectedVersion: FileVersion,
        delivery: PlaybackDeliveryStrategy
    ) -> String {
        let id = normalizeStoredId(requestedQualityId)
        if id == autoId {
            return autoId
        }
        if id == ultraHDId {
            return ultraHDId
        }
        if settingsOptions.contains(where: { $0.id == id }) {
            return id
        }
        return autoId
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

    /// Whether changing quality must re-run source-version selection instead
    /// of merely changing the label on the current direct/remux stream.
    ///
    /// A tier that raises the resolution ceiling can make a better alternate
    /// eligible. Legacy playback chooses that alternate only during a fresh
    /// load, so keeping the current file would leave (for example) a 720p file
    /// playing while the controls reported Original or 4K.
    static func shouldReselectSource(
        preferredQualityId: String?,
        selectedVersion: FileVersion,
        availableVersions: [FileVersion]
    ) -> Bool {
        let id = normalizeStoredId(preferredQualityId)
        guard id != autoId,
              let selectedHeight = height(for: selectedVersion.resolution) else {
            return false
        }

        let maximumHeight: Int?
        if id == originalId {
            maximumHeight = nil
        } else if id == ultraHDId {
            maximumHeight = height(for: ultraHDId)
        } else {
            maximumHeight = settingsOptions
                .first(where: { $0.id == id })
                .flatMap { height(for: $0.resolution) }
        }
        guard id == originalId || maximumHeight != nil else { return false }

        return availableVersions.contains { candidate in
            guard candidate.fileId != selectedVersion.fileId,
                  let candidateHeight = height(for: candidate.resolution),
                  candidateHeight > selectedHeight else {
                return false
            }
            return maximumHeight.map { candidateHeight <= $0 } ?? true
        }
    }

    /// Whether this tier requires a transcode for this source.
    ///
    /// `capKbps` is the stored `playback.max_bitrate_kbps` — the bandwidth half
    /// of the quality preference, which is a separate axis from the tier and is
    /// not implied by it. A source inside the tier's own rung bitrate but above
    /// the user's cap still has to be re-encoded; without this, widening the
    /// resolution axis would silently uncap the connection.
    static func shouldForceTranscode(
        preferredQualityId: String?,
        selectedVersion: FileVersion,
        capKbps: Int? = nil
    ) -> Bool {
        let id = normalizeStoredId(preferredQualityId)
        if id == autoId || id == originalId {
            guard let capKbps, capKbps > 0 else { return false }
            return exceedsBitrateCap(selectedVersion, ceilingKbps: capKbps)
        }
        if id == ultraHDId {
            let exceedsBandwidth = capKbps.flatMap { $0 > 0 ? $0 : nil }.map {
                exceedsBitrateCap(selectedVersion, ceilingKbps: $0)
            } ?? false
            return exceedsBandwidth || exceedsResolutionCap(
                selectedVersion,
                targetResolution: ultraHDId
            )
        }
        guard let option = settingsOptions.first(where: { $0.id == id && !$0.isOriginal && !$0.isAuto }) else {
            return false
        }
        return exceedsBitrateCap(selectedVersion, ceilingKbps: ceiling(option.bitrateKbps, capKbps))
            || exceedsResolutionCap(selectedVersion, option: option)
    }

    static func targetResolution(
        for option: ApplePlaybackQualityOption,
        selectedVersion: FileVersion
    ) -> String {
        guard !option.isOriginal, !option.isAuto else { return "" }
        guard let targetHeight = height(for: option.resolution),
              let sourceHeight = height(for: selectedVersion.resolution) else {
            return ""
        }
        return sourceHeight > targetHeight ? option.resolution : ""
    }

    /// The encode target for the legacy `/transcode/start` path.
    ///
    /// The lesser of the source's own bitrate, the tier's rung, and the stored
    /// `playback.max_bitrate_kbps` cap. The cap is the only place the bandwidth
    /// axis can be honoured on this path — the tier is chosen by resolution
    /// (see AppleQualityAxes.swift), so a 1080p preset capped at 6 Mbps arrives
    /// here as the 8 Mbps rung and must still encode at 6.
    static func targetBitrateKbps(
        for option: ApplePlaybackQualityOption,
        selectedVersion: FileVersion,
        capKbps: Int? = nil
    ) -> Int {
        if option.isOriginal || option.isAuto || option.id == ultraHDId {
            guard let capKbps, capKbps > 0 else { return 0 }
            guard let sourceBitrateKbps = sourceBitrateKbps(for: selectedVersion) else {
                return capKbps
            }
            return min(sourceBitrateKbps, capKbps)
        }
        let target = ceiling(option.bitrateKbps, capKbps)
        guard let sourceBitrateKbps = sourceBitrateKbps(for: selectedVersion) else {
            return target
        }
        return min(sourceBitrateKbps, target)
    }

    /// Whether the legacy HLS request should preserve the source video.
    /// A quality-imposed transcode always wins: `original` removes the
    /// resolution ceiling, but it does not cancel an independent bandwidth cap.
    static func shouldUseLegacyCopyVideo(
        delivery: PlaybackDeliveryStrategy,
        option: ApplePlaybackQualityOption,
        forcedByQuality: Bool
    ) -> Bool {
        guard !forcedByQuality else { return false }
        return delivery != .transcode || option.isOriginal
    }

    /// Whether an older server rejecting codec-copy may be retried as H.264.
    /// Original is an explicit no-transcode choice, so its copy failure must
    /// surface instead of silently reducing and re-encoding the video. Auto
    /// can also resolve to an original-quality copy, but retains its historical
    /// compatibility fallback because it did not promise never to transcode.
    static func allowsLegacyCopyFallbackToTranscode(
        preferredQualityId: String?
    ) -> Bool {
        normalizeStoredId(preferredQualityId) != originalId
    }

    /// The older-server retry target after codec copy is rejected. Preserve
    /// the historical 6 Mbps fallback without widening a lower user cap.
    static func legacyCopyFallbackBitrateKbps(capKbps: Int?) -> Int {
        let fallbackKbps = 6_000
        guard let capKbps, capKbps > 0 else { return fallbackKbps }
        return min(fallbackKbps, capKbps)
    }

    /// The tighter of a tier's rung bitrate and an optional user cap.
    private static func ceiling(_ tierKbps: Int, _ capKbps: Int?) -> Int {
        guard let capKbps, capKbps > 0 else { return tierKbps }
        return min(tierKbps, capKbps)
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

    private static func height(for value: String?) -> Int? {
        guard let value = value?.lowercased() else { return nil }
        if value.contains("2160") || value.contains("4k") { return 2160 }
        if value.contains("1080") { return 1080 }
        if value.contains("720") { return 720 }
        if value.contains("480") { return 480 }
        if value.contains("420") { return 420 }
        if value.contains("328") { return 328 }
        return nil
    }

    private static func exceedsBitrateCap(
        _ version: FileVersion,
        ceilingKbps: Int
    ) -> Bool {
        guard let sourceBitrateKbps = sourceBitrateKbps(for: version) else {
            return true
        }
        return sourceBitrateKbps > ceilingKbps
    }

    private static func exceedsResolutionCap(
        _ version: FileVersion,
        option: ApplePlaybackQualityOption
    ) -> Bool {
        exceedsResolutionCap(version, targetResolution: option.resolution)
    }

    private static func exceedsResolutionCap(
        _ version: FileVersion,
        targetResolution: String
    ) -> Bool {
        guard let sourceHeight = height(for: version.resolution),
              let targetHeight = height(for: targetResolution) else {
            return false
        }
        return sourceHeight > targetHeight
    }

    private static func sourceBitrateKbps(for version: FileVersion) -> Int? {
        guard let bitrate = version.bitrate, bitrate > 0 else { return nil }
        return bitrate
    }

}

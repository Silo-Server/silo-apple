import Foundation

struct ApplePlaybackQualityOption: Identifiable, Hashable {
    let id: String
    let label: String
    let resolution: String
    let bitrateKbps: Int
    let isAuto: Bool
    /// The label in English, for the Remote Control state sent to a phone
    /// (D44); nil where `label` is already the same in every language.
    var englishLabel: String? = nil

    var subtitle: String? {
        if isAuto {
            return AppLanguage.string(.playerQualityAutoDetail)
        }
        guard bitrateKbps > 0 else { return nil }
        return AppLanguage.string(.playerQualityMaximumBitrate(bitrateLabel))
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

    /// `labelWithBitrate` in English.
    var englishLabelWithBitrate: String {
        let label = englishLabel ?? label
        return bitrateText.map { "\(label) (\($0))" } ?? label
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

    // Computed, so the labels follow the app language.
    static var auto: ApplePlaybackQualityOption {
        ApplePlaybackQualityOption(
            id: autoId,
            label: AppLanguage.string(.optionsAuto),
            resolution: "",
            bitrateKbps: 0,
            isAuto: true,
            englishLabel: AppLanguage.inEnglish { AppLanguage.string(.optionsAuto) }
        )
    }

    /// Auto while the plan carries `bandwidth_limit`: the server planned it
    /// under the limit this device learned from repeated rebuffering.
    static var autoLimitedAfterBuffering: ApplePlaybackQualityOption {
        ApplePlaybackQualityOption(
            id: autoId,
            label: AppLanguage.string(.bufferingQualityAutoLimited),
            resolution: "",
            bitrateKbps: 0,
            isAuto: true,
            englishLabel: AppLanguage.inEnglish { AppLanguage.string(.bufferingQualityAutoLimited) }
        )
    }

    /// A contract resolution cap without an invented bandwidth rung. A zero
    /// bitrate is a local sentinel for "uncapped" and is never sent as a cap.
    static let ultraHD = ApplePlaybackQualityOption(
        id: ultraHDId,
        label: "4K", // i18n-ignore: resolution name
        resolution: ultraHDId,
        bitrateKbps: 0,
        isAuto: false
    )

    /// One rung of the Settings ladder, without its label: the id and
    /// bitrate lookups below run often and need no text.
    struct Rung {
        enum Label { case upTo, upToHD, upToHDHigh, upToHDMedium }

        let id: String
        let resolution: String
        let bitrateKbps: Int
        let label: Label

        var displayLabel: String {
            switch label {
            case .upTo: return AppLanguage.string(.optionsQualityUpTo(resolution))
            case .upToHD: return AppLanguage.string(.optionsQualityUpToHd(resolution))
            case .upToHDHigh: return AppLanguage.string(.playerQualityUpToHdHigh(resolution))
            case .upToHDMedium: return AppLanguage.string(.playerQualityUpToHdMedium(resolution))
            }
        }
    }

    static let rungs: [Rung] = [
        Rung(id: "1080p-high", resolution: "1080p", bitrateKbps: 20_000, label: .upToHDHigh),
        Rung(id: "1080p-medium", resolution: "1080p", bitrateKbps: 12_000, label: .upToHDMedium),
        Rung(id: "1080p", resolution: "1080p", bitrateKbps: 10_000, label: .upToHD),
        Rung(id: "1080p-8", resolution: "1080p", bitrateKbps: 8_000, label: .upToHD),
        Rung(id: "720p-high", resolution: "720p", bitrateKbps: 4_000, label: .upToHDHigh),
        Rung(id: "720p-medium", resolution: "720p", bitrateKbps: 3_000, label: .upToHDMedium),
        Rung(id: "720p", resolution: "720p", bitrateKbps: 2_000, label: .upToHD),
        Rung(id: "480p", resolution: "480p", bitrateKbps: 1_500, label: .upTo),
        Rung(id: "328p", resolution: "328p", bitrateKbps: 700, label: .upTo),
    ]

    /// The ladder with labels in the app's language.
    static var tiers: [ApplePlaybackQualityOption] {
        rungs.map {
            ApplePlaybackQualityOption(
                id: $0.id,
                label: $0.displayLabel,
                resolution: $0.resolution,
                bitrateKbps: $0.bitrateKbps,
                isAuto: false
            )
        }
    }

    /// Every Settings option id: Auto, 4K and the ladder.
    static let settingsOptionIds: Set<String> = Set([autoId, ultraHDId] + rungs.map(\.id))

    static var settingsOptions: [ApplePlaybackQualityOption] { [auto, ultraHD] + tiers }

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
            if settingsOptionIds.contains(value) {
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
    /// the way back to the source. A plan that carries `bandwidthLimit` labels
    /// Auto as limited after buffering.
    static func playbackOptions(
        serverQualities: [PlaybackV3AvailableQuality],
        bandwidthLimit: PlaybackV3BandwidthLimit? = nil
    ) -> [ApplePlaybackQualityOption] {
        let auto = bandwidthLimit == nil ? Self.auto : autoLimitedAfterBuffering
        guard !serverQualities.isEmpty else {
            return [auto]
        }
        var seen = Set<String>()
        let planned = serverQualities.compactMap { quality -> ApplePlaybackQualityOption? in
            let id = protocolV3QualityId(quality.label)
            guard id != autoId, seen.insert(id).inserted else { return nil }
            let height = quality.height ?? 0
            let label = { playbackLabel(serverDisplayName: quality.displayName, id: id, height: height) }
            return ApplePlaybackQualityOption(
                id: id,
                label: label(),
                resolution: height <= 0 ? "" : "\(height)p",
                bitrateKbps: max(0, quality.bitrateKbps),
                isAuto: false,
                englishLabel: AppLanguage.inEnglish(label)
            )
        }
        return [auto] + planned
    }

    /// The in-player menu row to light. Auto only while the session's
    /// preference is auto, so a fixed preference leaves Auto a choice the
    /// viewer can make. Otherwise the server's word on which row the plan
    /// delivers (`planActiveQuality`), which may be none: the source playing
    /// unchanged, or an encode between two rungs. A server that predates that
    /// word lights only the rung the viewer picked: a saved setting's local id
    /// names no plan row, even where the names match (Apple's local
    /// `1080p-medium` is 12 Mbps, the server's 6 Mbps).
    static func highlightedOptionId(
        sessionQualityId: String,
        viewerPickId: String?,
        planActiveQuality: String?,
        planReportsActiveQuality: Bool,
        options: [ApplePlaybackQualityOption]
    ) -> String? {
        let session = protocolV3QualityId(sessionQualityId)
        if session == autoId { return autoId }
        let row: String?
        if planReportsActiveQuality {
            row = planActiveQuality.map(protocolV3QualityId)
        } else if let pick = viewerPickId.map(protocolV3QualityId), pick == session {
            row = pick
        } else {
            row = nil
        }
        guard let row, row != autoId, options.contains(where: { $0.id == row }) else { return nil }
        return row
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
        let serverPreference = settingsOptionIds.contains(clientQualityId)
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
        case 2_160: return AppLanguage.string(.optionsQualityUpTo("4K"))
        case 1_080: return AppLanguage.string(.optionsQualityUpToHd("1080p"))
        case 720: return AppLanguage.string(.optionsQualityUpToHd("720p"))
        case 480: return AppLanguage.string(.optionsQualityUpTo("480p"))
        default:
            return settingsOptions.first(where: { $0.id == id })?.label
                ?? (height > 0 ? AppLanguage.string(.optionsQualityUpTo("\(height)p")) : id)
        }
    }

    static func formatBitrate(kbps: Int, locale: Locale = AppLanguage.formattingLocale) -> String {
        if kbps >= 1000 {
            let mbps = Double(kbps) / 1000.0
            if mbps.rounded(.towardZero) == mbps {
                return "\(LocaleFormat.integer(Int(mbps), locale: locale)) Mbps"
            }
            return LocaleFormat.decimal(mbps, fractionDigits: 1, locale: locale) + " Mbps"
        }
        return "\(LocaleFormat.integer(kbps, locale: locale)) kbps"
    }
}

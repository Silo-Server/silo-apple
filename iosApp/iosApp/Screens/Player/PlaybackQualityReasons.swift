import Foundation

/// One `playback_plan.quality_reasons` entry. `code` is an open enum; each
/// figure is sent only with the codes that use it. `media_file_id`
/// (`alternate_version`) is not shown, so it is not decoded.
struct PlaybackV3QualityReason: Codable, Equatable, Sendable {
    let code: String
    var kbps: Int? = nil
    /// RFC 3339; `network_learned_limit` only.
    var expiresAt: String? = nil
    var height: Int? = nil
    var from: String? = nil
    var to: String? = nil
    /// Delivered audio channels; `audio_converted` only, when they drop.
    var channels: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case code, kbps, expiresAt, height, from, to, channels
    }
}

extension PlaybackV3QualityReason {
    /// A malformed entry loses its figures, not the plan: the list only
    /// explains a plan that is playable either way.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? container.decode(String.self, forKey: .code)) ?? ""
        kbps = try? container.decodeIfPresent(Int.self, forKey: .kbps)
        expiresAt = try? container.decodeIfPresent(String.self, forKey: .expiresAt)
        height = try? container.decodeIfPresent(Int.self, forKey: .height)
        from = try? container.decodeIfPresent(String.self, forKey: .from)
        to = try? container.decodeIfPresent(String.self, forKey: .to)
        channels = try? container.decodeIfPresent(Int.self, forKey: .channels)
    }
}

/// `playback_plan.quality_reasons` as sent, decoded so it never fails the
/// plan: a value that is not a list reads as no reasons, and an element
/// that is not an object is skipped.
struct PlaybackV3QualityReasonList: Decodable {
    let reasons: [PlaybackV3QualityReason]

    init(from decoder: Decoder) throws {
        guard var container = try? decoder.unkeyedContainer() else {
            reasons = []
            return
        }
        var reasons: [PlaybackV3QualityReason] = []
        while !container.isAtEnd {
            if let reason = try? container.decode(PlaybackV3QualityReason.self) {
                reasons.append(reason)
            } else if (try? container.decode(Skipped.self)) == nil {
                break
            }
        }
        self.reasons = reasons
    }

    /// Moves past an element without reading it.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) {}
    }
}

/// What the player says about the quality that plays: the `Auto · 1080p`
/// value of the quality control, the reason line under the checked quality
/// row, and the stats overlay's Reason row.
enum PlaybackQualityReasons {
    /// The plan's reasons, or nil when the server does not advertise
    /// `plan_quality_reasons_v1`, which shows no reason at all.
    static func reasons(plan: PlaybackV3Plan, serverFeatures: [String]) -> [PlaybackV3QualityReason]? {
        guard serverFeatures.contains(PlaybackProtocolV3.planQualityReasonsFeature),
              let reasons = plan.qualityReasons,
              !reasons.isEmpty else { return nil }
        return reasons
    }

    /// The quality control's value while Auto plays: Auto and the delivered
    /// resolution, or the source's when the plan names no output size.
    static func autoLabel(plan: PlaybackV3Plan?) -> String {
        guard let plan else { return ApplePlaybackQuality.auto.label }
        let sizes = [
            (plan.effectiveRecipe.width ?? 0, plan.effectiveRecipe.height ?? 0),
            (plan.source.width ?? 0, plan.source.height ?? 0),
        ]
        guard let size = sizes.first(where: { $0.0 > 0 || $0.1 > 0 }) else {
            return ApplePlaybackQuality.auto.label
        }
        return "\(ApplePlaybackQuality.auto.label) · \(resolutionLabel(width: size.0, height: size.1))"
    }

    /// The class a picture belongs to by either dimension, so a scope frame
    /// (1920x800) keeps its width's class. Pass a zero width to class by
    /// height alone.
    static func resolutionLabel(width: Int, height: Int) -> String {
        if width >= 3_200 || height >= 2_000 { return "4K" }
        if width >= 1_700 || height >= 1_000 { return "1080p" }
        if width >= 1_200 || height >= 700 { return "720p" }
        if width >= 800 || height >= 450 { return "480p" }
        return "360p"
    }

    /// The line under the checked quality row: the primary reason, joined by
    /// the second when that is a compatibility change and the two still fit
    /// one line.
    static func menuLine(_ reasons: [PlaybackV3QualityReason]) -> String? {
        guard let primary = reasons.first else { return nil }
        let line = text(primary) ?? "Adjusted for this device"
        guard reasons.count > 1,
              compatibilityCodes.contains(reasons[1].code),
              let second = text(reasons[1]) else { return line }
        let joined = "\(line) · \(second)"
        return joined.count <= menuLineMaxLength ? joined : line
    }

    /// The stats Reason row: every entry, one per line, an entry the client
    /// cannot word as its code.
    static func statsText(_ reasons: [PlaybackV3QualityReason]) -> String? {
        let lines = reasons.compactMap { reason -> String? in
            text(reason) ?? (reason.code.isEmpty ? nil : reason.code)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The English text for one entry; nil for an unknown code or a known
    /// one missing the figure its text needs.
    static func text(_ reason: PlaybackV3QualityReason) -> String? {
        let rate = reason.kbps.flatMap { $0 > 0 ? ApplePlaybackQuality.formatBitrate(kbps: $0) : nil }
        switch reason.code {
        case "original":
            return "Original quality"
        case "user_selected":
            return "Quality you picked"
        case "network_learned_limit":
            return rate.map { "Limited to \($0) after buffering" }
        case "network_estimate":
            return rate.map { "Your connection measured \($0)" }
        case "client_cap":
            return rate.map { "Limited to \($0) by this device's settings" }
        case "server_cap":
            return rate.map { "Limited to \($0) by the server" }
        case "device_resolution_limit":
            guard let height = reason.height, height > 0 else { return nil }
            return "This device plays up to \(resolutionLabel(width: 0, height: height))"
        case "alternate_version":
            return "Playing another version that fits"
        case "video_codec_unsupported":
            return token(reason.from).map { "Converted: this device can't play \(name($0, in: videoCodecNames)) video" }
        case "dynamic_range_converted":
            guard let from = token(reason.from), let to = token(reason.to) else { return nil }
            return "\(name(from, in: dynamicRangeNames)) shown as \(name(to, in: dynamicRangeNames))"
        case "audio_converted":
            guard let from = token(reason.from), let to = token(reason.to) else { return nil }
            guard from == to else {
                return "\(name(from, in: audioCodecNames)) audio converted to \(name(to, in: audioCodecNames))"
            }
            // Same codec: only the channels changed.
            return channelsName(reason.channels).map { "Audio downmixed to \($0)" }
        case "subtitle_burn_in":
            return "Subtitles burned into the video"
        case "container_unsupported":
            return "Repackaged for this device"
        case "compatibility_conversion":
            return "Converted for this device"
        default:
            return nil
        }
    }

    /// Two lines at most under the tvOS HUD's Quality row.
    private static let menuLineMaxLength = 72

    private static let compatibilityCodes: Set<String> = [
        "dynamic_range_converted", "audio_converted", "subtitle_burn_in"
    ]

    private static let videoCodecNames = [
        "hevc": "HEVC", "av1": "AV1", "vp9": "VP9", "mpeg2": "MPEG-2", "vc1": "VC-1", "h264": "H.264"
    ]

    private static let dynamicRangeNames = [
        "dolby_vision": "Dolby Vision", "hdr10": "HDR10", "hdr10_plus": "HDR10+", "hlg": "HLG", "sdr": "SDR"
    ]

    private static let audioCodecNames = [
        "truehd": "TrueHD", "dts": "DTS", "eac3": "Dolby Digital Plus", "ac3": "Dolby Digital",
        "aac": "AAC", "flac": "FLAC", "opus": "Opus"
    ]

    private static func token(_ raw: String?) -> String? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return value.isEmpty ? nil : value
    }

    private static func name(_ token: String, in names: [String: String]) -> String {
        names[token] ?? token.uppercased()
    }

    private static func channelsName(_ channels: Int?) -> String? {
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case let count? where count > 0: return "\(count) channels"
        default: return nil
        }
    }
}

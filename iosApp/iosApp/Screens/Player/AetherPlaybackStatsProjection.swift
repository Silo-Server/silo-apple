import AetherEngine
import Foundation

/// Immutable Silo-owned context that Aether cannot infer from a media source.
struct AetherPlaybackStatsSourceMetadata: Equatable {
    let source: String?
    let delivery: String?
    let container: String?
    let playbackRate: Double?
    let secondarySubtitleLabel: String?
    let plannedSourceDynamicRange: String?
    let plannedOutputDynamicRange: String?
    let plannedSourceDolbyVisionProfile: Int?

    init(
        sourceURL: URL?,
        delivery: String?,
        container: String?,
        playbackRate: Double?,
        secondarySubtitleLabel: String? = nil,
        plannedSourceDynamicRange: String? = nil,
        plannedOutputDynamicRange: String? = nil,
        plannedSourceDolbyVisionProfile: Int? = nil
    ) {
        source = Self.sourceLabel(for: sourceURL)
        self.delivery = Self.deliveryLabel(delivery)
        self.container = Self.containerLabel(container)
        self.playbackRate = playbackRate
        self.secondarySubtitleLabel = secondarySubtitleLabel
        self.plannedSourceDynamicRange = plannedSourceDynamicRange
        self.plannedOutputDynamicRange = plannedOutputDynamicRange
        self.plannedSourceDolbyVisionProfile = plannedSourceDolbyVisionProfile
    }

    private static func sourceLabel(for url: URL?) -> String? {
        guard let url else { return nil }
        if url.isFileURL { return "Offline file" }
        if let host = url.host, !host.isEmpty { return host }
        return url.scheme?.uppercased()
    }

    private static func deliveryLabel(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        switch value.lowercased() {
        case "original_http": return "Original HTTP"
        case "remux_hls": return "Remux HLS"
        case "transcode_hls": return "Transcode HLS"
        default:
            return value.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func containerLabel(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        switch value.lowercased() {
        case "matroska", "mkv": return "MKV"
        case "mpegts", "mpeg-ts", "ts": return "MPEG-TS"
        case "quicktime", "mov": return "MOV"
        case "mp4", "m4v": return value.uppercased()
        default: return value
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

/// Value-only snapshot of the public Aether state used by Silo diagnostics.
/// Keeping projection separate from observation makes generation fencing and
/// update cadence the controller's responsibility, not this formatter's.
struct AetherPlaybackStatsSnapshot: Equatable {
    let route: VideoRoute
    let phase: PlaybackPhase
    let telemetry: LiveTelemetry?
    let activeVideoDecoder: String?
    let activeAudioDecoder: String?
    let sourceVideoFormat: VideoFormat
    let outputVideoFormat: VideoFormat
    let sourceDVProfile: Int?
    let sourceVideoWidth: Int32
    let sourceVideoHeight: Int32
    let sourceVideoPixelAspectRatio: Double
    let sourceVideoFrameRate: Double?
    let sourceVideoBitrateBps: Int64
    let audioTracks: [TrackInfo]
    let activeAudioTrackIndex: Int?
    let subtitleTracks: [TrackInfo]
    let isSubtitleActive: Bool
    let activeSubtitleTrackIndex: Int?
    let isSecondarySubtitleActive: Bool

    @MainActor
    init(engine: AetherEngine) {
        route = engine.videoRoute
        phase = engine.playbackPhase
        telemetry = engine.liveTelemetry
        activeVideoDecoder = engine.activeVideoDecoder
        activeAudioDecoder = engine.activeAudioDecoder
        sourceVideoFormat = engine.sourceVideoFormat
        outputVideoFormat = engine.videoFormat
        sourceDVProfile = engine.sourceDVProfile
        sourceVideoWidth = engine.sourceVideoWidth
        sourceVideoHeight = engine.sourceVideoHeight
        sourceVideoPixelAspectRatio = engine.sourceVideoPixelAspectRatio
        sourceVideoFrameRate = engine.sourceVideoFrameRate
        sourceVideoBitrateBps = engine.sourceVideoBitrate
        audioTracks = engine.audioTracks
        activeAudioTrackIndex = engine.activeAudioTrackIndex
        subtitleTracks = engine.subtitleTracks
        isSubtitleActive = engine.isSubtitleActive
        activeSubtitleTrackIndex = engine.activeSubtitleTrackIndex
        isSecondarySubtitleActive = engine.isSecondarySubtitleActive
    }

    init(
        route: VideoRoute,
        phase: PlaybackPhase,
        telemetry: LiveTelemetry? = nil,
        activeVideoDecoder: String? = nil,
        activeAudioDecoder: String? = nil,
        sourceVideoFormat: VideoFormat = .sdr,
        outputVideoFormat: VideoFormat = .sdr,
        sourceDVProfile: Int? = nil,
        sourceVideoWidth: Int32 = 0,
        sourceVideoHeight: Int32 = 0,
        sourceVideoPixelAspectRatio: Double = 1,
        sourceVideoFrameRate: Double? = nil,
        sourceVideoBitrateBps: Int64 = 0,
        audioTracks: [TrackInfo] = [],
        activeAudioTrackIndex: Int? = nil,
        subtitleTracks: [TrackInfo] = [],
        isSubtitleActive: Bool = false,
        activeSubtitleTrackIndex: Int? = nil,
        isSecondarySubtitleActive: Bool = false
    ) {
        self.route = route
        self.phase = phase
        self.telemetry = telemetry
        self.activeVideoDecoder = activeVideoDecoder
        self.activeAudioDecoder = activeAudioDecoder
        self.sourceVideoFormat = sourceVideoFormat
        self.outputVideoFormat = outputVideoFormat
        self.sourceDVProfile = sourceDVProfile
        self.sourceVideoWidth = sourceVideoWidth
        self.sourceVideoHeight = sourceVideoHeight
        self.sourceVideoPixelAspectRatio = sourceVideoPixelAspectRatio
        self.sourceVideoFrameRate = sourceVideoFrameRate
        self.sourceVideoBitrateBps = sourceVideoBitrateBps
        self.audioTracks = audioTracks
        self.activeAudioTrackIndex = activeAudioTrackIndex
        self.subtitleTracks = subtitleTracks
        self.isSubtitleActive = isSubtitleActive
        self.activeSubtitleTrackIndex = activeSubtitleTrackIndex
        self.isSecondarySubtitleActive = isSecondarySubtitleActive
    }
}

enum AetherPlaybackStatsProjection {
    static func make(
        snapshot: AetherPlaybackStatsSnapshot,
        source: AetherPlaybackStatsSourceMetadata,
        sampledAt: Date = Date()
    ) -> PlaybackStats {
        let telemetry = snapshot.telemetry
        let activeAudio = snapshot.activeAudioTrackIndex.flatMap { activeID in
            snapshot.audioTracks.first { $0.id == activeID }
        }
        let activeSubtitle = snapshot.activeSubtitleTrackIndex.flatMap { activeID in
            snapshot.subtitleTracks.first { $0.id == activeID }
        }

        return PlaybackStats(
            sampledAt: sampledAt,
            route: routeLabel(snapshot.route),
            source: source.source,
            delivery: source.delivery,
            container: source.container,
            video: videoStream(snapshot),
            audio: audioStream(track: activeAudio, decoder: snapshot.activeAudioDecoder),
            dynamicRange: dynamicRangeLabel(snapshot, source: source),
            subtitles: subtitleLabel(
                route: snapshot.route,
                active: snapshot.isSubtitleActive,
                track: activeSubtitle,
                secondaryActive: snapshot.isSecondarySubtitleActive,
                secondaryLabel: source.secondarySubtitleLabel
            ),
            playbackRate: source.playbackRate,
            playbackStatus: phaseLabel(snapshot.phase),
            bufferedAheadSeconds: telemetry?.forwardBufferSeconds,
            displayCushionSeconds: telemetry?.displayCushionSeconds,
            readerWindowAheadBytes: telemetry?.readerWindowAheadBytes.map(Int64.init),
            observedFrameRate: telemetry?.observedFps,
            droppedVideoFrames: telemetry?.droppedFrameCount,
            accumulatedFrameDelaySeconds: telemetry?.accumulatedFrameDelaySeconds,
            avSyncGapMilliseconds: telemetry?.avSyncGapMs,
            instantReadBitrateBps: bitsPerSecond(telemetry?.instantBitrateMbps),
            averageReadBitrateBps: bitsPerSecond(telemetry?.averageBitrateMbps),
            audioBridgeBitrateBps: bitsPerSecond(telemetry?.audioBridgeBitrateMbps),
            networkThroughputBps: bitsPerSecond(telemetry?.networkThroughputMbps),
            bytesTransferred: telemetry?.networkTransferredBytes,
            cachedBytes: telemetry?.cachedBytes,
            demuxerBytesFetched: telemetry.map(\.demuxerBytesFetched),
            producerRestartCount: telemetry.map(\.producerRestartCount),
            residentMemoryBytes: telemetry.map { Int64($0.rssMb) * 1_000_000 }
        )
    }

    private static func videoStream(_ snapshot: AetherPlaybackStatsSnapshot) -> PlaybackStats.MediaStream {
        let dimensions = dimensionLabel(
            width: snapshot.sourceVideoWidth,
            height: snapshot.sourceVideoHeight,
            pixelAspectRatio: snapshot.sourceVideoPixelAspectRatio
        )
        let frameRate = snapshot.sourceVideoFrameRate.flatMap { fps in
            fps.isFinite && fps > 0 ? String(format: "%.3f fps", fps) : nil
        }
        let details = [dimensions, frameRate]
            .compactMap { $0 }
            .joined(separator: " · ")
        return PlaybackStats.MediaStream(
            codec: snapshot.activeVideoDecoder,
            detail: details.isEmpty ? nil : details,
            bitrateBps: snapshot.sourceVideoBitrateBps > 0
                ? Double(snapshot.sourceVideoBitrateBps)
                : nil
        )
    }

    private static func audioStream(track: TrackInfo?, decoder: String?) -> PlaybackStats.MediaStream {
        guard let track else {
            return PlaybackStats.MediaStream(codec: decoder, detail: nil, bitrateBps: nil)
        }
        var details: [String] = []
        if !track.name.isEmpty { details.append(track.name) }
        if let language = normalized(track.language),
           !details.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
            details.append(language)
        }
        if track.isAtmos {
            details.append("Atmos")
        } else if let channels = channelLabel(track.channels) {
            details.append(channels)
        }
        if let decoder = normalized(decoder),
           !details.contains(where: { $0.caseInsensitiveCompare(decoder) == .orderedSame }) {
            details.append(decoder)
        }
        return PlaybackStats.MediaStream(
            codec: track.codec,
            detail: details.joined(separator: " · "),
            bitrateBps: track.bitrate > 0 ? Double(track.bitrate) : nil
        )
    }

    private static func subtitleLabel(
        route: VideoRoute,
        active: Bool,
        track: TrackInfo?,
        secondaryActive: Bool,
        secondaryLabel: String?
    ) -> String? {
        guard route != .none else { return nil }
        guard active else { return secondaryActive ? "Secondary only" : "Off" }

        var primaryParts: [String] = []
        if let track {
            if !track.name.isEmpty { primaryParts.append(track.name) }
            if let language = normalized(track.language),
               !primaryParts.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
                primaryParts.append(language)
            }
            if !track.codec.isEmpty { primaryParts.append(track.codec.uppercased()) }
            if track.isForced, !containsToken("forced", in: primaryParts) {
                primaryParts.append("Forced")
            }
            if track.isHearingImpaired, !containsToken("sdh", in: primaryParts) {
                primaryParts.append("SDH")
            }
        }
        var label = primaryParts.isEmpty ? "On" : primaryParts.joined(separator: " · ")
        if secondaryActive {
            label += " + \(normalized(secondaryLabel) ?? "secondary")"
        }
        return label
    }

    private static func dimensionLabel(width: Int32, height: Int32, pixelAspectRatio: Double) -> String? {
        guard width > 0, height > 0 else { return nil }
        let coded = "\(width)×\(height)"
        guard pixelAspectRatio.isFinite,
              pixelAspectRatio > 0,
              abs(pixelAspectRatio - 1) > 0.001 else { return coded }
        let displayWidth = Int((Double(width) * pixelAspectRatio).rounded())
        return "\(coded) (\(displayWidth)×\(height) display)"
    }

    private static func dynamicRangeLabel(
        _ snapshot: AetherPlaybackStatsSnapshot,
        source metadata: AetherPlaybackStatsSourceMetadata
    ) -> String? {
        guard snapshot.sourceVideoWidth > 0, snapshot.sourceVideoHeight > 0 else { return nil }
        if let planned = plannedDynamicRangeLabel(metadata) { return planned }
        let source = videoFormatLabel(snapshot.sourceVideoFormat, dvProfile: snapshot.sourceDVProfile)
        let output = videoFormatLabel(snapshot.outputVideoFormat, dvProfile: nil)
        return snapshot.sourceVideoFormat == snapshot.outputVideoFormat
            ? source
            : "\(source) → \(output)"
    }

    /// A server-transformed stream reaches Aether after conversion, so both of
    /// Aether's format fields describe the delivered SDR/HDR bytes. Preserve
    /// the original-to-effective transition from the negotiated V3 plan when
    /// those ranges differ; equal ranges leave live panel adaptation to Aether.
    private static func plannedDynamicRangeLabel(
        _ source: AetherPlaybackStatsSourceMetadata
    ) -> String? {
        guard let input = normalized(source.plannedSourceDynamicRange)?.lowercased(),
              let output = normalized(source.plannedOutputDynamicRange)?.lowercased(),
              input != output,
              let inputLabel = plannedVideoFormatLabel(
                input,
                dvProfile: source.plannedSourceDolbyVisionProfile
              ),
              let outputLabel = plannedVideoFormatLabel(output, dvProfile: nil) else {
            return nil
        }
        return "\(inputLabel) → \(outputLabel)"
    }

    private static func plannedVideoFormatLabel(_ value: String, dvProfile: Int?) -> String? {
        switch value {
        case "sdr": return "SDR"
        case "hdr10": return "HDR10"
        case "hdr10_plus", "hdr10+": return "HDR10+"
        case "hlg": return "HLG"
        case "dolby_vision":
            return dvProfile.map { "Dolby Vision Profile \($0)" } ?? "Dolby Vision"
        default: return nil
        }
    }

    private static func videoFormatLabel(_ format: VideoFormat, dvProfile: Int?) -> String {
        switch format {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision:
            return dvProfile.map { "Dolby Vision Profile \($0)" } ?? "Dolby Vision"
        case .hlg: return "HLG"
        }
    }

    private static func routeLabel(_ route: VideoRoute) -> String? {
        switch route {
        case .none: return nil
        case .remoteBypass: return "Aether remote HLS"
        case .loopback: return "Aether loopback HLS"
        case .software: return "Aether software video"
        case .audio: return "Aether audio"
        }
    }

    private static func phaseLabel(_ phase: PlaybackPhase) -> String? {
        switch phase {
        case .idle: return nil
        case .loading: return "Loading"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .seeking: return "Seeking"
        case .rebuffering: return "Rebuffering"
        case .stalled(let reconnecting): return reconnecting ? "Reconnecting" : "Stalled"
        case .ended: return "Ended"
        case .error: return "Error"
        }
    }

    private static func channelLabel(_ channels: Int) -> String? {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        case let count where count > 0: return "\(count) channels"
        default: return nil
        }
    }

    private static func bitsPerSecond(_ megabitsPerSecond: Double?) -> Double? {
        guard let value = megabitsPerSecond, value.isFinite, value >= 0 else { return nil }
        return value * 1_000_000
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func containsToken(_ token: String, in values: [String]) -> Bool {
        values.contains { value in
            value.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

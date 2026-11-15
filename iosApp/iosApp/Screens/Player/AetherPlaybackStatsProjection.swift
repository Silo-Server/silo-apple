import AetherEngine
import Foundation

/// Immutable Silo-owned context that Aether cannot infer from a media source.
struct AetherPlaybackStatsSourceMetadata: Equatable {
    let source: String?
    let delivery: String?
    /// The delivery in viewer terms: "Direct play", "Offline file".
    let playMethod: String?
    /// Why the server chose this delivery, as a sentence.
    let decisionReason: String?
    let warnings: [String]
    let container: String?
    /// The codec of the video that reaches the device. Aether names only
    /// its decoder.
    let videoCodec: String?
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
        videoCodec: String? = nil,
        decisionReason: String? = nil,
        warnings: [String] = [],
        secondarySubtitleLabel: String? = nil,
        plannedSourceDynamicRange: String? = nil,
        plannedOutputDynamicRange: String? = nil,
        plannedSourceDolbyVisionProfile: Int? = nil
    ) {
        let isOffline = sourceURL?.isFileURL == true
        source = Self.sourceLabel(for: sourceURL)
        self.delivery = Self.deliveryLabel(delivery)
        playMethod = isOffline
            ? AppLanguage.string(.playerStatsOfflineFile)
            : Self.playMethodLabel(delivery)
        self.decisionReason = Self.reasonLabel(decisionReason)
        self.warnings = warnings.compactMap(Self.normalized)
        self.container = Self.containerLabel(container)
        self.videoCodec = Self.normalized(videoCodec)
        self.playbackRate = playbackRate
        self.secondarySubtitleLabel = secondarySubtitleLabel
        self.plannedSourceDynamicRange = plannedSourceDynamicRange
        self.plannedOutputDynamicRange = plannedOutputDynamicRange
        self.plannedSourceDolbyVisionProfile = plannedSourceDolbyVisionProfile
    }

    private static func sourceLabel(for url: URL?) -> String? {
        // A local file is named by the play method.
        guard let url, !url.isFileURL else { return nil }
        if let host = url.host, !host.isEmpty { return host }
        return url.scheme?.uppercased()
    }

    private static func deliveryLabel(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        switch value.lowercased() {
        case PlaybackProtocolV3.PlanDelivery.originalHTTP: return AppLanguage.string(.playerStatsDeliveryOriginalHttp)
        case PlaybackProtocolV3.PlanDelivery.remuxProgressive: return AppLanguage.string(.playerStatsDeliveryServerRemux)
        case PlaybackProtocolV3.PlanDelivery.remuxHLS: return AppLanguage.string(.playerStatsDeliveryServerRemuxHls)
        case PlaybackProtocolV3.PlanDelivery.transcodeHLS: return AppLanguage.string(.playerStatsDeliveryServerTranscodeHls)
        default:
            return value.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func playMethodLabel(_ value: String?) -> String? {
        switch normalized(value)?.lowercased() {
        case PlaybackProtocolV3.PlanDelivery.originalHTTP:
            return AppLanguage.string(.playerStatsPlayMethodDirectPlay)
        case PlaybackProtocolV3.PlanDelivery.remuxProgressive, PlaybackProtocolV3.PlanDelivery.remuxHLS:
            return AppLanguage.string(.playerStatsPlayMethodRemuxed)
        case PlaybackProtocolV3.PlanDelivery.transcodeHLS:
            return AppLanguage.string(.playerStatsPlayMethodTranscoded)
        default:
            return nil
        }
    }

    /// The server's reason code as a sentence: `video_codec_unsupported`
    /// reads "Video codec unsupported".
    private static func reasonLabel(_ value: String?) -> String? {
        guard let value = normalized(value) else { return nil }
        let words = value.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
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
    let dolbyVisionConversion: DolbyVisionConversion?
    /// FFmpeg's name for the source's transfer, e.g. `arib-std-b67` for an
    /// HLG Dolby Vision base layer.
    let sourceVideoTransfer: String?
    /// What the display can present. Sampled only on tvOS, where Aether
    /// cannot confirm which mode the TV is in; nil everywhere else.
    let tvDisplay: DisplayCapabilities?
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
        dolbyVisionConversion = engine.dolbyVisionConversion
        sourceVideoTransfer = engine.sourceVideoStreamFormat?.transfer
        #if os(tvOS)
        tvDisplay = AetherEngine.displayCapabilities
        #else
        tvDisplay = nil
        #endif
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
        dolbyVisionConversion: DolbyVisionConversion? = nil,
        sourceVideoTransfer: String? = nil,
        tvDisplay: DisplayCapabilities? = nil,
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
        self.dolbyVisionConversion = dolbyVisionConversion
        self.sourceVideoTransfer = sourceVideoTransfer
        self.tvDisplay = tvDisplay
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
            playMethod: source.playMethod,
            decisionReason: source.decisionReason,
            warnings: source.warnings,
            route: routeLabel(snapshot.route),
            source: source.source,
            delivery: source.delivery,
            container: source.container,
            video: videoStream(snapshot, codec: source.videoCodec),
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

    private static func videoStream(
        _ snapshot: AetherPlaybackStatsSnapshot,
        codec: String?
    ) -> PlaybackStats.MediaStream {
        let hasPicture = snapshot.sourceVideoWidth > 0 && snapshot.sourceVideoHeight > 0
        let dimensions = dimensionLabel(
            width: snapshot.sourceVideoWidth,
            height: snapshot.sourceVideoHeight,
            pixelAspectRatio: snapshot.sourceVideoPixelAspectRatio
        )
        let frameRate = snapshot.sourceVideoFrameRate.flatMap { fps in
            fps.isFinite && fps > 0 ? LocaleFormat.trimmed(fps, maxFractionDigits: 3) + " fps" : nil
        }
        let range = presentedVideoFormat(snapshot)
        return PlaybackStats.MediaStream(
            description: joined([hasPicture ? codec.map(videoCodecLabel) : nil, dimensions, frameRate]),
            bitrateBps: snapshot.sourceVideoBitrateBps > 0
                ? Double(snapshot.sourceVideoBitrateBps)
                : nil,
            decoder: normalized(snapshot.activeVideoDecoder),
            summary: joined([
                resolutionClass(
                    width: snapshot.sourceVideoWidth,
                    height: snapshot.sourceVideoHeight,
                    pixelAspectRatio: snapshot.sourceVideoPixelAspectRatio
                ),
                hasPicture && range != .sdr ? videoFormatLabel(range, dvProfile: nil) : nil,
            ])
        )
    }

    /// "4K", "1080p" and so on, for the picture as displayed. Either
    /// dimension reaching a class's size is enough: a scope crop of a 1080p
    /// master (1920×800) and a 4:3 picture (1440×1080) are both 1080p. An
    /// anamorphic stream counts its displayed width, as `dimensionLabel` does.
    private static func resolutionClass(width: Int32, height: Int32, pixelAspectRatio: Double) -> String? {
        guard width > 0, height > 0 else { return nil }
        let hasSquarePixels = !(pixelAspectRatio.isFinite && pixelAspectRatio > 0)
            || abs(pixelAspectRatio - 1) <= 0.001
        let displayWidth = hasSquarePixels
            ? Int(width)
            : Int((Double(width) * pixelAspectRatio).rounded())
        let classes: [(width: Int, height: Int, label: String)] = [
            (3_800, 2_100, "4K"),
            (2_500, 1_400, "1440p"),
            (1_900, 1_060, "1080p"),
            (1_260, 700, "720p"),
        ]
        let match = classes.first { displayWidth >= $0.width || Int(height) >= $0.height }
        return match?.label ?? "\(height)p"
    }

    private static func videoCodecLabel(_ codec: String) -> String {
        switch codec.lowercased() {
        case "hevc", "h265", "hvc1", "hev1": return "HEVC"
        case "h264", "avc", "avc1", "avc3": return "H.264"
        case "av1", "av01": return "AV1"
        case "vp9", "vp09": return "VP9"
        case "mpeg2video", "mpeg2": return "MPEG-2"
        case "mpeg4": return "MPEG-4"
        case "vc1": return "VC-1"
        default: return codec.uppercased()
        }
    }

    /// "English · EAC3 5.1", as the track pickers name a track: the language,
    /// or the track's own title when it has none. The picker keeps the rest
    /// of the title; here it would only crowd out the format.
    private static func audioStream(track: TrackInfo?, decoder: String?) -> PlaybackStats.MediaStream {
        guard let track else {
            return PlaybackStats.MediaStream(decoder: normalized(decoder))
        }
        let layout = track.isAtmos ? "Atmos" : channelLabel(track.channels)
        return PlaybackStats.MediaStream(
            description: joined([
                TrackLabels.languageName(track.language)
                    ?? TrackLabels.audioTitle(track.name, language: track.language),
                joined([TrackLabels.audioCodec(track.codec), layout], separator: " "),
            ]),
            bitrateBps: track.bitrate > 0 ? Double(track.bitrate) : nil,
            decoder: normalized(decoder)
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
        guard active else {
            return AppLanguage.string(secondaryActive ? .playerStatsSubtitlesSecondaryOnly : .playerTracksSubtitlesOff)
        }

        var primaryParts: [String] = []
        if let track {
            // The track pickers' vocabulary: the language leads, and the
            // track's own title follows only when it says something more. A
            // release name stamped on every track does not.
            if let title = TrackLabels.subtitleTitle(
                track.name,
                language: track.language,
                codec: track.codec,
                showsHearingImpaired: track.isHearingImpaired
            ) {
                primaryParts.append(title)
            }
            // A title usually names its language ("English SDH"); the
            // language is added only when it does not.
            if let language = TrackLabels.languageName(track.language),
               !containsToken(language, in: primaryParts) {
                primaryParts.insert(language, at: 0)
            }
            if let codec = TrackLabels.subtitleCodec(track.codec) { primaryParts.append(codec) }
            if track.isForced, !containsToken("forced", in: primaryParts) {
                primaryParts.append(AppLanguage.string(.detailTrackForced))
            }
            if track.isHearingImpaired, !containsToken("sdh", in: primaryParts) {
                primaryParts.append(AppLanguage.string(.detailTrackSdh))
            }
        }
        let label = primaryParts.isEmpty ? AppLanguage.string(.optionsOn) : primaryParts.joined(separator: " · ")
        guard secondaryActive else { return label }
        let secondary = normalized(secondaryLabel) ?? AppLanguage.string(.playerStatsSubtitlesSecondary)
        return AppLanguage.string(.playerStatsSubtitlesWithSecondary(label, secondary))
    }

    private static func dimensionLabel(width: Int32, height: Int32, pixelAspectRatio: Double) -> String? {
        guard width > 0, height > 0 else { return nil }
        let coded = LocaleFormat.localized("\(width)×\(height)")
        guard pixelAspectRatio.isFinite,
              pixelAspectRatio > 0,
              abs(pixelAspectRatio - 1) > 0.001 else { return coded }
        let displayWidth = Int((Double(width) * pixelAspectRatio).rounded())
        return AppLanguage.string(.playerStatsDimensionsWithDisplay(coded, LocaleFormat.localized("\(displayWidth)×\(height)")))
    }

    private static func dynamicRangeLabel(
        _ snapshot: AetherPlaybackStatsSnapshot,
        source metadata: AetherPlaybackStatsSourceMetadata
    ) -> String? {
        guard snapshot.sourceVideoWidth > 0, snapshot.sourceVideoHeight > 0 else { return nil }
        if let planned = plannedDynamicRangeLabel(metadata) { return planned }
        let source = videoFormatLabel(snapshot.sourceVideoFormat, dvProfile: snapshot.sourceDVProfile)
        let unconfirmed = unconfirmedSentVideoFormat(snapshot)
        let outputFormat = presentedVideoFormat(snapshot)
        let label: String
        if outputFormat == .dolbyVision,
           snapshot.dolbyVisionConversion == .profile7ToProfile81 {
            label = AppLanguage.string(.playerStatsDynamicRangeToProfile81(source))
        } else {
            let output = videoFormatLabel(outputFormat, dvProfile: nil)
            label = snapshot.sourceVideoFormat == outputFormat ? source : "\(source) → \(output)"
        }
        return unconfirmed == nil ? label : AppLanguage.string(.playerStatsDynamicRangeUnconfirmed(label))
    }

    /// The range that reaches the display: what Aether sent an Apple TV whose
    /// mode it can't confirm, otherwise its own `videoFormat`.
    private static func presentedVideoFormat(_ snapshot: AetherPlaybackStatsSnapshot) -> VideoFormat {
        unconfirmedSentVideoFormat(snapshot) ?? snapshot.outputVideoFormat
    }

    /// The range Aether sent to an Apple TV when it can't confirm the TV's
    /// mode, or nil when its own `videoFormat` stands.
    ///
    /// `videoFormat` stays SDR until the panel proves it left SDR, and an
    /// Apple TV whose format is set to SDR never proves it: its EDR headroom
    /// reads 1.0 even after Match Dynamic Range switches it. Aether sends an
    /// HDR display the HDR stream anyway, and tvOS doesn't say whether the TV
    /// switched (its one setting covers frame-rate and range matching both),
    /// so the label names what was sent and marks it unconfirmed. On a display
    /// without Dolby Vision that is the Dolby Vision base layer, as Aether's
    /// `effectiveVideoFormat` routes it.
    private static func unconfirmedSentVideoFormat(_ snapshot: AetherPlaybackStatsSnapshot) -> VideoFormat? {
        guard snapshot.outputVideoFormat == .sdr,
              snapshot.route == .loopback || snapshot.route == .remoteBypass,
              let display = snapshot.tvDisplay else { return nil }
        switch snapshot.sourceVideoFormat {
        case .sdr:
            return nil
        case .hdr10, .hdr10Plus:
            return display.supportsHDR10 ? snapshot.sourceVideoFormat : nil
        case .hlg:
            return display.supportsHLG ? .hlg : nil
        case .dolbyVision:
            let transfer = snapshot.sourceVideoTransfer
            let hasHLGBase = transfer == "arib-std-b67"
            // Aether treats an unspecified transfer as PQ (Profile 5 often has an empty VUI).
            let hasPQBase = transfer == nil || transfer == "smpte2084"
            // Aether strips Dolby Vision from an SDR base layer (Profiles 8.2
            // and 10.2) and plays that base as SDR on every display.
            guard hasHLGBase || hasPQBase else { return nil }
            if display.supportsDolbyVision { return .dolbyVision }
            if hasHLGBase { return display.supportsHLG ? .hlg : nil }
            return display.supportsHDR10 ? .hdr10 : nil
        }
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
            return dvProfile.map { AppLanguage.string(.playerStatsDolbyVisionProfile(String($0))) } ?? "Dolby Vision"
        default: return nil
        }
    }

    private static func videoFormatLabel(_ format: VideoFormat, dvProfile: Int?) -> String {
        switch format {
        case .sdr: return "SDR"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision:
            return dvProfile.map { AppLanguage.string(.playerStatsDolbyVisionProfile(String($0))) } ?? "Dolby Vision"
        case .hlg: return "HLG"
        }
    }

    private static func routeLabel(_ route: VideoRoute) -> String? {
        switch route {
        case .none: return nil
        case .remoteBypass: return AppLanguage.string(.playerStatsRouteRemoteHls)
        case .loopback: return AppLanguage.string(.playerStatsRouteLoopbackHls)
        case .software: return AppLanguage.string(.playerStatsRouteSoftwareVideo)
        case .audio: return AppLanguage.string(.playerStatsRouteAudio)
        }
    }

    private static func phaseLabel(_ phase: PlaybackPhase) -> String? {
        switch phase {
        case .idle: return nil
        case .loading: return AppLanguage.string(.commonLoading)
        case .playing: return AppLanguage.string(.playerStatsPhasePlaying)
        case .paused: return AppLanguage.string(.playerStatsPhasePaused)
        case .seeking: return AppLanguage.string(.playerStatsPhaseSeeking)
        case .rebuffering: return AppLanguage.string(.playerStatsPhaseRebuffering)
        case .stalled(let reconnecting):
            return AppLanguage.string(reconnecting ? .playerStatsPhaseReconnecting : .playerStatsPhaseStalled)
        case .ended: return AppLanguage.string(.playerStatsPhaseEnded)
        case .error: return AppLanguage.string(.playerStatsPhaseError)
        }
    }

    private static func channelLabel(_ channels: Int) -> String? {
        switch channels {
        case 1: return AppLanguage.string(.detailMono)
        case 2: return AppLanguage.string(.detailStereo)
        case 6: return "5.1"
        case 8: return "7.1"
        case let count where count > 0: return AppLanguage.string(.playerStatsChannelCount(count))
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

    /// The non-empty parts joined, or nil when none are left.
    private static func joined(_ parts: [String?], separator: String = " · ") -> String? {
        let present = parts.compactMap(normalized)
        return present.isEmpty ? nil : present.joined(separator: separator)
    }

    private static func containsToken(_ token: String, in values: [String]) -> Bool {
        values.contains { value in
            value.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

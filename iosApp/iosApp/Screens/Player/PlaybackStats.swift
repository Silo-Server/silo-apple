import Foundation

/// Host-facing playback diagnostics. Every value is projected from
/// AetherEngine's public state or from immutable Silo session metadata.
/// A missing value means the active Aether route cannot measure it.
struct PlaybackStats: Equatable {
    struct MediaStream: Equatable {
        var codec: String?
        var detail: String?
        var bitrateBps: Double?
        /// The stream in a few words for the summary ("1080p", "DTS 5.1"),
        /// and the one fact under it ("23.976 fps", "English").
        var label: String?
        var labelDetail: String?
    }

    var sampledAt: Date = Date()

    // Source/session identity supplied by Silo.
    var route: String?
    var source: String?
    var delivery: String?
    /// How the server delivers the file, in viewer terms ("Direct play").
    var playMethod: String?
    var container: String?

    // Static and selected media state supplied by Aether.
    var video: MediaStream = .init()
    var audio: MediaStream = .init()
    var dynamicRange: String?
    var subtitles: String?
    var playbackRate: Double?

    // Aether playback phase and route-appropriate live telemetry.
    var playbackStatus: String?
    var bufferedAheadSeconds: Double?
    var displayCushionSeconds: Double?
    var readerWindowAheadBytes: Int64?
    var observedFrameRate: Double?
    var droppedVideoFrames: Int?
    var accumulatedFrameDelaySeconds: Double?
    var avSyncGapMilliseconds: Double?

    // Aether source and network measurements.
    var instantReadBitrateBps: Double?
    var averageReadBitrateBps: Double?
    var audioBridgeBitrateBps: Double?
    var networkThroughputBps: Double?
    var bytesTransferred: Int64?
    var cachedBytes: Int64?
    var demuxerBytesFetched: Int64?

    // Small, cross-route engine health surface.
    var producerRestartCount: Int?
    var residentMemoryBytes: Int64?

    static let empty = PlaybackStats()
}

extension PlaybackStats {
    var allRows: [(String, String)] {
        sourceRows + mediaRows + bufferRows + networkRows + engineRows
    }

    /// The short set shown over iPhone video. It intentionally leaves the
    /// engine-health counters to the paged tvOS panel.
    var compactRows: [(String, String)] {
        let compactLabels = Self.compactLabels
        return allRows.filter { compactLabels.contains($0.0) }
    }

    /// Row labels as the rows carry them: in the app's language.
    private static var compactLabels: Set<String> {
        let labels: [LocalizedStringResource] = [
            .playerHudRoute, .playerStatsSource, .playerStatsDelivery, .playerStatsContainer,
            .playerHudVideo, .playerHudAudio, .playerStatsDynamicRange, .playerStatsSubtitles,
            .playerStatsPlaybackStatus, .playerStatsForwardBuffer, .playerStatsDisplayCushion,
            .playerStatsDroppedFrames, .playerStatsInstantReadBitrate, .playerStatsNetworkThroughput
        ]
        return Set(labels.map { AppLanguage.string($0) })
    }

    var hasRows: Bool { !allRows.isEmpty }

    /// Playback health at a glance, ahead of the full rows: what state
    /// playback is in, whether it is keeping up, and the few readings a
    /// viewer acts on. Every value comes from the same fields as the rows.
    struct Summary: Equatable {
        enum Health: Equatable {
            /// Playing with no dropped frames measured.
            case good
            case neutral
            /// Stalled, rebuffering, reconnecting or failed.
            case attention
        }

        struct Reading: Equatable {
            let title: String
            let value: String
            var detail: String?
            var needsAttention = false
        }

        let status: String
        let health: Health
        /// Play method and container ("Direct play · MKV").
        let context: String?
        let readings: [Reading]
    }

    var summary: Summary {
        let (status, health) = summaryStatus
        return Summary(
            status: status,
            health: health,
            context: joinedNonEmpty([playMethod, container]),
            readings: summaryReadings
        )
    }

    private var summaryStatus: (String, Summary.Health) {
        guard let status = normalized(playbackStatus) else {
            return (AppLanguage.string(.playerStatsSummaryWaiting), .neutral)
        }
        // The status as the projection wrote it: in the app's language.
        let attention: [LocalizedStringResource] = [
            .playerStatsPhaseRebuffering, .playerStatsPhaseStalled,
            .playerStatsPhaseReconnecting, .playerStatsPhaseError
        ]
        if attention.contains(where: { AppLanguage.string($0) == status }) {
            return (status, .attention)
        }
        if status == AppLanguage.string(.playerStatsPhasePlaying), droppedVideoFrames == 0 {
            return (AppLanguage.string(.playerStatsSummaryPlayingSmoothly), .good)
        }
        return (status, .neutral)
    }

    private var summaryReadings: [Summary.Reading] {
        var readings: [Summary.Reading] = []
        if let picture = normalized(video.label) {
            readings.append(.init(
                title: AppLanguage.string(.playerStatsSummaryPicture),
                value: picture,
                detail: joinedNonEmpty([dynamicRange, video.labelDetail])
            ))
        }
        if let sound = normalized(audio.label) {
            readings.append(.init(
                title: AppLanguage.string(.playerStatsSummarySound),
                value: sound,
                detail: normalized(audio.labelDetail)
            ))
        }
        if let rate = [instantReadBitrateBps, networkThroughputBps, averageReadBitrateBps]
            .compactMap({ $0 })
            .first(where: { $0.isFinite && $0 > 0 }) {
            readings.append(.init(
                title: AppLanguage.string(.playerHudStream),
                value: formatSummaryBitrate(rate),
                detail: AppLanguage.string(.playerStatsSummaryCurrentReadRate)
            ))
        }
        if let droppedVideoFrames, droppedVideoFrames >= 0 {
            let buffered = bufferedAheadSeconds
                .flatMap { seconds in
                    seconds.isFinite && seconds > 0
                        ? AppLanguage.string(.playerStatsSummaryBuffered(LocaleFormat.decimal(seconds, fractionDigits: 1)))
                        : nil
                }
            readings.append(.init(
                title: AppLanguage.string(.playerStatsSummaryFrames),
                value: droppedVideoFrames == 0
                    ? AppLanguage.string(.playerStatsSummaryNoneDropped)
                    : AppLanguage.string(.playerStatsSummaryDropped(
                        count: droppedVideoFrames,
                        LocaleFormat.integer(droppedVideoFrames)
                    )),
                detail: buffered,
                needsAttention: droppedVideoFrames > 0
            ))
        }
        return readings
    }

    /// The non-empty parts joined with " · ", or nil when none are left.
    private func joinedNonEmpty(_ parts: [String?]) -> String? {
        let present = parts.compactMap { normalized($0) }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }

    private func formatSummaryBitrate(_ bps: Double) -> String {
        bps >= 1_000_000
            ? LocaleFormat.decimal(bps / 1_000_000, fractionDigits: 1) + " Mbps"
            : LocaleFormat.decimal(bps / 1_000, fractionDigits: 0) + " Kbps"
    }

    var sourceRows: [(String, String)] {
        stringRows([
            (AppLanguage.string(.playerHudRoute), route),
            (AppLanguage.string(.playerStatsSource), source),
            (AppLanguage.string(.playerStatsDelivery), delivery),
            (AppLanguage.string(.playerStatsContainer), container)
        ])
    }

    var mediaRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let video = mediaDescription(video) {
            rows.append((AppLanguage.string(.playerHudVideo), video))
        }
        if let audio = mediaDescription(audio) {
            rows.append((AppLanguage.string(.playerHudAudio), audio))
        }
        rows.append(contentsOf: stringRows([
            (AppLanguage.string(.playerStatsDynamicRange), dynamicRange),
            (AppLanguage.string(.playerStatsSubtitles), subtitles)
        ]))
        if let playbackRate, playbackRate.isFinite, playbackRate > 0 {
            rows.append((AppLanguage.string(.playerStatsPlaybackRate), LocaleFormat.decimal(playbackRate, fractionDigits: 2) + "x"))
        }
        return rows
    }

    var bufferRows: [(String, String)] {
        var rows = stringRows([(AppLanguage.string(.playerStatsPlaybackStatus), playbackStatus)])
        if let bufferedAheadSeconds, bufferedAheadSeconds.isFinite {
            rows.append((AppLanguage.string(.playerStatsForwardBuffer), formatSeconds(bufferedAheadSeconds)))
        }
        if let displayCushionSeconds, displayCushionSeconds.isFinite {
            rows.append((AppLanguage.string(.playerStatsDisplayCushion), formatSeconds(displayCushionSeconds)))
        }
        if let readerWindowAheadBytes, readerWindowAheadBytes >= 0 {
            rows.append((AppLanguage.string(.playerStatsReaderRunway), formatBytes(readerWindowAheadBytes)))
        }
        if let observedFrameRate, observedFrameRate.isFinite, observedFrameRate > 0 {
            rows.append((AppLanguage.string(.playerStatsObservedFrameRate), LocaleFormat.decimal(observedFrameRate, fractionDigits: 2) + " fps"))
        }
        if let droppedVideoFrames, droppedVideoFrames >= 0 {
            rows.append((AppLanguage.string(.playerStatsDroppedFrames), LocaleFormat.integer(droppedVideoFrames)))
        }
        if let accumulatedFrameDelaySeconds,
           accumulatedFrameDelaySeconds.isFinite,
           accumulatedFrameDelaySeconds >= 0 {
            rows.append((AppLanguage.string(.playerStatsAccumulatedFrameDelay), formatSeconds(accumulatedFrameDelaySeconds)))
        }
        if let avSyncGapMilliseconds, avSyncGapMilliseconds.isFinite {
            rows.append((AppLanguage.string(.playerStatsAvSyncGap), LocaleFormat.decimal(avSyncGapMilliseconds, fractionDigits: 1) + " ms"))
        }
        return rows
    }

    var networkRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let instantReadBitrateBps {
            rows.append((AppLanguage.string(.playerStatsInstantReadBitrate), formatBitsPerSecond(instantReadBitrateBps)))
        }
        if let averageReadBitrateBps {
            rows.append((AppLanguage.string(.playerStatsAverageReadBitrate), formatBitsPerSecond(averageReadBitrateBps)))
        }
        if let audioBridgeBitrateBps {
            rows.append((AppLanguage.string(.playerStatsAudioBridgeBitrate), formatBitsPerSecond(audioBridgeBitrateBps)))
        }
        if let networkThroughputBps {
            rows.append((AppLanguage.string(.playerStatsNetworkThroughput), formatBitsPerSecond(networkThroughputBps)))
        }
        if let bytesTransferred, bytesTransferred >= 0 {
            rows.append((AppLanguage.string(.playerStatsNetworkTransferred), formatBytes(bytesTransferred)))
        }
        if let cachedBytes, cachedBytes >= 0 {
            rows.append((AppLanguage.string(.playerStatsAetherCache), formatBytes(cachedBytes)))
        }
        if let demuxerBytesFetched, demuxerBytesFetched >= 0 {
            rows.append((AppLanguage.string(.playerStatsDemuxerRead), formatBytes(demuxerBytesFetched)))
        }
        return rows
    }

    var engineRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let producerRestartCount, producerRestartCount > 0 {
            rows.append((AppLanguage.string(.playerStatsProducerRestarts), LocaleFormat.integer(producerRestartCount)))
        }
        if let residentMemoryBytes, residentMemoryBytes >= 0 {
            rows.append((AppLanguage.string(.playerStatsResidentMemory), formatBytes(residentMemoryBytes)))
        }
        return rows
    }

    private func mediaDescription(_ stream: MediaStream) -> String? {
        var parts: [String] = []
        if let codec = normalized(stream.codec) {
            parts.append(Self.codecName(codec))
        }
        if let detail = normalized(stream.detail) {
            parts.append(detail)
        }
        if let bitrateBps = stream.bitrateBps,
           bitrateBps.isFinite,
           bitrateBps > 0 {
            parts.append(formatBitsPerSecond(bitrateBps))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func stringRows(_ candidates: [(String, String?)]) -> [(String, String)] {
        candidates.compactMap { label, value in
            normalized(value).map { (label, $0) }
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func codecName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "hevc", "hvc1", "hev1": return "HEVC"
        case "h264", "avc1", "avc3": return "H.264"
        case "truehd", "mlpa": return "TrueHD"
        case "eac3", "e-ac-3", "ec-3": return "E-AC-3"
        case "ac3", "ac-3": return "AC-3"
        case "aac", "mp4a", "mp4a.40.2": return "AAC"
        case "dca", "dts": return "DTS"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        default: return codec
        }
    }

    private func formatBitsPerSecond(_ bps: Double) -> String {
        guard bps.isFinite, bps > 0 else { return LocaleFormat.integer(0) + " bps" }
        if bps >= 1_000_000 {
            return LocaleFormat.decimal(bps / 1_000_000, fractionDigits: 2) + " Mbps"
        }
        return LocaleFormat.decimal(bps / 1_000, fractionDigits: 0) + " Kbps"
    }

    private func formatSeconds(_ seconds: Double) -> String {
        LocaleFormat.decimal(max(0, seconds), fractionDigits: 2) + " s"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        LocaleFormat.bytes(bytes)
    }
}

import Foundation

/// Host-facing playback diagnostics. Every value is projected from
/// AetherEngine's public state or from immutable Silo session metadata.
/// A missing value means the active Aether route cannot measure it.
///
/// The rows come in three sections, one per reader, and a fact appears in
/// exactly one of them:
///
/// - `playbackRows`: what is playing and how it reaches the device.
/// - `streamRows`: whether playback is keeping up right now.
/// - `engineRows`: Aether's internals, for a bug report.
struct PlaybackStats: Equatable {
    struct MediaStream: Equatable {
        /// The stream as the Playback section shows it, without its bitrate:
        /// "HEVC · 3840×2160 · 23.976 fps", "English · EAC3 5.1".
        var description: String?
        var bitrateBps: Double?
        /// What Aether decodes or passes the stream with:
        /// "VideoToolbox HEVC (HW)", "Stream-copy (EAC3+JOC Atmos)".
        var decoder: String?
        /// The stream in a few words, for the surfaces that say what is
        /// playing rather than measure it: "4K · Dolby Vision".
        var summary: String?
    }

    struct Row: Equatable, Identifiable {
        /// Stable across languages; labels are not unique.
        let id: String
        /// In the app's language. Empty on a row that continues the one
        /// above it.
        let label: String
        let value: String
    }

    var sampledAt: Date = Date()

    // Source/session identity supplied by Silo.
    /// How the file reaches the device, in viewer terms: "Direct play".
    var playMethod: String?
    /// The server's reason for delivering the file this way.
    var decisionReason: String?
    /// What the plan gave up, in the server's words.
    var warnings: [String] = []
    var route: String?
    var source: String?
    var delivery: String?
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
    var allRows: [Row] {
        playbackRows + streamRows + engineRows
    }

    /// What the inert iPhone overlay draws: everything a viewer can act on.
    /// Aether's internals stay on the pages that scroll.
    var overlayRows: [Row] {
        playbackRows + streamRows
    }

    var hasRows: Bool { !allRows.isEmpty }

    /// What is playing and how it reaches the device.
    var playbackRows: [Row] {
        var rows: [Row] = []
        append(&rows, "playback", .playerHudPlayback, joined([playMethod, container]))
        append(&rows, "video", .playerHudVideo, mediaDescription(video))
        append(&rows, "dynamicRange", .playerStatsDynamicRange, dynamicRange)
        append(&rows, "audio", .playerHudAudio, mediaDescription(audio))
        append(&rows, "subtitles", .playerStatsSubtitles, subtitles)
        // The speed is a setting the viewer chose; it is a stat only while
        // it changes what the other rows mean.
        if let playbackRate, playbackRate.isFinite, playbackRate > 0, abs(playbackRate - 1) > 0.001 {
            append(&rows, "playbackRate", .playerStatsPlaybackRate, LocaleFormat.rate(playbackRate))
        }
        // The reason and the warnings share one label; only the first row
        // carries it.
        let notes = ([decisionReason] + warnings).compactMap { normalized($0) }
        for (index, note) in notes.enumerated() {
            rows.append(Row(
                id: "diagnostics.\(index)",
                label: index == 0 ? AppLanguage.string(.playerSettingsDiagnostics) : "",
                value: note
            ))
        }
        return rows
    }

    /// Whether playback is keeping up right now.
    var streamRows: [Row] {
        var rows: [Row] = []
        append(&rows, "status", .playerStatsPlaybackStatus, playbackStatus)
        if let bufferedAheadSeconds, bufferedAheadSeconds.isFinite {
            append(&rows, "forwardBuffer", .playerStatsForwardBuffer, formatSeconds(bufferedAheadSeconds))
        } else if let cushion = displayCushion {
            // The software route has no forward buffer to report; its
            // display cushion is the comparable reading.
            append(&rows, "displayCushion", .playerStatsDisplayCushion, cushion)
        }
        if let networkThroughputBps {
            append(&rows, "networkThroughput", .playerStatsNetworkThroughput, formatBitsPerSecond(networkThroughputBps))
        }
        if let instantReadBitrateBps {
            append(&rows, "instantReadBitrate", .playerStatsInstantReadBitrate, formatBitsPerSecond(instantReadBitrateBps))
        }
        if let droppedVideoFrames, droppedVideoFrames >= 0 {
            append(&rows, "droppedFrames", .playerStatsDroppedFrames, LocaleFormat.integer(droppedVideoFrames))
        }
        if let avSyncGapMilliseconds, avSyncGapMilliseconds.isFinite {
            append(
                &rows, "avSyncGap", .playerStatsAvSyncGap,
                LocaleFormat.decimal(avSyncGapMilliseconds, fractionDigits: 1) + " ms"
            )
        }
        return rows
    }

    /// Aether's internals: the pipeline it chose and its own counters.
    var engineRows: [Row] {
        var rows: [Row] = []
        append(&rows, "route", .playerHudRoute, route)
        append(&rows, "delivery", .playerStatsDelivery, delivery)
        append(&rows, "source", .playerStatsSource, source)
        append(&rows, "videoDecoder", .playerHudVideo, video.decoder)
        append(&rows, "audioDecoder", .playerHudAudio, audio.decoder)
        if let bufferedAheadSeconds, bufferedAheadSeconds.isFinite, let cushion = displayCushion {
            append(&rows, "displayCushion", .playerStatsDisplayCushion, cushion)
        }
        if let readerWindowAheadBytes, readerWindowAheadBytes >= 0 {
            append(&rows, "readerRunway", .playerStatsReaderRunway, LocaleFormat.bytes(readerWindowAheadBytes))
        }
        if let observedFrameRate, observedFrameRate.isFinite, observedFrameRate > 0 {
            append(
                &rows, "observedFrameRate", .playerStatsObservedFrameRate,
                LocaleFormat.decimal(observedFrameRate, fractionDigits: 2) + " fps"
            )
        }
        if let accumulatedFrameDelaySeconds,
           accumulatedFrameDelaySeconds.isFinite,
           accumulatedFrameDelaySeconds >= 0 {
            append(
                &rows, "accumulatedFrameDelay", .playerStatsAccumulatedFrameDelay,
                formatSeconds(accumulatedFrameDelaySeconds)
            )
        }
        if let averageReadBitrateBps {
            append(&rows, "averageReadBitrate", .playerStatsAverageReadBitrate, formatBitsPerSecond(averageReadBitrateBps))
        }
        if let audioBridgeBitrateBps {
            append(&rows, "audioBridgeBitrate", .playerStatsAudioBridgeBitrate, formatBitsPerSecond(audioBridgeBitrateBps))
        }
        if let bytesTransferred, bytesTransferred >= 0 {
            append(&rows, "networkTransferred", .playerStatsNetworkTransferred, LocaleFormat.bytes(bytesTransferred))
        }
        if let cachedBytes, cachedBytes >= 0 {
            append(&rows, "aetherCache", .playerStatsAetherCache, LocaleFormat.bytes(cachedBytes))
        }
        if let demuxerBytesFetched, demuxerBytesFetched >= 0 {
            append(&rows, "demuxerRead", .playerStatsDemuxerRead, LocaleFormat.bytes(demuxerBytesFetched))
        }
        if let producerRestartCount, producerRestartCount > 0 {
            append(&rows, "producerRestarts", .playerStatsProducerRestarts, LocaleFormat.integer(producerRestartCount))
        }
        if let residentMemoryBytes, residentMemoryBytes >= 0 {
            append(&rows, "residentMemory", .playerStatsResidentMemory, LocaleFormat.bytes(residentMemoryBytes))
        }
        return rows
    }

    private var displayCushion: String? {
        guard let displayCushionSeconds, displayCushionSeconds.isFinite else { return nil }
        return formatSeconds(displayCushionSeconds)
    }

    private func mediaDescription(_ stream: MediaStream) -> String? {
        let bitrate = stream.bitrateBps.flatMap { bps in
            bps.isFinite && bps > 0 ? formatBitsPerSecond(bps) : nil
        }
        return joined([stream.description, bitrate])
    }

    private func append(
        _ rows: inout [Row],
        _ id: String,
        _ label: LocalizedStringResource,
        _ value: String?
    ) {
        guard let value = normalized(value) else { return }
        rows.append(Row(id: id, label: AppLanguage.string(label), value: value))
    }

    /// The non-empty parts joined with " · ", or nil when none are left.
    private func joined(_ parts: [String?]) -> String? {
        let present = parts.compactMap { normalized($0) }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func formatBitsPerSecond(_ bps: Double) -> String {
        guard bps.isFinite, bps > 0 else { return LocaleFormat.integer(0) + " bps" }
        if bps >= 1_000_000 {
            return LocaleFormat.decimal(bps / 1_000_000, fractionDigits: 1) + " Mbps"
        }
        return LocaleFormat.decimal(bps / 1_000, fractionDigits: 0) + " Kbps"
    }

    private func formatSeconds(_ seconds: Double) -> String {
        LocaleFormat.decimal(max(0, seconds), fractionDigits: 1) + " s"
    }
}

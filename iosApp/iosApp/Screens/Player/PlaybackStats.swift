import Foundation

/// Host-facing playback diagnostics. Every value is projected from
/// AetherEngine's public state or from immutable Silo session metadata.
/// A missing value means the active Aether route cannot measure it.
struct PlaybackStats: Equatable {
    struct MediaStream: Equatable {
        var codec: String?
        var detail: String?
        var bitrateBps: Double?
    }

    var sampledAt: Date = Date()

    // Source/session identity supplied by Silo.
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
    var allRows: [(String, String)] {
        sourceRows + mediaRows + bufferRows + networkRows + engineRows
    }

    /// The short set shown over iPhone video. It intentionally leaves the
    /// engine-health counters to the paged tvOS panel.
    var compactRows: [(String, String)] {
        let wanted = [
            "Route", "Source", "Delivery", "Container",
            "Video", "Audio", "Dynamic range", "Subtitles",
            "Playback status", "Forward buffer", "Display cushion",
            "Dropped frames", "Instant read bitrate", "Network throughput"
        ]
        let rows = allRows
        return wanted.compactMap { label in
            rows.first { $0.0 == label }
        }
    }

    var hasRows: Bool { !allRows.isEmpty }

    var sourceRows: [(String, String)] {
        stringRows([
            ("Route", route),
            ("Source", source),
            ("Delivery", delivery),
            ("Container", container)
        ])
    }

    var mediaRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let video = mediaDescription(video) {
            rows.append(("Video", video))
        }
        if let audio = mediaDescription(audio) {
            rows.append(("Audio", audio))
        }
        rows.append(contentsOf: stringRows([
            ("Dynamic range", dynamicRange),
            ("Subtitles", subtitles)
        ]))
        if let playbackRate, playbackRate.isFinite, playbackRate > 0 {
            rows.append(("Playback rate", String(format: "%.2fx", playbackRate)))
        }
        return rows
    }

    var bufferRows: [(String, String)] {
        var rows = stringRows([("Playback status", playbackStatus)])
        if let bufferedAheadSeconds, bufferedAheadSeconds.isFinite {
            rows.append(("Forward buffer", formatSeconds(bufferedAheadSeconds)))
        }
        if let displayCushionSeconds, displayCushionSeconds.isFinite {
            rows.append(("Display cushion", formatSeconds(displayCushionSeconds)))
        }
        if let readerWindowAheadBytes, readerWindowAheadBytes >= 0 {
            rows.append(("Reader runway", formatBytes(readerWindowAheadBytes)))
        }
        if let observedFrameRate, observedFrameRate.isFinite, observedFrameRate > 0 {
            rows.append(("Observed frame rate", String(format: "%.2f fps", observedFrameRate)))
        }
        if let droppedVideoFrames, droppedVideoFrames >= 0 {
            rows.append(("Dropped frames", "\(droppedVideoFrames)"))
        }
        if let accumulatedFrameDelaySeconds,
           accumulatedFrameDelaySeconds.isFinite,
           accumulatedFrameDelaySeconds >= 0 {
            rows.append(("Accumulated frame delay", formatSeconds(accumulatedFrameDelaySeconds)))
        }
        if let avSyncGapMilliseconds, avSyncGapMilliseconds.isFinite {
            rows.append(("A/V sync gap", String(format: "%.1f ms", avSyncGapMilliseconds)))
        }
        return rows
    }

    var networkRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let instantReadBitrateBps {
            rows.append(("Instant read bitrate", formatBitsPerSecond(instantReadBitrateBps)))
        }
        if let averageReadBitrateBps {
            rows.append(("Average read bitrate", formatBitsPerSecond(averageReadBitrateBps)))
        }
        if let audioBridgeBitrateBps {
            rows.append(("Audio bridge bitrate", formatBitsPerSecond(audioBridgeBitrateBps)))
        }
        if let networkThroughputBps {
            rows.append(("Network throughput", formatBitsPerSecond(networkThroughputBps)))
        }
        if let bytesTransferred, bytesTransferred >= 0 {
            rows.append(("Network transferred", formatBytes(bytesTransferred)))
        }
        if let cachedBytes, cachedBytes >= 0 {
            rows.append(("Aether cache", formatBytes(cachedBytes)))
        }
        if let demuxerBytesFetched, demuxerBytesFetched >= 0 {
            rows.append(("Demuxer read", formatBytes(demuxerBytesFetched)))
        }
        return rows
    }

    var engineRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let producerRestartCount, producerRestartCount > 0 {
            rows.append(("Producer restarts", "\(producerRestartCount)"))
        }
        if let residentMemoryBytes, residentMemoryBytes >= 0 {
            rows.append(("Resident memory", formatBytes(residentMemoryBytes)))
        }
        return rows
    }

    private func mediaDescription(_ stream: MediaStream) -> String? {
        var parts: [String] = []
        if let codec = normalized(stream.codec) {
            parts.append(formatCodec(codec))
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

    private func formatCodec(_ codec: String) -> String {
        switch codec.lowercased() {
        case "hevc", "hvc1", "hev1": return "HEVC"
        case "h264", "avc1", "avc3": return "H.264"
        case "truehd", "mlpa": return "TrueHD"
        case "eac3", "e-ac-3", "ec-3": return "E-AC-3"
        case "ac3", "ac-3": return "AC-3"
        case "aac", "mp4a", "mp4a.40.2": return "AAC"
        default: return codec
        }
    }

    private func formatBitsPerSecond(_ bps: Double) -> String {
        guard bps.isFinite, bps > 0 else { return "0 bps" }
        if bps >= 1_000_000 {
            return String(format: "%.2f Mbps", bps / 1_000_000)
        }
        return String(format: "%.0f Kbps", bps / 1_000)
    }

    private func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.2f s", max(0, seconds))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

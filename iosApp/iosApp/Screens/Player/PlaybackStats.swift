import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import OSLog

struct PlaybackStats: Equatable {
    struct MediaStream: Equatable {
        var codec: String?
        var detail: String?
        var bitrateBps: Double?
    }

    /// What the engine is actually rendering, as opposed to what the plan
    /// asked for. `dynamicRange` below is a human-readable label that may
    /// describe the source instead ("Dolby Vision Profile 7 … as HDR10") or
    /// fall back to the planned route, so it cannot be pattern-matched to
    /// decide what the picture really is. This is only ever set from engine
    /// introspection; `nil` means "not determined yet", never "SDR".
    enum ConfirmedDynamicRange: Equatable {
        case sdr
        case hdr10
        case hlg
        case dolbyVision
    }

    var route: String?
    var source: String?
    var container: String?
    var video: MediaStream = .init()
    var audio: MediaStream = .init()
    var dynamicRange: String?
    var confirmedDynamicRange: ConfirmedDynamicRange?
    var subtitles: String?
    var screenFrameRate: Double?
    var playbackRate: Double?
    var bufferStatus: String?
    /// Raw AVPlayer decode buffer ahead of the playhead. Diagnostics and the
    /// recovery ladder only — the user-facing figure is `runwaySeconds`.
    var playableAheadSeconds: Double?
    /// Seconds of media that will play with zero network. On loopback this is
    /// normally far larger than `playableAheadSeconds`.
    var runwaySeconds: Double?
    var rebufferCount: Int?
    /// Catalog-declared bitrate. Composer-owned; the backend never sets it.
    var nominalFileBitrateBps: Double?
    /// One definition per route, chosen by `PlaybackStatsComposer`.
    var downloadRateBps: Double?
    var observedBitrateBps: Double?
    var indicatedBitrateBps: Double?
    var streamSpeed: Double?
    var networkBytesTransferred: Int64?
    /// Loopback-only debug rows: what the demuxer pulled off the proxy, which
    /// is not the same thing as what the transport downloaded.
    var demuxReadRateBps: Double?
    var demuxReadBytes: Int64?
    var sourceCacheBytes: Int64?
    var sourceCacheBudgetBytes: Int64?
    var sourceCacheHighWaterBytes: Int64?
    var sourceCacheLowWaterBytes: Int64?
    var sourceCacheForwardBytes: Int64?
    var sourceCacheAheadSeconds: Double?
    var sourceBytesServedFromCache: Int64?
    var sourceOriginWaitCount: Int?
    /// `sourceBytesServedFromCache / networkBytesTransferred`. May exceed 1 —
    /// a backward seek re-serves bytes that were only fetched once.
    var sourceCacheReuseRatio: Double?
    var sourceActiveOriginRequestCount: Int?
    var sourceDiskSpillBytes: Int64?
    var sourceDiskBytesWritten: Int64?
    var sourceResumeCapable: Bool?
    var sourceResumeServerAdvertised: Bool?
    var generatedAheadSeconds: Double?
    var generatedVisibleAheadSeconds: Double?
    var generatedMediaBitrateBps: Double?
    var generatedSegmentCount: Int?
    var generatedSpilledSegmentCount: Int?
    var generatedLoopbackGeneration: UInt64?
    var generatedPlaylistMediaSequence: String?
    var generatedPlaylistVisibleRange: String?
    var generatedPlaylistBytes: Int?
    var generatedPlaylistHash: UInt64?
    var generatedDurationSource: String?
    var segmentStoreBytes: Int64?
    var segmentStoreBudgetBytes: Int64?
    var segmentStoreTempSpillBytes: Int64?
    var segmentStoreTempSpillBudgetBytes: Int64?
    var segmentStoreTempSpillPercent: Double?
    var segmentStoreDebugMirrorBytes: Int64?
    var segmentServerRequestCount: Int64?
    var segmentServerBytesServed: Int64?
    var segmentServerLastLatencyMs: Double?
    var segmentServerWaitCount: Int64?
    var deviceInfo: String?
    var freeDiskSpaceBytes: Int64?
    var volumeAvailableCapacityBytes: Int64?

    static let empty = PlaybackStats()
}

extension PlaybackStats {
    /// Stable identity for a row, independent of its label. The iOS compact
    /// set selects on these — renaming a label must never silently drop a
    /// row from the overlay again.
    enum RowID: String, Hashable, CaseIterable {
        case route, source, container
        case video, audio, dynamicRange, subtitles, screenFrameRate, playbackRate
        case bufferStatus, runway, downloadedAhead, generatedAhead, playableAhead, rebufferEvents
        case nominalFileBitrate, downloadRate, streamSpeed
        case indicatedBitrate, observedBitrate
        case networkBytesTransferred, servedFromCache, cacheReuse, originWaits
        case sourceCache, sourceCacheForward, sourceCacheWatermarks
        case originRequests, sourceDiskSpill, sourceDiskWritten
        case directStreamResume, serverResumeFeature
        case demuxReadRate, demuxReadBytes
        case generatedWrittenAhead, generatedMediaBitrate, generatedSegments
        case generatedSpilledSegments, loopbackGeneration
        case playlistMediaSequence, playlistVisibleRange, playlistBytes, playlistHash
        case segmentDurationSource
        case generatedStore, generatedTempSpill, generatedDebugMirror
        case hlsRequests, hlsServed, hlsLatency, hlsWaits
        case device, freeDiskSpace, volumeAvailable
    }

    struct Row: Identifiable, Equatable {
        let id: RowID
        let label: String
        let value: String
    }

    /// Every section's rows in display order — the full set the tvOS HUD
    /// pane pages through.
    var allRows: [Row] {
        sourceRows + mediaRows + bufferRows + networkRows + deviceRows
    }

    /// The subset the iOS overlay draws. The full set runs to ~45 rows on
    /// the loopback route, which is a wall of text over the picture and
    /// mostly cache/segment internals you'd go to the tvOS pane (or the
    /// Advanced page) for. This keeps what identifies the file and tells
    /// you whether playback is healthy, in the same order.
    ///
    /// Selected by `RowID` against `allRows` rather than by label, so a label
    /// rename can never silently drop a row from the overlay, and rebuilt
    /// from the pane's own rows so the formatting can never drift from it.
    private static let compactRowIDs: [RowID] = [
        .route, .source, .container,
        .video, .audio, .dynamicRange, .subtitles,
        .bufferStatus, .runway, .playableAhead,
        .nominalFileBitrate, .downloadRate, .streamSpeed,
        .indicatedBitrate, .observedBitrate,
        .device, .freeDiskSpace
    ]

    var compactRows: [Row] {
        let rows = allRows
        return Self.compactRowIDs.compactMap { id in rows.first { $0.id == id } }
    }

    /// True once any section has something to show. Every row accessor drops
    /// nil/empty values, so a snapshot taken before the engine has reported
    /// anything renders as a blank panel; callers use this to show a
    /// placeholder instead.
    var hasRows: Bool { !allRows.isEmpty }

    var sourceRows: [Row] {
        [
            (RowID.route, "Route", route),
            (RowID.source, "Source", source),
            (RowID.container, "Container", container)
        ].compactMap { id, label, value in
            guard let value, !value.isEmpty else { return nil }
            return Row(id: id, label: label, value: value)
        }
    }

    var mediaRows: [Row] {
        var rows: [Row] = []
        if let video = mediaDescription(video) {
            rows.append(Row(id: .video, label: "Video", value: video))
        }
        if let audio = mediaDescription(audio) {
            rows.append(Row(id: .audio, label: "Audio", value: audio))
        }
        if let dynamicRange, !dynamicRange.isEmpty {
            rows.append(Row(id: .dynamicRange, label: "Dynamic range", value: dynamicRange))
        }
        if let subtitles, !subtitles.isEmpty {
            rows.append(Row(id: .subtitles, label: "Subtitles", value: subtitles))
        }
        if let screenFrameRate, screenFrameRate > 0 {
            rows.append(Row(id: .screenFrameRate, label: "Screen frame rate", value: formatFrameRate(screenFrameRate)))
        }
        if let playbackRate {
            rows.append(Row(id: .playbackRate, label: "Playback rate", value: String(format: "%.2fx", playbackRate)))
        }
        return rows
    }

    /// The buffer pipeline, in flow order: what has been downloaded, what has
    /// been remuxed out of it, and what AVPlayer has actually decoded ahead —
    /// with the user-facing runway on top. The ordering is load-bearing; a
    /// "just move this row" edit breaks the reading.
    var bufferRows: [Row] {
        var rows: [Row] = []
        if let bufferStatus, !bufferStatus.isEmpty {
            rows.append(Row(id: .bufferStatus, label: "Buffer status", value: bufferStatus))
        }
        if let runwaySeconds {
            rows.append(Row(id: .runway, label: "Runway", value: String(format: "%.1f s", runwaySeconds)))
        }
        if let sourceCacheAheadSeconds {
            rows.append(Row(
                id: .downloadedAhead,
                label: "Downloaded ahead (est)",
                value: String(format: "%.1f s", sourceCacheAheadSeconds)
            ))
        }
        if let generatedVisibleAheadSeconds {
            rows.append(Row(
                id: .generatedAhead,
                label: "Generated ahead",
                value: String(format: "%.1f s", generatedVisibleAheadSeconds)
            ))
        }
        if let playableAheadSeconds {
            rows.append(Row(
                id: .playableAhead,
                label: "Playable ahead",
                value: String(format: "%.1f s", playableAheadSeconds)
            ))
        }
        if let rebufferCount {
            rows.append(Row(id: .rebufferEvents, label: "Rebuffer events", value: "\(rebufferCount)"))
        }
        return rows
    }

    var networkRows: [Row] {
        var rows: [Row] = []
        if let nominalFileBitrateBps {
            rows.append(Row(id: .nominalFileBitrate, label: "File bitrate (nominal)", value: formatBitsPerSecond(nominalFileBitrateBps)))
        }
        if let downloadRateBps {
            rows.append(Row(id: .downloadRate, label: "Download rate", value: formatBitsPerSecond(downloadRateBps)))
        }
        // AVPlayer's own transport numbers, emitted whenever present. No
        // route-conditional fallback is needed here because the backend
        // already publishes them only where AVPlayer fetches the origin
        // itself (`publishesRemoteAccessLogNetworkStats`) — behind the proxy
        // or the loopback server they would be a 127.0.0.1 socket rate, and
        // those routes report transport through `Download rate` instead.
        if let indicatedBitrateBps {
            rows.append(Row(id: .indicatedBitrate, label: "Indicated bitrate", value: formatBitsPerSecond(indicatedBitrateBps)))
        }
        if let observedBitrateBps {
            rows.append(Row(id: .observedBitrate, label: "Observed bitrate", value: formatBitsPerSecond(observedBitrateBps)))
        }
        if let streamSpeed {
            rows.append(Row(id: .streamSpeed, label: "Stream speed", value: String(format: "%.2fx", streamSpeed)))
        }
        if let networkBytesTransferred {
            rows.append(Row(
                id: .networkBytesTransferred,
                label: "Downloaded from origin",
                value: ByteCountFormatter.string(fromByteCount: networkBytesTransferred, countStyle: .file)
            ))
        }
        if let sourceCacheBytes {
            let value: String
            if let sourceCacheBudgetBytes {
                value = "\(ByteCountFormatter.string(fromByteCount: sourceCacheBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: sourceCacheBudgetBytes, countStyle: .file))"
            } else {
                value = ByteCountFormatter.string(fromByteCount: sourceCacheBytes, countStyle: .file)
            }
            rows.append(Row(id: .sourceCache, label: "Source cache", value: value))
        }
        if let sourceCacheForwardBytes {
            rows.append(Row(id: .sourceCacheForward, label: "Source cache forward", value: ByteCountFormatter.string(fromByteCount: sourceCacheForwardBytes, countStyle: .file)))
        }
        if let sourceCacheHighWaterBytes, let sourceCacheLowWaterBytes {
            rows.append(Row(
                id: .sourceCacheWatermarks,
                label: "Source cache watermarks",
                value: "\(ByteCountFormatter.string(fromByteCount: sourceCacheLowWaterBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: sourceCacheHighWaterBytes, countStyle: .file))"
            ))
        }
        if let sourceBytesServedFromCache {
            rows.append(Row(
                id: .servedFromCache,
                label: "Served from cache",
                value: ByteCountFormatter.string(fromByteCount: sourceBytesServedFromCache, countStyle: .file)
            ))
        }
        if let sourceCacheReuseRatio {
            rows.append(Row(id: .cacheReuse, label: "Cache reuse", value: String(format: "%.2fx", sourceCacheReuseRatio)))
        }
        if let sourceOriginWaitCount {
            rows.append(Row(id: .originWaits, label: "Origin waits", value: "\(sourceOriginWaitCount)"))
        }
        if let sourceActiveOriginRequestCount {
            rows.append(Row(id: .originRequests, label: "Origin requests", value: "\(sourceActiveOriginRequestCount)"))
        }
        if let sourceDiskSpillBytes {
            rows.append(Row(id: .sourceDiskSpill, label: "Source disk spill", value: ByteCountFormatter.string(fromByteCount: sourceDiskSpillBytes, countStyle: .file)))
        }
        if let sourceDiskBytesWritten, sourceDiskBytesWritten > 0 {
            rows.append(Row(id: .sourceDiskWritten, label: "Source disk written", value: ByteCountFormatter.string(fromByteCount: sourceDiskBytesWritten, countStyle: .file)))
        }
        if let sourceResumeCapable {
            rows.append(Row(id: .directStreamResume, label: "Direct stream resume", value: sourceResumeCapable ? "Enabled" : "Disabled"))
        }
        if let sourceResumeServerAdvertised {
            rows.append(Row(id: .serverResumeFeature, label: "Server resume feature", value: sourceResumeServerAdvertised ? "Advertised" : "Not advertised"))
        }
        if let demuxReadRateBps {
            rows.append(Row(id: .demuxReadRate, label: "Demux read rate", value: formatBitsPerSecond(demuxReadRateBps)))
        }
        if let demuxReadBytes {
            rows.append(Row(id: .demuxReadBytes, label: "Demux read bytes", value: ByteCountFormatter.string(fromByteCount: demuxReadBytes, countStyle: .file)))
        }
        if let generatedAheadSeconds {
            rows.append(Row(id: .generatedWrittenAhead, label: "Generated (written) ahead", value: String(format: "%.1f s", generatedAheadSeconds)))
        }
        if let generatedMediaBitrateBps {
            rows.append(Row(id: .generatedMediaBitrate, label: "Generated media bitrate", value: formatBitsPerSecond(generatedMediaBitrateBps)))
        }
        if let generatedSegmentCount {
            rows.append(Row(id: .generatedSegments, label: "Generated segments", value: "\(generatedSegmentCount)"))
        }
        if let generatedSpilledSegmentCount {
            rows.append(Row(id: .generatedSpilledSegments, label: "Generated spilled segments", value: "\(generatedSpilledSegmentCount)"))
        }
        if let generatedLoopbackGeneration {
            rows.append(Row(id: .loopbackGeneration, label: "Loopback generation", value: "\(generatedLoopbackGeneration)"))
        }
        if let generatedPlaylistMediaSequence {
            rows.append(Row(id: .playlistMediaSequence, label: "Playlist media sequence", value: generatedPlaylistMediaSequence))
        }
        if let generatedPlaylistVisibleRange {
            rows.append(Row(id: .playlistVisibleRange, label: "Playlist visible range", value: generatedPlaylistVisibleRange))
        }
        if let generatedPlaylistBytes {
            rows.append(Row(id: .playlistBytes, label: "Playlist bytes", value: "\(generatedPlaylistBytes)"))
        }
        if let generatedPlaylistHash {
            rows.append(Row(id: .playlistHash, label: "Playlist hash", value: String(format: "%016llx", generatedPlaylistHash)))
        }
        if let generatedDurationSource {
            rows.append(Row(id: .segmentDurationSource, label: "Segment duration source", value: generatedDurationSource))
        }
        if let segmentStoreBytes {
            let value: String
            if let segmentStoreBudgetBytes {
                value = "\(ByteCountFormatter.string(fromByteCount: segmentStoreBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: segmentStoreBudgetBytes, countStyle: .file))"
            } else {
                value = ByteCountFormatter.string(fromByteCount: segmentStoreBytes, countStyle: .file)
            }
            rows.append(Row(id: .generatedStore, label: "Generated store", value: value))
        }
        if let segmentStoreTempSpillBytes {
            var value = ByteCountFormatter.string(fromByteCount: segmentStoreTempSpillBytes, countStyle: .file)
            if let segmentStoreTempSpillBudgetBytes, segmentStoreTempSpillBudgetBytes > 0 {
                value += " / \(ByteCountFormatter.string(fromByteCount: segmentStoreTempSpillBudgetBytes, countStyle: .file))"
            }
            if let segmentStoreTempSpillPercent {
                value += String(format: " (%.1f%%)", segmentStoreTempSpillPercent)
            }
            rows.append(Row(id: .generatedTempSpill, label: "Generated temp spill", value: value))
        }
        if let segmentStoreDebugMirrorBytes {
            rows.append(Row(id: .generatedDebugMirror, label: "Generated debug mirror", value: ByteCountFormatter.string(fromByteCount: segmentStoreDebugMirrorBytes, countStyle: .file)))
        }
        if let segmentServerRequestCount {
            rows.append(Row(id: .hlsRequests, label: "HLS requests", value: "\(segmentServerRequestCount)"))
        }
        if let segmentServerBytesServed {
            rows.append(Row(id: .hlsServed, label: "HLS served", value: ByteCountFormatter.string(fromByteCount: segmentServerBytesServed, countStyle: .file)))
        }
        if let segmentServerLastLatencyMs {
            rows.append(Row(id: .hlsLatency, label: "HLS latency", value: String(format: "%.1f ms", segmentServerLastLatencyMs)))
        }
        if let segmentServerWaitCount {
            rows.append(Row(id: .hlsWaits, label: "HLS waits", value: "\(segmentServerWaitCount)"))
        }
        return rows
    }

    var deviceRows: [Row] {
        var rows: [Row] = []
        if let deviceInfo, !deviceInfo.isEmpty {
            rows.append(Row(id: .device, label: "Device", value: deviceInfo))
        }
        if let freeDiskSpaceBytes {
            rows.append(Row(id: .freeDiskSpace, label: "Free disk space", value: ByteCountFormatter.string(fromByteCount: freeDiskSpaceBytes, countStyle: .file)))
        }
        if let volumeAvailableCapacityBytes {
            rows.append(Row(id: .volumeAvailable, label: "Volume available", value: ByteCountFormatter.string(fromByteCount: volumeAvailableCapacityBytes, countStyle: .file)))
        }
        return rows
    }

    private func mediaDescription(_ stream: MediaStream) -> String? {
        var parts: [String] = []
        if let codec = stream.codec, !codec.isEmpty {
            parts.append(formatCodec(codec))
        }
        if let detail = stream.detail, !detail.isEmpty {
            parts.append(detail)
        }
        if let bitrateBps = stream.bitrateBps {
            parts.append(formatBitsPerSecond(bitrateBps))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func formatCodec(_ codec: String) -> String {
        switch codec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "hevc", "hvc1", "hev1":
            return "HEVC"
        case "h264", "avc1", "avc3":
            return "H.264"
        case "truehd", "mlpa":
            return "TrueHD"
        case "eac3", "e-ac-3", "ec-3":
            return "E-AC-3"
        case "ac3", "ac-3":
            return "AC-3"
        case "aac", "mp4a", "mp4a.40.2":
            return "AAC"
        default:
            return codec
        }
    }

    private func formatBitsPerSecond(_ bps: Double) -> String {
        guard bps.isFinite, bps > 0 else { return "0 bps" }
        let mbps = bps / 1_000_000
        if mbps >= 1 {
            return String(format: "%.2f Mbps", mbps)
        }
        let kbps = bps / 1_000
        return String(format: "%.0f Kbps", kbps)
    }

    private func formatFrameRate(_ fps: Double) -> String {
        let rounded = fps.rounded()
        if abs(fps - rounded) < 0.01 {
            return String(format: "%.0f Hz", fps)
        }
        return String(format: "%.2f Hz", fps)
    }
}

enum AVFoundationPlaybackIntrospection {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "PlaybackStats"
    )

    struct VideoFormat {
        var stream: PlaybackStats.MediaStream
        var dynamicRange: String?
        /// Set only when the item's own format description settled the
        /// question. `nil` when there is no format description to read yet,
        /// so callers never mistake an unresolved item for SDR.
        var confirmedDynamicRange: PlaybackStats.ConfirmedDynamicRange?
    }

    @MainActor
    static func videoFormat(for item: AVPlayerItem) async -> VideoFormat {
        let track = await firstTrack(on: item, mediaType: .video)
        let description = await firstFormatDescription(on: item, mediaType: .video)
        let codec = description.flatMap { codecLabel(for: CMFormatDescriptionGetMediaSubType($0), mediaType: .video) }
        let dimensions = videoDimensions(from: description) ?? itemPresentationDimensions(item)
        let frameRate: Double?
        if let track {
            frameRate = positive(Double((try? await track.load(.nominalFrameRate)) ?? 0))
        } else {
            frameRate = nil
        }
        let detail = joined([
            dimensions.map { "\($0.width)x\($0.height)" },
            frameRate.map { String(format: "%.2f fps", $0) }
        ])
        let bitrate: Double?
        if let track {
            bitrate = positive(Double((try? await track.load(.estimatedDataRate)) ?? 0))
        } else {
            bitrate = nil
        }

        return VideoFormat(
            stream: PlaybackStats.MediaStream(
                codec: codec,
                detail: detail,
                bitrateBps: bitrate
            ),
            dynamicRange: description.flatMap(dynamicRangeLabel),
            confirmedDynamicRange: description.map(confirmedDynamicRange)
        )
    }

    @MainActor
    static func audioStream(for item: AVPlayerItem, selectionHint: String? = nil) async -> PlaybackStats.MediaStream {
        let track = await firstTrack(on: item, mediaType: .audio)
        let description = await firstFormatDescription(on: item, mediaType: .audio)
        let codec = description.flatMap { codecLabel(for: CMFormatDescriptionGetMediaSubType($0), mediaType: .audio) }
        let audioInfo = description.flatMap(audioDetail)
        let atmos = containsAtmosHint(selectionHint) || description.map(containsAtmosHint) == true
        let detail = joined([
            audioInfo,
            atmos ? "Atmos" : nil
        ])
        let bitrate: Double?
        if let track {
            bitrate = positive(Double((try? await track.load(.estimatedDataRate)) ?? 0))
        } else {
            bitrate = nil
        }

        return PlaybackStats.MediaStream(
            codec: codec,
            detail: detail,
            bitrateBps: bitrate
        )
    }

    static func dolbyVisionLabel(profile: Int?, level: Int? = nil, compatibilityID: Int? = nil) -> String? {
        guard let profile else { return nil }
        var label = "Dolby Vision Profile \(profile)"
        if let level, level > 0 {
            label += " Level \(level)"
        }
        if let compatibility = compatibilityLabel(for: compatibilityID) {
            label += " (\(compatibility))"
        }
        return label
    }

    @MainActor
    private static func firstTrack(on item: AVPlayerItem, mediaType: AVMediaType) async -> AVAssetTrack? {
        let itemTrack = item.tracks.first { playerTrack in
            playerTrack.isEnabled && playerTrack.assetTrack?.mediaType == mediaType
        }?.assetTrack
        if let itemTrack {
            return itemTrack
        }
        let tracks = try? await item.asset.loadTracks(withMediaType: mediaType)
        return tracks?.first
    }

    @MainActor
    private static func firstFormatDescription(on item: AVPlayerItem, mediaType: AVMediaType) async -> CMFormatDescription? {
        guard let track = await firstTrack(on: item, mediaType: mediaType) else { return nil }
        guard let descriptions = try? await track.load(.formatDescriptions) else { return nil }
        return descriptions.first
    }

    private static func videoDimensions(from description: CMFormatDescription?) -> (width: Int, height: Int)? {
        guard let description else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        return (Int(dimensions.width), Int(dimensions.height))
    }

    private static func itemPresentationDimensions(_ item: AVPlayerItem) -> (width: Int, height: Int)? {
        let size = item.presentationSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return nil
        }
        return (Int(size.width.rounded()), Int(size.height.rounded()))
    }

    private static func audioDetail(from description: CMFormatDescription) -> String? {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return nil
        }
        let channelCount = Int(asbd.mChannelsPerFrame)
        let sampleRate = asbd.mSampleRate.isFinite && asbd.mSampleRate > 0
            ? "\(Int(asbd.mSampleRate.rounded())) Hz"
            : nil
        return joined([
            channelLayoutLabel(channelCount),
            sampleRate
        ])
    }

    /// The same classification `dynamicRangeLabel` describes in prose, as a
    /// value the UI can branch on. Read from the description AVPlayer is
    /// actually feeding its decoder, so a Dolby Vision source the loopback
    /// stripped to its base layer is written out as `hvc1` + PQ and reports
    /// `.hdr10` here, not `.dolbyVision`.
    private static func confirmedDynamicRange(
        from description: CMFormatDescription
    ) -> PlaybackStats.ConfirmedDynamicRange {
        if dolbyVisionConfig(in: description) != nil {
            return .dolbyVision
        }

        let subtype = fourCC(CMFormatDescriptionGetMediaSubType(description)).lowercased()
        if subtype == "dvh1" || subtype == "dvhe" {
            return .dolbyVision
        }

        let transfer = extensionString(description, key: kCMFormatDescriptionExtension_TransferFunction)
        if containsAny(transfer, ["smpte_st_2084", "smpte2084", "pq"]) {
            return .hdr10
        }
        if containsAny(transfer, ["arib_std_b67", "itu_r_2100_hlg", "hlg"]) {
            return .hlg
        }
        return .sdr
    }

    /// Prose form of `confirmedDynamicRange`, which is the single classifier.
    private static func dynamicRangeLabel(from description: CMFormatDescription) -> String? {
        switch confirmedDynamicRange(from: description) {
        case .dolbyVision:
            if let dovi = dolbyVisionConfig(in: description) {
                return dolbyVisionLabel(
                    profile: dovi.profile,
                    level: dovi.level,
                    compatibilityID: dovi.compatibilityID
                )
            }
            return "Dolby Vision"
        case .hdr10:
            return "HDR10"
        case .hlg:
            return "HLG"
        case .sdr:
            return nil
        }
    }

    private static func codecLabel(for subtype: FourCharCode, mediaType: AVMediaType) -> String? {
        let token = fourCC(subtype).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        switch token.lowercased() {
        case "hvc1", "hev1":
            return "HEVC"
        case "dvh1", "dvhe":
            return "Dolby Vision HEVC"
        case "avc1", "avc3":
            return "H.264"
        case "av01":
            return "AV1"
        case "mp4v":
            return "MPEG-4 Video"
        case "ec-3", "ec3 ":
            return "E-AC-3"
        case "ac-3", "ac3 ":
            return "AC-3"
        case "mlpa":
            return "TrueHD"
        case "mp4a":
            return "AAC"
        case "lpcm":
            return "LPCM"
        default:
            return mediaType == .audio ? token.uppercased() : token
        }
    }

    private static func dolbyVisionConfig(in description: CMFormatDescription) -> (profile: Int, level: Int?, compatibilityID: Int?)? {
        guard let atoms = CMFormatDescriptionGetExtension(
            description,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
        ) else { return nil }

        guard let atom = atomData(named: "dvcC", in: atoms) ?? atomData(named: "dvvC", in: atoms) else {
            return nil
        }
        let data = atom.data
        let bytes = [UInt8](data)
        let payload: ArraySlice<UInt8>
        if bytes.count >= 13,
           String(bytes: bytes[4..<8], encoding: .ascii).map({ $0 == "dvcC" || $0 == "dvvC" }) == true {
            payload = bytes.dropFirst(8)
        } else {
            payload = bytes[...]
        }
        guard payload.count >= 5 else { return nil }

        let values = Array(payload.prefix(8))
        let packedProfile = Int((values[2] >> 1) & 0x7F)
        let packedLevel = Int(((values[2] & 0x01) << 5) | ((values[3] >> 3) & 0x1F))
        let packedCompatibilityID = Int((values[4] >> 4) & 0x0F)
        let looksPacked = isSupportedDolbyVisionProfile(packedProfile)

        let profile: Int
        let level: Int
        let compatibilityID: Int
        if looksPacked {
            profile = packedProfile
            level = packedLevel
            compatibilityID = packedCompatibilityID
        } else if values.count >= 8 {
            profile = Int(values[2] & 0x7F)
            level = Int(values[3] & 0x3F)
            compatibilityID = Int(values[7] & 0x0F)
        } else {
            return nil
        }
        guard isSupportedDolbyVisionProfile(profile) else {
            logger.info(
                "Ignoring unsupported Dolby Vision profile from \(atom.name, privacy: .public): profile=\(profile, privacy: .public) payloadPrefix=\(hexPrefix(payload), privacy: .public)"
            )
            return nil
        }
        return (profile, level > 0 ? level : nil, compatibilityID)
    }

    private static func atomData(named name: String, in value: Any) -> (name: String, data: Data)? {
        if value is Data {
            return nil
        }
        if value is NSData {
            return nil
        }
        if let dictionary = value as? [String: Any] {
            if let match = dictionary[name] {
                return dataValue(match).map { (name, $0) }
            }
            for (key, nested) in dictionary {
                if key == name, let data = dataValue(nested) {
                    return (key, data)
                }
                if let match = atomData(named: name, in: nested) {
                    return match
                }
            }
        }
        if let dictionary = value as? NSDictionary {
            if let match = dictionary[name] {
                return dataValue(match).map { (name, $0) }
            }
            for key in dictionary.allKeys {
                guard let keyString = key as? String,
                      let nested = dictionary[key] else {
                    continue
                }
                if keyString == name, let data = dataValue(nested) {
                    return (keyString, data)
                }
                if let match = atomData(named: name, in: nested) {
                    return match
                }
            }
        }
        return nil
    }

    private static func dataValue(_ value: Any) -> Data? {
        if let data = value as? Data {
            return data
        }
        if let data = value as? NSData {
            return data as Data
        }
        return nil
    }

    private static func isSupportedDolbyVisionProfile(_ profile: Int) -> Bool {
        switch profile {
        case 4, 5, 7, 8, 9, 10:
            return true
        default:
            return false
        }
    }

    private static func hexPrefix(_ bytes: ArraySlice<UInt8>, count: Int = 12) -> String {
        bytes.prefix(count)
            .map { String(format: "%02x", $0) }
            .joined(separator: " ")
    }

    private static func extensionString(_ description: CMFormatDescription, key: CFString) -> String? {
        CMFormatDescriptionGetExtension(description, extensionKey: key).map { "\($0)" }
    }

    private static func containsAtmosHint(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value.contains("atmos") || value.contains("joc")
    }

    private static func containsAtmosHint(_ description: CMFormatDescription) -> Bool {
        let extensions = CMFormatDescriptionGetExtensions(description).map { "\($0)" } ?? ""
        return containsAtmosHint(extensions)
    }

    private static func containsAny(_ value: String?, _ needles: [String]) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return needles.contains { value.contains($0) }
    }

    private static func compatibilityLabel(for compatibilityID: Int?) -> String? {
        switch compatibilityID {
        case 1: return "HDR10 compatible"
        case 2: return "SDR compatible"
        case 4: return "HLG compatible"
        default: return nil
        }
    }

    private static func channelLayoutLabel(_ count: Int) -> String? {
        switch count {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        case let count where count > 0:
            return "\(count) ch"
        default:
            return nil
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let scalars = [
            UnicodeScalar((code >> 24) & 0xFF),
            UnicodeScalar((code >> 16) & 0xFF),
            UnicodeScalar((code >> 8) & 0xFF),
            UnicodeScalar(code & 0xFF)
        ]
        return String(String.UnicodeScalarView(scalars.compactMap { $0 }))
    }

    private static func joined(_ parts: [String?]) -> String? {
        let values = parts.compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private static func positive(_ value: Double) -> Double? {
        value.isFinite && value > 0 ? value : nil
    }
}

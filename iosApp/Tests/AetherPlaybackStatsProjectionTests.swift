import AetherEngine
import Foundation
import XCTest
@testable import Silo

final class AetherPlaybackStatsProjectionTests: XCTestCase {
    func testProjectsPublicAetherStateAndRedactsSignedSourceURL() throws {
        let audio = TrackInfo(
            id: 2,
            name: "English",
            codec: "eac3",
            language: "eng",
            channels: 6,
            bitrate: 768_000,
            isDefault: true,
            isAtmos: true
        )
        let subtitle = TrackInfo(
            id: 5,
            name: "English SDH",
            codec: "subrip",
            language: "eng",
            isDefault: true,
            isHearingImpaired: true
        )
        let telemetry = LiveTelemetry(
            instantBitrateMbps: 18.5,
            averageBitrateMbps: 14.25,
            audioBridgeBitrateMbps: 0.76,
            observedFps: 23.976,
            droppedFrameCount: 3,
            forwardBufferSeconds: 12.5,
            displayCushionSeconds: nil,
            readerWindowAheadBytes: 8_000_000,
            accumulatedFrameDelaySeconds: 0.25,
            cachedBytes: 12_000_000,
            networkThroughputMbps: 95,
            networkTransferredBytes: 120_000_000,
            avSyncGapMs: -7.5,
            producerRestartCount: 1,
            muxedBytesLifetime: 80_000_000,
            serverBytesSentLifetime: 75_000_000,
            serverRequestCount: 42,
            demuxerBytesFetched: 130_000_000,
            audioBridgeLiveBytes: 32_000,
            rssMb: 384
        )
        let snapshot = AetherPlaybackStatsSnapshot(
            route: .loopback,
            phase: .playing,
            telemetry: telemetry,
            activeVideoDecoder: "VideoToolbox HEVC (HW)",
            activeAudioDecoder: "Stream-copy (EAC3+JOC Atmos)",
            sourceVideoFormat: .dolbyVision,
            outputVideoFormat: .hdr10,
            sourceDVProfile: 7,
            sourceVideoWidth: 3840,
            sourceVideoHeight: 2160,
            sourceVideoFrameRate: 23.976,
            sourceVideoBitrateBps: 16_000_000,
            audioTracks: [audio],
            activeAudioTrackIndex: audio.id,
            subtitleTracks: [subtitle],
            isSubtitleActive: true,
            activeSubtitleTrackIndex: subtitle.id,
            isSecondarySubtitleActive: true
        )
        let sourceURL = try XCTUnwrap(URL(
            string: "https://media.example.test/items/secret-title.mkv?token=do-not-display"
        ))
        let source = AetherPlaybackStatsSourceMetadata(
            sourceURL: sourceURL,
            delivery: "original_http",
            container: "matroska",
            playbackRate: 1.25,
            secondarySubtitleLabel: "Spanish"
        )
        let sampledAt = Date(timeIntervalSince1970: 1_000)

        let stats = AetherPlaybackStatsProjection.make(
            snapshot: snapshot,
            source: source,
            sampledAt: sampledAt
        )

        XCTAssertEqual(stats.sampledAt, sampledAt)
        XCTAssertEqual(stats.route, "Aether loopback HLS")
        XCTAssertEqual(stats.source, "media.example.test")
        XCTAssertFalse(stats.allRows.map(\.1).joined().contains("do-not-display"))
        XCTAssertFalse(stats.allRows.map(\.1).joined().contains("secret-title"))
        XCTAssertEqual(stats.delivery, "Original HTTP")
        XCTAssertEqual(stats.container, "MKV")
        XCTAssertEqual(stats.video.codec, "VideoToolbox HEVC (HW)")
        XCTAssertEqual(stats.video.detail, "3840×2160 · 23.976 fps")
        XCTAssertEqual(stats.video.bitrateBps, 16_000_000)
        XCTAssertEqual(stats.audio.codec, "eac3")
        XCTAssertEqual(
            stats.audio.detail,
            "English · eng · Atmos · Stream-copy (EAC3+JOC Atmos)"
        )
        XCTAssertEqual(stats.dynamicRange, "Dolby Vision Profile 7 → HDR10")
        XCTAssertEqual(stats.subtitles, "English SDH · eng · SUBRIP + Spanish")
        XCTAssertEqual(stats.playbackStatus, "Playing")
        XCTAssertEqual(stats.instantReadBitrateBps, 18_500_000)
        XCTAssertEqual(stats.networkThroughputBps, 95_000_000)
        XCTAssertEqual(stats.readerWindowAheadBytes, 8_000_000)
        XCTAssertEqual(stats.residentMemoryBytes, 384_000_000)

        let labels = Set(stats.allRows.map(\.0))
        XCTAssertFalse(labels.contains("Loopback generation"))
        XCTAssertFalse(labels.contains("Source cache watermarks"))
        XCTAssertFalse(labels.contains("Video packets"))
    }

    func testRouteAsymmetricTelemetryDoesNotInventForwardBuffer() {
        let telemetry = LiveTelemetry(
            instantBitrateMbps: nil,
            averageBitrateMbps: nil,
            audioBridgeBitrateMbps: nil,
            observedFps: 59.94,
            droppedFrameCount: 0,
            forwardBufferSeconds: nil,
            displayCushionSeconds: 0.42,
            readerWindowAheadBytes: 2_000_000,
            accumulatedFrameDelaySeconds: 0,
            cachedBytes: nil,
            networkThroughputMbps: nil,
            networkTransferredBytes: nil,
            avSyncGapMs: nil,
            producerRestartCount: 0,
            muxedBytesLifetime: 0,
            serverBytesSentLifetime: 0,
            serverRequestCount: 0,
            demuxerBytesFetched: 0,
            audioBridgeLiveBytes: 0,
            rssMb: 200
        )
        let stats = AetherPlaybackStatsProjection.make(
            snapshot: AetherPlaybackStatsSnapshot(
                route: .software,
                phase: .rebuffering,
                telemetry: telemetry,
                activeVideoDecoder: "dav1d AV1 (SW)",
                sourceVideoWidth: 1920,
                sourceVideoHeight: 1080
            ),
            source: AetherPlaybackStatsSourceMetadata(
                sourceURL: URL(fileURLWithPath: "/private/media/title.mkv"),
                delivery: nil,
                container: "mkv",
                playbackRate: 1
            )
        )

        XCTAssertEqual(stats.source, "Offline file")
        XCTAssertEqual(stats.bufferedAheadSeconds, nil)
        XCTAssertEqual(stats.displayCushionSeconds, 0.42)
        XCTAssertEqual(stats.playbackStatus, "Rebuffering")
        XCTAssertFalse(stats.bufferRows.contains { $0.0 == "Forward buffer" })
        XCTAssertTrue(stats.bufferRows.contains { $0.0 == "Display cushion" })
        XCTAssertFalse(stats.engineRows.contains { $0.0 == "Producer restarts" })
    }

    func testServerToneMapPlanPreservesOriginalDynamicRangeInStats() {
        let stats = AetherPlaybackStatsProjection.make(
            snapshot: AetherPlaybackStatsSnapshot(
                route: .remoteBypass,
                phase: .playing,
                sourceVideoFormat: .sdr,
                outputVideoFormat: .sdr,
                sourceVideoWidth: 1_920,
                sourceVideoHeight: 1_080
            ),
            source: AetherPlaybackStatsSourceMetadata(
                sourceURL: URL(string: "https://media.example.test/transcode/master.m3u8"),
                delivery: PlaybackProtocolV3.PlanDelivery.transcodeHLS,
                container: "hls",
                playbackRate: 1,
                plannedSourceDynamicRange: "hdr10",
                plannedOutputDynamicRange: "sdr"
            )
        )

        XCTAssertEqual(stats.dynamicRange, "HDR10 → SDR")
    }

    func testIdleSnapshotProducesNoSyntheticEngineRows() {
        let stats = AetherPlaybackStatsProjection.make(
            snapshot: AetherPlaybackStatsSnapshot(route: .none, phase: .idle),
            source: AetherPlaybackStatsSourceMetadata(
                sourceURL: nil,
                delivery: nil,
                container: nil,
                playbackRate: nil
            )
        )

        XCTAssertFalse(stats.hasRows)
        XCTAssertEqual(stats, PlaybackStats(
            sampledAt: stats.sampledAt,
            route: nil,
            source: nil,
            delivery: nil,
            container: nil,
            video: .init(),
            audio: .init(),
            dynamicRange: nil,
            subtitles: nil,
            playbackRate: nil,
            playbackStatus: nil,
            bufferedAheadSeconds: nil,
            displayCushionSeconds: nil,
            readerWindowAheadBytes: nil,
            observedFrameRate: nil,
            droppedVideoFrames: nil,
            accumulatedFrameDelaySeconds: nil,
            avSyncGapMilliseconds: nil,
            instantReadBitrateBps: nil,
            averageReadBitrateBps: nil,
            audioBridgeBitrateBps: nil,
            networkThroughputBps: nil,
            bytesTransferred: nil,
            cachedBytes: nil,
            demuxerBytesFetched: nil,
            producerRestartCount: nil,
            residentMemoryBytes: nil
        ))
    }
}

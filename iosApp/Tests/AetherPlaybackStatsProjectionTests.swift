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
            videoCodec: "hevc",
            decisionReason: "direct_play_supported",
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
        XCTAssertFalse(stats.allRows.map(\.value).joined().contains("do-not-display"))
        XCTAssertFalse(stats.allRows.map(\.value).joined().contains("secret-title"))
        XCTAssertEqual(stats.delivery, "Original HTTP")
        XCTAssertEqual(stats.playMethod, "Direct play")
        XCTAssertEqual(stats.decisionReason, "Direct play supported")
        XCTAssertEqual(stats.container, "MKV")
        XCTAssertEqual(stats.video.description, "HEVC · 3840×2160 · 23.976 fps")
        XCTAssertEqual(stats.video.decoder, "VideoToolbox HEVC (HW)")
        XCTAssertEqual(stats.video.summary, "4K · HDR10")
        XCTAssertEqual(stats.video.bitrateBps, 16_000_000)
        XCTAssertEqual(stats.audio.description, "English · EAC3 Atmos")
        XCTAssertEqual(stats.audio.decoder, "Stream-copy (EAC3+JOC Atmos)")
        XCTAssertEqual(stats.dynamicRange, "Dolby Vision Profile 7 → HDR10")
        XCTAssertEqual(stats.subtitles, "English SDH · SRT + Spanish")
        XCTAssertEqual(stats.playbackStatus, "Playing")
        XCTAssertEqual(stats.instantReadBitrateBps, 18_500_000)
        XCTAssertEqual(stats.networkThroughputBps, 95_000_000)
        XCTAssertEqual(stats.readerWindowAheadBytes, 8_000_000)
        XCTAssertEqual(stats.residentMemoryBytes, 384_000_000)

        let labels = Set(stats.allRows.map(\.label))
        XCTAssertFalse(labels.contains("Loopback generation"))
        XCTAssertFalse(labels.contains("Source cache watermarks"))
        XCTAssertFalse(labels.contains("Video packets"))

        // A fact has one row, in one section.
        XCTAssertEqual(Set(stats.allRows.map(\.id)).count, stats.allRows.count)
        // The overlay sits over a picture people screenshot and share: the
        // server's host and Aether's internals stay off it.
        let overlay = stats.overlayRows.map(\.value).joined(separator: "\n")
        XCTAssertFalse(overlay.contains("media.example.test"))
        XCTAssertFalse(overlay.contains("Aether loopback HLS"))
        XCTAssertEqual(
            stats.playbackRows.map(\.value),
            [
                "Direct play · MKV",
                "HEVC · 3840×2160 · 23.976 fps · 16.0 Mbps",
                "Dolby Vision Profile 7 → HDR10",
                "English · EAC3 Atmos · 768 Kbps",
                "English SDH · SRT + Spanish",
                "1.25×",
                "Direct play supported",
            ]
        )
    }

    /// A converted file says how and why; the server's reason and each
    /// warning get a row, under one label.
    func testConvertedPlaybackExplainsItself() {
        let stats = AetherPlaybackStatsProjection.make(
            snapshot: AetherPlaybackStatsSnapshot(
                route: .remoteBypass,
                phase: .playing,
                sourceVideoWidth: 1_920,
                sourceVideoHeight: 800
            ),
            source: AetherPlaybackStatsSourceMetadata(
                sourceURL: URL(string: "https://media.example.test/transcode/master.m3u8"),
                delivery: PlaybackProtocolV3.PlanDelivery.transcodeHLS,
                container: "mkv",
                playbackRate: 1,
                videoCodec: "h264",
                decisionReason: "video_codec_unsupported",
                warnings: ["HDR was tone-mapped to SDR.", "  "]
            )
        )

        XCTAssertEqual(stats.playMethod, "Transcoded by the server")
        // A scope crop of a 1080p master is still 1080p, and SDR goes unsaid.
        XCTAssertEqual(stats.video.summary, "1080p")
        XCTAssertEqual(stats.video.description, "H.264 · 1920×800")
        let notes = stats.playbackRows.filter { $0.id.hasPrefix("diagnostics") }
        XCTAssertEqual(notes.map(\.value), ["Video codec unsupported", "HDR was tone-mapped to SDR."])
        XCTAssertEqual(notes.map(\.label), ["Diagnostics", ""])
        XCTAssertFalse(stats.playbackRows.contains { $0.id == "playbackRate" }, "normal speed is not a stat")
        // The overlay cannot scroll: it keeps the one-line reason and leaves
        // the warnings, which have no limit, to the pages that do.
        let overlayNotes = stats.overlayRows.filter { $0.id.hasPrefix("diagnostics") }
        XCTAssertEqual(overlayNotes.map(\.value), ["Video codec unsupported"])
    }

    func testDolbyVisionProfileConversionRequiresEngineConfirmation() {
        let cases: [(DolbyVisionConversion?, VideoFormat, String)] = [
            (.profile7ToProfile81, .dolbyVision, "Dolby Vision Profile 7 → Profile 8.1"),
            (nil, .dolbyVision, "Dolby Vision Profile 7"),
            (.profile7ToProfile81, .hdr10, "Dolby Vision Profile 7 → HDR10"),
            (.profile7ToProfile81, .hdr10Plus, "Dolby Vision Profile 7 → HDR10+"),
        ]
        for (conversion, output, expected) in cases {
            let stats = AetherPlaybackStatsProjection.make(
                snapshot: AetherPlaybackStatsSnapshot(
                    route: .loopback,
                    phase: .playing,
                    sourceVideoFormat: .dolbyVision,
                    outputVideoFormat: output,
                    sourceDVProfile: 7,
                    dolbyVisionConversion: conversion,
                    sourceVideoWidth: 3840,
                    sourceVideoHeight: 2160
                ),
                source: AetherPlaybackStatsSourceMetadata(
                    sourceURL: nil,
                    delivery: "original_http",
                    container: "mkv",
                    playbackRate: 1
                )
            )

            XCTAssertEqual(stats.dynamicRange, expected)
        }
    }

    /// Aether reports SDR on an Apple TV it can't prove left SDR, though it
    /// sent the HDR stream; the label names what was sent, unconfirmed.
    func testUnprovenAppleTVShowsTheSentRangeAsUnconfirmed() {
        let dolbyVisionTV = DisplayCapabilities(
            supportsHDR: true, supportsDolbyVision: true, supportsHDR10: true, supportsHLG: true)
        let hdr10TV = DisplayCapabilities(
            supportsHDR: true, supportsDolbyVision: false, supportsHDR10: true, supportsHLG: true)
        let sdrTV = DisplayCapabilities(
            supportsHDR: false, supportsDolbyVision: false, supportsHDR10: false, supportsHLG: false)
        let cases: [(VideoRoute, VideoFormat, Int?, String?, DisplayCapabilities?, String)] = [
            (.loopback, .dolbyVision, 7, "smpte2084", dolbyVisionTV,
             "Dolby Vision Profile 7 → Profile 8.1 (unconfirmed)"),
            (.remoteBypass, .hdr10, nil, "smpte2084", dolbyVisionTV, "HDR10 (unconfirmed)"),
            (.loopback, .dolbyVision, 7, "smpte2084", hdr10TV, "Dolby Vision Profile 7 → HDR10 (unconfirmed)"),
            (.loopback, .dolbyVision, 8, "arib-std-b67", hdr10TV, "Dolby Vision Profile 8 → HLG (unconfirmed)"),
            (.loopback, .dolbyVision, 8, "bt709", hdr10TV, "Dolby Vision Profile 8 → SDR"),
            (.loopback, .dolbyVision, 8, "bt709", dolbyVisionTV, "Dolby Vision Profile 8 → SDR"),
            (.loopback, .dolbyVision, 7, "smpte2084", sdrTV, "Dolby Vision Profile 7 → SDR"),
            (.loopback, .dolbyVision, 7, "smpte2084", nil, "Dolby Vision Profile 7 → SDR"),
            (.software, .dolbyVision, 7, "smpte2084", dolbyVisionTV, "Dolby Vision Profile 7 → SDR"),
        ]
        for (route, sourceFormat, profile, transfer, display, expected) in cases {
            let stats = AetherPlaybackStatsProjection.make(
                snapshot: AetherPlaybackStatsSnapshot(
                    route: route,
                    phase: .playing,
                    sourceVideoFormat: sourceFormat,
                    outputVideoFormat: .sdr,
                    sourceDVProfile: profile,
                    dolbyVisionConversion: profile == 7 ? .profile7ToProfile81 : nil,
                    sourceVideoTransfer: transfer,
                    tvDisplay: display,
                    sourceVideoWidth: 3840,
                    sourceVideoHeight: 2160
                ),
                source: AetherPlaybackStatsSourceMetadata(
                    sourceURL: nil,
                    delivery: "original_http",
                    container: "mkv",
                    playbackRate: 1
                )
            )

            XCTAssertEqual(stats.dynamicRange, expected, "\(route) \(profile.map(String.init) ?? "-") \(transfer ?? "-")")
        }
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

        XCTAssertEqual(stats.playMethod, "Offline file")
        XCTAssertNil(stats.source, "a local file has no host to name")
        XCTAssertEqual(stats.bufferedAheadSeconds, nil)
        XCTAssertEqual(stats.displayCushionSeconds, 0.42)
        XCTAssertEqual(stats.playbackStatus, "Rebuffering")
        // With no forward buffer, the display cushion is the buffer reading.
        XCTAssertFalse(stats.streamRows.contains { $0.label == "Forward buffer" })
        XCTAssertTrue(stats.streamRows.contains { $0.label == "Display cushion" })
        XCTAssertFalse(stats.engineRows.contains { $0.label == "Display cushion" })
        XCTAssertFalse(stats.engineRows.contains { $0.label == "Producer restarts" })
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
            playMethod: nil,
            decisionReason: nil,
            warnings: [],
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

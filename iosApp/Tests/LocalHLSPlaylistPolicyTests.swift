import XCTest
import Foundation
@testable import Silo

final class LocalHLSPlaylistPolicyTests: XCTestCase {
    func testStartTagIsStartupOnly() {
        XCTAssertTrue(
            LocalHLSPlaylistPolicy.shouldEmitStartTag(firstMediaSequence: 0),
            "initial live playlist should keep EXT-X-START for the first AVPlayer attach"
        )
        XCTAssertFalse(
            LocalHLSPlaylistPolicy.shouldEmitStartTag(firstMediaSequence: 1),
            "sliding live playlist should not keep EXT-X-START anchored at the moving head"
        )
    }

    func testSpillRetirementDropsSegmentsFromPlaylist() {
        XCTAssertTrue(
            LocalHLSPlaylistPolicy.shouldRemoveRetiredSegmentsFromPlaylist,
            "retiring old segment bytes from the store must also drop them from the manifest, "
                + "otherwise AVPlayer fetches a retired (.gone) URI and fails with HTTP 410 on a backward seek"
        )
    }

    func testNonFinalPlaylistIsSlidingLiveFromFirstPublish() {
        XCTAssertEqual(LocalHLSPlaylistPolicy.playlistType(isFinal: false), .liveSliding)
        XCTAssertNil(LocalHLSPlaylistPolicy.playlistType(isFinal: false).hlsTag)
    }

    func testFinalPlaylistIsVOD() {
        XCTAssertEqual(LocalHLSPlaylistPolicy.playlistType(isFinal: true), .vod)
        XCTAssertEqual(LocalHLSPlaylistPolicy.playlistType(isFinal: true).hlsTag, "#EXT-X-PLAYLIST-TYPE:VOD")
    }

    func testMasterBandwidthDeclaresSourceAverageWithPeakHeadroom() {
        let bw = LocalHLSPlaylistPolicy.masterPlaylistBandwidth(
            sourceBitrateBps: 63_000_000, isAudioBridgedToLossless: false
        )
        XCTAssertEqual(bw.average, 63_000_000)
        XCTAssertEqual(bw.peak, 126_000_000)
    }

    func testMasterBandwidthNeverDeclaresBelowLegacyFloor() {
        // Low-bitrate sources keep at least the legacy declaration so a
        // one-off oversized segment (FLAC audio burst) stays under it.
        let bw = LocalHLSPlaylistPolicy.masterPlaylistBandwidth(
            sourceBitrateBps: 4_000_000, isAudioBridgedToLossless: false
        )
        XCTAssertEqual(bw.average, 4_000_000)
        XCTAssertEqual(bw.peak, LocalHLSPlaylistPolicy.fallbackMasterBandwidthBps)
    }

    func testMasterBandwidthBudgetsBridgedLosslessAudioIntoAverage() {
        // The served variant carries re-encoded FLAC, not the source's lossy
        // track; the declared average must not understate it (RFC 8216).
        let bw = LocalHLSPlaylistPolicy.masterPlaylistBandwidth(
            sourceBitrateBps: 20_000_000, isAudioBridgedToLossless: true
        )
        XCTAssertEqual(bw.average, 24_000_000)
        XCTAssertEqual(bw.peak, 48_000_000)
    }

    func testMasterBandwidthFallsBackWhenSourceBitrateUnknown() {
        let unknown = LocalHLSPlaylistPolicy.masterPlaylistBandwidth(
            sourceBitrateBps: nil, isAudioBridgedToLossless: false
        )
        XCTAssertEqual(unknown.peak, LocalHLSPlaylistPolicy.fallbackMasterBandwidthBps)
        XCTAssertNil(unknown.average)
        XCTAssertNil(
            LocalHLSPlaylistPolicy.masterPlaylistBandwidth(
                sourceBitrateBps: 0, isAudioBridgedToLossless: false
            ).average
        )
        XCTAssertNil(
            LocalHLSPlaylistPolicy.masterPlaylistBandwidth(
                sourceBitrateBps: .nan, isAudioBridgedToLossless: true
            ).average
        )
    }

    func testMasterBandwidthClampsAbsurdSourceBitrates() {
        let bw = LocalHLSPlaylistPolicy.masterPlaylistBandwidth(
            sourceBitrateBps: 5e12, isAudioBridgedToLossless: true
        )
        XCTAssertEqual(bw.average, 1_000_000_000)
        XCTAssertEqual(bw.peak, 2_000_000_000)
    }
}

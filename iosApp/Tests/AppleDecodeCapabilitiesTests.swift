import XCTest
@testable import Silo

/// The client reports decode capability to the server through three doors —
/// the V3 capability snapshot, the playback bootstrap, and download creation.
/// They have to describe the same client. ALAC was once present in one list
/// and absent from the other two, which the server could only read as "this
/// device cannot play ALAC", silently, on two of the three paths.
final class AppleDecodeCapabilitiesTests: XCTestCase {

    // MARK: - The surfaces agree

    func testV3SnapshotReportsTheSharedVocabulary() {
        let capabilities = ApplePlaybackV3Capabilities.snapshot().capabilities
        XCTAssertEqual(capabilities.codecsAudio, AppleDecodeCapabilities.audioCodecs)
        XCTAssertEqual(capabilities.containers, AppleDecodeCapabilities.containers)
        // The snapshot covers every route the plan can land on, so it is the
        // one surface that claims the software-decoded MPEG-2 unconditionally.
        XCTAssertEqual(
            capabilities.codecsVideo,
            AppleDecodeCapabilities.videoCodecs(includingMPEG2: true)
        )
    }

    func testDownloadCapsReportTheSharedVocabulary() {
        let caps = DownloadCaps.current()
        XCTAssertEqual(caps.codecsAudio, AppleDecodeCapabilities.audioCodecs)
        XCTAssertEqual(caps.containers, AppleDecodeCapabilities.containers)
        XCTAssertEqual(caps.codecsVideo, AppleDecodeCapabilities.videoCodecs)
        XCTAssertEqual(caps.maxResolution, AppleDecodeCapabilities.maxResolution)
    }

    func testEveryAudioSurfaceCarriesTheSameCodecs() {
        // The concrete regression: one list gaining a codec the others miss.
        let v3 = Set(ApplePlaybackV3Capabilities.snapshot().capabilities.codecsAudio)
        let downloads = Set(DownloadCaps.current().codecsAudio)
        XCTAssertEqual(v3, downloads)
        XCTAssertEqual(v3, Set(AppleDecodeCapabilities.audioCodecs))
    }

    // MARK: - The vocabulary itself

    func testDeviceListsCoverTheFormatsTheStackDecodes() {
        // Asserted on the lists directly, since the test host is a simulator
        // and would otherwise only ever see the conservative claim.
        let audio = AppleDecodeCapabilities.audioCodecs
        let containers = AppleDecodeCapabilities.containers
        XCTAssertTrue(containers.contains("mkv"))
        XCTAssertTrue(containers.contains("mp4"))
        // Both spellings of the aliased containers, or a server that recorded
        // the other one reads as unsupported.
        XCTAssertEqual(containers.contains("mkv"), containers.contains("matroska"))
        XCTAssertEqual(containers.contains("ts"), containers.contains("mpegts"))
        XCTAssertTrue(audio.contains("aac"))
        XCTAssertTrue(audio.contains("flac"))
    }

    func testHardwareCodecsAreASubsetOfClaimedCodecs() {
        let claimed = Set(AppleDecodeCapabilities.videoCodecs(includingMPEG2: true))
        XCTAssertTrue(Set(AppleDecodeCapabilities.hardwareVideoCodecs).isSubset(of: claimed))
        // MPEG-2 runs on PlayerCore's software decoder, never VideoToolbox.
        XCTAssertFalse(
            AppleDecodeCapabilities.hardwareVideoCodecs
                .contains(AppleDecodeCapabilities.mpeg2VideoCodec)
        )
    }

    func testMPEG2IsOptInAndNeverClaimedBare() {
        XCTAssertFalse(
            AppleDecodeCapabilities.videoCodecs
                .contains(AppleDecodeCapabilities.mpeg2VideoCodec)
        )
    }

    func testDecodeEntriesNameTheDecoderTheyActuallyUse() {
        for entry in ApplePlaybackV3Capabilities.snapshot().capabilities.videoDecode {
            XCTAssertEqual(
                entry.decoderName == "VideoToolbox",
                entry.hardware,
                "\(entry.codec) names a decoder its hardware flag contradicts"
            )
        }
    }

    // MARK: - Simulator claim

    func testSimulatorClaimStaysConservative() throws {
        try XCTSkipUnless(AppleDecodeCapabilities.isSimulator)
        XCTAssertEqual(AppleDecodeCapabilities.videoCodecs(includingMPEG2: true), ["h264"])
        XCTAssertEqual(AppleDecodeCapabilities.maxResolution, "1080p")
        XCTAssertFalse(DownloadCaps.current().hdr)
        XCTAssertEqual(DownloadCaps.current().audioPassthroughCodecs, [])
    }
}

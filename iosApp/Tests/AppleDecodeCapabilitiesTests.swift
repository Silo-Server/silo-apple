import XCTest
@testable import Silo

/// The client reports decode capability to the server through three doors —
/// the V3 capability snapshot, the playback bootstrap, and download creation.
/// They have to describe the same client. ALAC was once present in one list
/// and absent from the other two, which the server could only read as "this
/// device cannot play ALAC", silently, on two of the three paths.
final class AppleDecodeCapabilitiesTests: XCTestCase {

    func testHigh10SoftwareCapabilityUsesValidatedDeviceFloor() {
        XCTAssertTrue(ApplePlaybackV3Capabilities.validatedH264High10DeviceClass(
            isMac: false,
            hasUnifiedMemory: true,
            supportsApple9GPUFamily: true
        ))
        XCTAssertFalse(ApplePlaybackV3Capabilities.validatedH264High10DeviceClass(
            isMac: false,
            hasUnifiedMemory: true,
            supportsApple9GPUFamily: false
        ))
        XCTAssertTrue(ApplePlaybackV3Capabilities.validatedH264High10DeviceClass(
            isMac: true,
            hasUnifiedMemory: true,
            supportsApple9GPUFamily: false
        ))
        XCTAssertFalse(ApplePlaybackV3Capabilities.validatedH264High10DeviceClass(
            isMac: true,
            hasUnifiedMemory: false,
            supportsApple9GPUFamily: true
        ))
    }

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

    func testBareAudioContainersReachTheFlatAndOriginalHTTPClaims() throws {
        let expected = Set(["mp3", "m4a", "m4b", "aac", "flac", "wav"])
        XCTAssertEqual(Set(AppleDecodeCapabilities.audioContainers), expected)
        XCTAssertTrue(expected.isSubset(of: Set(AppleDecodeCapabilities.containers)))

        let originalHTTP = try XCTUnwrap(
            ApplePlaybackV3Capabilities.snapshot().context.deliveries[
                PlaybackProtocolV3.DeliveryClass.originalHTTP
            ]
        )
        XCTAssertTrue(expected.isSubset(of: Set(originalHTTP.containers)))
        XCTAssertFalse(originalHTTP.containers.contains("ogg"))
    }

    // MARK: - The vocabulary itself

    func testDeviceListsCoverTheFormatsTheStackDecodes() {
        // Asserted on the lists directly, since the test host is a simulator
        // and would otherwise only ever see the conservative claim.
        let audio = AppleDecodeCapabilities.audioCodecs
        let containers = AppleDecodeCapabilities.containers
        XCTAssertTrue(containers.contains("mkv"))
        XCTAssertTrue(containers.contains("mp4"))
        XCTAssertTrue(containers.contains("mp3"))
        XCTAssertTrue(containers.contains("flac"))
        XCTAssertTrue(containers.contains("wav"))
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

    func testHigh10SoftwareCapabilityIsExplicitlyBounded() {
        let entry = ApplePlaybackV3Capabilities.h264High10SoftwareDecodeCapability
        XCTAssertEqual(entry.codec, "h264")
        XCTAssertEqual(entry.decoderName, "FFmpeg")
        XCTAssertEqual(entry.profiles, ["high 10", "high 10 intra"])
        XCTAssertEqual(entry.levels, [
            9, 10, 11, 12, 13,
            20, 21, 22,
            30, 31, 32,
            40, 41, 42,
            50, 51
        ])
        XCTAssertTrue(entry.levels.contains(31))
        XCTAssertTrue(entry.levels.contains(41))
        XCTAssertTrue(entry.levels.contains(51))
        XCTAssertEqual(entry.bitDepths, [10])
        XCTAssertEqual(entry.maxWidth, 1_280)
        XCTAssertEqual(entry.maxHeight, 720)
        XCTAssertEqual(entry.maxFrameRate, 24)
        XCTAssertEqual(entry.maxBitrateKbps, 4_096)
        XCTAssertFalse(entry.hardware)
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

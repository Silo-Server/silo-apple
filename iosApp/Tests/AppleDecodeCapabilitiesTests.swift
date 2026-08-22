import XCTest
@testable import Silo

/// Playback and downloads must describe the same stack while retaining the
/// evidence each wire contract can safely understand.
final class AppleDecodeCapabilitiesTests: XCTestCase {

    // MARK: - The surfaces agree

    func testV3SnapshotReportsTheSharedVocabulary() {
        let capabilities = ApplePlaybackV3Capabilities.snapshot().capabilities
        XCTAssertEqual(capabilities.codecsAudio, AppleDecodeCapabilities.audioCodecs)
        XCTAssertEqual(capabilities.containers, AppleDecodeCapabilities.containers)
        XCTAssertEqual(capabilities.codecsVideo, AppleDecodeCapabilities.videoCodecs)
    }

    func testDownloadCapsReportTheSharedVocabulary() {
        let caps = DownloadCaps.current()
        XCTAssertEqual(caps.codecsAudio, AppleDecodeCapabilities.audioCodecs)
        XCTAssertEqual(caps.containers, AppleDecodeCapabilities.containers)
        XCTAssertEqual(caps.codecsVideo, AppleDecodeCapabilities.hardwareVideoCodecs)
        XCTAssertEqual(caps.maxResolution, "1080p")
        XCTAssertEqual(caps.videoEvidence, PlaybackProtocolV3.Evidence.platformAttested)
        XCTAssertEqual(
            caps.videoDecode,
            ApplePlaybackV3Capabilities.snapshot().capabilities.videoDecode
        )
        XCTAssertEqual(caps.clientFeatures, [PlaybackProtocolV3.softwareVideoDecodeFeature])
        XCTAssertTrue(
            Set(AppleDecodeCapabilities.softwareVideoCodecs).isDisjoint(
                with: Set(caps.codecsVideo)
            )
        )
    }

    func testDownloadSoftwareClaimsRetainTheirOwnBounds() {
        let software = Dictionary(
            uniqueKeysWithValues: DownloadCaps.current().videoDecode
                .filter { !$0.hardware }
                .map { ($0.codec, [$0.maxWidth, $0.maxHeight, Int($0.maxFrameRate), $0.maxBitrateKbps]) }
        )
        XCTAssertEqual(software["h264"], [1_920, 1_080, 30, 10_000])
        XCTAssertEqual(software["av1"], [1_920, 1_080, 30, 3_000])
        XCTAssertEqual(software["vp9"], [1_920, 1_080, 30, 3_000])
        XCTAssertEqual(software["mpeg2video"], [720, 480, 31, 7_000])
        XCTAssertEqual(software["vc1"], [1_920, 1_080, 30, 32_000])
    }

    func testSoftwareClaimsStayWithinTheExercisedProfilesAndBitDepths() {
        let software = Dictionary(
            uniqueKeysWithValues: DownloadCaps.current().videoDecode
                .filter { !$0.hardware }
                .map { ($0.codec, ($0.profiles, $0.bitDepths)) }
        )
        XCTAssertEqual(software["h264"]?.0, ["high 10"])
        XCTAssertEqual(software["h264"]?.1, [10])
        XCTAssertEqual(software["av1"]?.0, ["main"])
        XCTAssertEqual(software["av1"]?.1, [10])
        XCTAssertEqual(software["vp9"]?.0, ["profile 0"])
        XCTAssertEqual(software["vp9"]?.1, [8])
        XCTAssertEqual(software["mpeg2video"]?.0, ["main"])
        XCTAssertEqual(software["mpeg2video"]?.1, [8])
        XCTAssertEqual(software["vc1"]?.0, ["advanced"])
        XCTAssertEqual(software["vc1"]?.1, [8])
    }

    func testDownloadSoftwareEvidenceUsesTheServerWireKeys() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(DownloadCaps.current()))
                as? [String: Any]
        )
        XCTAssertEqual(
            object["client_features"] as? [String],
            [PlaybackProtocolV3.softwareVideoDecodeFeature]
        )
        XCTAssertEqual(
            object["video_evidence"] as? String,
            PlaybackProtocolV3.Evidence.platformAttested
        )
        XCTAssertNotNil(object["video_decode"] as? [[String: Any]])
        XCTAssertNil(object["clientFeatures"])
        XCTAssertNil(object["videoDecode"])
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
        let claimed = Set(AppleDecodeCapabilities.videoCodecs)
        XCTAssertTrue(Set(AppleDecodeCapabilities.hardwareVideoCodecs).isSubset(of: claimed))
    }

    func testDecodeEntriesNameTheDecoderTheyActuallyUse() {
        for entry in ApplePlaybackV3Capabilities.snapshot().capabilities.videoDecode {
            XCTAssertEqual(entry.hardware ? "VideoToolbox" : (entry.codec == "av1" ? "dav1d" : "libavcodec"), entry.decoderName)
        }
    }

    // MARK: - Simulator claim

    func testSimulatorClaimStaysConservative() throws {
        try XCTSkipUnless(AppleDecodeCapabilities.isSimulator)
        XCTAssertEqual(
            AppleDecodeCapabilities.videoCodecs,
            ["h264", "av1", "vp9", "mpeg2video", "vc1"]
        )
        XCTAssertEqual(AppleDecodeCapabilities.maxResolution, "1080p")
        XCTAssertFalse(DownloadCaps.current().hdr)
        XCTAssertEqual(DownloadCaps.current().audioPassthroughCodecs, [])
    }
}

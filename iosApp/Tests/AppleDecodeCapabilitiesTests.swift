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
        // Every remaining route is AVPlayer-backed, so the snapshot claims
        // exactly the shared list — no software-only MPEG-2 extra.
        XCTAssertEqual(capabilities.codecsVideo, AppleDecodeCapabilities.videoCodecs)
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
        let claimed = Set(AppleDecodeCapabilities.videoCodecs)
        XCTAssertTrue(Set(AppleDecodeCapabilities.hardwareVideoCodecs).isSubset(of: claimed))
    }

    /// The client no longer carries a software MPEG-2 decoder, so no surface
    /// may advertise it — the server must transcode those sources.
    func testMPEG2IsNeverClaimed() {
        XCTAssertFalse(AppleDecodeCapabilities.videoCodecs.contains("mpeg2video"))
        XCTAssertFalse(AppleDecodeCapabilities.hardwareVideoCodecs.contains("mpeg2video"))
        XCTAssertFalse(DownloadCaps.current().codecsVideo.contains("mpeg2video"))
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        XCTAssertFalse(snapshot.capabilities.codecsVideo.contains("mpeg2video"))
        XCTAssertFalse(snapshot.capabilities.videoDecode.map(\.codec).contains("mpeg2video"))
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
        XCTAssertEqual(AppleDecodeCapabilities.videoCodecs, ["h264"])
        XCTAssertEqual(AppleDecodeCapabilities.maxResolution, "1080p")
        XCTAssertFalse(DownloadCaps.current().hdr)
        XCTAssertEqual(DownloadCaps.current().audioPassthroughCodecs, [])
    }
}

import XCTest
@testable import Silo

/// Online playback may trust Aether's load-time probe; downloads must retain
/// enough bounded evidence to be safe without a server replan.
final class AppleDecodeCapabilitiesTests: XCTestCase {

    // MARK: - The surfaces agree

    func testV3SnapshotReportsTheSharedVocabulary() {
        let capabilities = ApplePlaybackV3Capabilities.snapshot().capabilities
        XCTAssertEqual(capabilities.codecsAudio, AppleDecodeCapabilities.streamingAudioCodecs)
        XCTAssertEqual(capabilities.containers, AppleDecodeCapabilities.streamingContainers)
        XCTAssertEqual(capabilities.codecsVideo, AppleDecodeCapabilities.streamingVideoCodecs)
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
            AppleDecodeCapabilities.playbackV3VideoDecodeAttestation()
        )
        XCTAssertEqual(caps.clientFeatures, [PlaybackProtocolV3.softwareVideoDecodeFeature])
        // Software-decoded codecs are never claimed as hardware video codecs.
        XCTAssertTrue(Set(["av1", "vp9", "mpeg2video", "vc1"]).isDisjoint(with: Set(caps.codecsVideo)))
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
        XCTAssertEqual(software["mpeg2video"], [1_920, 1_080, 31, 40_000])
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

    func testConservativeStreamingAndDownloadsShareAudioCodecs() {
        let v3 = Set(ApplePlaybackV3Capabilities.snapshot(
            videoCapabilityMode: .platformAttested
        ).capabilities.codecsAudio)
        let downloads = Set(DownloadCaps.current().codecsAudio)
        XCTAssertEqual(v3, downloads)
        XCTAssertEqual(v3, Set(AppleDecodeCapabilities.audioCodecs))
    }

    /// Apple TV HD sends the platform-attested entries. A Blu-ray MPEG-2
    /// remux (1080p23.976, about 36 Mbps of video) must fit its MPEG-2
    /// entry, or the server transcodes it (silo-apple#1124).
    func testPlatformAttestedMPEG2AdmitsBluRayRemux() throws {
        let entry = try XCTUnwrap(
            ApplePlaybackV3Capabilities.snapshot(videoCapabilityMode: .platformAttested)
                .capabilities.videoDecode.first { $0.codec == "mpeg2video" }
        )
        XCTAssertGreaterThanOrEqual(entry.maxWidth, 1_920)
        XCTAssertGreaterThanOrEqual(entry.maxHeight, 1_080)
        XCTAssertGreaterThanOrEqual(entry.maxFrameRate, 24_000.0 / 1_001.0)
        XCTAssertGreaterThanOrEqual(entry.maxBitrateKbps, 36_000)
    }

    func testBareAudioContainersReachTheFlatAndOriginalHTTPClaims() throws {
        let expected = Set(["mp3", "m4a", "m4b", "aac", "flac", "wav"])
        XCTAssertEqual(Set(AppleDecodeCapabilities.audioContainers), expected)
        XCTAssertTrue(expected.isSubset(of: Set(AppleDecodeCapabilities.containers)))

        let originalHTTP = try XCTUnwrap(
            ApplePlaybackV3Capabilities.snapshot(
                videoCapabilityMode: .platformAttested
            ).context.deliveries[
                PlaybackProtocolV3.DeliveryClass.originalHTTP
            ]
        )
        XCTAssertTrue(expected.isSubset(of: Set(originalHTTP.containers)))
        XCTAssertFalse(originalHTTP.containers.contains("ogg"))
    }

    func testOriginalFilePlaybackUsesTheAetherBuildDeclaration() throws {
        let snapshot = ApplePlaybackV3Capabilities.snapshot(
            videoCapabilityMode: .aetherDeclared
        )
        XCTAssertEqual(snapshot.capabilities.videoEvidence, PlaybackProtocolV3.Evidence.declared)
        XCTAssertEqual(
            snapshot.capabilities.videoDecode,
            AppleDecodeCapabilities.playbackV3VideoDecode(AppleDecodeCapabilities.declaredOnlineVideo.decode)
        )
        XCTAssertEqual(
            snapshot.capabilities.codecsVideoHardware,
            AppleDecodeCapabilities.hardwareVideoCodecs
        )
        XCTAssertEqual(
            snapshot.capabilities.codecsVideo,
            AppleDecodeCapabilities.declaredOnlineVideo.codecs
        )
        XCTAssertEqual(
            snapshot.capabilities.codecsAudio,
            AppleDecodeCapabilities.aetherOriginalHTTPAudioCodecs
        )
        XCTAssertEqual(
            snapshot.capabilities.containers,
            AppleDecodeCapabilities.aetherOriginalHTTPContainers
        )
        XCTAssertEqual(snapshot.capabilities.maxResolution, "2160p")

        let originalHTTP = try XCTUnwrap(
            snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP]
        )
        XCTAssertEqual(
            originalHTTP.videoCodecs,
            AppleDecodeCapabilities.declaredOnlineVideo.codecs
        )
        XCTAssertEqual(
            originalHTTP.audioDecodeCodecs,
            AppleDecodeCapabilities.aetherOriginalHTTPAudioCodecs
        )
        XCTAssertEqual(
            originalHTTP.containers,
            AppleDecodeCapabilities.aetherOriginalHTTPContainers
        )
        XCTAssertTrue(
            originalHTTP.validatedClaims.contains(
                PlaybackProtocolV3.clientManagedDynamicRangeClaim
            ),
            "The Aether original-file executor must declare that display adaptation happens after delivery."
        )
        XCTAssertTrue(
            originalHTTP.validatedClaims.contains(
                PlaybackProtocolV3.clientSelectedAudioTrackClaim
            ),
            "The Aether original-file executor maps the plan's selected audio ordinal to an exact stream before opening non-default audio."
        )

        let progressive = try XCTUnwrap(
            snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.progressive]
        )
        XCTAssertEqual(progressive.videoCodecs, AppleDecodeCapabilities.packagedVideoCodecs)
        XCTAssertEqual(progressive.containers, ["mp4", "mov", "m4v"])
        XCTAssertEqual(progressive.audioDecodeCodecs, ["aac", "ac3", "eac3", "alac", "mp3"])

        let hls = try XCTUnwrap(
            snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.hls]
        )
        XCTAssertEqual(hls.videoCodecs, AppleDecodeCapabilities.packagedVideoCodecs)
        XCTAssertEqual(hls.containers, ["hls", "mpegts", "fmp4", "mp4"])
        XCTAssertEqual(hls.audioDecodeCodecs, ["aac", "ac3", "eac3"])
    }

    func testConservativeAndAudioOnlySnapshotsDoNotClaimClientManagedDynamicRange() throws {
        let conservativeOriginal = try XCTUnwrap(
            ApplePlaybackV3Capabilities.snapshot(
                videoCapabilityMode: .platformAttested
            ).context.deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP]
        )
        XCTAssertFalse(
            conservativeOriginal.validatedClaims.contains(
                PlaybackProtocolV3.clientManagedDynamicRangeClaim
            )
        )
        XCTAssertFalse(
            conservativeOriginal.validatedClaims.contains(
                PlaybackProtocolV3.clientSelectedAudioTrackClaim
            )
        )

        let audiobookOriginal = try XCTUnwrap(
            ApplePlaybackV3Capabilities.audiobookSnapshot(
                videoCapabilityMode: .aetherDeclared
            ).context.deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP]
        )
        XCTAssertFalse(
            audiobookOriginal.validatedClaims.contains(
                PlaybackProtocolV3.clientManagedDynamicRangeClaim
            )
        )
        XCTAssertFalse(
            audiobookOriginal.validatedClaims.contains(
                PlaybackProtocolV3.clientSelectedAudioTrackClaim
            )
        )
    }

    /// iPhone and iPad claim software-only codecs within their measured
    /// envelopes; hardware AV1 stays unbounded and the simulator, which does
    /// not play AV1 direct, claims none.
    func testDeclaredOnlineVideoBoundsSoftwareOnlyCodecs() {
        func policy(tvOS: Bool = false, hardwareAV1: Bool, simulator: Bool) -> (codecs: Set<String>, bounded: [String: [Int]]) {
            let declared = AppleDecodeCapabilities.declaredOnlineVideo(
                isTVOS: tvOS, hardwareAV1: hardwareAV1, isSimulator: simulator
            )
            XCTAssertTrue(declared.decode.allSatisfy { !$0.hardware })
            return (Set(declared.codecs), Dictionary(uniqueKeysWithValues: declared.decode.map {
                ($0.codec, [$0.bitDepths.first ?? 0, $0.maxWidth, $0.maxHeight, Int($0.maxFrameRate), $0.maxBitrateKbps])
            }))
        }
        let mpeg2 = [8, 1_920, 1_080, 31, 40_000]
        let dav1d = [10, 1_920, 1_080, 30, 3_000]

        let hardware = policy(hardwareAV1: true, simulator: false)
        XCTAssertTrue(hardware.codecs.contains("av1"))
        XCTAssertEqual(hardware.bounded, ["mpeg2video": mpeg2])

        let software = policy(hardwareAV1: false, simulator: false)
        XCTAssertTrue(software.codecs.contains("av1"))
        XCTAssertEqual(software.bounded, ["mpeg2video": mpeg2, "av1": dav1d])

        let simulator = policy(hardwareAV1: false, simulator: true)
        XCTAssertFalse(simulator.codecs.contains("av1"))
        XCTAssertTrue(simulator.codecs.contains("mpeg2video"))
        XCTAssertEqual(simulator.bounded, ["mpeg2video": mpeg2])

        let appleTV = policy(tvOS: true, hardwareAV1: false, simulator: false)
        XCTAssertEqual(appleTV.codecs, Set(AppleDecodeCapabilities.aetherOriginalHTTPVideoCodecs))
        XCTAssertEqual(appleTV.bounded, [:])

        for declared in [hardware, software, simulator] {
            XCTAssertEqual(
                declared.codecs.union(["av1"]), Set(AppleDecodeCapabilities.aetherOriginalHTTPVideoCodecs),
                "only AV1 ever leaves the engine's list"
            )
        }
    }

    func testAetherDeclarationKeepsV3WireShape() throws {
        let capabilities = ApplePlaybackV3Capabilities.snapshot(
            videoCapabilityMode: .aetherDeclared
        ).capabilities
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(capabilities))
                as? [String: Any]
        )

        XCTAssertEqual(
            object["video_evidence"] as? String,
            PlaybackProtocolV3.Evidence.declared
        )
        let decode = try XCTUnwrap(object["video_decode"] as? [[String: Any]])
        #if os(tvOS)
        XCTAssertTrue(decode.isEmpty, "Apple TV 4K keeps the unbounded declaration")
        #else
        XCTAssertTrue(decode.contains { $0["codec"] as? String == "mpeg2video" && $0["max_height"] as? Int == 1_080 })
        #endif
        XCTAssertEqual(
            object["codecs_video"] as? [String],
            AppleDecodeCapabilities.declaredOnlineVideo.codecs
        )
        XCTAssertNil(object["videoEvidence"])
        XCTAssertNil(object["videoDecode"])
    }

    func testEngineDeclarationCoversPinnedAetherFFmpegManifest() {
        let video = Set(AppleDecodeCapabilities.aetherOriginalHTTPVideoCodecs)
        let audio = Set(AppleDecodeCapabilities.aetherOriginalHTTPAudioCodecs)
        let containers = Set(AppleDecodeCapabilities.aetherOriginalHTTPContainers)

        XCTAssertEqual(video, Set([
            "h264", "hevc", "av1", "vp9", "vp8", "mpeg4", "mpeg2video", "vc1",
            "qtrle", "msmpeg4v1", "msmpeg4v2", "msmpeg4v3", "wmv1", "wmv2", "wmv3",
        ]))
        XCTAssertEqual(audio, Set([
            "aac", "ac3", "eac3", "mp3", "mp2", "flac", "opus", "vorbis", "alac",
            "truehd", "mlp", "dts", "dca", "dts-hd", "dtshd", "pcm", "pcm_s16le",
            "pcm_s24le", "pcm_f32le", "pcm_bluray",
        ]))
        XCTAssertEqual(containers, Set([
            "mp4", "m4v", "mov", "mkv", "matroska", "avi", "mpegts", "ts", "m2ts",
            "mts", "3gp", "3g2", "mpeg", "vob", "ogg", "webm", "flv", "mp3", "aac",
            "m4a", "m4b", "flac", "alac", "wav", "opus",
        ]))
        XCTAssertFalse(containers.contains("asf"))
        // The scanner normalizes MPEG program streams (`.mpg`/`.vob`) to
        // `mpeg`; without that token DVD-class sources could never take
        // `original_http` despite the mpeg2video claim above.
        XCTAssertTrue(containers.contains("mpeg"))
    }

    func testPersistentDownloadsDoNotInheritOptimisticEngineClaims() {
        let caps = DownloadCaps.current()
        XCTAssertFalse(caps.codecsVideo.contains("qtrle"))
        XCTAssertFalse(caps.codecsAudio.contains("mlp"))
        XCTAssertFalse(caps.containers.contains("flv"))
        XCTAssertFalse(caps.videoDecode.isEmpty)
    }

    func testStreamingPolicyUsesAetherForPhysicalIOSAndAppleTV4K() {
        func mode(
            _ isTVOS: Bool,
            _ machineIdentifier: String
        ) -> AppleDecodeCapabilities.StreamingVideoCapabilityMode {
            AppleDecodeCapabilities.streamingVideoCapabilityModeForDevice(
                isTVOS: isTVOS,
                machineIdentifier: machineIdentifier
            )
        }
        XCTAssertEqual(mode(true, "AppleTV5,3"), .platformAttested)
        XCTAssertEqual(mode(true, "AppleTV6,2"), .aetherDeclared)
        XCTAssertEqual(mode(true, "AppleTV11,1"), .aetherDeclared)
        XCTAssertEqual(mode(true, "AppleTV14,1"), .aetherDeclared)
        XCTAssertEqual(mode(true, "AppleTV99,1"), .aetherDeclared)
        XCTAssertEqual(mode(false, "iPhone19,1"), .aetherDeclared)
        XCTAssertEqual(mode(false, "iPhone11,2"), .aetherDeclared)
        XCTAssertEqual(mode(false, "iPad16,3"), .aetherDeclared)
        XCTAssertEqual(mode(false, "Mac16,1"), .platformAttested)
        XCTAssertEqual(mode(false, "arm64"), .platformAttested)
        XCTAssertEqual(mode(false, "unknown"), .platformAttested)
        XCTAssertEqual(mode(true, "unknown"), .platformAttested)
    }

    func testPhysicalIOSAdvertisesOriginalFileAudioSelectionAndHDRHandling() throws {
        for device in ["iPhone19,1", "iPad16,3"] {
            let mode = AppleDecodeCapabilities.streamingVideoCapabilityModeForDevice(
                isTVOS: false, machineIdentifier: device
            )
            let snapshot = ApplePlaybackV3Capabilities.snapshot(videoCapabilityMode: mode)
            let original = try XCTUnwrap(snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP])
            XCTAssertTrue(original.validatedClaims.contains(PlaybackProtocolV3.clientSelectedAudioTrackClaim), device)
            XCTAssertTrue(original.validatedClaims.contains(PlaybackProtocolV3.clientManagedDynamicRangeClaim), device)
            XCTAssertTrue(original.containers.contains("mkv"))
            XCTAssertTrue(original.videoCodecs.contains("hevc"))
            XCTAssertTrue(original.audioDecodeCodecs.contains("eac3"))
            XCTAssertTrue(original.audioDecodeCodecs.contains("truehd"))
            XCTAssertEqual(snapshot.capabilities.videoEvidence, PlaybackProtocolV3.Evidence.declared)
            XCTAssertTrue(snapshot.capabilities.videoDecode.allSatisfy { !$0.hardware }, "only software envelopes bound the declaration")

            for delivery in [PlaybackProtocolV3.DeliveryClass.progressive, PlaybackProtocolV3.DeliveryClass.hls] {
                let packaged = try XCTUnwrap(snapshot.context.deliveries[delivery])
                XCTAssertFalse(packaged.validatedClaims.contains(PlaybackProtocolV3.clientSelectedAudioTrackClaim))
                XCTAssertFalse(packaged.validatedClaims.contains(PlaybackProtocolV3.clientManagedDynamicRangeClaim))
            }
        }
    }

    func testAppleSiliconMacManagesOriginalDynamicRangeOnlyWhileHDRIsOn() {
        // A Mac's `uname` reports its architecture, not a model.
        let manages = ApplePlaybackV3Capabilities.macManagesOriginalDynamicRange
        XCTAssertTrue(manages("arm64", true))
        XCTAssertFalse(manages("arm64", false))
        XCTAssertFalse(manages("x86_64", true))
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
        let hardware = Set(AppleDecodeCapabilities.hardwareVideoCodecs)
        XCTAssertTrue(hardware.isSubset(of: Set(AppleDecodeCapabilities.attestedVideoCodecs)))
        XCTAssertTrue(hardware.isSubset(of: Set(AppleDecodeCapabilities.aetherOriginalHTTPVideoCodecs)))
    }

    func testDecodeEntriesNameTheDecoderTheyActuallyUse() {
        for entry in AppleDecodeCapabilities.videoDecodeAttestation() {
            XCTAssertEqual(entry.hardware ? "VideoToolbox" : (entry.codec == "av1" ? "dav1d" : "libavcodec"), entry.decoderName)
        }
    }
}

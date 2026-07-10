import CoreVideo
import XCTest
@testable import Silo

final class HDRDisplayCriteriaPolicyTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "HDRDisplayCriteriaPolicyTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Gate

    func testGateIsOnWhenKeyAbsent() {
        XCTAssertTrue(HDRDisplayCriteriaPolicy.isEnabled(defaults: defaults))
    }

    func testGateIsOffWhenExplicitlyFalse() {
        defaults.set(false, forKey: HDRDisplayCriteriaPolicy.gateKey)
        XCTAssertFalse(HDRDisplayCriteriaPolicy.isEnabled(defaults: defaults))
    }

    func testGateIsOnWhenTrue() {
        defaults.set(true, forKey: HDRDisplayCriteriaPolicy.gateKey)
        XCTAssertTrue(HDRDisplayCriteriaPolicy.isEnabled(defaults: defaults))
    }

    // MARK: - Selection

    func testDolbyVisionModesPreserveBaseLayerRegardlessOfGate() {
        let modes: [(LoopbackSessionSpec.VideoMode, HDRDisplayCriteriaPolicy.CriteriaSelection)] = [
            (.passthroughProfile5, .dolbyVision(.hdr10)),
            (.convertProfile7To81, .dolbyVision(.hdr10)),
            (.passthroughProfile8(.hdr10), .dolbyVision(.hdr10)),
            (.passthroughProfile8(.sdr), .dolbyVision(.sdr)),
            (.passthroughProfile8(.hlg), .dolbyVision(.hlg)),
        ]
        for (mode, expected) in modes {
            for gate in [false, true] {
                XCTAssertEqual(
                    HDRDisplayCriteriaPolicy.selection(
                        videoMode: mode,
                        manifestVideoRange: "PQ",
                        hdrGateEnabled: gate
                    ),
                    expected,
                    "\(mode) gate=\(gate)"
                )
            }
        }
    }

    /// The two sides that decide a Profile 8 base layer — the parsed
    /// configuration record after decode, and server metadata before it —
    /// must name the same one, including Profile 8.2's SDR base. Requesting a
    /// PQ HDMI mode for an SDR base layer is the failure this pins against.
    func testProfile8BaseLayerAgreesAcrossBothDecisionPaths() {
        let byCompatibilityID: [(Int?, LoopbackSessionSpec.DVProfile8BaseLayer)] = [
            (nil, .hdr10),   // no record parsed
            (0, .hdr10),     // no cross-compatibility signalled
            (1, .hdr10),     // 8.1
            (2, .sdr),       // 8.2
            (4, .hlg),       // 8.4
        ]
        for (compatibilityID, expected) in byCompatibilityID {
            XCTAssertEqual(
                LoopbackSessionSpec.DVProfile8BaseLayer(dolbyVisionCompatibilityID: compatibilityID),
                expected,
                "compatibilityID=\(String(describing: compatibilityID))"
            )
        }

        let byTransfer: [(String?, LoopbackSessionSpec.DVProfile8BaseLayer)] = [
            ("smpte2084", .hdr10),
            ("bt709", .sdr),
            ("arib-std-b67", .hlg),
            (nil, .hdr10),
        ]
        for (transfer, expected) in byTransfer {
            XCTAssertEqual(
                ApplePlaybackRoutePlanner.dvProfile8BaseLayer(
                    for: hevcVersion(colorTransfer: transfer, videoRange: "DolbyVision"),
                    sourceMetadata: .unknown
                ),
                expected,
                "colorTransfer=\(String(describing: transfer))"
            )
        }
    }

    /// The base layer decides two things that have to agree: the HDMI mode
    /// tvOS asks the panel for, and the colorimetry the decoder's format
    /// description declares. Both read this one mapping, so a Profile 8.2
    /// stream cannot be handed PQ frames while the panel is asked for SDR.
    func testBaseLayerColorimetryDescribesTheBaseLayer() {
        let expected: [(LoopbackSessionSpec.DVProfile8BaseLayer, CFString, CFString)] = [
            (.hdr10, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVImageBufferColorPrimaries_ITU_R_2020),
            (.hlg, kCVImageBufferTransferFunction_ITU_R_2100_HLG, kCVImageBufferColorPrimaries_ITU_R_2020),
            (.sdr, kCVImageBufferTransferFunction_ITU_R_709_2, kCVImageBufferColorPrimaries_ITU_R_709_2),
        ]
        for (baseLayer, transfer, primaries) in expected {
            let colorimetry = VideoColorMetadata.dolbyVisionBaseLayerColorimetry(baseLayer)
            XCTAssertEqual(colorimetry.transfer as String, transfer as String, "\(baseLayer)")
            XCTAssertEqual(colorimetry.primaries as String, primaries as String, "\(baseLayer)")
        }

        // The specific regression: an SDR base layer declared as PQ.
        let sdr = VideoColorMetadata.dolbyVisionBaseLayerColorimetry(.sdr)
        XCTAssertNotEqual(
            sdr.transfer as String,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        )
        XCTAssertEqual(sdr.matrix as String, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    func testHEVCSelectsHDRRangeWhenGateOn() {
        XCTAssertEqual(
            HDRDisplayCriteriaPolicy.selection(
                videoMode: .passthroughHEVC,
                manifestVideoRange: "PQ",
                hdrGateEnabled: true
            ),
            .hdr10
        )
        XCTAssertEqual(
            HDRDisplayCriteriaPolicy.selection(
                videoMode: .passthroughHEVC,
                manifestVideoRange: "HLG",
                hdrGateEnabled: true
            ),
            .hlg
        )
    }

    func testHEVCSelectsNoneWhenGateOff() {
        for range in ["PQ", "HLG"] {
            XCTAssertEqual(
                HDRDisplayCriteriaPolicy.selection(
                    videoMode: .passthroughHEVC,
                    manifestVideoRange: range,
                    hdrGateEnabled: false
                ),
                .none,
                "range=\(range)"
            )
        }
    }

    func testHEVCSDRAndUnknownRangesSelectNoneEvenWhenGateOn() {
        for range in ["SDR", "", "pq", "HDR10"] {
            XCTAssertEqual(
                HDRDisplayCriteriaPolicy.selection(
                    videoMode: .passthroughHEVC,
                    manifestVideoRange: range,
                    hdrGateEnabled: true
                ),
                .none,
                "range=\(range)"
            )
        }
    }

    func testH264SelectsNoneInBothGateStates() {
        for gate in [false, true] {
            XCTAssertEqual(
                HDRDisplayCriteriaPolicy.selection(
                    videoMode: .passthroughH264,
                    manifestVideoRange: "PQ",
                    hdrGateEnabled: gate
                ),
                .none,
                "gate=\(gate)"
            )
        }
    }

    // MARK: - Token producer + policy composition

    private func hevcVersion(colorTransfer: String?, videoRange: String?) -> FileVersion {
        FileVersion(
            fileId: 1,
            fileName: "movie.mkv",
            resolution: "2160p",
            codecVideo: "hevc",
            codecAudio: nil,
            hdr: nil,
            container: "mkv",
            fileSize: nil,
            duration: nil,
            bitrate: nil,
            videoTracks: [
                VideoTrack(
                    index: 0, codec: "hevc", width: 3840, height: 2160,
                    frameRate: "23.976", bitrate: nil, profile: nil,
                    level: nil, bitDepth: nil, colorRange: nil, colorSpace: nil,
                    colorPrimaries: nil, colorTransfer: colorTransfer,
                    videoRange: videoRange, videoRangeType: nil,
                    dolbyVision: nil, dvProfile: nil, title: nil,
                    language: nil
                )
            ],
            audioTracks: nil,
            subtitleTracks: nil,
            chapters: nil
        )
    }

    func testMetadataPoorHEVCComposesToNoCriteriaEvenWhenGateOn() {
        // Drive the REAL token producer into the policy: HEVC whose track
        // carries no recognizable transfer signaling must resolve to a token
        // the policy maps to .none — never a default that would force an
        // HDR10 HDMI mode switch for possibly-SDR content.
        let metadataPoor = [
            hevcVersion(colorTransfer: nil, videoRange: nil),
            hevcVersion(colorTransfer: "unknown", videoRange: "mystery"),
        ]
        for version in metadataPoor {
            let token = ApplePlaybackRoutePlanner.hevcLoopbackVideoRange(for: version)
            XCTAssertEqual(
                HDRDisplayCriteriaPolicy.selection(
                    videoMode: .passthroughHEVC,
                    manifestVideoRange: token,
                    hdrGateEnabled: true
                ),
                .none,
                "token=\(token)"
            )
        }
    }

    func testTaggedHEVCComposesToHDRSelectionWhenGateOn() {
        let pqToken = ApplePlaybackRoutePlanner.hevcLoopbackVideoRange(
            for: hevcVersion(colorTransfer: "smpte2084", videoRange: nil)
        )
        XCTAssertEqual(
            HDRDisplayCriteriaPolicy.selection(
                videoMode: .passthroughHEVC,
                manifestVideoRange: pqToken,
                hdrGateEnabled: true
            ),
            .hdr10
        )
        let hlgToken = ApplePlaybackRoutePlanner.hevcLoopbackVideoRange(
            for: hevcVersion(colorTransfer: "arib-std-b67", videoRange: nil)
        )
        XCTAssertEqual(
            HDRDisplayCriteriaPolicy.selection(
                videoMode: .passthroughHEVC,
                manifestVideoRange: hlgToken,
                hdrGateEnabled: true
            ),
            .hlg
        )
    }

    // MARK: - Settle-poll constants

    func testSettlePollConstantsArePinned() {
        XCTAssertEqual(HDRDisplayCriteriaPolicy.switchStartPollAttempts, 100)
        XCTAssertEqual(HDRDisplayCriteriaPolicy.switchStartPollIntervalMs, 10)
        XCTAssertEqual(HDRDisplayCriteriaPolicy.switchSettlePollAttempts, 50)
        XCTAssertEqual(HDRDisplayCriteriaPolicy.switchSettlePollIntervalMs, 100)
        XCTAssertEqual(HDRDisplayCriteriaPolicy.hdrHeadroomFloor, 1.001)
    }

    // MARK: - Preserve across reload

    func testPreservesCriteriaForSameSelectionAndRate() {
        for selection: HDRDisplayCriteriaPolicy.CriteriaSelection in [.dolbyVision(.hdr10), .dolbyVision(.hlg), .hdr10, .hlg] {
            XCTAssertTrue(
                HDRDisplayCriteriaPolicy.shouldPreserveCriteriaAcrossReload(
                    current: selection,
                    next: selection,
                    currentRate: 23.976,
                    nextRate: 23.976
                ),
                "\(selection)"
            )
        }
    }

    func testDoesNotPreserveAcrossSelectionOrRateChanges() {
        XCTAssertFalse(
            HDRDisplayCriteriaPolicy.shouldPreserveCriteriaAcrossReload(
                current: .hdr10, next: .hlg,
                currentRate: 23.976, nextRate: 23.976
            )
        )
        XCTAssertFalse(
            HDRDisplayCriteriaPolicy.shouldPreserveCriteriaAcrossReload(
                current: .none, next: .none,
                currentRate: 24.0, nextRate: 24.0
            )
        )
        XCTAssertFalse(
            HDRDisplayCriteriaPolicy.shouldPreserveCriteriaAcrossReload(
                current: .dolbyVision(.hdr10), next: .dolbyVision(.hdr10),
                currentRate: 23.976, nextRate: 25.0
            )
        )
        XCTAssertFalse(
            HDRDisplayCriteriaPolicy.shouldPreserveCriteriaAcrossReload(
                current: .dolbyVision(.hdr10), next: .dolbyVision(.hlg),
                currentRate: 23.976, nextRate: 23.976
            )
        )
    }

    // MARK: - EDR (iOS + macOS hosts)

    func testEDRNeedsBothAnHDRStreamAndScreenHeadroom() {
        // `publishSigPeakIfNeeded` emits 1.1 for HDR with the user setting on.
        XCTAssertTrue(HDRDisplayCriteriaPolicy.shouldEnableEDR(sigPeak: 1.1, screenHeadroom: 4.0))
        // HDR stream, SDR display — e.g. the window dragged onto one.
        XCTAssertFalse(HDRDisplayCriteriaPolicy.shouldEnableEDR(sigPeak: 1.1, screenHeadroom: 1.0))
        // SDR stream on an HDR-capable display.
        XCTAssertFalse(HDRDisplayCriteriaPolicy.shouldEnableEDR(sigPeak: 0.0, screenHeadroom: 4.0))
    }

    func testEDRHeadroomUsesTheSharedFloorNotBareOne() {
        // An SDR panel reporting just over 1.0 through float noise must not
        // read as HDR — the same floor the tvOS settle path judges by.
        XCTAssertFalse(
            HDRDisplayCriteriaPolicy.shouldEnableEDR(sigPeak: 1.1, screenHeadroom: 1.0005)
        )
        XCTAssertTrue(
            HDRDisplayCriteriaPolicy.shouldEnableEDR(
                sigPeak: 1.1,
                screenHeadroom: HDRDisplayCriteriaPolicy.hdrHeadroomFloor + 0.001
            )
        )
    }
}

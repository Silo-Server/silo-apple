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

    func testGateIsOffWhenKeyAbsent() {
        XCTAssertFalse(HDRDisplayCriteriaPolicy.isEnabled(defaults: defaults))
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

    func testDolbyVisionModesSelectDolbyVisionRegardlessOfGate() {
        let modes: [LoopbackSessionSpec.VideoMode] = [
            .passthroughProfile5,
            .convertProfile7To81,
            .passthroughProfile8(.hdr10),
            .passthroughProfile8(.hlg),
        ]
        for mode in modes {
            for gate in [false, true] {
                XCTAssertEqual(
                    HDRDisplayCriteriaPolicy.selection(
                        videoMode: mode,
                        manifestVideoRange: "PQ",
                        hdrGateEnabled: gate
                    ),
                    .dolbyVision,
                    "\(mode) gate=\(gate)"
                )
            }
        }
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
        for selection: HDRDisplayCriteriaPolicy.CriteriaSelection in [.dolbyVision, .hdr10, .hlg] {
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
                current: .dolbyVision, next: .dolbyVision,
                currentRate: 23.976, nextRate: 25.0
            )
        )
    }
}

import XCTest
@testable import Silo

/// The audiobook full player labels its speed menu, chip and VoiceOver value
/// with `AudioFullPlayerView.rateLabel`, so each label must name the rate the
/// engine actually applies.
@MainActor
final class AudioRateLabelTests: XCTestCase {
    func testLabelsEveryAvailableRateWithUpToTwoDecimals() {
        let labels = AudioPlayerViewModel.availableRates.map(AudioFullPlayerView.rateLabel)

        XCTAssertEqual(labels, ["0.75×", "1×", "1.25×", "1.5×", "1.75×", "2×", "2.5×", "3×"])
    }

    func testCapsOffLadderRatesAtTwoDecimals() {
        XCTAssertEqual(AudioFullPlayerView.rateLabel(1.333), "1.33×")
    }

    func testLabelsLowerClampBound() {
        XCTAssertEqual(AudioFullPlayerView.rateLabel(0.5), "0.5×")
    }
}

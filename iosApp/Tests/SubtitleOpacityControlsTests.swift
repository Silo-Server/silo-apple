import XCTest

@testable import Silo

/// The stepped opacity pickers on tvOS (player HUD and Settings) build their
/// options from ``SubtitleAppearance/opacityPickerValues(current:lowest:step:)``;
/// iOS and macOS type the value into ``PercentField``.
final class SubtitleOpacityControlsTests: XCTestCase {

    /// The HUD's text opacity picker: fully opaque must stay selectable after
    /// a change, and an invisible 1% must not be offered.
    func testTextOpacityStepsEndAtOneHundredAndStartVisible() {
        XCTAssertEqual(
            SubtitleAppearance.opacityPickerValues(current: 100, lowest: 25, step: 25),
            [25, 50, 75, 100]
        )
        XCTAssertEqual(
            SubtitleAppearance.opacityPickerValues(current: 50, lowest: 25, step: 25),
            [25, 50, 75, 100]
        )
    }

    func testBackgroundOpacityStepsStartAtOff() {
        XCTAssertEqual(
            SubtitleAppearance.opacityPickerValues(current: 75, lowest: 0, step: 25),
            [0, 25, 50, 75, 100]
        )
    }

    /// A value another client stored between the steps is offered in order,
    /// so the picker can select it rather than overwrite it.
    func testAnOffStepCurrentValueIsKeptInOrder() {
        XCTAssertEqual(
            SubtitleAppearance.opacityPickerValues(current: 42, lowest: 25, step: 25),
            [25, 42, 50, 75, 100]
        )
        XCTAssertEqual(
            SubtitleAppearance.opacityPickerValues(current: 3, lowest: 25, step: 25),
            [3, 25, 50, 75, 100]
        )
        XCTAssertEqual(
            SubtitleAppearance.opacityPickerValues(current: 42, lowest: 5, step: 5).filter { $0 >= 40 && $0 <= 45 },
            [40, 42, 45]
        )
    }

    /// macOS has no number pad, so a typed "%" or stray space must not throw
    /// the edit away.
    func testPercentFieldAcceptsATrailingPercentSignAndWhitespace() {
        XCTAssertEqual(PercentField.parse("42"), 42)
        XCTAssertEqual(PercentField.parse(" 42% "), 42)
        XCTAssertEqual(PercentField.parse("42 %"), 42)
        XCTAssertNil(PercentField.parse("%"))
        XCTAssertNil(PercentField.parse("forty"))
    }
}

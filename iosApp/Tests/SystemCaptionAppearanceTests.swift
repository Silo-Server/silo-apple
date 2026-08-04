import MediaAccessibility
import XCTest

@testable import Silo

/// Mapping tests for the Media Accessibility → SubtitleAppearance bridge.
/// The snapshot struct is exercised directly so tests never depend on the
/// process-wide caption preferences.
final class SystemCaptionAppearanceTests: XCTestCase {

    func testEmptySnapshotKeepsSiloDefaults() {
        let mapped = SystemCaptionAppearance.appearance(from: .init())
        XCTAssertEqual(mapped, SubtitleAppearance.default.sanitized())
    }

    func testBackgroundOpacityMapsToBox() {
        var snapshot = SystemCaptionAppearance.Snapshot()
        snapshot.backgroundOpacity = 0.5
        snapshot.backgroundColorHex = "#123456"

        let mapped = SystemCaptionAppearance.appearance(from: snapshot)
        XCTAssertEqual(mapped.backgroundStyle, .box)
        XCTAssertEqual(mapped.backgroundOpacity, 50)
        XCTAssertEqual(mapped.backgroundColor, "#123456")
    }

    func testZeroBackgroundOpacityRemovesBackground() {
        var snapshot = SystemCaptionAppearance.Snapshot()
        snapshot.backgroundOpacity = 0

        let mapped = SystemCaptionAppearance.appearance(from: snapshot)
        XCTAssertEqual(mapped.backgroundStyle, SubtitleBackgroundStylePreset.none)
    }

    func testUniformEdgeMapsToTextOutline() {
        var snapshot = SystemCaptionAppearance.Snapshot()
        snapshot.edgeStyle = .uniform

        let mapped = SystemCaptionAppearance.appearance(from: snapshot)
        XCTAssertTrue(mapped.textOutline)
    }

    func testDropShadowEdgeMapsToShadowWhenNoBackground() {
        var snapshot = SystemCaptionAppearance.Snapshot()
        snapshot.backgroundOpacity = 0
        snapshot.edgeStyle = .dropShadow

        let mapped = SystemCaptionAppearance.appearance(from: snapshot)
        XCTAssertEqual(mapped.backgroundStyle, .shadow)
        XCTAssertFalse(mapped.textOutline)
    }

    func testDropShadowEdgeYieldsToBoxBackground() {
        // Our model has one backgroundStyle slot; an opaque background
        // wins over the drop-shadow edge.
        var snapshot = SystemCaptionAppearance.Snapshot()
        snapshot.backgroundOpacity = 0.8
        snapshot.edgeStyle = .dropShadow

        let mapped = SystemCaptionAppearance.appearance(from: snapshot)
        XCTAssertEqual(mapped.backgroundStyle, .box)
        XCTAssertEqual(mapped.backgroundOpacity, 80)
    }

    func testForegroundColorMaps() {
        var snapshot = SystemCaptionAppearance.Snapshot()
        snapshot.foregroundColorHex = "#facc15"

        let mapped = SystemCaptionAppearance.appearance(from: snapshot)
        XCTAssertEqual(mapped.fontColor, "#facc15")
    }

    func testRelativeSizeAnchorsDefaultAtSiloDefaultPreset() {
        XCTAssertEqual(SystemCaptionAppearance.fontSizePreset(forRelativeSize: 1.0), .large)
        XCTAssertEqual(SystemCaptionAppearance.fontSizePreset(forRelativeSize: 0.5), .small)
        XCTAssertEqual(SystemCaptionAppearance.fontSizePreset(forRelativeSize: 0.8), .medium)
        XCTAssertEqual(SystemCaptionAppearance.fontSizePreset(forRelativeSize: 1.5), .xlarge)
        XCTAssertEqual(SystemCaptionAppearance.fontSizePreset(forRelativeSize: 2.0), .xxlarge)
    }

    func testHexStringFromCGColor() {
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(SystemCaptionAppearance.hexString(from: red), "#ff0000")

        let gray = CGColor(gray: 0.5, alpha: 1)
        // Grayscale converts through sRGB; channels must match each other.
        if let hex = SystemCaptionAppearance.hexString(from: gray) {
            let body = hex.dropFirst()
            XCTAssertEqual(body.prefix(2), body.dropFirst(2).prefix(2))
        } else {
            XCTFail("grayscale conversion failed")
        }
    }

    func testContentFallbackBehaviorStillUsesSystemValueWhenMatchingDeviceSettings() {
        XCTAssertEqual(
            SystemCaptionAppearance.valueForMatchingDeviceSettings(
                MACaptionAppearanceTextEdgeStyle.uniform,
                behavior: .useContentIfAvailable
            ),
            .uniform
        )
    }
}

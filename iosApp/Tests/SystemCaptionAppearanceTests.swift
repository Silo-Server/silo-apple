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

    func testWindowOpacityMapsToBox() {
        var snapshot = SystemCaptionAppearance.Snapshot()
        snapshot.windowOpacity = 0.5
        snapshot.windowColorHex = "#ff00ff"
        snapshot.windowCornerRadius = 8

        let mapped = SystemCaptionAppearance.appearance(from: snapshot)
        XCTAssertEqual(mapped.captionWindowOpacity, 50)
        XCTAssertEqual(mapped.captionWindowColor, "#ff00ff")
        XCTAssertEqual(mapped.captionWindowCornerRadius, 8)
    }

    func testWindowAndGlyphBackgroundRemainIndependent() {
        var snapshot = SystemCaptionAppearance.Snapshot()
        snapshot.backgroundOpacity = 0.8
        snapshot.backgroundColorHex = "#000000"
        snapshot.windowOpacity = 0.5
        snapshot.windowColorHex = "#ff00ff"

        let mapped = SystemCaptionAppearance.appearance(from: snapshot)
        XCTAssertEqual(mapped.backgroundOpacity, 80)
        XCTAssertEqual(mapped.backgroundColor, "#000000")
        XCTAssertEqual(mapped.captionWindowOpacity, 50)
        XCTAssertEqual(mapped.captionWindowColor, "#ff00ff")
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
        XCTAssertEqual(mapped.backgroundStyle, SubtitleBackgroundStylePreset.none)
        XCTAssertFalse(mapped.textOutline)
        XCTAssertEqual(mapped.systemTextEdgeStyle, .dropShadow)
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
        XCTAssertEqual(mapped.systemTextEdgeStyle, .dropShadow)
    }

    func testForegroundColorMaps() {
        var snapshot = SystemCaptionAppearance.Snapshot()
        snapshot.foregroundColorHex = "#facc15"

        let mapped = SystemCaptionAppearance.appearance(from: snapshot)
        XCTAssertEqual(mapped.fontColor, "#facc15")
    }

    func testForegroundOpacityMapsWithoutChangingColor() {
        var snapshot = SystemCaptionAppearance.Snapshot()
        snapshot.foregroundOpacity = 0.4

        let mapped = SystemCaptionAppearance.appearance(from: snapshot)
        XCTAssertEqual(mapped.fontOpacity, 40)
    }

    func testRelativeSizePreservesExactSystemScale() {
        var snapshot = SystemCaptionAppearance.Snapshot()
        snapshot.relativeCharacterSize = 1.75

        let mapped = SystemCaptionAppearance.appearance(from: snapshot)
        XCTAssertEqual(mapped.systemRelativeFontScale, 1.75)
    }

    func testRaisedAndDepressedEdgesStayDistinct() {
        var raised = SystemCaptionAppearance.Snapshot()
        raised.edgeStyle = .raised
        var depressed = SystemCaptionAppearance.Snapshot()
        depressed.edgeStyle = .depressed

        XCTAssertEqual(
            SystemCaptionAppearance.appearance(from: raised).systemTextEdgeStyle,
            .raised
        )
        XCTAssertEqual(
            SystemCaptionAppearance.appearance(from: depressed).systemTextEdgeStyle,
            .depressed
        )
    }

    func testVideoOverridePrecedenceSurvivesMapping() {
        var snapshot = SystemCaptionAppearance.Snapshot()
        snapshot.contentOverrides = [.font, .size, .colors, .edge, .window]

        let mapped = SystemCaptionAppearance.appearance(from: snapshot)
        XCTAssertEqual(mapped.systemContentOverrides, snapshot.contentOverrides)
    }

    func testColorOverridePrecedenceRemainsPerProperty() {
        var snapshot = SystemCaptionAppearance.Snapshot()
        snapshot.contentOverrides = [.foregroundColor, .backgroundOpacity]

        let overrides = SystemCaptionAppearance.appearance(from: snapshot).systemContentOverrides
        XCTAssertTrue(overrides.contains(.foregroundColor))
        XCTAssertFalse(overrides.contains(.foregroundOpacity))
        XCTAssertFalse(overrides.contains(.backgroundColor))
        XCTAssertTrue(overrides.contains(.backgroundOpacity))
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

import SwiftUI
import XCTest
@testable import Silo

final class OverlayPresetTests: XCTestCase {
    func testAccentBackgroundsPreserveStraightAlphaSRGBRecipes() {
        let accent = Color(.sRGB, red: 245.0 / 255, green: 197.0 / 255, blue: 24.0 / 255)
        let cases: [(PresetId, Float, Float, Float, Float)] = [
            (.classic, 245.0 / 255 * 0.72, 197.0 / 255 * 0.72, 24.0 / 255 * 0.72, 0.888),
            (.pill, (245.0 * 0.8 + 20.0 * 0.2) / 255,
             (197.0 * 0.8 + 20.0 * 0.2) / 255,
             (24.0 * 0.8 + 30.0 * 0.2) / 255, 0.94),
        ]
        for (id, red, green, blue, opacity) in cases {
            let actual = OverlayPresets.preset(id).backgroundColor(accent).resolve(in: EnvironmentValues())
            XCTAssertEqual(actual.red, red, accuracy: 0.001, id.rawValue)
            XCTAssertEqual(actual.green, green, accuracy: 0.001, id.rawValue)
            XCTAssertEqual(actual.blue, blue, accuracy: 0.001, id.rawValue)
            XCTAssertEqual(actual.opacity, opacity, accuracy: 0.001, id.rawValue)
        }
    }
}

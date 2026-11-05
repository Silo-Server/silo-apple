import XCTest
@testable import Silo
import AetherEngine

/// Silo's AetherEngine fork sets which optional engine components are compiled in.
/// Upstream says each may need third-party patent licenses, so Silo ships none of
/// them. A pin bump or fork change must not turn one on by accident.
final class AetherOptionalComponentsTests: XCTestCase {

    func testNoOptionalComponentIsBuiltIn() {
        for component in AetherEngine.OptionalComponent.allCases {
            XCTAssertFalse(component.isBuiltIn, "\(component.traitName) is built in")
        }
    }

    /// The TrueHD Atmos and DTS:X setting is hidden, and a stored "on" from an
    /// earlier build asks the engine for nothing.
    func testObjectAudioSettingNeverRequestsRendering() {
        XCTAssertFalse(AetherObjectAudioPolicy.isAvailable)
        XCTAssertEqual(AetherObjectAudioPolicy.rendering(enabled: true), .off)
    }
}

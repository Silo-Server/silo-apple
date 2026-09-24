import XCTest
@testable import Silo

@MainActor
final class ExperimentalFeaturesTests: XCTestCase {
    func testReleaseDefaultsHideTheSectionUntilTheVersionIsTappedEnoughTimes() throws {
        let suiteName = "experimental-features-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let features = ExperimentalFeatures(defaults: defaults, defaultOn: false)
        XCTAssertFalse(features.isUnlocked)
        XCTAssertFalse(features.isEnabled(.watchParty))

        for _ in 1..<ExperimentalFeatures.unlockTapCount {
            XCTAssertFalse(features.registerVersionTap())
        }
        XCTAssertFalse(features.isUnlocked)
        XCTAssertTrue(features.registerVersionTap())
        XCTAssertTrue(features.isUnlocked)
        XCTAssertFalse(features.isEnabled(.watchParty), "unlocking must not turn a feature on")

        features.setEnabled(.watchParty, true)

        let restored = ExperimentalFeatures(defaults: defaults, defaultOn: false)
        XCTAssertTrue(restored.isUnlocked)
        XCTAssertTrue(restored.isEnabled(.watchParty))
    }

    func testAStoredChoiceOverridesTheDebugDefault() throws {
        let suiteName = "experimental-features-debug-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let features = ExperimentalFeatures(defaults: defaults, defaultOn: true)
        XCTAssertTrue(features.isUnlocked)
        XCTAssertTrue(features.isEnabled(.watchParty))

        features.setEnabled(.watchParty, false)
        XCTAssertFalse(ExperimentalFeatures(defaults: defaults, defaultOn: true).isEnabled(.watchParty))
    }
}

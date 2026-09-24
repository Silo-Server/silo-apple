import XCTest
@testable import Silo

@MainActor
final class ExperimentalFeaturesTests: XCTestCase {
    func testReleaseDefaultsStartOffAndPersistTheChoice() throws {
        let suiteName = "experimental-features-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let features = ExperimentalFeatures(defaults: defaults, defaultOn: false)
        XCTAssertFalse(features.isEnabled(.watchParty))

        features.setEnabled(.watchParty, true)
        XCTAssertTrue(ExperimentalFeatures(defaults: defaults, defaultOn: false).isEnabled(.watchParty))
    }

    func testAStoredChoiceOverridesTheDebugDefault() throws {
        let suiteName = "experimental-features-debug-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let features = ExperimentalFeatures(defaults: defaults, defaultOn: true)
        XCTAssertTrue(features.isEnabled(.watchParty))

        features.setEnabled(.watchParty, false)
        XCTAssertFalse(ExperimentalFeatures(defaults: defaults, defaultOn: true).isEnabled(.watchParty))
    }
}

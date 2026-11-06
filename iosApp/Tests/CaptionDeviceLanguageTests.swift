@testable import Silo
import XCTest

/// D31: subtitle fallback reads the device's language list, not the app's own
/// `AppleLanguages` that Silo writes to apply the app language. The fallback
/// runs when MediaAccessibility names no caption language, which tests can't
/// arrange, so they read the list it falls back to.
final class CaptionDeviceLanguageTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let keys = ["AppleLanguages", "appLanguage.ledger.v1", "appLanguage.deviceList.v1"]
    private var saved: [String: Any] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let app = defaults.persistentDomain(forName: domain) ?? [:]
        for key in keys { saved[key] = app[key] }
    }

    override func tearDown() {
        for key in keys { defaults.set(saved[key], forKey: key) }
        super.tearDown()
    }

    /// Silo's own value, recorded in its ledger, with the list from before it.
    func testCaptionFallbackIgnoresSilosAppLanguage() throws {
        defaults.set(["fr-CA", "en-US"], forKey: "appLanguage.deviceList.v1")
        defaults.set(Data(#"{"applied":"is"}"#.utf8), forKey: "appLanguage.ledger.v1")
        defaults.set(["is"], forKey: "AppleLanguages")
        let global = defaults.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? []

        XCTAssertEqual(StandardAppLanguageSystem.deviceLanguages(), global.isEmpty ? ["fr-CA", "en-US"] : global)
    }

    /// Silo's first write keeps the list the device resolved before it.
    @MainActor
    func testSilosWriteRecordsTheDeviceListFirst() {
        defaults.removeObject(forKey: "appLanguage.ledger.v1")
        defaults.removeObject(forKey: "AppleLanguages")
        let before = Locale.preferredLanguages

        StandardAppLanguageSystem().write(.set(["is"]))

        XCTAssertEqual(defaults.stringArray(forKey: "appLanguage.deviceList.v1"), before)
        XCTAssertEqual(Locale.preferredLanguages.first, "is")
    }

    /// A per-app language the user chose themselves still counts, as before.
    func testCaptionFallbackKeepsTheUsersOwnAppLanguage() {
        defaults.removeObject(forKey: "appLanguage.ledger.v1")
        defaults.set(["is"], forKey: "AppleLanguages")

        XCTAssertEqual(StandardAppLanguageSystem.deviceLanguages().first, "is")
    }
}

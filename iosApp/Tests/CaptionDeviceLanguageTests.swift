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

    /// Silo's own value hides the device's list: read the global list, or
    /// the one recorded before Silo wrote when the global one is unreadable.
    func testFallbackIgnoresSilosAppLanguage() {
        defaults.set(["fr-CA", "en-US"], forKey: "appLanguage.deviceList.v1")
        defaults.set(Data(#"{"applied":"is"}"#.utf8), forKey: "appLanguage.ledger.v1")
        defaults.set(["is"], forKey: "AppleLanguages")

        XCTAssertEqual(StandardAppLanguageSystem.deviceLanguages(global: ["de-DE"]), ["de-DE"])
        XCTAssertEqual(StandardAppLanguageSystem.deviceLanguages(global: nil), ["fr-CA", "en-US"])
    }

    /// Over a per-app language the user chose, their list from before Silo's
    /// write still counts, as it did then.
    func testFallbackKeepsTheUsersAppLanguageUnderSilos() {
        defaults.set(["fr", "en-US"], forKey: "appLanguage.deviceList.v1")
        defaults.set(Data(#"{"applied":"is","baseline":["fr"]}"#.utf8), forKey: "appLanguage.ledger.v1")
        defaults.set(["is"], forKey: "AppleLanguages")

        XCTAssertEqual(StandardAppLanguageSystem.deviceLanguages(global: ["de-DE"]), ["fr", "en-US"])
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

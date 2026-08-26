import XCTest
@testable import Silo

final class ClientLocalSettingsTests: XCTestCase {
    func testDownloadContractPreferencesPersistAndDriveTheirPolicies() throws {
        let suiteName = "client-local-download-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let settings = DownloadSettings(defaults: defaults)
        XCTAssertEqual(settings.preferredFormat, DownloadFormat.original.rawValue)
        XCTAssertTrue(settings.wifiOnly)
        XCTAssertFalse(settings.keepWatchedDownloads)

        settings.preferredFormat = DownloadFormat.fiveMbps.rawValue
        settings.wifiOnly = false
        settings.keepWatchedDownloads = true

        let restored = DownloadSettings(defaults: defaults)
        XCTAssertEqual(restored.preferredFormat, DownloadFormat.fiveMbps.rawValue)
        XCTAssertFalse(restored.wifiOnly)
        XCTAssertTrue(restored.keepWatchedDownloads)
        XCTAssertEqual(
            restored.resolvedFormat(allowedFormats: [DownloadFormat.fiveMbps.rawValue]),
            DownloadFormat.fiveMbps.rawValue
        )
        XCTAssertEqual(
            restored.resolvedFormat(allowedFormats: [DownloadFormat.original.rawValue]),
            DownloadFormat.original.rawValue,
            "an unavailable saved quality must fall back to a request the server offers"
        )
    }

    func testShowAudiobooksPersistsAtItsInjectedProfileScope() throws {
        let suiteName = "client-local-nav-suite-\(UUID().uuidString)"
        let standardName = "client-local-nav-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }
        let defaults = SharedDefaults(suite: suite, standard: standard)
        let key = "ios.nav.showAudiobooks.test-server.test-profile"

        let settings = AppNavPreferences(defaults: defaults, storageKey: { key })
        XCTAssertFalse(settings.showAudiobooks, "the contract makes audiobook navigation opt-in")
        settings.setShowAudiobooks(true)

        let restored = AppNavPreferences(defaults: defaults, storageKey: { key })
        XCTAssertTrue(restored.showAudiobooks)
        XCTAssertTrue(defaults.containsObject(forKey: key))
    }

    func testShowFeaturedHeroDefaultsOnAndPersistsAtItsInjectedProfileScope() throws {
        let suiteName = "client-local-hero-suite-\(UUID().uuidString)"
        let standardName = "client-local-hero-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }
        let defaults = SharedDefaults(suite: suite, standard: standard)
        let key = "ios.home.showFeaturedHero.test-server.test-profile"
        let cardsKey = "ios.home.useFeaturedHeroCards.test-server.test-profile"

        let settings = AppNavPreferences(
            defaults: defaults,
            featuredHeroStorageKey: { key },
            featuredHeroCardsStorageKey: { cardsKey }
        )
        XCTAssertTrue(settings.showFeaturedHero)
        XCTAssertTrue(settings.useFeaturedHeroCards)
        settings.setShowFeaturedHero(false)
        settings.setUseFeaturedHeroCards(false)

        let restored = AppNavPreferences(
            defaults: defaults,
            featuredHeroStorageKey: { key },
            featuredHeroCardsStorageKey: { cardsKey }
        )
        XCTAssertFalse(restored.showFeaturedHero)
        XCTAssertFalse(restored.useFeaturedHeroCards)
        XCTAssertTrue(defaults.containsObject(forKey: key))
        XCTAssertTrue(defaults.containsObject(forKey: cardsKey))
    }

    @MainActor
    func testMatchDeviceCaptionsOverridesServerAppearanceAndManualEditingTakesBackControl() async throws {
        let harness = try PlayerSettingsHarness()
        var systemAppearance = SubtitleAppearance.default
        systemAppearance.fontSize = .xxlarge
        systemAppearance.fontColor = "#facc15"
        systemAppearance.position = .top
        harness.settings.setSubtitleMatchesSystemAppearance(true)
        harness.settings.subtitleSystemAppearance = systemAppearance
        XCTAssertTrue(harness.settings.subtitleMatchesSystemAppearance)
        XCTAssertEqual(harness.settings.effectiveSubtitleAppearance, systemAppearance)

        var customAppearance = SubtitleAppearance.default
        customAppearance.fontSize = .small
        await harness.settings.setSubtitleAppearance(customAppearance)

        XCTAssertFalse(harness.settings.subtitleMatchesSystemAppearance)
        XCTAssertEqual(harness.settings.effectiveSubtitleAppearance, customAppearance)
    }
}

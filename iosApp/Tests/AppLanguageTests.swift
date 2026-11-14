@testable import Silo
import XCTest

/// `ui.app_language`: matching (D6), the `AppleLanguages` ledger, the write-back
/// of a system per-app change (D18), the picker's options (D5), and the
/// `Accept-Language` header.
final class AppLanguageMatchingTests: XCTestCase {
    private let shipped = ["en", "es", "de", "fr", "pt-BR", "ja", "zh-Hans", "ar"]

    func testRegionalTagsMatchTheirShippedLanguage() {
        XCTAssertEqual(AppLanguage.match("es-MX", shipped: shipped), "es")
        XCTAssertEqual(AppLanguage.match("es-419", shipped: shipped), "es")
        XCTAssertEqual(AppLanguage.match("en-GB", shipped: shipped), "en")
        XCTAssertEqual(AppLanguage.match("pt-PT", shipped: shipped), "pt-BR")
        XCTAssertEqual(AppLanguage.match("zh-CN", shipped: shipped), "zh-Hans")
        XCTAssertEqual(AppLanguage.match("zh-SG", shipped: shipped), "zh-Hans")
        XCTAssertEqual(AppLanguage.match("ar-EG", shipped: shipped), "ar")
    }

    /// The system falls back to the first shipped language; that is no match.
    func testUnshippedLanguagesMatchNothing() {
        XCTAssertNil(AppLanguage.match("it", shipped: shipped))
        XCTAssertNil(AppLanguage.match("zh-TW", shipped: shipped))
        XCTAssertNil(AppLanguage.match("zh-Hant", shipped: shipped))
        XCTAssertNil(AppLanguage.match("es", shipped: ["en"]))
    }

    /// D26: the device's region, calendar and hour cycle stay the user's,
    /// as the system shows them once `AppleLanguages` holds the language.
    func testLocaleKeepsTheDeviceRegionAndHourCycle() {
        let locale = AppLanguage.locale(for: "es", base: Locale(identifier: "en_GB@hours=h23"))
        XCTAssertEqual(locale.language.languageCode, .spanish)
        XCTAssertEqual(locale.region, .unitedKingdom)
        XCTAssertEqual(locale.hourCycle, .zeroToTwentyThree)
    }

    /// D55: Arabic writes Arabic-Indic digits on any device, unless the
    /// user chose other digits. Apple's plain `ar` would write Latin ones.
    func testArabicWritesArabicIndicDigitsUnlessTheUserChoseOthers() {
        let onUSDevice = AppLanguage.locale(for: "ar", base: Locale(identifier: "en_US"))
        XCTAssertEqual(1234.formatted(.number.grouping(.never).locale(onUSDevice)), "١٢٣٤")
        let afterRelaunch = AppLanguage.locale(for: "ar", base: Locale(identifier: "ar_US"))
        XCTAssertEqual(1234.formatted(.number.grouping(.never).locale(afterRelaunch)), "١٢٣٤")
        let westernDigits = AppLanguage.locale(for: "ar", base: Locale(identifier: "ar_EG@numbers=latn"))
        XCTAssertEqual(1234.formatted(.number.grouping(.never).locale(westernDigits)), "1234")
        let english = AppLanguage.locale(for: "en", base: Locale(identifier: "en_US"))
        XCTAssertEqual(1234.formatted(.number.grouping(.never).locale(english)), "1234")
    }

    /// D28: isolates only in a right-to-left interface; LTR keeps its bytes.
    func testIsolatedWrapsInFirstStrongIsolatesOnlyRightToLeft() {
        XCTAssertEqual(AppLanguage.isolated("Severance", language: "ar"), "\u{2068}Severance\u{2069}")
        XCTAssertEqual(AppLanguage.isolated("Severance", language: "de"), "Severance")
        XCTAssertEqual(AppLanguage.isolated("Severance", language: "en"), "Severance")
    }
}

#if !os(tvOS)
final class ResolvedStringCacheTests: XCTestCase {
    /// Each resource resolves once; another argument or locale is another
    /// resource, never an earlier one's text.
    func testResolvesEachResourceOnceAndKeepsArgumentsAndLocalesApart() {
        let cache = ResolvedStringCache()
        var resolved: [String] = []
        func value(_ resource: LocalizedStringResource) -> String {
            cache.value(for: resource) { resource in
                let text = String(localized: resource)
                resolved.append(text)
                return text
            }
        }
        var english: LocalizedStringResource = "\(45) left"
        english.locale = Locale(identifier: "en")
        var other: LocalizedStringResource = "\(46) left"
        other.locale = Locale(identifier: "en")
        var french = english
        french.locale = Locale(identifier: "fr")

        XCTAssertEqual(value(english), "45 left")
        XCTAssertEqual(value(english), "45 left")
        XCTAssertEqual(value(other), "46 left")
        _ = value(french)
        XCTAssertEqual(resolved.count, 3)
    }

    /// A key whose argument keeps changing keeps only its newest entries.
    func testKeepsTheNewestEntriesPerKey() {
        let cache = ResolvedStringCache(entriesPerKey: 2)
        var resolutions = 0
        func value(_ number: Int) -> String {
            var resource: LocalizedStringResource = "\(number) left"
            resource.locale = Locale(identifier: "en")
            return cache.value(for: resource) { resolutions += 1; return String(localized: $0) }
        }
        _ = value(1)
        _ = value(2)
        _ = value(3)
        XCTAssertEqual(value(3), "3 left")
        XCTAssertEqual(resolutions, 3)
        XCTAssertEqual(value(1), "1 left")
        XCTAssertEqual(resolutions, 4)
    }
}
#endif

final class AppLanguageReconcilerTests: XCTestCase {
    private typealias R = AppLanguageReconciler
    private typealias Ledger = AppLanguageLedger

    func testFirstOverrideRecordsWhatWasThere() {
        XCTAssertEqual(
            R.reconcile(current: nil, override: "es", ledger: nil),
            R.Decision(write: .set(["es"]), ledger: Ledger(applied: "es", baseline: nil))
        )
        XCTAssertEqual(
            R.reconcile(current: ["fr"], override: "es", ledger: nil),
            R.Decision(write: .set(["es"]), ledger: Ledger(applied: "es", baseline: ["fr"]))
        )
    }

    func testProfileWithoutOverrideRestoresTheUsersValue() {
        XCTAssertEqual(
            R.reconcile(current: ["es"], override: nil, ledger: Ledger(applied: "es", baseline: nil)),
            R.Decision(write: .remove, ledger: nil)
        )
        XCTAssertEqual(
            R.reconcile(current: ["es"], override: nil, ledger: Ledger(applied: "es", baseline: ["fr"])),
            R.Decision(write: .set(["fr"]), ledger: nil)
        )
    }

    func testSwitchingBetweenOverridesKeepsTheOriginalBaseline() {
        XCTAssertEqual(
            R.reconcile(current: ["es"], override: "de", ledger: Ledger(applied: "es", baseline: ["fr"])),
            R.Decision(write: .set(["de"]), ledger: Ledger(applied: "de", baseline: ["fr"]))
        )
        XCTAssertEqual(
            R.reconcile(current: ["es"], override: "es", ledger: Ledger(applied: "es", baseline: nil)),
            R.Decision(write: nil, ledger: Ledger(applied: "es", baseline: nil))
        )
    }

    /// A value the user set in system settings after Silo's is never overwritten
    /// by a restore, and becomes the one to come back to.
    func testSystemChangeAfterSiloIsKept() {
        XCTAssertEqual(
            R.reconcile(current: ["fr"], override: nil, ledger: Ledger(applied: "es", baseline: nil)),
            R.Decision(write: nil, ledger: nil)
        )
        XCTAssertEqual(
            R.reconcile(current: ["fr"], override: "de", ledger: Ledger(applied: "es", baseline: nil)),
            R.Decision(write: .set(["de"]), ledger: Ledger(applied: "de", baseline: ["fr"]))
        )
    }

    func testSystemChoiceIsOnlyAChangeAfterSiloApplied() {
        let shipped = ["en", "es", "fr"]
        XCTAssertNil(R.systemChoice(current: ["fr"], ledger: nil, shipped: shipped))
        XCTAssertNil(R.systemChoice(current: ["es"], ledger: Ledger(applied: "es", baseline: nil), shipped: shipped))
        XCTAssertEqual(
            R.systemChoice(current: ["fr"], ledger: Ledger(applied: "es", baseline: nil), shipped: shipped),
            AppLanguageSystemChoice(tag: "fr")
        )
        // The key removed: follow the device, written as null.
        XCTAssertEqual(
            R.systemChoice(current: nil, ledger: Ledger(applied: "es", baseline: ["fr"]), shipped: shipped),
            AppLanguageSystemChoice(tag: nil)
        )
    }
}

@MainActor
final class AppLanguagePreferencesTests: XCTestCase {
    private let shipped = ["en", "es", "fr", "ar"]
    private let profileA = HTTPRequestIdentity(serverId: "s", serverURL: "http://s", profileId: "A", clientFamily: "mobile")
    private let profileB = HTTPRequestIdentity(serverId: "s", serverURL: "http://s", profileId: "B", clientFamily: "mobile")

    private func makeStore(
        transport: FakeAppLanguageTransport,
        system: FakeAppLanguageSystem,
        identity: @escaping @MainActor () -> HTTPRequestIdentity?
    ) -> AppLanguagePreferences {
        AppLanguagePreferences(transport: transport, requestIdentity: identity, system: system, shipped: shipped)
    }

    func testProfileLanguageAppliesAndAProfileWithoutOneRestores() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "es"
        let system = FakeAppLanguageSystem()
        var active = profileA
        let store = makeStore(transport: transport, system: system) { active }
        XCTAssertEqual(store.displayed, "en")

        await store.refresh()
        XCTAssertEqual(store.displayed, "es")
        XCTAssertEqual(system.appValue, ["es"])
        XCTAssertEqual(system.displayedStored, "es")
        XCTAssertEqual(store.currentChoice, .init(tag: "es", isDeviceValue: false))

        active = profileB
        await store.refresh()
        XCTAssertEqual(store.displayed, "en", "follows the device again at once")
        XCTAssertNil(system.appValue)
        XCTAssertNil(system.ledger)
        XCTAssertEqual(store.currentChoice, .init(tag: nil, isDeviceValue: false))
    }

    func testUnshippedTagFollowsTheDeviceButStaysTheChoice() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "it"
        let system = FakeAppLanguageSystem()
        let store = makeStore(transport: transport, system: system) { self.profileA }

        await store.refresh()
        XCTAssertEqual(store.displayed, "en")
        XCTAssertNil(system.appValue)
        // Match Device first, the shipped languages (sorted for the reader's
        // locale), then the stored tag the build doesn't ship.
        let tags = store.options.map(\.tag)
        XCTAssertEqual(tags.first, .some(nil))
        XCTAssertEqual(Set(tags.dropFirst().dropLast()), ["en", "es", "fr", "ar"])
        XCTAssertEqual(tags.last, "it")
        XCTAssertEqual(AppLanguage.string(store.selectedLabel), "Italiano")
        XCTAssertTrue(AppLanguage.string(store.footer).contains("isn’t available in Italiano"))
    }

    func testRegionalTagIsAppliedWithoutTheUnavailableFooter() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "es-MX"
        let store = makeStore(transport: transport, system: FakeAppLanguageSystem()) { self.profileA }

        await store.refresh()
        XCTAssertEqual(store.displayed, "es")
        XCTAssertTrue(store.options.contains { $0.tag == "es-MX" }, "the stored tag stays selectable")
        XCTAssertFalse(AppLanguage.string(store.footer).contains("isn’t available"))
    }

    /// D18: the user picked French in system settings after Silo applied
    /// Spanish. The next launch shows French at once and writes it back as this
    /// device's value before reading the profile's.
    func testSystemChangeIsWrittenBackAsTheDeviceValue() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "es"
        let system = FakeAppLanguageSystem()
        system.appValue = ["fr"]
        system.ledger = AppLanguageLedger(applied: "es", baseline: nil)
        let store = makeStore(transport: transport, system: system) { self.profileA }
        XCTAssertEqual(store.displayed, "fr", "seeded from the system choice, not the ledger")

        await store.refresh()
        XCTAssertEqual(transport.calls.first, .put(.profileDevice, "A", .string("fr")))
        XCTAssertEqual(store.displayed, "fr")
        XCTAssertEqual(system.appValue, ["fr"])
        XCTAssertEqual(store.currentChoice, .init(tag: "fr", isDeviceValue: true))
    }

    func testRemovedSystemValueIsWrittenBackAsNull() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "es"
        let system = FakeAppLanguageSystem()
        system.ledger = AppLanguageLedger(applied: "es", baseline: nil)
        let store = makeStore(transport: transport, system: system) { self.profileA }

        await store.refresh()
        XCTAssertEqual(transport.calls.first, .put(.profileDevice, "A", .null))
        XCTAssertEqual(store.displayed, "en")
        XCTAssertNil(system.appValue)
    }

    /// Offline write-back: nothing from the server is applied, so the
    /// profile's Spanish never replaces the user's French, and the ledger is
    /// kept for the next launch to find the change again.
    func testUnsentWriteBackAppliesNothing() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "es"
        transport.putError = SettingsAPIError.transport(description: "offline")
        let system = FakeAppLanguageSystem()
        system.appValue = ["fr"]
        let ledger = AppLanguageLedger(applied: "es", baseline: nil)
        system.ledger = ledger
        let store = makeStore(transport: transport, system: system) { self.profileA }

        await store.refresh()
        XCTAssertEqual(store.displayed, "fr")
        XCTAssertEqual(system.appValue, ["fr"])
        XCTAssertEqual(system.ledger, ledger)
        XCTAssertEqual(transport.effectiveReads, 0)

        transport.putError = nil
        await store.refresh()
        XCTAssertEqual(transport.calls.last, .put(.profileDevice, "A", .string("fr")))
        XCTAssertEqual(store.displayed, "fr")
    }

    /// The picker saves the profile's value and clears this device's own row,
    /// so the choice takes effect here.
    func testPickerSavesProfileAndClearsTheDeviceValue() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "es"
        transport.deviceValues["A"] = "fr"
        let system = FakeAppLanguageSystem()
        let store = makeStore(transport: transport, system: system) { self.profileA }
        await store.refresh()
        XCTAssertEqual(store.displayed, "fr")

        await store.select("de")
        XCTAssertEqual(transport.calls, [.put(.profile, "A", .string("de")), .delete(.profileDevice, "A")])
        // "de" isn't shipped in this test: stored and shown, device language on screen.
        XCTAssertEqual(store.currentChoice, .init(tag: "de", isDeviceValue: false))
        XCTAssertEqual(store.displayed, "en")

        await store.select(nil)
        XCTAssertEqual(transport.calls.last, .put(.profile, "A", .null))
        XCTAssertEqual(store.currentChoice, .init(tag: nil, isDeviceValue: false))
    }

    /// The profile write lands but clearing the device row fails: the error
    /// shows and the screen follows what the server now resolves.
    func testPartialPickerWriteReadsBack() async {
        let transport = FakeAppLanguageTransport()
        transport.deviceValues["A"] = "fr"
        transport.deleteError = SettingsAPIError.transport(description: "offline")
        let system = FakeAppLanguageSystem()
        let store = makeStore(transport: transport, system: system) { self.profileA }
        await store.refresh()

        await store.select("es")
        XCTAssertEqual(transport.profileValues["A"], "es")
        XCTAssertEqual(store.currentChoice, .init(tag: "fr", isDeviceValue: true))
        XCTAssertEqual(store.displayed, "fr")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.isSaving)
    }

    /// A write-back the server refuses for good doesn't lock the profile's
    /// value out: it applies, and the user's value is the one to come back to.
    func testRefusedWriteBackLetsTheProfileValueApply() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "es"
        transport.putError = SettingsAPIError.scopeNotAllowed(key: "ui.app_language", scope: .profileDevice)
        let system = FakeAppLanguageSystem()
        system.appValue = ["fr"]
        system.ledger = AppLanguageLedger(applied: "es", baseline: nil)
        let store = makeStore(transport: transport, system: system) { self.profileA }

        await store.refresh()
        XCTAssertEqual(store.displayed, "es")
        XCTAssertEqual(system.ledger, AppLanguageLedger(applied: "es", baseline: ["fr"]))
        XCTAssertEqual(store.currentChoice, .init(tag: "es", isDeviceValue: false))
    }

    /// A server without the setting keeps a pending write-back and the ledger
    /// for a server that has it.
    func testServerWithoutTheSettingKeepsAPendingWriteBack() async {
        let transport = FakeAppLanguageTransport()
        transport.revision = 26
        let system = FakeAppLanguageSystem()
        system.appValue = ["fr"]
        let ledger = AppLanguageLedger(applied: "es", baseline: nil)
        system.ledger = ledger
        let store = makeStore(transport: transport, system: system) { self.profileA }

        await store.refresh()
        XCTAssertEqual(system.ledger, ledger)
        XCTAssertEqual(store.displayed, "fr")

        transport.revision = 28
        await store.refresh()
        XCTAssertEqual(transport.calls, [.put(.profileDevice, "A", .string("fr"))])
    }

    /// A profile switch while the write-back is in flight sends it once, to
    /// the profile it started for, then reads the new profile.
    func testWriteBackGoesToOneProfile() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["B"] = "es"
        let system = FakeAppLanguageSystem()
        system.appValue = ["fr"]
        system.ledger = AppLanguageLedger(applied: "es", baseline: nil)
        var active = profileA
        let store = makeStore(transport: transport, system: system) { active }
        transport.onPut = {
            active = self.profileB
            Task { await store.refresh() }
        }

        await store.refresh()
        XCTAssertEqual(transport.calls.filter { if case .put(.profileDevice, _, _) = $0 { true } else { false } },
                       [.put(.profileDevice, "A", .string("fr"))])
        XCTAssertEqual(store.currentChoice, .init(tag: "es", isDeviceValue: false))
        XCTAssertEqual(store.displayed, "es")
    }

    /// A profile switch during a write-back that fails still loads the new
    /// profile: its own refresh skipped the read while the write ran.
    func testFailedWriteBackStillLoadsTheProfileSwitchedTo() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["B"] = "es"
        transport.putError = SettingsAPIError.transport(description: "offline")
        let system = FakeAppLanguageSystem()
        system.appValue = ["fr"]
        system.ledger = AppLanguageLedger(applied: "es", baseline: nil)
        var active = profileA
        let store = makeStore(transport: transport, system: system) { active }
        transport.onPut = {
            active = self.profileB
            Task {
                transport.putError = nil
                await store.refresh()
            }
        }

        await store.refresh()
        XCTAssertEqual(transport.calls.first, .put(.profileDevice, "A", .string("fr")))
        XCTAssertEqual(store.currentChoice?.tag, "fr")
        XCTAssertEqual(store.displayed, "fr")
    }

    /// macOS keeps the app open when its language changes in System Settings:
    /// the next refresh writes it back instead of overwriting it.
    func testSystemChangeWhileRunningIsWrittenBack() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "es"
        let system = FakeAppLanguageSystem()
        let store = makeStore(transport: transport, system: system) { self.profileA }
        await store.refresh()
        XCTAssertEqual(system.appValue, ["es"])

        system.appValue = ["fr"]
        await store.refresh()
        XCTAssertEqual(transport.calls.last, .put(.profileDevice, "A", .string("fr")))
        XCTAssertEqual(store.displayed, "fr")
    }

    /// Choosing Match Device clears the app's own language rather than
    /// bringing back the one from before Silo's.
    func testMatchDeviceClearsTheAppLanguage() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "es"
        let system = FakeAppLanguageSystem()
        system.appValue = ["fr"]
        let store = makeStore(transport: transport, system: system) { self.profileA }
        await store.refresh()
        XCTAssertEqual(system.ledger, AppLanguageLedger(applied: "es", baseline: ["fr"]))

        await store.select(nil)
        XCTAssertNil(system.appValue)
        XCTAssertNil(system.ledger)
        XCTAssertEqual(store.displayed, "en")
    }

    /// Re-picking the language a device row shows makes it the profile's.
    func testPickingTheShownDeviceLanguageSavesItForTheProfile() async {
        let transport = FakeAppLanguageTransport()
        transport.deviceValues["A"] = "fr"
        let store = makeStore(transport: transport, system: FakeAppLanguageSystem()) { self.profileA }
        await store.refresh()

        await store.select("fr")
        XCTAssertEqual(transport.calls, [.put(.profile, "A", .string("fr")), .delete(.profileDevice, "A")])
        XCTAssertEqual(store.currentChoice, .init(tag: "fr", isDeviceValue: false))
    }

    /// A retryable HTTP answer (408) keeps the system choice to send again.
    func testRetryableRefusalKeepsTheWriteBack() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "es"
        transport.putError = SettingsAPIError.server(status: 408, code: nil, message: nil)
        let system = FakeAppLanguageSystem()
        system.appValue = ["fr"]
        system.ledger = AppLanguageLedger(applied: "es", baseline: nil)
        let store = makeStore(transport: transport, system: system) { self.profileA }

        await store.refresh()
        XCTAssertEqual(system.appValue, ["fr"])
        XCTAssertEqual(transport.effectiveReads, 0)
        XCTAssertEqual(store.displayed, "fr")
    }

    /// A newer system change replaces a choice still unsent.
    func testNewerSystemChangeReplacesAnUnsentOne() async {
        let transport = FakeAppLanguageTransport()
        transport.putError = SettingsAPIError.transport(description: "offline")
        let system = FakeAppLanguageSystem()
        system.appValue = ["fr"]
        system.ledger = AppLanguageLedger(applied: "es", baseline: nil)
        let store = makeStore(transport: transport, system: system) { self.profileA }
        await store.refresh()

        system.appValue = ["ar"]
        transport.putError = nil
        await store.refresh()
        XCTAssertEqual(transport.calls.last, .put(.profileDevice, "A", .string("ar")))
        XCTAssertEqual(system.appValue, ["ar"])
    }

    /// A refresh that lands during a Match Device save can't bring back the
    /// language from before Silo's.
    func testRefreshDuringMatchDeviceSaveDoesNotRestoreTheOldValue() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "es"
        let system = FakeAppLanguageSystem()
        system.appValue = ["fr"]
        let store = makeStore(transport: transport, system: system) { self.profileA }
        await store.refresh()
        var concurrent: Task<Void, Never>?
        transport.onPut = { concurrent = Task { await store.refresh() } }

        await store.select(nil)
        await concurrent?.value
        XCTAssertNil(system.appValue)
        XCTAssertNil(system.ledger)
    }

    /// Changing the system language back to Silo's during the write-back
    /// is itself written back, not lost to the value just sent.
    func testRevertDuringWriteBackIsWrittenBackNext() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "es"
        let system = FakeAppLanguageSystem()
        system.appValue = ["fr"]
        system.ledger = AppLanguageLedger(applied: "es", baseline: nil)
        let store = makeStore(transport: transport, system: system) { self.profileA }
        transport.onPut = { system.appValue = ["es"] }

        await store.refresh()
        XCTAssertEqual(transport.effectiveReads, 0, "nothing applied over the newer choice")
        XCTAssertEqual(system.appValue, ["es"])

        await store.refresh()
        XCTAssertEqual(transport.calls.last, .put(.profileDevice, "A", .string("es")))
        XCTAssertEqual(store.currentChoice, .init(tag: "es", isDeviceValue: true))
        XCTAssertEqual(system.appValue, ["es"])
    }

    /// A profile switch during a picker save still loads the new profile.
    func testProfileSwitchDuringSaveLoadsTheNewProfile() async {
        let transport = FakeAppLanguageTransport()
        transport.profileValues["A"] = "es"
        transport.profileValues["B"] = "fr"
        let system = FakeAppLanguageSystem()
        var active = profileA
        let store = makeStore(transport: transport, system: system) { active }
        await store.refresh()
        var concurrent: Task<Void, Never>?
        transport.onPut = {
            active = self.profileB
            concurrent = Task { await store.refresh() }
        }

        await store.select("ar")
        await concurrent?.value
        XCTAssertEqual(store.currentChoice, .init(tag: "fr", isDeviceValue: false))
        XCTAssertEqual(store.displayed, "fr")
    }

    func testServerWithoutTheSettingFollowsTheDevice() async {
        let transport = FakeAppLanguageTransport()
        transport.revision = 26
        let system = FakeAppLanguageSystem()
        system.appValue = ["es"]
        system.ledger = AppLanguageLedger(applied: "es", baseline: nil)
        let store = makeStore(transport: transport, system: system) { self.profileA }

        await store.refresh()
        XCTAssertNil(store.currentChoice, "no picker")
        XCTAssertNil(system.appValue)
        XCTAssertEqual(store.displayed, "en")
        XCTAssertEqual(transport.effectiveReads, 0)
    }
}

final class AppLanguageHeaderTests: XCTestCase {
    /// Every Silo request names the language the app shows.
    func testRequestsCarryTheDisplayedLanguage() {
        let key = "appLanguage.displayed.v1"
        let defaults = SharedStorage.suite
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }
        defaults.set("es", forKey: key)

        var request = URLRequest(url: URL(string: "http://example.invalid/api/v2/home")!)
        AppleDeviceIdentity.current.applyHeaders(to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "es")
    }
}

// MARK: Fakes

@MainActor
private final class FakeAppLanguageSystem: AppLanguageSystem {
    var appValue: [String]?
    var deviceList = ["en-US"]
    var ledger: AppLanguageLedger?
    private(set) var displayedStored: String?

    var effectiveList: [String] { appValue ?? deviceList }

    func write(_ write: AppLanguageReconciler.Write) {
        switch write {
        case .set(let tags): appValue = tags
        case .remove: appValue = nil
        }
    }

    func storeDisplayed(_ tag: String) { displayedStored = tag }
}

/// Stores values the way the server resolves them: this device's row, then
/// the profile's, then the default `null`.
@MainActor
private final class FakeAppLanguageTransport: TitleArtTransport, @unchecked Sendable {
    enum Call: Equatable {
        case put(SettingScope, String, SettingJSONValue)
        case delete(SettingScope, String)
    }

    var revision = 28
    var profileValues: [String: String?] = [:]
    var deviceValues: [String: String?] = [:]
    var putError: Error?
    var deleteError: Error?
    /// Runs inside the next write, before it answers.
    var onPut: (@MainActor () -> Void)?
    private(set) var calls: [Call] = []
    private(set) var effectiveReads = 0

    nonisolated func contractCapabilities(requestIdentity: HTTPRequestIdentity) async -> SettingsCapabilitiesResult {
        await MainActor.run {
            .available(APIv2SettingsContractCapabilities(
                revision: "capabilities-\(revision)",
                state: "available",
                allowed: true,
                manifestRevision: revision,
                clientFamilies: ["tv", "mobile", "tablet", "desktop", "web"],
                supportsBatchedEffective: true
            ))
        }
    }

    nonisolated func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        try await MainActor.run {
            effectiveReads += 1
            let profile = requestIdentity.profileId
            let (value, source): (String?, String) = if let device = deviceValues[profile] {
                (device, "profile_device")
            } else if let stored = profileValues[profile] {
                (stored, "profile")
            } else {
                (nil, "default")
            }
            let row: [String: Any] = ["key": "ui.app_language", "value": value ?? NSNull(), "source": source]
            let data = try JSONSerialization.data(withJSONObject: ["items": [row], "revision": revision])
            return try SettingsWireCoding.makeDecoder().decode(EffectiveSettingValuesResponse.self, from: data)
        }
    }

    nonisolated func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await MainActor.run {
            calls.append(.put(scope.scope, requestIdentity.profileId, value))
            let hook = onPut
            onPut = nil
            hook?()
            if let putError { throw putError }
            var tag: String?
            if case .string(let stored) = value { tag = stored }
            if scope.scope == .profileDevice {
                deviceValues[requestIdentity.profileId] = .some(tag)
            } else {
                profileValues[requestIdentity.profileId] = .some(tag)
            }
        }
    }

    nonisolated func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await MainActor.run {
            calls.append(.delete(scope.scope, requestIdentity.profileId))
            if let deleteError { throw deleteError }
            deviceValues[requestIdentity.profileId] = nil
        }
    }
}

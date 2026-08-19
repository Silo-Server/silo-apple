import XCTest
@testable import Silo

/// Pins the one-time migrations that let the pre-rename ("continuum") names
/// disappear from the Apple clients without logging users out, orphaning
/// downloads, or stranding caches.
///
/// The Keychain cases run against a UUID-unique service pair (current +
/// injected legacy service) so they exercise the migration logic without
/// touching the real shared service; account names are UUID-unique too, and
/// every case cleans up both the Silo-branded and the pre-rename slot.
final class BrandMigrationTests: XCTestCase {

    private func makeAccounts() -> (silo: String, legacy: String) {
        let suffix = "brandMigrationTests.\(UUID().uuidString)"
        return (
            SharedStorage.keychainAccountPrefix + suffix,
            LegacyBrandKeys.accountPrefix + suffix
        )
    }

    private func makeKeychains() throws -> (silo: SharedKeychain, legacy: SharedKeychain) {
        let base = "org.siloserver.silo.tests.brandMigration.\(UUID().uuidString)"
        let silo = SharedKeychain(service: base, accessGroup: nil, legacyService: .some(base + ".legacy"))
        // The simulator test host cannot always write to the keychain (the
        // same environment limitation behind the documented baseline
        // failures). Skip rather than fail so the migration contract is still
        // asserted wherever the keychain is writable.
        let probe = "\(SharedStorage.keychainAccountPrefix)brandMigrationTests.probe.\(UUID().uuidString)"
        let writable = silo.set("probe", for: probe)
        silo.delete(probe)
        try XCTSkipUnless(writable, "Keychain is not writable in this test environment")
        return (silo, try XCTUnwrap(silo.legacyBrandSource))
    }

    // MARK: - Keychain

    func testReadMissAdoptsPreRenameItemAndKeepsItForRollback() throws {
        let (siloAccount, legacyAccount) = makeAccounts()
        let (silo, legacy) = try makeKeychains()
        defer {
            silo.delete(siloAccount)
            legacy.delete(legacyAccount)
        }

        XCTAssertTrue(legacy.set("token-value", for: legacyAccount))

        // Read-miss on the Silo-branded name finds the pre-rename copy.
        XCTAssertEqual(silo.get(siloAccount), "token-value")
        // ...writes it forward, so the next read needs no migration...
        XCTAssertEqual(
            SharedKeychain(service: silo.service, accessGroup: nil, legacyService: .some(nil))
                .get(siloAccount),
            "token-value"
        )
        // ...and leaves the pre-rename copy in place so a TestFlight rollback
        // to the previous build still finds its credentials.
        XCTAssertEqual(legacy.get(legacyAccount), "token-value")
    }

    func testSiloBrandedItemWinsOverPreRenameItem() throws {
        let (siloAccount, legacyAccount) = makeAccounts()
        let (silo, legacy) = try makeKeychains()
        defer {
            silo.delete(siloAccount)
            legacy.delete(legacyAccount)
        }

        XCTAssertTrue(legacy.set("stale", for: legacyAccount))
        XCTAssertTrue(silo.set("current", for: siloAccount))

        XCTAssertEqual(silo.get(siloAccount), "current")
        // The pre-rename copy is never consulted, so it is left untouched.
        XCTAssertEqual(legacy.get(legacyAccount), "stale")
    }

    /// Sign-out must not be undone by a later read migrating the pre-rename
    /// copy of the same credential back in.
    func testDeleteAlsoRemovesPreRenameItem() throws {
        let (siloAccount, legacyAccount) = makeAccounts()
        let (silo, legacy) = try makeKeychains()
        defer {
            silo.delete(siloAccount)
            legacy.delete(legacyAccount)
        }

        XCTAssertTrue(legacy.set("stale", for: legacyAccount))
        XCTAssertTrue(silo.set("current", for: siloAccount))

        XCTAssertTrue(silo.delete(siloAccount))
        XCTAssertNil(silo.get(siloAccount))
        XCTAssertNil(legacy.get(legacyAccount))
    }

    /// Test-injected keychains use their own service and therefore have no
    /// pre-rename counterpart to migrate from.
    func testCustomServiceHasNoPreRenameSource() {
        let isolated = SharedKeychain(
            service: "BrandMigrationTests.\(UUID().uuidString)",
            accessGroup: nil
        )
        XCTAssertNil(isolated.legacyBrandSource)
    }

    // MARK: - UserDefaults

    func testRegistryAdoptsPreRenameMigratedFlag() throws {
        let suiteName = "BrandMigrationTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(true, forKey: LegacyBrandKeys.serverRegistryMigratedDefaultsKey)
        // A single-server install the old build already migrated. Without the
        // flag moving across, the registry would re-run that migration.
        defaults.set("https://silo.example.test", forKey: SharedStorage.serverUrlKey)

        let registry = ServerRegistry(
            defaults: defaults,
            keychain: SharedKeychain(
                service: "BrandMigrationTests.\(UUID().uuidString)",
                accessGroup: nil
            ),
            launchPreferences: ProfileLaunchPreferences(defaults: defaults)
        )

        XCTAssertTrue(defaults.bool(forKey: "siloServerRegistry.migrated.v1"))
        // The pre-rename flag survives for a rollback build.
        XCTAssertTrue(defaults.bool(forKey: LegacyBrandKeys.serverRegistryMigratedDefaultsKey))
        XCTAssertTrue(defaults.bool(forKey: "siloServerRegistry.brandMigrated.v1"))
        XCTAssertTrue(registry.entries.isEmpty)
    }

    // MARK: - OS-registered identifiers

    func testOSRegisteredIdentifiersCarryTheSiloBrand() {
        XCTAssertEqual(DownloadSessionDelegate.sessionIdentifier, "org.siloserver.silo.downloads")
        XCTAssertNotEqual(
            DownloadSessionDelegate.sessionIdentifier,
            LegacyBrandKeys.downloadsSessionIdentifier
        )
        XCTAssertEqual(
            DownloadBackgroundRefresh.taskIdentifier,
            "org.siloserver.silo.downloads-refresh"
        )
    }
}

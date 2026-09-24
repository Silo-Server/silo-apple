import XCTest
@testable import Silo

/// Covers moving stored state from its pre-rename `continuum` names.
final class SiloRenameMigrationTests: XCTestCase {
    private func keychains() -> (current: SharedKeychain, legacy: SharedKeychain) {
        let name = "SiloRenameMigrationTests.\(UUID().uuidString)"
        let legacyName = name + ".legacy"
        let current = SharedKeychain(service: name, accessGroup: nil, legacyService: legacyName)
        let legacy = SharedKeychain(service: legacyName, accessGroup: nil)
        return (current, legacy)
    }

    func testReadMovesAnItemFromItsLegacyName() throws {
        let (current, legacy) = keychains()
        let account = SharedStorage.refreshTokenAccount(for: "server")
        XCTAssertEqual(SharedStorage.legacyKeychainAccount(for: account), "com.continuum.server.refreshToken")
        XCTAssertTrue(legacy.set("refresh", for: "com.continuum.server.refreshToken"))
        addTeardownBlock { current.delete(account) }

        XCTAssertEqual(current.get(account), "refresh")
        XCTAssertNil(legacy.get("com.continuum.server.refreshToken"))
    }

    func testStrictReadMovesAnItemFromItsLegacyName() throws {
        let (current, legacy) = keychains()
        let account = AccountSessionPersistence.markerKey("server")
        XCTAssertTrue(legacy.set("1", for: "com.continuum.server.accountSessionAdopted"))
        addTeardownBlock { current.delete(account) }

        XCTAssertEqual(try current.getChecked(account), "1")
        XCTAssertNil(try legacy.getChecked("com.continuum.server.accountSessionAdopted"))
    }

    func testCurrentValueWinsOverAStaleLegacyCopy() {
        let (current, legacy) = keychains()
        let account = SharedStorage.accessTokenAccount(for: "server")
        XCTAssertTrue(current.set("rotated", for: account))
        XCTAssertTrue(legacy.set("stale", for: "com.continuum.server.accessToken"))
        addTeardownBlock { current.delete(account) }

        XCTAssertEqual(current.get(account), "rotated")
    }

    func testWriteRetiresTheLegacyCopy() {
        let (current, legacy) = keychains()
        let account = SharedStorage.accessTokenAccount(for: "server")
        XCTAssertTrue(legacy.set("stale", for: "com.continuum.server.accessToken"))
        addTeardownBlock { current.delete(account) }

        XCTAssertTrue(current.set("fresh", for: account))
        XCTAssertNil(legacy.get("com.continuum.server.accessToken"))
    }

    func testDeleteRemovesBothNamesSoSignedOutTokensStayGone() {
        let (current, legacy) = keychains()
        let account = SharedStorage.accessTokenAccount(for: "server")
        XCTAssertTrue(legacy.set("legacy", for: "com.continuum.server.accessToken"))

        XCTAssertTrue(current.delete(account))
        XCTAssertNil(current.get(account))
        XCTAssertNil(legacy.get("com.continuum.server.accessToken"))
    }

    func testPreRenameFixedNamesAreReadFromTheLegacyService() {
        let (current, legacy) = keychains()
        XCTAssertTrue(legacy.set("old", for: "com.continuum.app.accessToken"))
        addTeardownBlock { current.delete("com.continuum.app.accessToken") }

        XCTAssertEqual(current.get("com.continuum.app.accessToken"), "old")
    }

    func testUnprefixedAccountsMoveUnderTheirOwnName() {
        let (current, legacy) = keychains()
        XCTAssertEqual(SharedStorage.legacyKeychainAccount(for: WatchPartyRecentStore.key), WatchPartyRecentStore.key)
        XCTAssertTrue(legacy.set("room", for: WatchPartyRecentStore.key))
        addTeardownBlock { current.delete(WatchPartyRecentStore.key) }

        XCTAssertEqual(current.get(WatchPartyRecentStore.key), "room")
        XCTAssertNil(legacy.get(WatchPartyRecentStore.key))
    }

    /// Personal Team tvOS builds run without the user-independent Keychain,
    /// so both audiences address the same item. The move must survive a
    /// second read rather than being deleted as a "persona" leftover.
    func testMovedAccountItemSurvivesWithoutTheUserIndependentKeychain() {
        let name = "SiloRenameMigrationTests.\(UUID().uuidString)"
        let current = SharedKeychain(service: name, accessGroup: nil, audience: .userIndependent,
                                     usesUserIndependentKeychain: false, legacyService: name + ".legacy")
        let legacy = SharedKeychain(service: name + ".legacy", accessGroup: nil, audience: .userIndependent,
                                    usesUserIndependentKeychain: false)
        let account = SharedStorage.accessTokenAccount(for: "server")
        XCTAssertTrue(legacy.set("access", for: "com.continuum.server.accessToken"))
        addTeardownBlock { current.delete(account) }

        XCTAssertEqual(current.get(account), "access")
        XCTAssertEqual(current.get(account), "access")
        XCTAssertEqual(current.withAudience(.currentUser).get(account), "access")
    }

    func testOnlyTheSharedServiceDefaultsToTheLegacyService() {
        XCTAssertEqual(SharedKeychain(accessGroup: nil).legacyService, "com.continuum.app")
        XCTAssertNil(SharedKeychain(service: "isolated", accessGroup: nil).legacyService)
    }

    func testRegistryDefaultsMoveToTheirCurrentKeys() throws {
        let name = "SiloRenameMigrationTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(Data("registry".utf8), forKey: "continuumServerRegistry.v1")
        defaults.set(true, forKey: "continuumServerRegistry.migrated.v1")

        ServerRegistry.adoptLegacyDefaultsKeys(defaults)

        XCTAssertEqual(defaults.data(forKey: ServerRegistry.defaultsKey), Data("registry".utf8))
        XCTAssertTrue(defaults.bool(forKey: ServerRegistry.migratedKey))
        XCTAssertFalse(defaults.containsObject(forKey: "continuumServerRegistry.v1"))
        XCTAssertFalse(defaults.containsObject(forKey: "continuumServerRegistry.migrated.v1"))
    }

    func testCurrentRegistryWinsOverALegacyCopy() throws {
        let name = "SiloRenameMigrationTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(Data("current".utf8), forKey: ServerRegistry.defaultsKey)
        defaults.set(Data("legacy".utf8), forKey: "continuumServerRegistry.v1")

        ServerRegistry.adoptLegacyDefaultsKeys(defaults)

        XCTAssertEqual(defaults.data(forKey: ServerRegistry.defaultsKey), Data("current".utf8))
        XCTAssertFalse(defaults.containsObject(forKey: "continuumServerRegistry.v1"))
        XCTAssertFalse(defaults.containsObject(forKey: ServerRegistry.migratedKey))
    }
}

import XCTest
@testable import Silo

/// A server can be renamed for the current user. The name replaces the
/// advertised one, survives reconnects, and syncs between that user's devices
/// without either device losing an edit. Two registries sharing one fake
/// iCloud store stand in for two devices.
@MainActor
final class ServerNicknameTests: XCTestCase {
    private static let publicURL = "https://home.example"
    private static let lanURL = "http://home.lan.example:8096"
    private static let otherURL = "https://other.example"
    private static let deployment = "deployment-1"

    func testARenameReplacesTheServersNameAndSurvivesARelaunch() throws {
        let device = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")])

        XCTAssertTrue(device.registry.rename(serverId: Self.id(Self.publicURL), to: "  Home  "))

        XCTAssertEqual(device.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Home")
        let relaunched = device.relaunched()
        XCTAssertEqual(relaunched.entry(with: Self.id(Self.publicURL))?.displayName, "Home")
        XCTAssertEqual(relaunched.entry(with: Self.id(Self.publicURL))?.serverName, "Silo")
    }

    func testClearingTheNameGoesBackToTheServersName() throws {
        let device = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")])
        device.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")

        XCTAssertTrue(device.registry.rename(serverId: Self.id(Self.publicURL), to: "   "))

        XCTAssertNil(device.registry.entry(with: Self.id(Self.publicURL))?.nickname)
        XCTAssertEqual(device.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Silo")
    }

    func testReconnectingKeepsTheNicknameAndNeverSavesItWithTheServerList() throws {
        var savedLists: [[ServerEntry]] = []
        let device = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")]) { savedLists.append($0) }
        device.registry.rename(serverId: Self.id(Self.publicURL), to: "Lounge")

        let reconnected = device.registry.addOrUpdate(Self.entry(Self.publicURL, name: "Silo Media"))
        device.registry.updateFetchedName(for: Self.id(Self.publicURL), fetchedName: "Silo Media 2")

        XCTAssertEqual(reconnected?.displayName, "Lounge")
        XCTAssertEqual(device.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Lounge")
        XCTAssertEqual(device.registry.entry(with: Self.id(Self.publicURL))?.serverName, "Silo Media 2")
        // tvOS shares the saved list between Apple TV users; nicknames are not
        // theirs to see.
        let lastSaved = try XCTUnwrap(savedLists.last)
        XCTAssertEqual(lastSaved.first?.nickname, "Lounge")
        let encoded = try JSONEncoder().encode(lastSaved)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("Lounge"))
    }

    func testANameGivenOnOneDeviceReachesTheUsersOtherDevices() throws {
        let cloud = CloudStorage()
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")], cloud: cloud)
        let tv = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")], cloud: cloud)

        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")
        tv.cloudChanged()

        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Home")
        // A device set up later finds it at launch.
        let ipad = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")], cloud: cloud)
        XCTAssertEqual(ipad.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Home")
    }

    func testClearingTheNameReachesTheOtherDevicesToo() throws {
        let cloud = CloudStorage()
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")], cloud: cloud)
        let tv = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")], cloud: cloud)
        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")
        tv.cloudChanged()

        phone.registry.rename(serverId: Self.id(Self.publicURL), to: nil)
        tv.cloudChanged()

        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Silo")
    }

    func testAnOlderSyncedNameNeverReplacesANewerLocalOne() throws {
        let cloud = CloudStorage()
        let device = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")], cloud: cloud)
        device.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")

        cloud.records = [ServerNickname(
            serverId: Self.id(Self.publicURL), verifiedServerId: nil, name: "Old", updatedAt: .distantPast
        )]
        device.cloudChanged()

        XCTAssertEqual(device.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Home")
        // The newer local name is written back over the stale synced one.
        XCTAssertEqual(cloud.records.map(\.name), ["Home"])
    }

    /// iCloud keeps whichever device wrote last, so a rename made at the same
    /// moment on another device can vanish from the synced copy. The device
    /// that made it writes it back when it sees the change.
    func testTwoDevicesRenamingDifferentServersAtOnceBothKeepTheirNames() throws {
        let cloud = CloudStorage()
        let saved = [Self.entry(Self.publicURL, name: "Silo"), Self.entry(Self.otherURL, name: "Other")]
        let phone = try Device(saved: saved, cloud: cloud)
        let tv = try Device(saved: saved, cloud: cloud)

        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")
        let phoneWrite = cloud.records
        cloud.records = []
        tv.registry.rename(serverId: Self.id(Self.otherURL), to: "Work")
        XCTAssertNotEqual(cloud.records, phoneWrite)
        phone.cloudChanged()
        tv.cloudChanged()

        for device in [phone, tv] {
            XCTAssertEqual(device.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Home")
            XCTAssertEqual(device.registry.entry(with: Self.id(Self.otherURL))?.displayName, "Work")
        }
    }

    /// A device that saved the server at another address finds the name
    /// through the deployment identity, but an address with its own name keeps
    /// it, so "Home (LAN)" and "Home" can live side by side.
    func testANameFollowsTheServerToAnotherAddressUnlessThatAddressHasItsOwn() throws {
        let cloud = CloudStorage()
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)
        let tv = try Device(saved: [Self.entry(Self.lanURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)

        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")
        tv.cloudChanged()
        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.lanURL))?.displayName, "Home")

        tv.registry.rename(serverId: Self.id(Self.lanURL), to: "Home (LAN)")
        phone.cloudChanged()
        XCTAssertEqual(phone.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Home")
        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.lanURL))?.displayName, "Home (LAN)")
    }

    func testANameArrivesWhenTheServerReportsItsDeploymentIdentity() throws {
        let cloud = CloudStorage()
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)
        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")
        let tv = try Device(saved: [Self.entry(Self.lanURL, name: "Silo")], cloud: cloud)
        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.lanURL))?.displayName, "Silo")

        tv.registry.updateVerifiedServerId(for: Self.id(Self.lanURL), verifiedServerId: Self.deployment)

        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.lanURL))?.displayName, "Home")
    }

    func testRemovingAServerKeepsItsNameForTheUsersOtherDevicesAndForReAdding() async throws {
        let cloud = CloudStorage()
        let saved = [Self.entry(Self.otherURL, name: "Other"), Self.entry(Self.publicURL, name: "Silo")]
        let device = try Device(saved: saved, cloud: cloud)
        device.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")

        let removed = await device.registry.remove(serverId: Self.id(Self.publicURL))

        XCTAssertTrue(removed)
        XCTAssertEqual(cloud.records.map(\.name), ["Home"])
        let readded = device.registry.addOrUpdate(Self.entry(Self.publicURL, name: "Silo"))
        XCTAssertEqual(readded?.displayName, "Home")
    }

    /// The local names belong to the iCloud account they synced with; a new
    /// account on the device must not receive them.
    func testAnICloudAccountChangeNeverCarriesTheOldAccountsNamesAcross() throws {
        let cloud = CloudStorage()
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")], cloud: cloud)
        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")

        cloud.records = []
        phone.iCloudAccountChanged()

        XCTAssertEqual(phone.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Silo")
        XCTAssertTrue(cloud.records.isEmpty)
    }

    func testAnICloudAccountChangeTakesTheNewAccountsNames() throws {
        let cloud = CloudStorage()
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")], cloud: cloud)
        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")

        cloud.records = [ServerNickname(
            serverId: Self.id(Self.publicURL), verifiedServerId: nil, name: "Lounge", updatedAt: .distantPast
        )]
        phone.iCloudAccountChanged()

        XCTAssertEqual(phone.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Lounge")
        XCTAssertEqual(cloud.records.map(\.name), ["Lounge"])
    }

    /// Renamed before the server reported its deployment identity: the synced
    /// record gains the identity later, so another address of the server can
    /// still find the name.
    func testAnIdentityLearnedAfterARenameReachesTheServersOtherAddresses() throws {
        let cloud = CloudStorage()
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")], cloud: cloud)
        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")

        phone.registry.updateVerifiedServerId(for: Self.id(Self.publicURL), verifiedServerId: Self.deployment)
        let tv = try Device(saved: [Self.entry(Self.lanURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)

        XCTAssertEqual(cloud.records.first?.verifiedServerId, Self.deployment)
        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.lanURL))?.displayName, "Home")
    }

    /// A device that saved the address before learning its deployment
    /// identity renames it: the synced record keeps the identity it already
    /// had, so the server's other addresses still find the new name.
    func testARenameFromADeviceWithoutTheIdentityKeepsTheSyncedIdentity() throws {
        let cloud = CloudStorage()
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)
        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")
        let pad = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")], cloud: cloud)

        pad.registry.rename(serverId: Self.id(Self.publicURL), to: "Lounge")
        let tv = try Device(saved: [Self.entry(Self.lanURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)

        XCTAssertEqual(cloud.records.map(\.verifiedServerId), [Self.deployment])
        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.lanURL))?.displayName, "Lounge")
    }

    /// An address's own name, given while its sync was lost, survives a newer
    /// name for another address of the server and is written back.
    func testAnAddressesOwnNameSurvivesANewerNameForAnotherAddress() throws {
        let cloud = CloudStorage()
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)
        let tv = try Device(saved: [Self.entry(Self.lanURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)

        tv.registry.rename(serverId: Self.id(Self.lanURL), to: "Home (LAN)")
        cloud.records = []
        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")
        tv.cloudChanged()
        phone.cloudChanged()

        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.lanURL))?.displayName, "Home (LAN)")
        XCTAssertEqual(phone.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Home")
        XCTAssertEqual(Set(cloud.records.compactMap(\.name)), ["Home (LAN)", "Home"])
    }

    /// A name copied from another address is never published as this
    /// address's own, so the original rename keeps reaching it.
    func testACopiedNameFollowsLaterRenamesOfTheOriginalAddress() throws {
        let cloud = CloudStorage()
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)
        let tv = try Device(saved: [Self.entry(Self.lanURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)
        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")
        tv.cloudChanged()

        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Lounge")
        tv.cloudChanged()

        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.lanURL))?.displayName, "Lounge")
        XCTAssertEqual(cloud.records.map(\.serverId), [Self.id(Self.publicURL)])
    }

    /// Another device's clock runs an hour ahead. A rename here still wins
    /// over the name it gave, instead of being put back by the merge.
    func testARenameWinsOverANameStampedByAClockRunningAhead() throws {
        let cloud = CloudStorage()
        cloud.records = [ServerNickname(
            serverId: Self.id(Self.publicURL), verifiedServerId: nil, name: "Home", updatedAt: Date().addingTimeInterval(3600)
        )]
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")], cloud: cloud)

        XCTAssertTrue(phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Lounge"))

        XCTAssertEqual(phone.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Lounge")
        XCTAssertEqual(cloud.records.map(\.name), ["Lounge"])
    }

    /// Two devices rename one server at once after a name stamped by a clock
    /// running ahead, so both renames carry the same time. Once iCloud keeps
    /// one of them, the other device takes it instead of keeping its own.
    func testDevicesRenamingWithTheSameTimeAgreeOnTheNameICloudKeeps() throws {
        let ahead = ServerNickname(
            serverId: Self.id(Self.publicURL), verifiedServerId: nil, name: "Home", updatedAt: Date().addingTimeInterval(3600)
        )
        let phoneCloud = CloudStorage()
        let tvCloud = CloudStorage()
        phoneCloud.records = [ahead]
        tvCloud.records = [ahead]
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")], cloud: phoneCloud)
        let tv = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")], cloud: tvCloud)
        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Lounge")
        tv.registry.rename(serverId: Self.id(Self.publicURL), to: "Den")
        XCTAssertEqual(phoneCloud.records.map(\.updatedAt), tvCloud.records.map(\.updatedAt))

        tvCloud.records = phoneCloud.records
        tv.cloudChanged()

        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.publicURL))?.displayName, "Lounge")
    }

    /// An address that took another address's name later reports a different
    /// deployment: the copied name belonged to the old server and goes.
    func testACopiedNameGoesWhenTheAddressReportsAnotherDeployment() throws {
        let cloud = CloudStorage()
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)
        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")
        let tv = try Device(saved: [Self.entry(Self.lanURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)
        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.lanURL))?.displayName, "Home")

        tv.registry.updateVerifiedServerId(for: Self.id(Self.lanURL), verifiedServerId: "deployment-2")

        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.lanURL))?.displayName, "Silo")
    }

    /// Saving the prompt without changing it writes nothing, so a name the
    /// user later gives another address of the server still reaches this one.
    func testSavingTheUnchangedNameKeepsTakingTheServersOtherNames() throws {
        let cloud = CloudStorage()
        let phone = try Device(saved: [Self.entry(Self.publicURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)
        let tv = try Device(saved: [Self.entry(Self.lanURL, name: "Silo", deployment: Self.deployment)], cloud: cloud)

        XCTAssertTrue(tv.registry.rename(serverId: Self.id(Self.lanURL), to: ""))
        phone.registry.rename(serverId: Self.id(Self.publicURL), to: "Home")
        tv.cloudChanged()

        XCTAssertEqual(tv.registry.entry(with: Self.id(Self.lanURL))?.displayName, "Home")
        XCTAssertEqual(cloud.records.map(\.serverId), [Self.id(Self.publicURL)])
    }

    /// Other people's devices get the server's own name, never this user's
    /// nickname for it.
    func testTheNameSentToOtherDevicesIsNeverTheNickname() {
        var named = Self.entry(Self.publicURL, name: "Silo")
        named.nickname = "Home"
        var unnamed = Self.entry(Self.publicURL, name: nil)
        unnamed.nickname = "Home"

        XCTAssertEqual(named.sharedName, "Silo")
        XCTAssertEqual(unnamed.sharedName, Self.publicURL)
    }

    /// A named address proven to reach a saved server is merged into it at
    /// launch. With no iCloud store to bring the name back, it moves to the
    /// surviving entry with the address's other data.
    func testANameMovesWithAnAddressMergedAtLaunch() throws {
        let name = "ServerNicknameTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let accounts = AccountStore(keychain: keychain, defaults: defaults)
        let dropped = Self.entry(Self.lanURL, name: "Silo", deployment: Self.deployment)
        let survivor = Self.entry(Self.publicURL, name: "Silo", deployment: Self.deployment)
        let account = try accounts.saveSignIn(serverId: dropped.id, origin: dropped.url, serverUserId: "user",
                                              username: nil, accessToken: "access", refreshToken: nil,
                                              replacingOtherAccounts: false).account
        let stored = keychain.withAudience(.userIndependent)
        addTeardownBlock {
            _ = stored.delete(SharedStorage.accountIndexAccount)
            _ = stored.delete(SharedStorage.accountIndexBackupAccount)
            for server in [dropped.id, survivor.id] {
                _ = stored.delete(SharedStorage.accountRecordAccount(serverID: server, localAccountID: account.localAccountId))
            }
            UserDefaults().removePersistentDomain(forName: name)
        }
        defaults.set(true, forKey: ServerRegistry.migratedKey)
        defaults.set(try JSONEncoder().encode(SavedRegistry(activeServerId: survivor.id, entries: [dropped, survivor])),
                     forKey: ServerRegistry.defaultsKey)
        defaults.set(try JSONEncoder().encode([ServerNickname(
            serverId: dropped.id, verifiedServerId: Self.deployment, name: "Home", updatedAt: Date()
        )]), forKey: ServerRegistry.nicknamesKey)
        // The stored login-session proof that lets `init` merge offline.
        let proofsKey = "serverMerge.proofs.v1"
        let previousProofs = SharedDefaults.shared.data(forKey: proofsKey)
        addTeardownBlock {
            if let previousProofs {
                SharedDefaults.shared.set(previousProofs, forKey: proofsKey)
            } else {
                SharedDefaults.shared.removeObject(forKey: proofsKey)
            }
        }
        let epoch = try XCTUnwrap(account.epoch).uuidString
        let pair = ServerMerge.pairKey(dropped.id, survivor.id)
        SharedDefaults.shared.set(Data(#"{"\#(pair)":{"outcome":"proven","epochs":{"\#(account.localAccountId)":"\#(epoch)"},"provenAt":0}}"#.utf8),
                                  forKey: proofsKey)

        let registry = ServerRegistry(
            defaults: defaults,
            keychain: keychain,
            accounts: accounts,
            launchPreferences: ProfileLaunchPreferences(defaults: defaults),
            persistenceOverride: { _, _ in true }
        )

        XCTAssertEqual(registry.entries.map(\.id), [survivor.id], "the proven duplicate merged in init")
        XCTAssertEqual(registry.entry(with: survivor.id)?.displayName, "Home")

        // The moved name is a copy, so it goes once the address reports
        // another deployment, without an iCloud store too.
        XCTAssertTrue(registry.updateVerifiedServerId(for: survivor.id, verifiedServerId: "deployment-2"))
        XCTAssertEqual(registry.entry(with: survivor.id)?.displayName, "Silo")
    }

    func testANameIsCutToTheLengthLimit() throws {
        let device = try Device(saved: [Self.entry(Self.publicURL, name: "Silo")])

        device.registry.rename(serverId: Self.id(Self.publicURL), to: String(repeating: "a", count: 200))

        XCTAssertEqual(device.registry.entry(with: Self.id(Self.publicURL))?.nickname?.count, ServerNickname.lengthLimit)
    }

    // MARK: - Helpers

    private static func id(_ url: String) -> String { ServerRegistry.serverId(for: url) }

    private static func entry(_ url: String, name: String?, deployment: String? = nil) -> ServerEntry {
        ServerEntry(id: id(url), url: url, fetchedName: name, lastUsedAt: Date(), verifiedServerId: deployment)
    }

    /// One device: its own defaults and Keychain, and the user's shared
    /// iCloud storage when given one.
    private final class Device {
        let registry: ServerRegistry
        private let cloud: FakeNicknameCloud?
        private let defaults: SharedDefaults
        private let keychain: SharedKeychain
        private let suiteName = "ServerNicknameTests.\(UUID().uuidString)"

        init(
            saved: [ServerEntry],
            cloud storage: CloudStorage? = nil,
            onPersist: @escaping ([ServerEntry]) -> Void = { _ in }
        ) throws {
            let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defaults = SharedDefaults(suite: suite, standard: suite)
            keychain = SharedKeychain(service: suiteName, accessGroup: nil)
            defaults.set(true, forKey: ServerRegistry.migratedKey)
            defaults.set(
                try JSONEncoder().encode(SavedRegistry(activeServerId: saved.first?.id, entries: saved)),
                forKey: ServerRegistry.defaultsKey
            )
            cloud = storage.map(FakeNicknameCloud.init)
            registry = Self.makeRegistry(defaults: defaults, keychain: keychain, cloud: cloud, onPersist: onPersist)
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        /// Another device changed the synced copy.
        func cloudChanged() { cloud?.onExternalChange?(false) }

        /// The device's iCloud account changed; the store now holds the new
        /// account's records.
        func iCloudAccountChanged() { cloud?.onExternalChange?(true) }

        /// The same device after the app restarts, with no iCloud.
        func relaunched() -> ServerRegistry {
            Self.makeRegistry(defaults: defaults, keychain: keychain, cloud: nil, onPersist: { _ in })
        }

        private static func makeRegistry(
            defaults: SharedDefaults,
            keychain: SharedKeychain,
            cloud: FakeNicknameCloud?,
            onPersist: @escaping ([ServerEntry]) -> Void
        ) -> ServerRegistry {
            let tokenStore = TokenStore(keychain: keychain, defaults: defaults)
            return ServerRegistry(
                defaults: defaults,
                keychain: keychain,
                launchPreferences: ProfileLaunchPreferences(defaults: defaults),
                persistenceOverride: { entries, _ in
                    onPersist(entries)
                    return true
                },
                tokenStore: tokenStore,
                httpClient: HTTPClient(session: APIv2TestStub().makeSession(), tokenStore: tokenStore),
                nicknameCloud: cloud,
                unregisterPush: { _ in },
                restorePush: { _ in }
            )
        }
    }
}

/// The synced copy one user's devices share.
private final class CloudStorage {
    var records: [ServerNickname] = []
}

private final class FakeNicknameCloud: ServerNicknameCloud {
    let storage: CloudStorage
    var onExternalChange: ((_ accountChanged: Bool) -> Void)?

    init(storage: CloudStorage) { self.storage = storage }

    func load() -> [ServerNickname] { storage.records }
    func save(_ records: [ServerNickname]) { storage.records = records }
}

/// The registry's saved shape.
private struct SavedRegistry: Encodable {
    var activeServerId: String?
    var entries: [ServerEntry]
}

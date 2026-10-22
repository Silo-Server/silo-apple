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
        func cloudChanged() { cloud?.onExternalChange?() }

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
    var onExternalChange: (() -> Void)?

    init(storage: CloudStorage) { self.storage = storage }

    func load() -> [ServerNickname] { storage.records }
    func save(_ records: [ServerNickname]) { storage.records = records }
}

/// The registry's saved shape.
private struct SavedRegistry: Encodable {
    var activeServerId: String?
    var entries: [ServerEntry]
}

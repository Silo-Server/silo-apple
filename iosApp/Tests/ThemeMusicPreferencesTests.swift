import XCTest
@testable import Silo

/// `ui.theme_music_enabled` and `ui.theme_music_loop`: opt-in, read from the
/// server's effective answer and written as this device's choice.
@MainActor
final class ThemeMusicPreferencesTests: XCTestCase {
    var transport: FakeThemeMusicTransport!
    var identity: HTTPRequestIdentity? = ThemeMusicPreferencesTests.profileA

    static let profileA = HTTPRequestIdentity(
        serverId: "server-1", serverURL: "https://silo.example", profileId: "profile-a", clientFamily: "mobile")
    static let profileB = HTTPRequestIdentity(
        serverId: "server-1", serverURL: "https://silo.example", profileId: "profile-b", clientFamily: "mobile")

    override func setUp() async throws {
        try await super.setUp()
        transport = FakeThemeMusicTransport()
        identity = Self.profileA
    }

    func makeStore() -> ThemeMusicPreferences {
        ThemeMusicPreferences(transport: transport, requestIdentity: { [unowned self] in self.identity })
    }

    func testThemeMusicStaysOffAndUnofferedUntilTheServerAnswers() {
        let store = makeStore()
        XCTAssertFalse(store.playsThemeMusic)
        XCTAssertFalse(store.loops)
        XCTAssertFalse(store.isOffered)
    }

    func testAnOlderServerNeverOffersItOrReadsIt() async {
        transport.manifestRevision = 10
        let store = makeStore()
        await store.refresh()

        XCTAssertFalse(store.isOffered)
        XCTAssertFalse(store.playsThemeMusic)
        XCTAssertEqual(transport.effectiveReads, 0)
    }

    func testTheServersEffectiveAnswerDrivesBothSwitches() async {
        transport.stored = [.uiThemeMusicEnabled: (true, "profile"), .uiThemeMusicLoop: (true, "profile_device")]
        let store = makeStore()
        await store.refresh()

        XCTAssertTrue(store.isOffered)
        XCTAssertTrue(store.allowsEditing)
        XCTAssertTrue(store.playsThemeMusic)
        XCTAssertTrue(store.loops)
        XCTAssertEqual(Set(transport.requestedKeys), [.uiThemeMusicEnabled, .uiThemeMusicLoop])
    }

    func testTheContractDefaultIsOff() async {
        let store = makeStore()
        await store.refresh()

        XCTAssertTrue(store.isOffered)
        XCTAssertFalse(store.playsThemeMusic)
        XCTAssertFalse(store.loops)
    }

    func testSwitchesWriteThisDevicesChoice() async {
        // A device value wins over the profile's, so it is what makes the
        // switch take effect here whatever the profile chose elsewhere.
        transport.stored = [.uiThemeMusicEnabled: (false, "profile")]
        let store = makeStore()
        await store.refresh()

        store.setEnabled(true)
        XCTAssertTrue(store.playsThemeMusic, "the switch answers at once")
        store.setLoop(true)
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.writes.map(\.key), [.uiThemeMusicEnabled, .uiThemeMusicLoop])
        XCTAssertEqual(transport.writes.map(\.scope), [.profileDevice, .profileDevice])
        XCTAssertEqual(transport.writes.map(\.value), [true, true])
        XCTAssertTrue(store.playsThemeMusic)
        XCTAssertTrue(store.loops)
        XCTAssertNil(store.errorMessage)
    }

    func testAFailedWriteRestoresTheSavedChoiceAndSaysSo() async {
        let store = makeStore()
        await store.refresh()
        transport.putError = SettingsAPIError.server(status: 503, code: "unavailable", message: "busy")

        store.setEnabled(true)
        await store.waitForPendingWrites()

        XCTAssertFalse(store.playsThemeMusic)
        XCTAssertNotNil(store.errorMessage)
    }

    func testAnotherProfileNeverPlaysOnThePreviousProfilesChoice() async {
        transport.stored = [.uiThemeMusicEnabled: (true, "profile")]
        let store = makeStore()
        await store.refresh()
        XCTAssertTrue(store.playsThemeMusic)

        identity = Self.profileB

        XCTAssertFalse(store.playsThemeMusic)
        XCTAssertFalse(store.allowsEditing)
    }
}

@MainActor
extension ThemeMusicPreferencesTests {
    func testAWriteStillInFlightDoesNotKeepTheNextProfileFromReading() async {
        let store = makeStore()
        await store.refresh()
        transport.holdNextPut = true
        store.setEnabled(true)
        while transport.heldPut == nil { await Task.yield() }

        identity = Self.profileB
        transport.stored = [.uiThemeMusicEnabled: (true, "profile")]
        await store.refresh()

        XCTAssertTrue(store.isOffered)
        XCTAssertTrue(store.playsThemeMusic, "profile B reads its own answer")
        transport.heldPut?.resume()
        await store.waitForPendingWrites()
    }
}

@MainActor
final class FakeThemeMusicTransport: TitleArtTransport, @unchecked Sendable {
    struct Write: Equatable {
        let key: SettingKey
        let scope: SettingScope
        let value: Bool
    }

    var manifestRevision = 18
    var stored: [SettingKey: (value: Bool, source: String)] = [:]
    var putError: Error?
    /// Holds the next write until opened, so a test can switch profiles meanwhile.
    var holdNextPut = false
    private(set) var heldPut: CheckedContinuation<Void, Never>?
    private(set) var effectiveReads = 0
    private(set) var requestedKeys: [SettingKey] = []
    private(set) var writes: [Write] = []

    nonisolated func contractCapabilities(requestIdentity: HTTPRequestIdentity) async -> SettingsCapabilitiesResult {
        await MainActor.run {
            .available(APIv2SettingsContractCapabilities(
                revision: "capabilities-\(manifestRevision)", state: "available", allowed: true,
                manifestRevision: manifestRevision, clientFamilies: ["tv", "mobile", "tablet", "desktop", "web"],
                supportsBatchedEffective: true))
        }
    }

    nonisolated func effectiveValues(keys: [SettingKey], requestIdentity: HTTPRequestIdentity) async throws -> EffectiveSettingValuesResponse {
        try await MainActor.run {
            effectiveReads += 1
            requestedKeys = keys
            let rows: [[String: Any]] = keys.map { key in
                let entry = stored[key] ?? (false, "default")
                return ["key": key.rawValue, "value": entry.value, "source": entry.source]
            }
            let data = try JSONSerialization.data(withJSONObject: ["items": rows, "revision": manifestRevision])
            return try SettingsWireCoding.makeDecoder().decode(EffectiveSettingValuesResponse.self, from: data)
        }
    }

    nonisolated func putValue(key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue,
                              requestIdentity: HTTPRequestIdentity) async throws {
        if await MainActor.run(body: { holdNextPut }) {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    holdNextPut = false
                    heldPut = continuation
                }
            }
        }
        try await MainActor.run {
            guard case .bool(let flag) = value else { return XCTFail("unexpected value \(value)") }
            writes.append(Write(key: key, scope: scope.scope, value: flag))
            if let putError { throw putError }
            stored[key] = (flag, scope.scope == .profile ? "profile" : "profile_device")
        }
    }

    nonisolated func deleteValue(key: SettingKey, scope: SettingScopeIdentity,
                                 requestIdentity: HTTPRequestIdentity) async throws {
        await MainActor.run { XCTFail("theme music never clears a scope") }
    }
}

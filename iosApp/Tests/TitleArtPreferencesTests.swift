import XCTest
import Observation
@testable import Silo

final class TitleArtWritePlanTests: XCTestCase {
    private let perDevice = TitleArtSetting(showTitleArt: true, appliesToAllDevices: false)
    private let allDevices = TitleArtSetting(showTitleArt: false, appliesToAllDevices: true)

    func testMainSwitchWritesThisDeviceWhileNotApplyingToAllDevices() {
        XCTAssertEqual(
            TitleArtWritePlan.steps(from: perDevice, showTitleArt: false),
            [.put(scope: .profileDevice, value: false)]
        )
    }

    func testMainSwitchWritesTheProfileWhileApplyingToAllDevices() {
        XCTAssertEqual(
            TitleArtWritePlan.steps(from: allDevices, showTitleArt: true),
            [.put(scope: .profile, value: true)]
        )
    }

    func testTurningApplyToAllDevicesOnWritesTheCurrentValueAtProfile() {
        XCTAssertEqual(
            TitleArtWritePlan.steps(from: perDevice, appliesToAllDevices: true),
            [.put(scope: .profile, value: true)]
        )
    }

    func testTurningApplyToAllDevicesOffPinsThisDeviceBeforeClearingTheProfile() {
        XCTAssertEqual(
            TitleArtWritePlan.steps(from: allDevices, appliesToAllDevices: false),
            [.put(scope: .profileDevice, value: false), .clear(scope: .profile)]
        )
    }

    func testAnUnchangedApplyToAllDevicesChoiceWritesNothing() {
        XCTAssertEqual(TitleArtWritePlan.steps(from: perDevice, appliesToAllDevices: false), [])
        XCTAssertEqual(TitleArtWritePlan.steps(from: allDevices, appliesToAllDevices: true), [])
    }

    func testTheEffectiveSourceDecidesApplyToAllDevices() throws {
        let profile = try titleArtResponse(value: false, source: "profile")
        XCTAssertEqual(
            TitleArtSetting(effective: profile.value(for: .uiTitleArt)),
            TitleArtSetting(showTitleArt: false, appliesToAllDevices: true)
        )
        let device = try titleArtResponse(value: false, source: "profile_device")
        XCTAssertEqual(
            TitleArtSetting(effective: device.value(for: .uiTitleArt)),
            TitleArtSetting(showTitleArt: false, appliesToAllDevices: false)
        )
        let unset = try titleArtResponse(value: true, source: "default")
        XCTAssertEqual(TitleArtSetting(effective: unset.value(for: .uiTitleArt)), .contractDefault)
        XCTAssertEqual(TitleArtSetting(effective: nil), .contractDefault)
    }
}

@MainActor
final class TitleArtPreferencesTests: XCTestCase {
    private var suiteName = ""
    private var suite: UserDefaults!
    private var defaults: SharedDefaults!
    private var transport: FakeTitleArtTransport!
    private var identity: HTTPRequestIdentity? = TitleArtPreferencesTests.profileA

    private static let profileA = HTTPRequestIdentity(
        serverId: "server-1",
        serverURL: "https://silo.example",
        profileId: "profile-a",
        clientFamily: "mobile"
    )
    private static let profileB = HTTPRequestIdentity(
        serverId: "server-1",
        serverURL: "https://silo.example",
        profileId: "profile-b",
        clientFamily: "mobile"
    )

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "title-art-tests-\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults = SharedDefaults(suite: suite, standard: suite)
        transport = FakeTitleArtTransport()
        identity = Self.profileA
    }

    override func tearDown() async throws {
        suite.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeStore() -> TitleArtPreferences {
        TitleArtPreferences(
            defaults: defaults,
            transport: transport,
            requestIdentity: { [unowned self] in self.identity }
        )
    }

    func testBeforeAnyAnswerLogosShowAndNothingIsOffered() {
        let store = makeStore()
        XCTAssertTrue(store.showsTitleArt)
        XCTAssertFalse(store.appliesToAllDevices)
        XCTAssertFalse(store.isOffered)
        XCTAssertFalse(store.allowsEditing)
    }

    func testAnOlderServerKeepsLogosAndNeverReadsOrWrites() async {
        transport.capabilities = .available(titleArtCapabilities(revision: 15))
        let store = makeStore()
        await store.refresh()

        XCTAssertEqual(store.syncState, .serverUpgradeRequired)
        XCTAssertTrue(store.showsTitleArt)
        XCTAssertFalse(store.isOffered)
        XCTAssertEqual(transport.effectiveReads, 0)

        store.setShowTitleArt(false)
        await store.waitForPendingWrites()
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertTrue(store.showsTitleArt)
    }

    func testTheServersEffectiveAnswerDrivesTheDisplay() async {
        transport.effective = (false, "profile_device")
        let store = makeStore()
        await store.refresh()

        XCTAssertEqual(store.syncState, .supported)
        XCTAssertTrue(store.isOffered)
        XCTAssertTrue(store.allowsEditing)
        XCTAssertFalse(store.showsTitleArt)
        XCTAssertFalse(store.appliesToAllDevices)
        XCTAssertEqual(transport.requestedKeys, [.uiTitleArt])
    }

    func testTheMainSwitchWritesThisDeviceByDefault() async {
        let store = makeStore()
        await store.refresh()

        store.setShowTitleArt(false)
        XCTAssertFalse(store.showsTitleArt, "the change shows before the write returns")
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.calls, [.put(.profileDevice, false)])
        XCTAssertEqual(transport.identities, [Self.profileA])
        XCTAssertNil(store.errorMessage)
    }

    func testTheMainSwitchWritesTheProfileWhileApplyingToAllDevices() async {
        transport.effective = (true, "profile")
        let store = makeStore()
        await store.refresh()
        XCTAssertTrue(store.appliesToAllDevices)

        store.setShowTitleArt(false)
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.calls, [.put(.profile, false)])
        XCTAssertFalse(store.showsTitleArt)
        XCTAssertTrue(store.appliesToAllDevices)
    }

    func testTurningApplyToAllDevicesOnWritesTheCurrentValueAtProfile() async {
        transport.effective = (false, "profile_device")
        let store = makeStore()
        await store.refresh()

        store.setAppliesToAllDevices(true)
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.calls, [.put(.profile, false)])
        XCTAssertTrue(store.appliesToAllDevices)
        XCTAssertFalse(store.showsTitleArt)
    }

    func testTurningApplyToAllDevicesOffPinsThisDeviceThenClearsTheProfile() async {
        transport.effective = (false, "profile")
        let store = makeStore()
        await store.refresh()

        store.setAppliesToAllDevices(false)
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.calls, [.put(.profileDevice, false), .delete(.profile)])
        XCTAssertFalse(store.appliesToAllDevices)
        XCTAssertFalse(store.showsTitleArt, "this device keeps its look")
        XCTAssertNil(store.errorMessage)
    }

    func testAnAlreadyClearProfileValueCountsAsCleared() async {
        transport.effective = (true, "profile")
        transport.deleteError = SettingsAPIError.noValueAtScope
        let store = makeStore()
        await store.refresh()

        store.setAppliesToAllDevices(false)
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.calls, [.put(.profileDevice, true), .delete(.profile)])
        XCTAssertFalse(store.appliesToAllDevices)
        XCTAssertNil(store.errorMessage)
    }

    func testAFailedClearRollsBackToApplyingToAllDevices() async {
        transport.effective = (false, "profile")
        transport.deleteError = SettingsAPIError.server(status: 500, code: "internal", message: "boom")
        let store = makeStore()
        await store.refresh()

        store.setAppliesToAllDevices(false)
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.calls, [.put(.profileDevice, false), .delete(.profile)])
        XCTAssertTrue(store.appliesToAllDevices)
        XCTAssertNotNil(store.errorMessage)
    }

    func testAFailedDeviceWriteNeverClearsTheProfile() async {
        transport.effective = (false, "profile")
        transport.putError = SettingsAPIError.transport(description: "offline")
        let store = makeStore()
        await store.refresh()

        store.setAppliesToAllDevices(false)
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.calls, [.put(.profileDevice, false)])
        XCTAssertTrue(store.appliesToAllDevices)
        XCTAssertNotNil(store.errorMessage)
    }

    func testAFailedMainSwitchWriteRollsBack() async {
        transport.putError = SettingsAPIError.server(status: 500, code: "internal", message: "boom")
        let store = makeStore()
        await store.refresh()

        store.setShowTitleArt(false)
        await store.waitForPendingWrites()

        XCTAssertTrue(store.showsTitleArt)
        XCTAssertNotNil(store.errorMessage)
    }

    func testAConfirmedAnswerPaintsTheNextLaunchBeforeAnyRead() async {
        transport.effective = (false, "profile_device")
        await makeStore().refresh()

        transport.capabilities = .failed(.transport(description: "offline"))
        let relaunched = makeStore()
        XCTAssertFalse(relaunched.showsTitleArt, "cold start reads the cache")
        await relaunched.refresh()
        XCTAssertEqual(relaunched.syncState, .unavailable)
        XCTAssertFalse(relaunched.showsTitleArt, "a failed probe keeps the last answer")
        XCTAssertTrue(relaunched.isOffered)
        XCTAssertFalse(relaunched.allowsEditing)
    }

    func testAServerDowngradeDropsTheCachedAnswer() async {
        transport.effective = (false, "profile_device")
        let store = makeStore()
        await store.refresh()
        XCTAssertFalse(store.showsTitleArt)

        transport.capabilities = .available(titleArtCapabilities(revision: 14))
        await store.refresh()
        XCTAssertTrue(store.showsTitleArt)
        XCTAssertFalse(store.isOffered)
        XCTAssertTrue(makeStore().showsTitleArt, "the cache is gone too")
    }

    func testProfilesDoNotShareAnAnswer() async {
        transport.effective = (false, "profile_device")
        let store = makeStore()
        await store.refresh()
        XCTAssertFalse(store.showsTitleArt)

        identity = Self.profileB
        XCTAssertTrue(store.showsTitleArt, "a switch never shows the previous profile's choice")

        transport.effective = (true, "default")
        await store.refresh()
        XCTAssertTrue(store.showsTitleArt)

        identity = Self.profileA
        XCTAssertFalse(store.showsTitleArt, "profile A's cached answer comes back")
    }

    /// Review P1: all devices on, then quickly "Apply to All Devices" off and
    /// "Show Title Art" off. The clear fails after the device pin landed, so
    /// the profile value still wins on the server. The queued main-switch write
    /// was planned for a per-device state that never happened and must not be
    /// sent, and nothing the server did not resolve may reach the cache.
    func testAFailedChangeDropsTheChangesQueuedBehindItAndRereadsTheServer() async {
        transport.effective = (true, "profile")
        transport.deleteError = SettingsAPIError.server(status: 503, code: "unavailable", message: "busy")
        let store = makeStore()
        await store.refresh()
        let readsBefore = transport.effectiveReads

        store.setAppliesToAllDevices(false)
        store.setShowTitleArt(false)
        XCTAssertFalse(store.showsTitleArt, "both choices show while in flight")
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.calls, [.put(.profileDevice, true), .delete(.profile)])
        XCTAssertEqual(transport.effectiveReads, readsBefore + 1, "the server answer is re-read")
        XCTAssertTrue(store.showsTitleArt)
        XCTAssertTrue(store.appliesToAllDevices)
        XCTAssertNotNil(store.errorMessage)

        transport.capabilities = .failed(.transport(description: "offline"))
        let relaunched = makeStore()
        XCTAssertTrue(relaunched.showsTitleArt, "the cache holds what the server resolves")
        XCTAssertTrue(relaunched.appliesToAllDevices)

        // The next choice is planned from the server's answer: profile scope.
        transport.deleteError = nil
        store.setShowTitleArt(false)
        await store.waitForPendingWrites()
        XCTAssertEqual(transport.calls.last, .put(.profile, false))
    }

    /// Review P2: a view that read the value while another profile's answer
    /// was still loaded must be invalidated when the refresh adopts the new
    /// profile.
    func testAViewThatReadTheSwitchedProfilesCacheUpdatesAfterItsRefresh() async {
        let store = makeStore()
        await store.refresh()
        XCTAssertTrue(store.showsTitleArt)

        identity = Self.profileB
        let invalidated = ObservationFlag()
        withObservationTracking {
            _ = store.showsTitleArt
        } onChange: {
            invalidated.fired = true
        }
        XCTAssertTrue(store.showsTitleArt)

        transport.effective = (false, "profile")
        await store.refresh()
        XCTAssertTrue(invalidated.fired)
        XCTAssertFalse(store.showsTitleArt)
    }

    func testAChangeThatLandsAfterAProfileSwitchStillReachesItsProfilesCache() async {
        transport.effective = (true, "default")
        let store = makeStore()
        await store.refresh()

        transport.onPut = { [unowned self] in self.identity = Self.profileB }
        store.setShowTitleArt(false)
        await store.waitForPendingWrites()

        identity = Self.profileA
        XCTAssertFalse(makeStore().showsTitleArt, "profile A's next launch shows its saved choice")
    }

    /// Kody K1: profile A's failed write must only drop changes planned on
    /// A's state. A change queued for profile B after the switch still runs.
    func testAFailedWriteForOneProfileDoesNotDropAnotherProfilesChange() async {
        let gate = WriteGate()
        transport.writeGate = gate
        let store = makeStore()
        await store.refresh()
        store.setShowTitleArt(false)

        identity = Self.profileB
        await store.refresh()
        store.setShowTitleArt(false)

        transport.failingProfiles = [Self.profileA.profileId]
        gate.open()
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.calls, [.put(.profileDevice, false), .put(.profileDevice, false)])
        XCTAssertEqual(transport.identities, [Self.profileA, Self.profileB])
        XCTAssertFalse(store.showsTitleArt)
        transport.capabilities = .failed(.transport(description: "offline"))
        XCTAssertFalse(makeStore().showsTitleArt, "profile B's change reached its cache")
    }

    /// Kody K2: switching A -> B -> A while A's write is pending repaints A's
    /// older cache and the refresh skips its read; the write landing must put
    /// A's choice back on screen.
    func testSwitchingBackWhileAWriteIsPendingShowsItOnceItLands() async {
        let gate = WriteGate()
        transport.writeGate = gate
        let store = makeStore()
        await store.refresh()
        store.setShowTitleArt(false)

        identity = Self.profileB
        await store.refresh()
        identity = Self.profileA
        await store.refresh()
        XCTAssertTrue(store.showsTitleArt, "A's older cache is back while its write is pending")

        gate.open()
        await store.waitForPendingWrites()
        XCTAssertFalse(store.showsTitleArt)
    }

    func testAReadThatRacesAChangeDoesNotUndoIt() async {
        transport.effective = (true, "default")
        let store = makeStore()
        await store.refresh()

        transport.onCapabilityProbe = { store.setShowTitleArt(false) }
        await store.refresh()
        await store.waitForPendingWrites()

        XCTAssertFalse(store.showsTitleArt)
    }
}

// MARK: - Support

private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
private final class WriteGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private func titleArtCapabilities(revision: Int) -> APIv2SettingsContractCapabilities {
    APIv2SettingsContractCapabilities(
        revision: "capabilities-\(revision)",
        state: "available",
        allowed: true,
        manifestRevision: revision,
        clientFamilies: ["tv", "mobile", "tablet", "desktop", "web"],
        supportsBatchedEffective: true,
        supportsAtomicShortcuts: true
    )
}

private func titleArtResponse(
    value: Bool,
    source: String,
    revision: Int = 16
) throws -> EffectiveSettingValuesResponse {
    let row: [String: Any] = ["key": "ui.title_art", "value": value, "source": source]
    let data = try JSONSerialization.data(withJSONObject: ["items": [row], "revision": revision])
    return try SettingsWireCoding.makeDecoder().decode(EffectiveSettingValuesResponse.self, from: data)
}

@MainActor
private final class FakeTitleArtTransport: TitleArtTransport, @unchecked Sendable {
    enum Call: Equatable {
        case put(SettingScope, Bool)
        case delete(SettingScope)
    }

    var capabilities: SettingsCapabilitiesResult = .available(titleArtCapabilities(revision: 16))
    var effective: (value: Bool, source: String) = (true, "default")
    var putError: Error?
    /// Profiles whose writes fail; other profiles' writes succeed.
    var failingProfiles: Set<String> = []
    /// Holds every write until opened, so a test can switch profiles while a
    /// write is in flight.
    var writeGate: WriteGate?
    var deleteError: Error?
    /// Runs inside the capability probe, while a refresh waits on it.
    var onCapabilityProbe: (@MainActor () -> Void)?
    /// Runs inside the next write, before it answers.
    var onPut: (@MainActor () -> Void)?

    private(set) var effectiveReads = 0
    private(set) var requestedKeys: [SettingKey] = []
    private(set) var calls: [Call] = []
    private(set) var identities: [HTTPRequestIdentity] = []

    nonisolated func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        await MainActor.run {
            let hook = onCapabilityProbe
            onCapabilityProbe = nil
            hook?()
            return capabilities
        }
    }

    nonisolated func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        try await MainActor.run {
            effectiveReads += 1
            requestedKeys = keys
            return try titleArtResponse(value: effective.value, source: effective.source)
        }
    }

    nonisolated func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        if let gate = await MainActor.run(body: { writeGate }) {
            await gate.wait()
        }
        try await MainActor.run {
            guard key == .uiTitleArt, case .bool(let flag) = value else {
                XCTFail("unexpected write \(key) \(value)")
                return
            }
            calls.append(.put(scope.scope, flag))
            identities.append(requestIdentity)
            let hook = onPut
            onPut = nil
            hook?()
            if let putError { throw putError }
            if failingProfiles.contains(requestIdentity.profileId) {
                throw SettingsAPIError.server(status: 503, code: "unavailable", message: "busy")
            }
        }
    }

    nonisolated func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        try await MainActor.run {
            XCTAssertEqual(key, .uiTitleArt)
            calls.append(.delete(scope.scope))
            identities.append(requestIdentity)
            if let deleteError { throw deleteError }
        }
    }
}

#if !os(tvOS)
final class PhoneHeroEyebrowTests: XCTestCase {
    func testMoviesNameTheirFirstStudioAndSeriesTheirFirstNetwork() throws {
        let movie = try detail(#""type":"movie","studios":["  ","Marvel Studios","Disney"]"#)
        XCTAssertEqual(PhoneHeroMetadata.titleEyebrow(from: movie)?.text, "MOVIE \u{00B7} MARVEL STUDIOS")

        let series = try detail(#""type":"series","networks":["HBO"],"studios":["Bighead"]"#)
        XCTAssertEqual(PhoneHeroMetadata.titleEyebrow(from: series)?.text, "SERIES \u{00B7} HBO")
    }

    func testWithoutAProviderOnlyTheTypeShows() throws {
        let movie = try detail(#""type":"movie""#)
        XCTAssertEqual(PhoneHeroMetadata.titleEyebrow(from: movie), PhoneHeroEyebrow(kind: "Movie", provider: nil))
        XCTAssertEqual(PhoneHeroMetadata.titleEyebrow(from: movie)?.text, "MOVIE")
    }

    func testEpisodesKeepTheirSeriesNameInsteadOfATypeLine() throws {
        let episode = try detail(#""type":"episode","series_title":"Severance","networks":["Apple TV+"]"#)
        XCTAssertNil(PhoneHeroMetadata.titleEyebrow(from: episode))
        XCTAssertEqual(PhoneHeroMetadata.episodeEyebrow(from: episode), "Severance")
    }

    func testOtherKindsHaveNoTitleEyebrow() throws {
        XCTAssertNil(PhoneHeroMetadata.titleEyebrow(from: try detail(#""type":"audiobook""#)))
    }

    private func detail(_ fields: String) throws -> ItemDetail {
        let json = #"{"content_id":"x","title":"T","# + fields + "}"
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ItemDetail.self, from: Data(json.utf8))
    }
}
#endif

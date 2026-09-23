import XCTest
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import Silo

// MARK: - Contract helpers

final class SeekIntervalContractTests: XCTestCase {
    func testResolveFallsBackToTheDefaultForMissingOrInvalidValues() {
        XCTAssertEqual(SeekIntervalContract.resolve(nil, direction: .backward), 10)
        XCTAssertEqual(SeekIntervalContract.resolve(nil, direction: .forward), 30)
        XCTAssertEqual(SeekIntervalContract.resolve(.null, direction: .forward), 30)
        XCTAssertEqual(SeekIntervalContract.resolve(.string("15"), direction: .backward), 10)
        XCTAssertEqual(SeekIntervalContract.resolve(.double(15.5), direction: .backward), 10)
        XCTAssertEqual(SeekIntervalContract.resolve(.int(20), direction: .forward), 30)
        XCTAssertEqual(SeekIntervalContract.resolve(.int(0), direction: .backward), 10)
        XCTAssertEqual(SeekIntervalContract.resolve(.int(-10), direction: .backward), 10)
    }

    func testResolveKeepsEveryContractChoice() {
        for seconds in SeekIntervalContract.choices {
            XCTAssertEqual(SeekIntervalContract.resolve(.int(seconds), direction: .backward), seconds)
            XCTAssertEqual(SeekIntervalContract.resolve(.int(seconds), direction: .forward), seconds)
        }
        // A whole-number double is still the integer the contract declared.
        XCTAssertEqual(SeekIntervalContract.resolve(.double(45), direction: .forward), 45)
    }

    func testResolveResponseMapsEachKeyAndDefaultsTheRest() throws {
        let response = try effectiveResponse([
            "player.video_skip_back_seconds": 5,
            "player.video_skip_forward_seconds": 90,
            "player.audiobook_skip_back_seconds": 17,
        ])
        let values = SeekIntervalContract.resolve(response)
        XCTAssertEqual(values.video, SeekIntervalPair(backward: 5, forward: 90))
        XCTAssertEqual(values.audiobook, SeekIntervalPair(backward: 10, forward: 30))
    }

    func testEmptyResponseResolvesToTheContractDefaults() throws {
        let values = SeekIntervalContract.resolve(try effectiveResponse([:]))
        XCTAssertEqual(values, .contractDefaults)
        XCTAssertEqual(values.video, SeekIntervalPair(backward: 10, forward: 30))
    }

    func testEachMediaAndDirectionHasItsOwnKey() {
        XCTAssertEqual(SeekIntervalContract.key(.video, .backward).rawValue, "player.video_skip_back_seconds")
        XCTAssertEqual(SeekIntervalContract.key(.video, .forward).rawValue, "player.video_skip_forward_seconds")
        XCTAssertEqual(SeekIntervalContract.key(.audiobook, .backward).rawValue, "player.audiobook_skip_back_seconds")
        XCTAssertEqual(SeekIntervalContract.key(.audiobook, .forward).rawValue, "player.audiobook_skip_forward_seconds")
        XCTAssertEqual(Set(SeekIntervalContract.keys).count, 4)
    }

    func testRevisionNineServersSupportTheKeys() {
        XCTAssertTrue(SeekIntervalContract.isSupported(by: seekCapabilities(revision: 9)))
        XCTAssertTrue(SeekIntervalContract.isSupported(by: seekCapabilities(revision: 10)))
    }

    func testOlderOrIncompleteServersDoNotSupportTheKeys() {
        XCTAssertFalse(SeekIntervalContract.isSupported(by: seekCapabilities(revision: 8)))
        XCTAssertFalse(SeekIntervalContract.isSupported(by: seekCapabilities(revision: 5)))
        XCTAssertFalse(SeekIntervalContract.isSupported(by: seekCapabilities(revision: 9, batchedEffective: false)))
        XCTAssertFalse(SeekIntervalContract.isSupported(by: seekCapabilities(revision: 9, state: "disabled")))
        XCTAssertFalse(SeekIntervalContract.isSupported(by: seekCapabilities(revision: 9, allowed: false)))
    }

    func testEveryChoiceAndLegacyIntervalHasANumberedSymbol() {
        var seconds = Set(SeekIntervalContract.choices)
        for surface in [
            SeekIntervalSurface.videoPlayer, .videoSystemControls, .videoRemoteControl, .audiobook,
        ] {
            seconds.insert(surface.legacy.backward)
            seconds.insert(surface.legacy.forward)
        }
        for value in seconds {
            for direction in SeekDirection.allCases {
                let name = SeekIntervalLabel.symbolName(direction, seconds: value)
                XCTAssertTrue(name.hasSuffix(".\(value)"), "\(name) is not numbered")
                XCTAssertTrue(symbolExists(name), "SF Symbol \(name) is missing")
            }
        }
        XCTAssertEqual(SeekIntervalLabel.symbolName(.backward, seconds: 7), "gobackward")
        XCTAssertTrue(symbolExists("gobackward"))
        XCTAssertTrue(symbolExists("goforward"))
    }

    func testAccessibilityLabelNamesTheInterval() {
        XCTAssertEqual(SeekIntervalLabel.accessibilityLabel(.backward, seconds: 45), "Back 45 seconds")
        XCTAssertEqual(SeekIntervalLabel.accessibilityLabel(.forward, seconds: 5), "Forward 5 seconds")
    }

    private func symbolExists(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil
        #else
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #endif
    }
}

// MARK: - Relative seeks

final class RelativeSeekTests: XCTestCase {
    func testRapidSkipsAccumulateFromThePendingTarget() {
        var pending: Double?
        for _ in 0..<3 {
            pending = RelativeSeek.target(current: 100, pending: pending, delta: 30, duration: 1_000)
        }
        XCTAssertEqual(pending, 190)
    }

    func testWithoutAPendingTargetTheSkipStartsFromThePlayhead() {
        XCTAssertEqual(RelativeSeek.target(current: 100, pending: nil, delta: -15, duration: 1_000), 85)
    }

    func testTargetsClampToTheMedia() {
        XCTAssertEqual(RelativeSeek.target(current: 5, pending: nil, delta: -10, duration: 1_000), 0)
        XCTAssertEqual(RelativeSeek.target(current: 980, pending: 995, delta: 30, duration: 1_000), 1_000)
    }

    func testUnknownDurationOnlyClampsAtZero() {
        XCTAssertEqual(RelativeSeek.target(current: 50, pending: nil, delta: 90, duration: nil), 140)
        XCTAssertEqual(RelativeSeek.target(current: 50, pending: nil, delta: 90, duration: 0), 140)
        XCTAssertEqual(RelativeSeek.target(current: 3, pending: nil, delta: -5, duration: nil), 0)
    }

    func testNonFiniteInputsNeverProduceANonFiniteTarget() {
        XCTAssertEqual(RelativeSeek.target(current: .nan, pending: nil, delta: 10, duration: 100), 0)
        XCTAssertEqual(RelativeSeek.target(current: 20, pending: nil, delta: .infinity, duration: nil), 20)
    }
}

// MARK: - Store

@MainActor
final class SeekIntervalPreferencesTests: XCTestCase {
    private var suiteName = ""
    private var suite: UserDefaults!
    private var defaults: SharedDefaults!
    private var transport: FakeSeekIntervalTransport!
    private var identity: HTTPRequestIdentity? = SeekIntervalPreferencesTests.profileA

    private static let profileA = HTTPRequestIdentity(
        serverId: "server-1",
        serverURL: "https://silo.example",
        profileId: "profile-a",
        clientFamily: "ios"
    )

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "seek-interval-tests-\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults = SharedDefaults(suite: suite, standard: suite)
        transport = FakeSeekIntervalTransport()
        identity = Self.profileA
    }

    override func tearDown() async throws {
        suite.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeStore() -> SeekIntervalPreferences {
        SeekIntervalPreferences(
            defaults: defaults,
            transport: transport,
            requestIdentity: { [unowned self] in self.identity }
        )
    }

    private var cacheKey: String {
        SeekIntervalPreferences.cacheKey(for: Self.profileA)
    }

    func testBeforeAnyAnswerEverySurfaceKeepsItsLegacyInterval() {
        let store = makeStore()
        XCTAssertNil(store.values)
        XCTAssertEqual(store.pair(for: .audiobook), SeekIntervalPair(backward: 30, forward: 30))
        XCTAssertEqual(store.pair(for: .videoSystemControls), SeekIntervalPair(backward: 10, forward: 10))
        XCTAssertEqual(store.pair(for: .videoRemoteControl), SeekIntervalPair(backward: 10, forward: 30))
        XCTAssertEqual(store.pair(for: .videoPlayer), SeekIntervalSurface.videoPlayer.legacy)
        XCTAssertFalse(store.allowsEditing)
    }

    func testOlderServerKeepsLegacyIntervalsAndNeverReceivesAWrite() async {
        transport.capabilities = .available(seekCapabilities(revision: 8))
        let store = makeStore()
        await store.refresh()

        XCTAssertEqual(store.syncState, .serverUpgradeRequired)
        XCTAssertNil(store.values)
        XCTAssertFalse(store.allowsEditing)
        XCTAssertNotNil(store.statusMessage)
        XCTAssertEqual(transport.effectiveReads, 0)
        XCTAssertEqual(store.pair(for: .audiobook), SeekIntervalSurface.audiobook.legacy)

        store.setInterval(45, media: .video, direction: .forward)
        await store.waitForPendingWrites()
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertNil(store.values)
    }

    func testServerBelowTheMinimumRevisionKeepsLegacyIntervals() async {
        transport.capabilities = .serverUpgradeRequired
        let store = makeStore()
        await store.refresh()
        XCTAssertEqual(store.syncState, .serverUpgradeRequired)
        XCTAssertNil(store.values)
        XCTAssertEqual(transport.effectiveReads, 0)
    }

    func testSupportedServerValuesReachEverySurfaceOfThatMedia() async {
        transport.effective = [
            "player.video_skip_back_seconds": 5,
            "player.video_skip_forward_seconds": 60,
            "player.audiobook_skip_back_seconds": 15,
            "player.audiobook_skip_forward_seconds": 45,
        ]
        let store = makeStore()
        await store.refresh()

        XCTAssertEqual(store.syncState, .supported)
        XCTAssertTrue(store.allowsEditing)
        XCTAssertNil(store.statusMessage)
        XCTAssertEqual(transport.requestedKeys, SeekIntervalContract.keys)
        XCTAssertEqual(transport.readIdentities, [Self.profileA])
        let video = SeekIntervalPair(backward: 5, forward: 60)
        XCTAssertEqual(store.pair(for: .videoPlayer), video)
        XCTAssertEqual(store.pair(for: .videoSystemControls), video)
        XCTAssertEqual(store.pair(for: .videoRemoteControl), video)
        XCTAssertEqual(store.pair(for: .audiobook), SeekIntervalPair(backward: 15, forward: 45))
        XCTAssertEqual(store.interval(.forward, for: .audiobook), 45)
    }

    func testUnsetProfileValuesResolveToTheContractDefaults() async {
        let store = makeStore()
        await store.refresh()
        XCTAssertEqual(store.values, .contractDefaults)
        XCTAssertEqual(store.pair(for: .videoPlayer), SeekIntervalPair(backward: 10, forward: 30))
        XCTAssertEqual(store.pair(for: .audiobook), SeekIntervalPair(backward: 10, forward: 30))
    }

    func testWriteGoesToProfileScopeWithTheActiveIdentity() async {
        let store = makeStore()
        await store.refresh()

        store.setInterval(45, media: .audiobook, direction: .backward)
        // Optimistic: surfaces see the new value before the write returns.
        XCTAssertEqual(store.seconds(.backward, for: .audiobook), 45)
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.writes.count, 1)
        let write = transport.writes[0]
        XCTAssertEqual(write.key, .playerAudiobookSkipBackSeconds)
        XCTAssertEqual(write.value, .int(45))
        XCTAssertEqual(write.identity, Self.profileA)
        XCTAssertFalse(store.isSaving)
        XCTAssertTrue(store.writeErrors.isEmpty)
        XCTAssertEqual(store.seconds(.backward, for: .audiobook), 45)
    }

    func testInvalidOrUnchangedChoicesAreNotWritten() async {
        let store = makeStore()
        await store.refresh()
        store.setInterval(20, media: .video, direction: .backward)
        store.setInterval(10, media: .video, direction: .backward)
        await store.waitForPendingWrites()
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertEqual(store.seconds(.backward, for: .videoPlayer), 10)
    }

    func testFailedWriteRollsBackOnlyThatDirection() async {
        transport.failingKeys = [.playerVideoSkipBackSeconds]
        let store = makeStore()
        await store.refresh()

        store.setInterval(60, media: .video, direction: .backward)
        store.setInterval(90, media: .video, direction: .forward)
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.writes.map(\.key), [.playerVideoSkipBackSeconds, .playerVideoSkipForwardSeconds])
        XCTAssertEqual(store.pair(for: .videoPlayer), SeekIntervalPair(backward: 10, forward: 90))
        XCTAssertNotNil(store.writeErrors[.playerVideoSkipBackSeconds])
        XCTAssertNil(store.writeErrors[.playerVideoSkipForwardSeconds])
        XCTAssertFalse(store.isSaving)
    }

    func testObserversHearLiveChanges() async {
        let store = makeStore()
        let owner = NSObject()
        var calls = 0
        store.observe(owner) { calls += 1 }

        await store.refresh()
        XCTAssertEqual(calls, 1)
        store.setInterval(15, media: .video, direction: .forward)
        XCTAssertEqual(calls, 2)
        await store.waitForPendingWrites()
        XCTAssertEqual(calls, 2)
    }

    func testProbeFailureKeepsTheCachedAnswer() async {
        transport.effective = ["player.video_skip_forward_seconds": 45]
        await makeStore().refresh()
        XCTAssertNotNil(suite.data(forKey: cacheKey))

        transport.capabilities = .failed(.transport(description: "offline"))
        let store = makeStore()
        XCTAssertEqual(store.seconds(.forward, for: .videoPlayer), 45)
        await store.refresh()

        XCTAssertEqual(store.syncState, .unavailable)
        XCTAssertEqual(store.seconds(.forward, for: .videoPlayer), 45)
        XCTAssertFalse(store.allowsEditing)
        XCTAssertNotNil(suite.data(forKey: cacheKey))
    }

    /// Settings disabled for this principal says nothing about the server's
    /// version, so the last answer stays in effect, read-only.
    func testUnavailableSettingsKeepTheCachedAnswer() async {
        transport.effective = ["player.video_skip_back_seconds": 5]
        await makeStore().refresh()

        transport.capabilities = .unavailable
        let store = makeStore()
        await store.refresh()

        XCTAssertEqual(store.syncState, .unavailable)
        XCTAssertEqual(store.seconds(.backward, for: .videoPlayer), 5)
        XCTAssertFalse(store.allowsEditing)
        XCTAssertEqual(transport.effectiveReads, 1)
    }

    func testRevalidatingASupportedProfileKeepsEditingEnabled() async {
        transport.effective = ["player.video_skip_forward_seconds": 45]
        let store = makeStore()
        await store.refresh()
        XCTAssertTrue(store.allowsEditing)

        var stateDuringProbe: SeekIntervalSyncState?
        transport.onCapabilityProbe = {
            stateDuringProbe = store.syncState
            // A choice made while the probe is on the wire must be written.
            store.setInterval(60, media: .video, direction: .forward)
            self.transport.effective["player.video_skip_forward_seconds"] = 60
        }
        await store.refresh()
        await store.waitForPendingWrites()

        XCTAssertEqual(stateDuringProbe, .supported)
        XCTAssertEqual(transport.writes.map(\.value), [.int(60)])
        XCTAssertEqual(store.seconds(.forward, for: .videoPlayer), 60)
        XCTAssertTrue(store.allowsEditing)
    }

    func testAChoiceMadeDuringTheProbeSurvivesAStaleRead() async {
        transport.effective = ["player.video_skip_forward_seconds": 45]
        let store = makeStore()
        await store.refresh()

        transport.onCapabilityProbe = {
            store.setInterval(60, media: .video, direction: .forward)
        }
        // The read answers 45, then the write settles before the answer lands.
        transport.beforeEffectiveReadReturns = { await store.waitForPendingWrites() }
        await store.refresh()
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.writes.map(\.value), [.int(60)])
        XCTAssertEqual(store.seconds(.forward, for: .videoPlayer), 60)
    }

    func testAWritePendingWhenARefreshStartsIsNotOverwrittenByIt() async {
        transport.effective = ["player.video_skip_back_seconds": 10]
        let store = makeStore()
        await store.refresh()

        store.setInterval(30, media: .video, direction: .backward)
        transport.beforeEffectiveReadReturns = { await store.waitForPendingWrites() }
        await store.refresh()

        XCTAssertEqual(store.seconds(.backward, for: .videoPlayer), 30)
    }

    func testAnotherProfilesQueuedWriteDoesNotBlockThisProfilesRefresh() async {
        let store = makeStore()
        await store.refresh()
        let gate = WriteGate()
        transport.beforeWrite = { await gate.wait() }
        store.setInterval(60, media: .video, direction: .forward)
        XCTAssertTrue(store.isSaving)

        identity = HTTPRequestIdentity(
            serverId: "server-1",
            serverURL: "https://silo.example",
            profileId: "profile-b",
            clientFamily: "ios"
        )
        transport.effective = ["player.video_skip_back_seconds": 5]
        await store.refresh()

        XCTAssertEqual(store.seconds(.backward, for: .videoPlayer), 5)
        XCTAssertTrue(store.allowsEditing)
        XCTAssertFalse(store.isSaving)

        await gate.open()
        await store.waitForPendingWrites()
    }

    func testTheCacheHoldsOnlyServerConfirmedValues() async {
        let store = makeStore()
        await store.refresh()

        transport.failingKeys = [.playerVideoSkipForwardSeconds]
        store.setInterval(90, media: .video, direction: .forward)
        // Shown at once, but a relaunch before the write settles must not
        // treat it as the profile's setting.
        XCTAssertEqual(store.seconds(.forward, for: .videoPlayer), 90)
        XCTAssertEqual(makeStore().seconds(.forward, for: .videoPlayer), 30)
        await store.waitForPendingWrites()
        XCTAssertEqual(makeStore().seconds(.forward, for: .videoPlayer), 30)

        transport.failingKeys = []
        store.setInterval(45, media: .video, direction: .forward)
        await store.waitForPendingWrites()
        XCTAssertEqual(makeStore().seconds(.forward, for: .videoPlayer), 45)
    }

    func testReadFailureKeepsTheCachedAnswer() async {
        transport.effective = ["player.audiobook_skip_back_seconds": 90]
        await makeStore().refresh()

        transport.effectiveError = SettingsAPIError.transport(description: "timed out")
        let store = makeStore()
        await store.refresh()
        XCTAssertEqual(store.seconds(.backward, for: .audiobook), 90)
        XCTAssertNotNil(store.readErrorMessage)
    }

    func testUpgradeRequiredReadClearsTheCache() async {
        transport.effective = ["player.video_skip_back_seconds": 5]
        await makeStore().refresh()
        XCTAssertNotNil(suite.data(forKey: cacheKey))

        transport.effectiveError = SettingsAPIError.serverUpgradeRequired
        let store = makeStore()
        await store.refresh()

        XCTAssertEqual(store.syncState, .serverUpgradeRequired)
        XCTAssertNil(store.values)
        XCTAssertNil(suite.data(forKey: cacheKey))
        XCTAssertEqual(store.pair(for: .videoSystemControls), SeekIntervalSurface.videoSystemControls.legacy)
    }

    func testServerDowngradeClearsTheCache() async {
        transport.effective = ["player.video_skip_back_seconds": 5]
        let store = makeStore()
        await store.refresh()
        XCTAssertEqual(store.seconds(.backward, for: .videoPlayer), 5)

        transport.capabilities = .available(seekCapabilities(revision: 8))
        await store.refresh()
        XCTAssertNil(store.values)
        XCTAssertNil(suite.data(forKey: cacheKey))
    }

    func testProfilesKeepSeparateCaches() async {
        transport.effective = ["player.video_skip_back_seconds": 5]
        let store = makeStore()
        await store.refresh()
        XCTAssertEqual(store.seconds(.backward, for: .videoPlayer), 5)

        identity = HTTPRequestIdentity(
            serverId: "server-1",
            serverURL: "https://silo.example",
            profileId: "profile-b",
            clientFamily: "ios"
        )
        transport.capabilities = .failed(.transport(description: "offline"))
        await store.refresh()
        XCTAssertNil(store.values)
        XCTAssertEqual(store.pair(for: .videoPlayer), SeekIntervalSurface.videoPlayer.legacy)
    }

    func testASwitchStopsUsingThePreviousProfilesIntervalsBeforeARefresh() async {
        let profileB = HTTPRequestIdentity(
            serverId: "server-1",
            serverURL: "https://silo.example",
            profileId: "profile-b",
            clientFamily: "ios"
        )
        let store = makeStore()
        identity = profileB
        transport.effective = ["player.video_skip_back_seconds": 15]
        await store.refresh()
        identity = Self.profileA
        transport.effective = ["player.video_skip_back_seconds": 5]
        await store.refresh()
        XCTAssertEqual(store.seconds(.backward, for: .videoPlayer), 5)

        // Switched, no refresh yet: B's cached answer, not A's live one.
        identity = profileB
        XCTAssertEqual(store.seconds(.backward, for: .videoPlayer), 15)

        // A profile with no cached answer gets the legacy interval.
        identity = HTTPRequestIdentity(
            serverId: "server-1",
            serverURL: "https://silo.example",
            profileId: "profile-c",
            clientFamily: "ios"
        )
        XCTAssertEqual(store.pair(for: .videoPlayer), SeekIntervalSurface.videoPlayer.legacy)
    }

    func testWithoutAnActiveProfileNothingIsRead() async {
        identity = nil
        let store = makeStore()
        await store.refresh()
        XCTAssertEqual(store.syncState, .unavailable)
        XCTAssertEqual(transport.capabilityProbes, 0)
    }
}

// MARK: - Fixtures

/// Holds writes in flight until a test opens it.
private actor WriteGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private func seekCapabilities(
    revision: Int,
    state: String = "available",
    allowed: Bool = true,
    batchedEffective: Bool = true
) -> APIv2SettingsContractCapabilities {
    APIv2SettingsContractCapabilities(
        revision: "capabilities-\(revision)",
        state: state,
        allowed: allowed,
        manifestRevision: revision,
        clientFamilies: ["tv", "mobile", "tablet", "desktop", "web"],
        supportsBatchedEffective: batchedEffective,
        supportsAtomicShortcuts: true
    )
}

private func effectiveResponse(_ values: [String: Int], revision: Int = 9) throws -> EffectiveSettingValuesResponse {
    let rows: [[String: Any]] = values.sorted { $0.key < $1.key }.map { key, value in
        ["key": key, "value": value, "source": "profile"]
    }
    let data = try JSONSerialization.data(withJSONObject: ["items": rows, "revision": revision])
    return try SettingsWireCoding.makeDecoder().decode(EffectiveSettingValuesResponse.self, from: data)
}

@MainActor
private final class FakeSeekIntervalTransport: SeekIntervalTransport, @unchecked Sendable {
    struct Write: Equatable {
        let key: SettingKey
        let value: SettingJSONValue
        let identity: HTTPRequestIdentity
    }

    var capabilities: SettingsCapabilitiesResult = .available(seekCapabilities(revision: 9))
    var effective: [String: Int] = [:]
    var effectiveError: Error?
    var failingKeys: Set<SettingKey> = []
    /// Runs inside the capability probe, while a refresh is waiting on it.
    var onCapabilityProbe: (@MainActor () -> Void)?
    /// Runs after the effective read has captured its answer and before it
    /// returns, so a test can let a write settle behind a stale read.
    var beforeEffectiveReadReturns: (@MainActor () async -> Void)?
    /// Runs before a write reaches the server, so a test can hold it in flight.
    var beforeWrite: (@MainActor () async -> Void)?

    private(set) var capabilityProbes = 0
    private(set) var effectiveReads = 0
    private(set) var requestedKeys: [SettingKey] = []
    private(set) var readIdentities: [HTTPRequestIdentity] = []
    private(set) var writes: [Write] = []

    nonisolated func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        await MainActor.run {
            capabilityProbes += 1
            onCapabilityProbe?()
            return capabilities
        }
    }

    nonisolated func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        let response = try await MainActor.run {
            effectiveReads += 1
            requestedKeys = keys
            readIdentities.append(requestIdentity)
            if let effectiveError { throw effectiveError }
            return try effectiveResponse(effective)
        }
        if let hook = await MainActor.run(body: { beforeEffectiveReadReturns }) {
            await hook()
        }
        return response
    }

    nonisolated func putProfileValue(
        key: SettingKey,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        if let hook = await MainActor.run(body: { beforeWrite }) {
            await hook()
        }
        try await MainActor.run {
            writes.append(Write(key: key, value: value, identity: requestIdentity))
            if failingKeys.contains(key) {
                throw SettingsAPIError.server(status: 500, code: "internal", message: "boom")
            }
        }
    }
}

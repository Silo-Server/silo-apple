import XCTest
@testable import Silo

@MainActor
final class AdvisoryAgePreferenceStoreTests: XCTestCase {
    private var identity: HTTPRequestIdentity?
    private var transport: FakeAdvisoryAgePreferenceTransport!

    private static let profileA = HTTPRequestIdentity(
        serverId: "server-1",
        serverURL: "https://silo.example",
        profileId: "profile-a",
        clientFamily: "ios"
    )
    private static let profileB = HTTPRequestIdentity(
        serverId: "server-1",
        serverURL: "https://silo.example",
        profileId: "profile-b",
        clientFamily: "ios"
    )

    override func setUp() async throws {
        try await super.setUp()
        identity = Self.profileA
        transport = FakeAdvisoryAgePreferenceTransport()
    }

    private func makeStore() -> AdvisoryAgePreferenceStore {
        AdvisoryAgePreferenceStore(
            transport: transport,
            requestIdentity: { [unowned self] in self.identity }
        )
    }

    func testSupportedValueHydratesAndWriteUsesCapturedIdentity() async {
        transport.effectiveValue = true
        let store = makeStore()
        await store.refresh()

        XCTAssertTrue(store.isSupported)
        XCTAssertTrue(store.showsAdvisoryAge)
        XCTAssertEqual(transport.readIdentities, [Self.profileA])

        await store.setShowsAdvisoryAge(false)
        XCTAssertFalse(store.showsAdvisoryAge)
        XCTAssertEqual(transport.writes, [.init(enabled: false, identity: Self.profileA)])
        XCTAssertFalse(store.isSaving)
    }

    func testUnsupportedServerHidesSettingAndDoesNotReadOrWrite() async {
        transport.capabilities = .available(advisoryCapabilities(revision: 9))
        let store = makeStore()
        await store.refresh()

        XCTAssertFalse(store.isSupported)
        XCTAssertFalse(store.showsAdvisoryAge)
        XCTAssertTrue(transport.readIdentities.isEmpty)
        await store.setShowsAdvisoryAge(true)
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testRefreshCannotOverwriteANewerToggle() async {
        let store = makeStore()
        await store.refresh()
        transport.readGate = AsyncTestGate()
        let refresh = Task { await store.refresh() }
        await waitUntil { self.transport.readIdentities.count == 2 }

        await store.setShowsAdvisoryAge(true)
        transport.readGate?.open()
        await refresh.value

        XCTAssertTrue(store.showsAdvisoryAge)
    }

    func testOlderUnsupportedResultCannotClearANewerSuccessfulToggle() async {
        let store = makeStore()
        await store.refresh()
        transport.capabilityGate = AsyncTestGate()
        let refresh = Task { await store.refresh() }
        await waitUntil { self.transport.capabilityRequests == 2 }

        await store.setShowsAdvisoryAge(true)
        transport.capabilities = .available(advisoryCapabilities(revision: 9))
        transport.capabilityGate?.open()
        await refresh.value

        XCTAssertTrue(store.isSupported)
        XCTAssertTrue(store.showsAdvisoryAge)
    }

    func testFailedWriteDoesNotDiscardConcurrentRefresh() async {
        let store = makeStore()
        await store.refresh()
        transport.effectiveValue = true
        transport.writeError = TestWriteError.failed
        transport.readGate = AsyncTestGate()
        let refresh = Task { await store.refresh() }
        await waitUntil { self.transport.readIdentities.count == 2 }

        await store.setShowsAdvisoryAge(true)
        XCTAssertFalse(store.showsAdvisoryAge)
        transport.readGate?.open()
        await refresh.value

        XCTAssertTrue(store.showsAdvisoryAge)
        XCTAssertFalse(store.isSaving)
    }

    func testToggleShowsChoiceWhileSaving() async {
        let store = makeStore()
        await store.refresh()
        transport.writeGate = AsyncTestGate()
        let write = Task { await store.setShowsAdvisoryAge(true) }
        await waitUntil { store.isSaving }

        XCTAssertTrue(store.showsAdvisoryAge)
        transport.writeGate?.open()
        await write.value
        XCTAssertTrue(store.showsAdvisoryAge)
        XCTAssertFalse(store.isSaving)
    }

    func testFailedWriteRollsBackAndExplains() async {
        let store = makeStore()
        await store.refresh()
        transport.writeError = SettingsAPIError.transport(description: "offline")

        await store.setShowsAdvisoryAge(true)

        XCTAssertFalse(store.showsAdvisoryAge)
        XCTAssertEqual(store.writeError, "Couldn't save Show Advisory Age. Check the connection and try again.")
        transport.writeError = nil
        await store.setShowsAdvisoryAge(true)
        XCTAssertTrue(store.showsAdvisoryAge)
        XCTAssertNil(store.writeError)
    }

    func testSettingStaysHiddenUntilItsValueLoads() async {
        transport.effectiveError = TestWriteError.failed
        let store = makeStore()
        await store.refresh()
        XCTAssertFalse(store.isSupported)

        transport.effectiveError = nil
        transport.effectiveValue = true
        await store.hydrateIfNeeded()
        XCTAssertTrue(store.isSupported)
        XCTAssertTrue(store.showsAdvisoryAge)
    }

    func testUnavailableSettingsRetryOnNextRead() async {
        transport.capabilities = .unavailable
        let store = makeStore()
        await store.hydrateIfNeeded()
        XCTAssertFalse(store.isSupported)

        transport.capabilities = .available(advisoryCapabilities(revision: 14))
        transport.effectiveValue = true
        await store.hydrateIfNeeded()
        XCTAssertTrue(store.isSupported)
        XCTAssertTrue(store.showsAdvisoryAge)
    }

    func testStaleValueIsReadAgainAfterForeground() async {
        let store = makeStore()
        await store.hydrateIfNeeded()
        XCTAssertFalse(store.showsAdvisoryAge)

        transport.effectiveValue = true
        await store.hydrateIfNeeded()
        XCTAssertFalse(store.showsAdvisoryAge, "a hydrated value is reused until marked stale")
        store.markStale()
        await store.hydrateIfNeeded()
        XCTAssertTrue(store.showsAdvisoryAge)
    }

    func testReadInFlightWhenMarkedStaleDoesNotCountAsFresh() async {
        let store = makeStore()
        await store.hydrateIfNeeded()
        transport.readGate = AsyncTestGate()
        let refresh = Task { await store.refresh() }
        await waitUntil { self.transport.readIdentities.count == 2 }

        store.markStale()
        transport.readGate?.open()
        await refresh.value
        transport.effectiveValue = true
        await store.hydrateIfNeeded()

        XCTAssertEqual(transport.readIdentities.count, 3)
        XCTAssertTrue(store.showsAdvisoryAge)
    }

    func testFailedWriteIsReconciledByTheNextRead() async {
        let store = makeStore()
        await store.hydrateIfNeeded()
        transport.writeError = SettingsAPIError.transport(description: "timed out")
        await store.setShowsAdvisoryAge(true)
        XCTAssertFalse(store.showsAdvisoryAge)

        // The PUT landed even though the client saw it fail.
        transport.effectiveValue = true
        await store.hydrateIfNeeded()
        XCTAssertTrue(store.showsAdvisoryAge)
    }

    func testWriteCompletionAfterClearCannotRestorePreviousProfileState() async {
        transport.writeGate = AsyncTestGate()
        let store = makeStore()
        await store.refresh()
        let write = Task { await store.setShowsAdvisoryAge(true) }
        await waitUntil { store.isSaving }

        store.clear()
        identity = Self.profileB
        transport.writeGate?.open()
        await write.value

        XCTAssertFalse(store.showsAdvisoryAge)
        XCTAssertFalse(store.isSupported)
        XCTAssertFalse(store.isSaving)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor
private final class FakeAdvisoryAgePreferenceTransport: AdvisoryAgePreferenceTransport, @unchecked Sendable {
    struct Write: Equatable {
        let enabled: Bool
        let identity: HTTPRequestIdentity
    }

    var capabilities: SettingsCapabilitiesResult = .available(advisoryCapabilities(revision: 14))
    var effectiveValue = false
    var capabilityGate: AsyncTestGate?
    var readGate: AsyncTestGate?
    var writeGate: AsyncTestGate?
    var writeError: Error?
    var effectiveError: Error?
    private(set) var capabilityRequests = 0
    private(set) var readIdentities: [HTTPRequestIdentity] = []
    private(set) var writes: [Write] = []

    func contractCapabilities(requestIdentity: HTTPRequestIdentity) async -> SettingsCapabilitiesResult {
        capabilityRequests += 1
        await capabilityGate?.wait()
        return capabilities
    }

    func effectiveValue(requestIdentity: HTTPRequestIdentity) async throws -> EffectiveSettingValuesResponse {
        readIdentities.append(requestIdentity)
        await readGate?.wait()
        if let effectiveError { throw effectiveError }
        return try advisoryEffectiveResponse(effectiveValue)
    }

    func putValue(_ enabled: Bool, requestIdentity: HTTPRequestIdentity) async throws {
        writes.append(.init(enabled: enabled, identity: requestIdentity))
        await writeGate?.wait()
        if let writeError { throw writeError }
    }
}

private enum TestWriteError: Error {
    case failed
}

@MainActor
private final class AsyncTestGate {
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

private func advisoryCapabilities(revision: Int) -> APIv2SettingsContractCapabilities {
    APIv2SettingsContractCapabilities(
        revision: "capabilities-\(revision)",
        state: "available",
        allowed: true,
        manifestRevision: revision,
        clientFamilies: ["ios"],
        supportsBatchedEffective: true,
        supportsAtomicShortcuts: true
    )
}

private func advisoryEffectiveResponse(_ enabled: Bool) throws -> EffectiveSettingValuesResponse {
    let object: [String: Any] = [
        "items": [[
            "key": SettingKey.catalogShowAdvisoryAge.rawValue,
            "value": enabled,
            "source": "profile",
        ]],
        "revision": 14,
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    return try SettingsWireCoding.makeDecoder().decode(EffectiveSettingValuesResponse.self, from: data)
}

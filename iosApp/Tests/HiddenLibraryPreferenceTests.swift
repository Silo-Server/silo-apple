import XCTest
@testable import Silo

@MainActor
final class HiddenLibraryPreferenceTests: XCTestCase {
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

    private var defaults: SharedDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let name = "HiddenLibraryPreferenceTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        defaults = SharedDefaults(suite: suite, standard: suite)
    }

    func testHiddenLibrariesLeaveTheListInServerOrder() {
        let libraries = [library(1), library(2), library(3)]

        let visible = HiddenLibraryPreference.visibleLibraries(libraries, hiding: [2, 99])

        XCTAssertEqual(visible.map(\.id), [1, 3])
    }

    func testParsesCanonicalArrayLegacyStringAndDefault() {
        XCTAssertEqual(
            HiddenLibraryPreference.libraryIds(from: .array([.int(4), .int(4), .int(0), .string("7"), .double(9)])),
            [4, 9]
        )
        XCTAssertEqual(HiddenLibraryPreference.libraryIds(from: .string("[2,5]")), [2, 5])
        XCTAssertEqual(HiddenLibraryPreference.libraryIds(from: .string("not json")), [])
        XCTAssertEqual(HiddenLibraryPreference.libraryIds(from: .null), [])
    }

    func testFailedReadKeepsTheProfilesLastAnswer() async {
        let first = await read(returning: .array([.int(3)]))
        XCTAssertEqual(first, [3])

        let afterDrop = await read(throwing: SettingsAPIError.transport(description: "offline"))
        XCTAssertEqual(afterDrop, [3])
    }

    func testServerWithoutTheSettingHidesNothing() async {
        _ = await read(returning: .array([.int(3)]))

        let older = await read(throwing: SettingsAPIError.serverUpgradeRequired)
        XCTAssertEqual(older, [])
        let afterDrop = await read(throwing: SettingsAPIError.transport(description: "offline"))
        XCTAssertEqual(afterDrop, [])
    }

    func testClearedSettingShowsEveryLibraryAfterADroppedRead() async {
        _ = await read(returning: .array([.int(3)]))
        _ = await read(returning: .null)

        let afterDrop = await read(throwing: SettingsAPIError.transport(description: "offline"))
        XCTAssertEqual(afterDrop, [])
    }

    func testAnotherProfileNeverGetsThisProfilesHiddenLibraries() async {
        _ = await read(returning: .array([.int(3)]))

        let otherProfile = await HiddenLibraryPreference.hiddenLibraryIds(
            defaults: defaults,
            requestIdentity: { Self.profileB },
            read: { _ in throw SettingsAPIError.transport(description: "offline") }
        )
        XCTAssertEqual(otherProfile, [])
    }

    func testHidingKeepsLibrariesHiddenElsewhereSinceTheLastRead() async throws {
        _ = await read(returning: .array([.int(3)]))
        var written: [Set<Int>] = []

        // Another device hid 9 after this one last read [3].
        let updated = try await setHidden(true, libraryId: 5, serverValue: .array([.int(9), .int(3)])) {
            written.append($0)
        }

        XCTAssertEqual(updated, [3, 5, 9])
        XCTAssertEqual(written, [[3, 5, 9]])
        let afterDrop = await read(throwing: SettingsAPIError.transport(description: "offline"))
        XCTAssertEqual(afterDrop, [3, 5, 9])
    }

    func testShowingRemovesOnlyThatLibraryAndSkipsANoOpWrite() async throws {
        var written: [Set<Int>] = []

        let shown = try await setHidden(false, libraryId: 3, serverValue: .array([.int(3), .int(4)])) {
            written.append($0)
        }
        let unchanged = try await setHidden(false, libraryId: 3, serverValue: .array([.int(4)])) {
            written.append($0)
        }

        XCTAssertEqual(shown, [4])
        XCTAssertEqual(unchanged, [4])
        XCTAssertEqual(written, [[4]])
    }

    func testFailedWriteThrowsAndKeepsTheLastAnswer() async {
        _ = await read(returning: .array([.int(3)]))

        do {
            _ = try await setHidden(true, libraryId: 5, serverValue: .array([.int(3)])) { _ in
                throw SettingsAPIError.transport(description: "offline")
            }
            XCTFail("A failed write must throw")
        } catch {}

        let afterDrop = await read(throwing: SettingsAPIError.transport(description: "offline"))
        XCTAssertEqual(afterDrop, [3])
    }

    /// Each save reads the whole list and writes it back, so two hides at
    /// once must not undo each other.
    func testHidesStartedTogetherBothLand() async throws {
        let server = ServerState(hidden: [3])

        let first = Task { try await self.hide(5, on: server) }
        let second = Task { try await self.hide(7, on: server) }
        _ = try await (first.value, second.value)

        XCTAssertEqual(server.hidden, [3, 5, 7])
    }

    func testProfileSwitchBeforeTheWriteCancelsIt() async {
        var identities = [Self.profileA, Self.profileB]
        var written: [Set<Int>] = []

        do {
            _ = try await HiddenLibraryPreference.setHidden(
                true,
                libraryId: 5,
                defaults: defaults,
                requestIdentity: { identities.count > 1 ? identities.removeFirst() : identities[0] },
                capabilities: { _ in .available(Self.contract) },
                read: { _ in try Self.response(.array([.int(3)])) },
                write: { ids, _ in written.append(ids) }
            )
            XCTFail("A save for a profile that is no longer active must not write")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(written, [])
    }

    /// A read without the key would look like an empty list, and writing
    /// from it would show every library hidden elsewhere.
    func testReadWithoutTheSettingRefusesToSave() async throws {
        var written: [Set<Int>] = []
        let missing = try SettingsWireCoding.makeDecoder().decode(
            EffectiveSettingValuesResponse.self,
            from: JSONSerialization.data(withJSONObject: ["items": [], "revision": SettingKey.revision])
        )

        do {
            _ = try await HiddenLibraryPreference.setHidden(
                true,
                libraryId: 5,
                defaults: defaults,
                requestIdentity: { Self.profileA },
                capabilities: { _ in .available(Self.contract) },
                read: { _ in missing },
                write: { ids, _ in written.append(ids) }
            )
            XCTFail("A read without the setting must not lead to a write")
        } catch {}
        XCTAssertEqual(written, [])
    }

    func testServerWhoseContractLacksTheSettingIsNeverWritten() async {
        var written: [Set<Int>] = []

        do {
            _ = try await HiddenLibraryPreference.setHidden(
                true,
                libraryId: 5,
                defaults: defaults,
                requestIdentity: { Self.profileA },
                capabilities: { _ in .serverUpgradeRequired },
                read: { _ in try Self.response(.array([])) },
                write: { ids, _ in written.append(ids) }
            )
            XCTFail("An unsupported server must not be written")
        } catch {
            XCTAssertEqual(SettingsAPIError.from(error), .serverUpgradeRequired)
        }
        XCTAssertEqual(written, [])
    }

    /// The Libraries page counts hidden libraries from the cached list, and a
    /// list cached before the split has none.
    func testCachedLibraryListKeepsItsHiddenLibraries() throws {
        let split = LibrariesResponse(libraries: [library(1)], hiddenLibraries: [library(2)])
        let unsplit = LibrariesResponse(libraries: [library(1)])

        let decodedSplit = try JSONDecoder().decode(LibrariesResponse.self, from: JSONEncoder().encode(split))
        let decodedUnsplit = try JSONDecoder().decode(LibrariesResponse.self, from: JSONEncoder().encode(unsplit))

        XCTAssertEqual(decodedSplit.hiddenLibraries?.map(\.id), [2])
        XCTAssertNil(decodedUnsplit.hiddenLibraries)
    }

    // MARK: Helpers

    private final class ServerState {
        var hidden: Set<Int>
        init(hidden: Set<Int>) { self.hidden = hidden }
    }

    /// A server whose read and write each suspend, so two saves overlap
    /// unless the second waits.
    private func hide(_ libraryId: Int, on server: ServerState) async throws -> Set<Int> {
        try await HiddenLibraryPreference.setHidden(
            true,
            libraryId: libraryId,
            defaults: defaults,
            requestIdentity: { Self.profileA },
            capabilities: { _ in .available(Self.contract) },
            read: { _ in
                let ids = server.hidden
                await Task.yield()
                return try Self.response(.array(ids.sorted().map { .int($0) }))
            },
            write: { ids, _ in
                await Task.yield()
                server.hidden = ids
            }
        )
    }

    private func setHidden(
        _ isHidden: Bool,
        libraryId: Int,
        serverValue: SettingJSONValue,
        write: @escaping (Set<Int>) throws -> Void
    ) async throws -> Set<Int> {
        try await HiddenLibraryPreference.setHidden(
            isHidden,
            libraryId: libraryId,
            defaults: defaults,
            requestIdentity: { Self.profileA },
            capabilities: { _ in .available(Self.contract) },
            read: { _ in try Self.response(serverValue) },
            write: { ids, _ in try write(ids) }
        )
    }

    private func read(returning value: SettingJSONValue) async -> Set<Int> {
        await HiddenLibraryPreference.hiddenLibraryIds(
            defaults: defaults,
            requestIdentity: { Self.profileA },
            read: { _ in try Self.response(value) }
        )
    }

    private func read(throwing error: Error) async -> Set<Int> {
        await HiddenLibraryPreference.hiddenLibraryIds(
            defaults: defaults,
            requestIdentity: { Self.profileA },
            read: { _ in throw error }
        )
    }

    private static let contract = APIv2SettingsContractCapabilities(
        revision: "capabilities",
        state: "available",
        allowed: true,
        manifestRevision: SettingKey.revision,
        clientFamilies: ["ios"],
        supportsBatchedEffective: true,
        supportsAtomicShortcuts: true
    )

    private static func response(_ value: SettingJSONValue) throws -> EffectiveSettingValuesResponse {
        let row: [String: Any] = [
            "key": SettingKey.uiDisabledLibraryIds.rawValue,
            "value": try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(value),
                options: .fragmentsAllowed
            ),
            "source": "profile",
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "items": [row],
            "revision": SettingKey.revision,
        ])
        return try SettingsWireCoding.makeDecoder().decode(EffectiveSettingValuesResponse.self, from: data)
    }

    private func library(_ id: Int) -> Library {
        Library(id: id, name: "Library \(id)", type: "movies", sortOrder: id, posterUrl: nil)
    }
}

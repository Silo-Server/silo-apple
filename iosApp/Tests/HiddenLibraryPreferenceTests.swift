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

    // MARK: Helpers

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
        return try JSONDecoder().decode(EffectiveSettingValuesResponse.self, from: data)
    }

    private func library(_ id: Int) -> Library {
        Library(id: id, name: "Library \(id)", type: "movies", sortOrder: id, posterUrl: nil)
    }
}

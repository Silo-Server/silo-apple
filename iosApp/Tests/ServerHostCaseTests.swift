import XCTest
@testable import Silo

/// A server typed or pasted with a mixed-case host is the same server.
@MainActor
final class ServerHostCaseTests: XCTestCase {
    func testSetupLowercasesTheSchemeAndHostButNotThePath() throws {
        let viewModel = ServerSetupViewModel(checkServer: { _ in APIv2SetupStatus(needsSetup: false) })
        viewModel.host = "HTTPS://Media.Example.COM/Silo"
        XCTAssertEqual(try viewModel.buildCandidateURLs().first, "https://media.example.com/Silo")

        viewModel.host = "Media.Example.COM"
        XCTAssertEqual(try viewModel.buildCandidateURLs().first, "https://media.example.com")
    }

    func testRegistryUpdatesTheSavedMixedCaseEntryInsteadOfAddingOne() throws {
        let name = "ServerHostCaseTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(true, forKey: ServerRegistry.migratedKey)
        let registry = ServerRegistry(
            defaults: defaults,
            keychain: SharedKeychain(service: name, accessGroup: nil),
            launchPreferences: ProfileLaunchPreferences(defaults: defaults),
            persistenceOverride: { _, _ in true }
        )
        let storedURL = "https://Media.Example.com"
        let storedID = ServerRegistry.serverId(for: storedURL)
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(
            id: storedID, url: storedURL, fetchedName: nil, lastUsedAt: Date(timeIntervalSince1970: 1)
        )))

        let typedURL = "https://media.example.com"
        let saved = registry.addOrUpdate(ServerEntry(
            id: ServerRegistry.serverId(for: typedURL), url: typedURL, fetchedName: "Home", lastUsedAt: Date()
        ))

        // The saved id keys the server's credentials, so it must survive.
        XCTAssertEqual(saved?.id, storedID)
        XCTAssertEqual(saved?.url, storedURL)
        XCTAssertEqual(registry.entries.map(\.id), [storedID])
        XCTAssertEqual(registry.entries.first?.fetchedName, "Home")
        XCTAssertEqual(registry.entry(matching: ServerRegistry.serverId(for: typedURL))?.id, storedID)
        // Paths stay case-sensitive.
        XCTAssertNil(registry.entry(matching: ServerRegistry.serverId(for: "https://media.example.com/Other")))
    }
}

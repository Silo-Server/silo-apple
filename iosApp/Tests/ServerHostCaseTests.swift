import XCTest
@testable import Silo

/// A server typed or pasted with a mixed-case host is the same server.
@MainActor
final class ServerHostCaseTests: XCTestCase {
    func testRegistryUpdatesTheSavedMixedCaseEntryInsteadOfAddingOne() throws {
        let storedURL = "https://Media.Example.com"
        let storedID = ServerRegistry.serverId(for: storedURL)
        let registry = try makeRegistry(saved: [ServerEntry(
            id: storedID, url: storedURL, fetchedName: nil, lastUsedAt: Date(timeIntervalSince1970: 1)
        )])

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

    /// A device that saved one server twice before this fix keeps both
    /// entries, and each saved spelling still reaches its own.
    func testAnExactSavedSpellingKeepsItsOwnEntryBesideADuplicate() throws {
        let lower = entry("https://media.example.com")
        let mixed = entry("https://Media.Example.com")
        let registry = try makeRegistry(saved: [lower, mixed])

        let saved = registry.addOrUpdate(entry(mixed.url))

        XCTAssertEqual(saved?.id, mixed.id)
        XCTAssertEqual(registry.entries.map(\.id), [lower.id, mixed.id])
    }

    /// Picking a server from Recent fills in its saved URL; connecting must
    /// probe that exact URL so the saved entry, not a duplicate, is updated.
    func testSetupKeepsTheHostAsSavedOrTyped() throws {
        let viewModel = ServerSetupViewModel(checkServer: { _ in APIv2SetupStatus(needsSetup: false) })
        viewModel.useRecent("https://Media.Example.com")
        XCTAssertEqual(try viewModel.buildCandidateURLs().first, "https://Media.Example.com")

        viewModel.host = "HTTPS://Media.Example.COM/Silo"
        XCTAssertEqual(try viewModel.buildCandidateURLs().first, "https://Media.Example.COM/Silo")
    }

    private func entry(_ url: String) -> ServerEntry {
        ServerEntry(id: ServerRegistry.serverId(for: url), url: url, fetchedName: nil, lastUsedAt: Date())
    }

    /// A registry loaded from `saved`, which may hold entries `addOrUpdate`
    /// would now merge.
    private func makeRegistry(saved: [ServerEntry]) throws -> ServerRegistry {
        let name = "ServerHostCaseTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(true, forKey: ServerRegistry.migratedKey)
        defaults.set(
            try JSONEncoder().encode(SavedRegistry(activeServerId: saved.first?.id, entries: saved)),
            forKey: ServerRegistry.defaultsKey
        )
        return ServerRegistry(
            defaults: defaults,
            keychain: SharedKeychain(service: name, accessGroup: nil),
            launchPreferences: ProfileLaunchPreferences(defaults: defaults),
            persistenceOverride: { _, _ in true }
        )
    }
}

/// The registry's saved shape.
private struct SavedRegistry: Encodable {
    var activeServerId: String?
    var entries: [ServerEntry]
}

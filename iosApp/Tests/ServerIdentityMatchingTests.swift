import XCTest
@testable import Silo

/// Recognising one deployment across addresses (issue #341). Registry keys
/// stay URL-derived; the verified deployment identity only adds matches.
final class ServerIdentityMatchingTests: XCTestCase {
    private let identity = "96c1bd08-b839-4d47-980e-57d4e7a44cfa"

    func testDifferentHostnamesMatchWhenVerifiedIdentitiesAgree() {
        let phone = ServerRegistry.serverId(for: "https://silo-dev-1.bonobo-kitefin.ts.net")
        let tv = ServerRegistry.serverId(for: "https://silo-dev.arkyncdn.net")

        XCTAssertFalse(ServerRegistry.serverIdsMatch(phone, tv), "URL rule alone cannot relate them")
        XCTAssertTrue(ServerRegistry.serversMatch(
            serverId: phone, verifiedServerId: identity,
            serverId: tv, verifiedServerId: identity
        ))
    }

    func testMissingOrDifferentIdentityFallsBackToURLRule() {
        let phone = ServerRegistry.serverId(for: "https://a.example")
        let tv = ServerRegistry.serverId(for: "https://b.example")

        XCTAssertFalse(ServerRegistry.serversMatch(
            serverId: phone, verifiedServerId: identity, serverId: tv, verifiedServerId: nil
        ))
        XCTAssertFalse(ServerRegistry.serversMatch(
            serverId: phone, verifiedServerId: "", serverId: tv, verifiedServerId: ""
        ))
        XCTAssertFalse(ServerRegistry.serversMatch(
            serverId: phone, verifiedServerId: identity, serverId: tv, verifiedServerId: "other"
        ))
        // Same origin still matches without any identity, as before.
        XCTAssertTrue(ServerRegistry.serversMatch(
            serverId: ServerRegistry.serverId(for: "https://A.example"), verifiedServerId: nil,
            serverId: phone, verifiedServerId: nil
        ))
    }

    func testEntryPersistsVerifiedIdentityAndDecodesWithoutIt() throws {
        let entry = ServerEntry(
            id: "id", url: "https://a.example", fetchedName: "Home",
            lastUsedAt: Date(timeIntervalSince1970: 1), verifiedServerId: identity
        )
        let data = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(ServerEntry.self, from: data).verifiedServerId, identity)

        let legacy = Data(#"{"id":"id","url":"https://a.example","lastUsedAt":1}"#.utf8)
        let decoded = try JSONDecoder().decode(ServerEntry.self, from: legacy)
        XCTAssertNil(decoded.verifiedServerId)
        XCTAssertEqual(decoded.url, "https://a.example")
    }

    func testRegistryKeepsIdentityWhenAnUpdateOmitsIt() throws {
        let name = "ServerIdentityMatchingTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(true, forKey: "continuumServerRegistry.migrated.v1")
        let registry = ServerRegistry(
            defaults: defaults,
            keychain: SharedKeychain(service: name, accessGroup: nil),
            launchPreferences: ProfileLaunchPreferences(defaults: defaults),
            persistenceOverride: { _, _ in true }
        )
        let first = ServerEntry(id: "id", url: "https://a.example", fetchedName: nil, lastUsedAt: Date())
        XCTAssertNotNil(registry.addOrUpdate(first))
        XCTAssertTrue(registry.updateVerifiedServerId(for: "id", verifiedServerId: identity))
        XCTAssertFalse(registry.updateVerifiedServerId(for: "id", verifiedServerId: " "), "blank never replaces a known identity")

        let renamed = ServerEntry(id: "id", url: "https://a.example", fetchedName: "Home", lastUsedAt: Date())
        XCTAssertEqual(registry.addOrUpdate(renamed)?.verifiedServerId, identity)
        XCTAssertEqual(registry.entry(verifiedServerId: identity)?.id, "id")
        XCTAssertNil(registry.entry(verifiedServerId: "other"))
    }

    func testConnectionsDocumentOffersOnlyAddressesWithURLs() throws {
        let json = #"""
        {"revision":"r","state":"available","allowed":true,"server_id":"S",
         "current":{"kind":"default"},
         "endpoints":[
           {"kind":"public","url":"https://silo.example/"},
           {"kind":"provider","provider":"down","display_name":"Down Overlay","state":"unavailable"},
           {"kind":"provider","url":"https://silo.overlay.example","provider":"tailscale","display_name":"Tailscale","state":"connected"},
           {"kind":"public","url":"https://silo.example"}
         ]}
        """#
        let document = try HTTPClient.makeJSONDecoder().decode(ServerConnectionsDocument.self, from: Data(json.utf8))
        XCTAssertTrue(document.isAvailable)
        XCTAssertEqual(document.usableEndpoints, [
            ServerEndpoint(url: "https://silo.example", kind: .public),
            ServerEndpoint(url: "https://silo.overlay.example", kind: .provider, provider: "tailscale", displayName: "Tailscale"),
        ])
    }

    func testProviderHelpNamesTheProviderWithoutClaimingItIsMissing() {
        let endpoint = ServerEndpoint(url: "https://silo.overlay.example", kind: .provider, provider: "tailscale", displayName: "Tailscale")
        let help = endpoint.unreachableHelp(serverName: "Home")
        XCTAssertTrue(help.contains("through Tailscale"))
        XCTAssertTrue(help.contains("Install or open the Tailscale app"))
        XCTAssertFalse(help.lowercased().contains("not installed"))
        XCTAssertFalse(help.contains("overlay.example"), "provider name comes from the manifest, not the host")
    }

    func testCandidateOrderPrefersSavedThenOfferedThenEndpointsWithoutDuplicates() {
        let urls = RemotePlaybackCandidatePolicy.candidateURLs(
            savedURL: "https://silo.example/",
            offeredURL: "https://silo.overlay.example",
            endpoints: [
                ServerEndpoint(url: "https://silo.example", kind: .public),
                ServerEndpoint(url: "https://silo.overlay.example/", kind: .provider, provider: "tailscale", displayName: "Tailscale"),
                ServerEndpoint(url: "https://other.overlay.example", kind: .provider, provider: "zerotier", displayName: "ZeroTier"),
            ]
        )
        XCTAssertEqual(urls, [
            "https://silo.example",
            "https://silo.overlay.example",
            "https://other.overlay.example",
        ])
        XCTAssertEqual(
            RemotePlaybackCandidatePolicy.candidateURLs(savedURL: nil, offeredURL: "https://a.example", endpoints: nil),
            ["https://a.example"]
        )
    }
}

import XCTest
@testable import Silo

@MainActor
final class ServerInvitationParserTests: XCTestCase {
    func testValidHTTPSSignupInvitation() throws {
        let invitation = try ServerInvitationParser.parse(try invitationURL(
            "v=1&action=signup&server=https%3A%2F%2Fmedia.example.com&invite=TESTCODE"
        ))

        XCTAssertEqual(invitation.action, .signup)
        XCTAssertEqual(invitation.serverURL.absoluteString, "https://media.example.com")
        XCTAssertEqual(invitation.hostname, "media.example.com")
        XCTAssertEqual(invitation.inviteCode, "TESTCODE")
        XCTAssertFalse(invitation.usesPlainHTTP)
    }

    func testValidAddServerInvitationWithoutInvite() throws {
        let invitation = try ServerInvitationParser.parse(try invitationURL(
            "v=1&action=add-server&server=http%3A%2F%2Fsilo.lan%3A8090"
        ))

        XCTAssertEqual(invitation.action, .addServer)
        XCTAssertEqual(invitation.serverURL.absoluteString, "http://silo.lan:8090")
        XCTAssertNil(invitation.inviteCode)
        XCTAssertTrue(invitation.usesPlainHTTP)
    }

    func testPercentEncodedServerURLWithPathAndQuery() throws {
        let invitation = try ServerInvitationParser.parse(try invitationURL(
            "v=1&action=signup&server=https%3A%2F%2FMedia.Example.com%3A443%2Fsilo%3Flibrary%3Dfamily&invite=A1"
        ))

        XCTAssertEqual(
            invitation.serverURL.absoluteString,
            "https://media.example.com/silo?library=family"
        )
    }

    func testMalformedFragmentIsRejected() throws {
        XCTAssertThrowsError(try ServerInvitationParser.parse(try invitationURL(
            "v=1&action=signup&invite=TESTCODE"
        ))) { error in
            XCTAssertEqual(error as? ServerInvitationParser.ParseError, .invalidServer)
        }
    }

    func testUnsupportedActionAndVersionAreRejected() throws {
        XCTAssertThrowsError(try ServerInvitationParser.parse(try invitationURL(
            "v=2&action=signup&server=https%3A%2F%2Fmedia.example.com"
        ))) { error in
            XCTAssertEqual(error as? ServerInvitationParser.ParseError, .unsupportedVersion)
        }

        XCTAssertThrowsError(try ServerInvitationParser.parse(try invitationURL(
            "v=1&action=authenticate&server=https%3A%2F%2Fmedia.example.com"
        ))) { error in
            XCTAssertEqual(error as? ServerInvitationParser.ParseError, .unsupportedAction)
        }
    }

    func testEmbeddedServerCredentialsAreRejected() throws {
        XCTAssertThrowsError(try ServerInvitationParser.parse(try invitationURL(
            "v=1&action=signup&server=https%3A%2F%2Fuser%3Apassword%40media.example.com"
        ))) { error in
            XCTAssertEqual(error as? ServerInvitationParser.ParseError, .credentialsNotAllowed)
        }
    }

    func testOversizedPayloadIsRejected() throws {
        let oversizedInvite = String(repeating: "A", count: ServerInvitationParser.maximumURLBytes)
        XCTAssertThrowsError(try ServerInvitationParser.parse(try invitationURL(
            "v=1&action=signup&server=https%3A%2F%2Fmedia.example.com&invite=\(oversizedInvite)"
        ))) { error in
            XCTAssertEqual(error as? ServerInvitationParser.ParseError, .oversized)
        }
    }

    func testCancellationLeavesServerRegistryUnchanged() throws {
        let suiteName = "ServerInvitationTests.suite.\(UUID().uuidString)"
        let standardName = "ServerInvitationTests.standard.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let standard = UserDefaults(suiteName: standardName)!
        defer {
            suite.removePersistentDomain(forName: suiteName)
            standard.removePersistentDomain(forName: standardName)
        }

        let registry = ServerRegistry(
            defaults: SharedDefaults(suite: suite, standard: standard),
            keychain: SharedKeychain(service: "ServerInvitationTests.\(UUID().uuidString)", accessGroup: nil)
        )
        let existing = ServerEntry(
            id: ServerRegistry.serverId(for: "https://existing.example.com"),
            url: "https://existing.example.com",
            fetchedName: "Existing",
            profileId: nil,
            lastUsedAt: Date(timeIntervalSince1970: 1)
        )
        registry.addOrUpdate(existing)
        let before = registry.entries
        var checkerWasCalled = false
        let coordinator = ServerInvitationCoordinator(
            serverChecker: { _ in
                checkerWasCalled = true
                return SetupStatus(needsSetup: false)
            },
            signupStatusChecker: { true }
        )

        XCTAssertTrue(coordinator.receive(try invitationURL(
            "v=1&action=signup&server=https%3A%2F%2Fnew.example.com&invite=SECRET"
        )))
        coordinator.cancel()

        XCTAssertNil(coordinator.pendingInvitation)
        XCTAssertFalse(checkerWasCalled)
        XCTAssertEqual(registry.entries, before)
    }

    private func invitationURL(_ fragment: String) throws -> URL {
        try XCTUnwrap(URL(string: "https://temporary.example/#\(fragment)"))
    }
}

final class ContinuumDeepLinkCompatibilityTests: XCTestCase {
    func testExistingContinuumRoutesRemainUnchanged() throws {
        XCTAssertEqual(
            ContinuumDeepLink.parse(try XCTUnwrap(URL(string: "continuum://item/movie-1"))),
            .item(contentId: "movie-1")
        )
        XCTAssertEqual(
            ContinuumDeepLink.parse(try XCTUnwrap(URL(string: "continuum://play/episode-2"))),
            .play(contentId: "episode-2")
        )
        XCTAssertEqual(
            ContinuumDeepLink.parse(try XCTUnwrap(URL(string: "continuum://downloads"))),
            .downloads
        )
        XCTAssertNil(ContinuumDeepLink.parse(try XCTUnwrap(URL(string: "https://temporary.example/#v=1"))))
    }
}

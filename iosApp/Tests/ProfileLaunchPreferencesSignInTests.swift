import XCTest
@testable import Silo

/// The per-Apple-TV-user launch state for Silo accounts (plan §2.7): the
/// linked account, remembered profiles and pending switches per sign-in, the
/// legacy owner's adoption of server-keyed state, Ask For, and rollback.
final class ProfileLaunchPreferencesSignInTests: XCTestCase {
    private let alex = SignInKey.make("aG9tZQ", "12")
    private let sam = SignInKey.make("aG9tZQ", "13")
    private let friend = SignInKey.make("ZnJpZW5k", "12")

    private func preferences(persists: @escaping () -> Bool = { true }) throws -> (ProfileLaunchPreferences, SharedDefaults) {
        let name = "ProfileLaunchPreferencesSignInTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        return (ProfileLaunchPreferences(defaults: defaults, persistenceOverride: { _ in persists() }), defaults)
    }

    private func remembered(_ profileID: String, epoch: String = "epoch") -> RememberedProfile {
        RememberedProfile(profileID: profileID, requiredPINAtSelection: false, accountEpoch: epoch)
    }

    func testLinkAndForgetAccountPersist() throws {
        let (preferences, defaults) = try preferences()
        XCTAssertTrue(preferences.link(.signIn(alex)))
        XCTAssertEqual(ProfileLaunchPreferences(defaults: defaults).state.linkedAccountRef, .signIn(alex))

        // Removing another account leaves the link alone.
        XCTAssertTrue(preferences.forgetAccount(.signIn(sam)))
        XCTAssertEqual(preferences.state.linkedAccountRef, .signIn(alex))

        XCTAssertTrue(preferences.forgetAccount(.signIn(alex)))
        XCTAssertNil(preferences.state.linkedAccount)
        XCTAssertNil(ProfileLaunchPreferences(defaults: defaults).state.linkedAccount)

        XCTAssertTrue(preferences.link(.pendingLegacy(serverID: alex.serverID)))
        XCTAssertEqual(ProfileLaunchPreferences(defaults: defaults).state.linkedAccountRef,
                       .pendingLegacy(serverID: alex.serverID))
    }

    /// Two accounts on one server keep their own remembered profile and
    /// pending switch, even with the same profile ID.
    func testRememberAndSwitchesArePerSignIn() throws {
        let (preferences, _) = try preferences()
        XCTAssertTrue(preferences.remember(profileID: "default", requiresPIN: false, accountEpoch: "a",
                                           for: alex, legacyOwnerAccountID: nil))
        XCTAssertTrue(preferences.remember(profileID: "default", requiresPIN: true, accountEpoch: "b",
                                           for: sam, legacyOwnerAccountID: nil))
        XCTAssertTrue(preferences.markSelectionRequired(for: sam))

        XCTAssertEqual(preferences.rememberedProfile(for: alex, accountEpoch: "a")?.requiredPINAtSelection, false)
        XCTAssertEqual(preferences.rememberedProfile(for: sam, accountEpoch: "b")?.requiredPINAtSelection, true)
        XCTAssertFalse(preferences.state.isSelectionRequired(for: alex, legacyOwnerAccountID: nil))
        XCTAssertTrue(preferences.state.isSelectionRequired(for: sam, legacyOwnerAccountID: nil))

        XCTAssertTrue(preferences.forgetSignIn(sam, legacyOwnerAccountID: nil))
        XCTAssertNil(preferences.rememberedProfile(for: sam, accountEpoch: "b"))
        XCTAssertFalse(preferences.state.isSelectionRequired(for: sam, legacyOwnerAccountID: nil))
        XCTAssertNotNil(preferences.rememberedProfile(for: alex, accountEpoch: "a"), "the other account keeps its own")
    }

    /// The server-keyed state from before sign-ins existed belongs to the
    /// server's legacy owner: it adopts it, and nobody else reads it.
    func testOnlyTheLegacyOwnerAdoptsServerKeyedState() throws {
        let (preferences, _) = try preferences()
        XCTAssertTrue(preferences.rememberLegacy(profileID: "jamie", requiresPIN: true, accountEpoch: "epoch",
                                                 forServer: alex.serverID))
        XCTAssertTrue(preferences.markLegacySelectionRequired(forServer: alex.serverID))

        XCTAssertFalse(preferences.adoptLegacyEntries(for: sam, accountEpoch: "epoch", legacyOwnerAccountID: "12"))
        XCTAssertNil(preferences.state.rememberedBySignIn)

        XCTAssertTrue(preferences.adoptLegacyEntries(for: alex, accountEpoch: "epoch", legacyOwnerAccountID: "12"))
        XCTAssertEqual(preferences.state.rememberedBySignIn?[alex.storageKey],
                       RememberedProfile(profileID: "jamie", requiredPINAtSelection: true, accountEpoch: "epoch"))
        XCTAssertTrue(preferences.state.isSelectionRequired(for: alex, legacyOwnerAccountID: nil))
        XCTAssertNil(preferences.legacyRememberedProfile(forServer: alex.serverID))
        XCTAssertTrue(preferences.state.selectionRequiredServerIDs.isEmpty)
    }

    /// A legacy entry from another session (another epoch) is dropped, not
    /// adopted: it was recorded for a sign-in that no longer exists.
    func testAdoptionNeedsTheSignInsEpoch() throws {
        let (preferences, _) = try preferences()
        preferences.rememberLegacy(profileID: "jamie", requiresPIN: false, accountEpoch: "old", forServer: alex.serverID)

        XCTAssertTrue(preferences.adoptLegacyEntries(for: alex, accountEpoch: "new", legacyOwnerAccountID: "12"))
        XCTAssertNil(preferences.state.rememberedBySignIn?[alex.storageKey])
        XCTAssertNil(preferences.legacyRememberedProfile(forServer: alex.serverID))
    }

    /// Remembering for the legacy owner ends the server-keyed pending switch
    /// too, or the old entry would keep asking forever.
    func testRememberingForTheOwnerEndsTheLegacyPendingSwitch() throws {
        let (preferences, _) = try preferences()
        preferences.markLegacySelectionRequired(forServer: alex.serverID)
        XCTAssertTrue(preferences.state.isSelectionRequired(for: alex, legacyOwnerAccountID: "12"))

        preferences.remember(profileID: "p", requiresPIN: false, accountEpoch: "e", for: alex, legacyOwnerAccountID: "12")

        XCTAssertFalse(preferences.state.isSelectionRequired(for: alex, legacyOwnerAccountID: "12"))
    }

    func testForgettingAServerDropsEverythingForIt() throws {
        let (preferences, _) = try preferences()
        preferences.remember(profileID: "p", requiresPIN: false, accountEpoch: "e", for: alex, legacyOwnerAccountID: nil)
        preferences.remember(profileID: "p", requiresPIN: false, accountEpoch: "e", for: friend, legacyOwnerAccountID: nil)
        preferences.markSelectionRequired(for: sam)
        preferences.rememberLegacy(profileID: "p", requiresPIN: false, accountEpoch: "e", forServer: alex.serverID)
        preferences.link(.signIn(sam))

        XCTAssertTrue(preferences.forgetServer(alex.serverID))

        XCTAssertNil(preferences.rememberedProfile(for: alex, accountEpoch: "e"))
        XCTAssertNotNil(preferences.rememberedProfile(for: friend, accountEpoch: "e"))
        XCTAssertFalse(preferences.state.isSelectionRequired(for: sam, legacyOwnerAccountID: nil))
        XCTAssertNil(preferences.legacyRememberedProfile(forServer: alex.serverID))
        XCTAssertNil(preferences.state.linkedAccount, "a link to an account on the server goes")
    }

    func testForgettingAServerKeepsALinkToAnotherServer() throws {
        let (preferences, _) = try preferences()
        preferences.link(.signIn(friend))
        preferences.forgetServer(alex.serverID)
        XCTAssertEqual(preferences.state.linkedAccountRef, .signIn(friend))

        preferences.link(.pendingLegacy(serverID: alex.serverID))
        XCTAssertTrue(preferences.forgetServer(alex.serverID))
        XCTAssertNil(preferences.state.linkedAccount)
    }

    func testAskForPersistsAndDefaultsToProfileOnly() throws {
        let (preferences, defaults) = try preferences()
        XCTAssertEqual(preferences.askFor, .profileOnly)
        XCTAssertNil(preferences.state.askFor)

        preferences.askFor = .accountAndProfile
        XCTAssertEqual(ProfileLaunchPreferences(defaults: defaults).askFor, .accountAndProfile)
    }

    /// A change that can't be saved is rolled back.
    func testFailedWritesChangeNothing() throws {
        var persists = true
        let (preferences, _) = try preferences(persists: { persists })
        preferences.link(.signIn(alex))
        persists = false

        XCTAssertFalse(preferences.link(.signIn(sam)))
        XCTAssertFalse(preferences.forgetAccount(.signIn(alex)))
        XCTAssertFalse(preferences.remember(profileID: "p", requiresPIN: false, accountEpoch: "e",
                                            for: alex, legacyOwnerAccountID: nil))
        XCTAssertFalse(preferences.markSelectionRequired(for: alex))
        preferences.askFor = .accountAndProfile

        XCTAssertEqual(preferences.state.linkedAccountRef, .signIn(alex))
        XCTAssertNil(preferences.state.rememberedBySignIn)
        XCTAssertNil(preferences.state.selectionRequiredSignIns)
        XCTAssertEqual(preferences.askFor, .profileOnly)
    }
}

import Foundation
import XCTest
@testable import Silo

/// Top Shelf finds this Apple TV user's credentials without the app running,
/// before, during, and after sign-in migration (plan §2.12, §3.6), and shows
/// nothing whenever the app's mirrors say it is signed in somewhere else.
final class TopShelfSignInTests: XCTestCase {
    private typealias F = SignInStoreFixture
    private static let sectionsPath = "/api/v2/home/sections"
    private let alexHome = SignInKey.make(F.home, "12")
    private let samHome = SignInKey.make(F.home, "13")

    private struct Harness {
        let keychain: SharedKeychain
        let suite: UserDefaults
        let stub: APIv2TestStub
        let epoch: UUID

        var defaults: SharedDefaults { SharedDefaults(suite: suite, standard: suite) }

        func client(defaults: SharedDefaults? = nil) -> TopShelfHTTPClient {
            TopShelfHTTPClient(defaults: defaults ?? self.defaults, keychain: keychain, session: stub.makeSession())
        }

        func setState(_ state: ProfileLaunchState, in suite: UserDefaults? = nil) throws {
            (suite ?? self.suite).set(try JSONEncoder().encode(state), forKey: SharedStorage.profileLaunchStateKey)
        }

        /// Runs the app's migration with this Apple TV user's mirrors, then
        /// stops before the app selects anything (no `activeAccountId` yet).
        func migrate() async {
            let store = TokenStore(keychain: keychain, defaults: defaults)
            _ = await store.migrateLegacySessionsIfNeeded(servers: [(F.home, F.homeURL)], activeServerID: F.home)
        }
    }

    /// Before the update: Home signed in (account 12 when `verified`), Jamie
    /// remembered with her PIN, and this Apple TV user's proof for it.
    private func harness(verified: Bool = true) throws -> Harness {
        let name = "TopShelfSignInTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let epoch = UUID()
        try AccountSessionPersistence(keychain: keychain).save(CanonicalAccountSession(version: 1, signedOut: false,
            origin: F.homeURL, accountID: verified ? "12" : nil, epoch: epoch,
            accessToken: "home-access", refreshToken: "home-refresh"), serverID: F.home)
        let account = keychain.withAudience(.userIndependent)
        account.set("home-access", for: SharedStorage.accessTokenAccount(for: F.home))
        account.set("home-refresh", for: SharedStorage.refreshTokenAccount(for: F.home))
        account.set(epoch.uuidString, for: SharedStorage.accountEpochAccount(for: F.home))
        keychain.withAudience(.currentUser).set("pin-proof", for: SharedStorage.profileTokenAccount(for: F.home))
        // The saved server list, where each platform's registry keeps it.
        let registry = #"{"entries":[{"id":"\#(F.home)"}]}"#
        account.set(registry, for: SharedStorage.serverRegistryAccount)
        suite.set(Data(registry.utf8), forKey: SharedStorage.serverRegistryDefaultsKey)
        suite.set(F.home, forKey: SharedStorage.activeServerIdKey)
        suite.set(F.homeURL, forKey: SharedStorage.serverUrlKey)
        suite.set("default", forKey: SharedStorage.profileIdKey)
        let h = Harness(keychain: keychain, suite: suite, stub: APIv2TestStub(), epoch: epoch)
        try h.setState(ProfileLaunchState(rememberedByServerID: [
            F.home: RememberedProfile(profileID: "default", requiredPINAtSelection: true, accountEpoch: epoch.uuidString),
        ]))
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)
        return h
    }

    /// The headers Top Shelf's first request carried, or nil when it had no
    /// credentials to send.
    private func shelfRequest(_ client: TopShelfHTTPClient, _ stub: APIv2TestStub) async throws -> StubURLProtocol.Request? {
        guard client.isPersonalizedContentAllowed, let http = client.authenticated() else { return nil }
        _ = try await http.fetchHomeSections(imageSizeQuery: [:])
        return stub.requests.last
    }

    // MARK: - Through migration (plan §3.6)

    func testBeforeTheAppRunsAfterTheUpdateTheServersSlotsAreRead() async throws {
        let h = try harness()

        let request = try await shelfRequest(h.client(), h.stub)

        XCTAssertEqual(request?.header("Authorization"), "Bearer home-access")
        XCTAssertEqual(request?.header("X-Profile-Id"), "default")
        XCTAssertEqual(request?.header("X-Profile-Token"), "pin-proof")
    }

    /// After migration the server's raw slots are gone. Top Shelf finds the
    /// migrated user, its sign-in on the active server, the remembered
    /// profile by epoch, and the old proof, which it reads but never moves.
    func testAfterMigrationTheSignInIsRead() async throws {
        let h = try harness()
        await h.migrate()
        XCTAssertNil(h.keychain.withAudience(.userIndependent).get(SharedStorage.accessTokenAccount(for: F.home)))
        XCTAssertNil(h.suite.string(forKey: SharedStorage.activeAccountIdKey))

        let request = try await shelfRequest(h.client(), h.stub)

        XCTAssertEqual(request?.header("Authorization"), "Bearer home-access")
        XCTAssertEqual(request?.header("X-Profile-Token"), "pin-proof")
        XCTAssertEqual(h.keychain.withAudience(.currentUser).get(SharedStorage.profileTokenAccount(for: F.home)),
                       "pin-proof", "Top Shelf never moves the proof")
        XCTAssertNil(try SignInProofStore(keychain: h.keychain).load(alexHome))
    }

    func testAPendingServerKeepsUsingItsOwnSlots() async throws {
        let h = try harness(verified: false)
        await h.migrate()
        XCTAssertEqual(try SavedSignInStore(keychain: h.keychain).loadIndex()?.users.first?.pendingLegacyServerIDs,
                       [F.home])

        let request = try await shelfRequest(h.client(), h.stub)

        XCTAssertEqual(request?.header("Authorization"), "Bearer home-access")
        XCTAssertEqual(request?.header("X-Profile-Token"), "pin-proof")
    }

    /// Another Apple TV user who hasn't opened Silo since the update has only
    /// their own defaults from before it; their remembered profile carries
    /// the same epoch, so their shelf keeps working.
    func testAnotherAppleTVUserWhoHasNotLaunchedSinceKeepsTheirShelf() async throws {
        let h = try harness()
        await h.migrate()
        let name = "TopShelfSignInTests.other.\(UUID().uuidString)"
        let other = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        other.set(F.home, forKey: SharedStorage.activeServerIdKey)
        other.set(F.homeURL, forKey: SharedStorage.serverUrlKey)
        other.set("kids", forKey: SharedStorage.profileIdKey)
        other.set(h.suite.data(forKey: SharedStorage.serverRegistryDefaultsKey),
                  forKey: SharedStorage.serverRegistryDefaultsKey)
        try h.setState(ProfileLaunchState(behavior: .afterOneHour, rememberedByServerID: [
            F.home: RememberedProfile(profileID: "kids", requiredPINAtSelection: false, accountEpoch: h.epoch.uuidString),
        ]), in: other)

        let request = try await shelfRequest(h.client(defaults: SharedDefaults(suite: other, standard: other)), h.stub)

        XCTAssertEqual(request?.header("Authorization"), "Bearer home-access")
        XCTAssertEqual(request?.header("X-Profile-Id"), "kids")
    }

    // MARK: - Nothing shown

    func testAnotherAccountInTheMirrorShowsNothing() async throws {
        let h = try harness()
        await h.migrate()
        h.suite.set("99", forKey: SharedStorage.activeAccountIdKey)

        let client = h.client()

        XCTAssertFalse(client.isPersonalizedContentAllowed)
        XCTAssertNil(client.authenticated())
    }

    func testPendingProfileSelectionShowsNothing() async throws {
        for byServer in [true, false] {
            let h = try harness()
            await h.migrate()
            var state = ProfileLaunchState(rememberedByServerID: [
                F.home: RememberedProfile(profileID: "default", requiredPINAtSelection: true,
                                          accountEpoch: h.epoch.uuidString),
            ])
            if byServer {
                state.selectionRequiredServerIDs = [F.home]
            } else {
                state.selectionRequiredSignIns = [alexHome.storageKey]
            }
            try h.setState(state)

            XCTAssertFalse(h.client().isPersonalizedContentAllowed, byServer ? "server-keyed" : "sign-in-keyed")
        }
    }

    /// A server the user can no longer open (it was removed from the saved
    /// list) shows nothing.
    func testAServerNoLongerSavedShowsNothing() async throws {
        let h = try harness()
        await h.migrate()
        let empty = #"{"entries":[]}"#
        h.keychain.withAudience(.userIndependent).set(empty, for: SharedStorage.serverRegistryAccount)
        h.suite.set(Data(empty.utf8), forKey: SharedStorage.serverRegistryDefaultsKey)

        XCTAssertFalse(h.client().isPersonalizedContentAllowed)
    }

    func testAnUnreadableIndexShowsNothing() async throws {
        let h = try harness()
        await h.migrate()
        let account = h.keychain.withAudience(.userIndependent)
        XCTAssertTrue(account.set("garbage", for: SharedStorage.usersIndexAccount))
        XCTAssertTrue(account.delete(SharedStorage.usersIndexBackupAccount))

        XCTAssertFalse(h.client().isPersonalizedContentAllowed)
    }

    // MARK: - Resolver rules

    private func signIn(_ key: SignInKey, user: String) -> SavedSignIn {
        SavedSignIn(key: key, userID: user, origin: F.homeURL, accessToken: "\(key.accountID)-access",
                    refreshToken: "\(key.accountID)-refresh", epoch: UUID(), addedAt: Date())
    }

    private func resolve(
        _ index: SiloUserIndex?,
        saved: Set<String> = [F.home, F.friend],
        state: ProfileLaunchState = ProfileLaunchState(),
        server: String? = F.home,
        account: String? = nil,
        profile: String? = "default",
        url: String? = F.homeURL,
        signIns: [SavedSignIn] = [],
        proofs: [SignInKey: SignInProfileProof] = [:],
        legacyProof: String? = nil
    ) -> TopShelfCredentialResolver.Resolution {
        TopShelfCredentialResolver.resolve(
            index: index, savedServerIDs: saved, state: state, activeServerID: server, activeAccountID: account,
            activeProfileID: profile, serverURL: url,
            signIn: { key in signIns.first { $0.key == key } },
            proof: { proofs[$0] },
            legacyProof: { _ in legacyProof }
        )
    }

    func testTheLinkedUsersLastServerIsUsedOnlyWhileTheAppIsThere() {
        let index = SiloUserIndex(users: [
            SiloUser(id: "alex", createdAt: Date(), signIns: [alexHome]),
            SiloUser(id: "sam", createdAt: Date(), signIns: [samHome, .make(F.friend, "13")]),
        ], migratedUserID: "alex", legacyDataOwnerByServerID: [F.home: "12"])
        var state = ProfileLaunchState()
        state.linkedUserID = "sam"
        state.lastServerByUserID = ["sam": F.home]
        let saved = [signIn(alexHome, user: "alex"), signIn(samHome, user: "sam")]

        guard case .signIn(let credential) = resolve(index, state: state, account: "13", signIns: saved) else {
            return XCTFail("sam's sign-in")
        }
        XCTAssertEqual(credential.key, samHome)
        XCTAssertEqual(credential.accessToken, "13-access")
        XCTAssertEqual(credential.legacyOwnerAccountID, "12")

        // The app is signing in to another server.
        XCTAssertEqual(resolve(index, state: state, server: F.friend, account: "13", signIns: saved), .unavailable)
        // Only the legacy owner may go without an account mirror.
        XCTAssertEqual(resolve(index, state: state, account: nil, signIns: saved), .unavailable)
        // The bearer goes only to the sign-in's own address.
        XCTAssertEqual(resolve(index, state: state, account: "13", url: "https://elsewhere.example", signIns: saved),
                       .unavailable)
    }

    /// The app's launch rules (plan §2.8): the migrated user is assumed only
    /// for an Apple TV user who used Silo before users existed, and its
    /// active server only while it has never recorded a last server.
    func testUserAndServerFollowTheAppsLaunchRules() {
        let alexFriend = SignInKey.make(F.friend, "12")
        let index = SiloUserIndex(users: [
            SiloUser(id: "alex", createdAt: Date(), signIns: [alexHome, alexFriend]),
            SiloUser(id: "sam", createdAt: Date(), signIns: [samHome]),
        ], migratedUserID: "alex", legacyDataOwnerByServerID: [F.home: "12"])
        let saved = [signIn(alexHome, user: "alex"), signIn(alexFriend, user: "alex"), signIn(samHome, user: "sam")]

        // Legacy history: the migrated user, on the server the app has active.
        guard case .signIn(let migrated) = resolve(index, account: "12", signIns: saved) else {
            return XCTFail("the migrated user on its active server")
        }
        XCTAssertEqual(migrated.key, alexHome)

        // This Apple TV user has picked servers since: no legacy history, and
        // two users with no link means no personal content.
        var state = ProfileLaunchState()
        state.lastServerByUserID = ["sam": F.home]
        XCTAssertEqual(resolve(index, state: state, account: "12", signIns: saved), .unavailable)

        // The migrated user with a recorded last server uses it, not the
        // mirror; a last server no longer saved falls back to the only one left.
        state = ProfileLaunchState()
        state.linkedUserID = "alex"
        state.lastServerByUserID = ["alex": F.friend]
        XCTAssertEqual(resolve(index, state: state, account: "12", signIns: saved), .unavailable,
                       "the app is on Home but alex last used Friend's")
        guard case .signIn(let onlyLeft) = resolve(index, saved: [F.home], state: state, account: "12",
                                                   signIns: saved) else {
            return XCTFail("Friend's is no longer saved, so Home is alex's only server")
        }
        XCTAssertEqual(onlyLeft.key, alexHome)

        // A server missing from the saved list can't be opened.
        state.lastServerByUserID = nil
        XCTAssertEqual(resolve(index, saved: [F.friend], state: state, account: "12", signIns: saved), .unavailable)
    }

    /// A user created by signing in rather than by migration, with two
    /// servers: until a last server is recorded for it, the server the app
    /// has open is the one, as for the migrated user. Today's single user
    /// with two servers keeps a shelf for whichever server is open.
    func testAUserWithoutALastServerUsesTheServerTheAppHasOpen() {
        let alexFriend = SignInKey.make(F.friend, "12")
        let index = SiloUserIndex(users: [SiloUser(id: "alex", createdAt: Date(), signIns: [alexHome, alexFriend])])
        let friendSignIn = SavedSignIn(key: alexFriend, userID: "alex", origin: F.friendURL, accessToken: "friend-access",
                                       refreshToken: "friend-refresh", epoch: UUID(), addedAt: Date())
        let saved = [signIn(alexHome, user: "alex"), friendSignIn]

        guard case .signIn(let home) = resolve(index, account: "12", signIns: saved) else {
            return XCTFail("Home is open")
        }
        XCTAssertEqual(home.key, alexHome)
        guard case .signIn(let friend) = resolve(index, server: F.friend, account: "12", url: F.friendURL,
                                                 signIns: saved) else {
            return XCTFail("Friend's is open")
        }
        XCTAssertEqual(friend.key, alexFriend)
        XCTAssertEqual(friend.accessToken, "friend-access")

        // Once a last server is recorded, the app opens that one.
        var state = ProfileLaunchState()
        state.lastServerByUserID = ["alex": F.friend]
        XCTAssertEqual(resolve(index, state: state, account: "12", signIns: saved), .unavailable)
    }

    func testWithoutALinkTwoUsersAndNoMigratedUserShowNothing() {
        let index = SiloUserIndex(users: [
            SiloUser(id: "alex", createdAt: Date(), signIns: [alexHome]),
            SiloUser(id: "sam", createdAt: Date(), signIns: [samHome]),
        ])
        let saved = [signIn(alexHome, user: "alex"), signIn(samHome, user: "sam")]

        XCTAssertEqual(resolve(index, account: "12", signIns: saved), .unavailable)
        XCTAssertEqual(resolve(nil), .legacy(serverID: F.home))
        XCTAssertEqual(resolve(nil, server: nil), .unavailable)
    }

    func testExpiredSignInsAndOtherProfilesProofsAreNotUsed() {
        let index = SiloUserIndex(users: [SiloUser(id: "alex", createdAt: Date(), signIns: [alexHome])],
                                  legacyDataOwnerByServerID: [F.home: "12"])
        var expired = signIn(alexHome, user: "alex")
        expired.accessToken = nil
        expired.refreshToken = nil
        expired.epoch = nil
        XCTAssertEqual(resolve(index, account: "12", signIns: [expired]), .unavailable)

        let saved = [signIn(alexHome, user: "alex")]
        let otherProfile = resolve(index, account: "12", signIns: saved,
                                   proofs: [alexHome: SignInProfileProof(profileID: "kids", token: "kids-proof")],
                                   legacyProof: "old-proof")
        guard case .signIn(let credential) = otherProfile else { return XCTFail() }
        XCTAssertNil(credential.profileToken, "a proof for another profile is never sent")

        let adopted = resolve(index, account: "12", signIns: saved,
                              proofs: [alexHome: SignInProfileProof(profileID: nil, token: "adopted")])
        guard case .signIn(let withProof) = adopted else { return XCTFail() }
        XCTAssertEqual(withProof.profileToken, "adopted")

        let orphan = resolve(index, account: "12", signIns: [signIn(alexHome, user: "someone-else")])
        XCTAssertEqual(orphan, .unavailable)
    }

    func testTheSignInPolicyUsesTheEpochAndLegacyOwnerRules() {
        let epoch = UUID().uuidString
        var state = ProfileLaunchState(rememberedByServerID: [
            F.home: RememberedProfile(profileID: "default", requiredPINAtSelection: false, accountEpoch: epoch),
        ])
        func allowed(_ key: SignInKey, epoch accountEpoch: String) -> Bool {
            TopShelfProfilePolicy.allowsPersonalizedContent(state: state, key: key, legacyOwnerAccountID: "12",
                activeProfileID: "default", accountEpoch: accountEpoch, hasStoredProfileToken: false)
        }

        XCTAssertTrue(allowed(alexHome, epoch: epoch))
        XCTAssertFalse(allowed(samHome, epoch: UUID().uuidString), "another sign-in's epoch never matches")
        state.selectionRequiredServerIDs = [F.home]
        XCTAssertFalse(allowed(alexHome, epoch: epoch))
        XCTAssertTrue(allowed(samHome, epoch: epoch), "a server-keyed pending selection is the legacy owner's")
    }
}

#if os(tvOS)
/// Saved sign-ins and the user index are shared by every Apple TV user;
/// PIN proofs belong to the one who entered the PIN.
final class SignInKeychainAudienceTests: XCTestCase {
    func testSignInsAndIndexAreSharedAndProofsArePerAppleTVUser() async throws {
        XCTAssertEqual(SavedSignInStore.audience, .userIndependent)
        XCTAssertEqual(SignInProofStore.audience, .currentUser)

        let f = try SignInStoreFixture.make(self)
        let keychain = f.keychain
        let store = TokenStore(keychain: keychain, defaults: f.defaults)
        try SavedSignInStore(keychain: keychain).saveIndex(SiloUserIndex())
        await f.activate(SignInStoreFixture.home, url: SignInStoreFixture.homeURL, in: store)
        try await f.install("12", access: "a", refresh: "r", placement: .newUser, in: store)
        await store.setProfileId("default")
        _ = await store.setProfileToken("pin")
        let key = SignInKey.make(SignInStoreFixture.home, "12")

        let shared = keychain.withAudience(.userIndependent)
        XCTAssertNotNil(try shared.getChecked(SharedStorage.usersIndexAccount))
        XCTAssertNotNil(try shared.getChecked(SharedStorage.signInAccount(key)))
        XCTAssertNotNil(try keychain.withAudience(.currentUser).getChecked(SharedStorage.signInProofAccount(key)))
    }
}
#endif

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
    /// sign-in that took over the active server's session, the remembered
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
        XCTAssertEqual(try SavedSignInStore(keychain: h.keychain).loadIndex()?.accounts,
                       [.pendingLegacy(serverID: F.home)])

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

    private func signIn(_ key: SignInKey, origin: String = F.homeURL) -> SavedSignIn {
        SavedSignIn(key: key, origin: origin, accessToken: "\(key.accountID)-access",
                    refreshToken: "\(key.accountID)-refresh", epoch: UUID(), addedAt: Date())
    }

    private func resolve(
        _ index: SiloAccountIndex?,
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

    /// The app's launch rules (`SiloLaunchResolver`, plan §2.8), and only
    /// while the app has that account's server open.
    func testTheLinkedAccountIsUsedOnlyWhileTheAppIsOnItsServer() {
        let samFriend = SignInKey.make(F.friend, "13")
        let index = SiloAccountIndex(accounts: [.signIn(alexHome), .signIn(samHome), .signIn(samFriend)],
                                     migrated: true, legacyDataOwnerByServerID: [F.home: "12"])
        let state = ProfileLaunchState(linkedAccount: SiloAccountRef.signIn(samHome).storageKey)
        let saved = [signIn(alexHome), signIn(samHome), signIn(samFriend, origin: F.friendURL)]

        guard case .signIn(let credential) = resolve(index, state: state, account: "13", signIns: saved) else {
            return XCTFail("sam's sign-in on Home")
        }
        XCTAssertEqual(credential.key, samHome)
        XCTAssertEqual(credential.accessToken, "13-access")
        XCTAssertEqual(credential.legacyOwnerAccountID, "12")

        // The app is signing in to another server.
        XCTAssertEqual(resolve(index, state: state, server: F.friend, account: "13", url: F.friendURL,
                               signIns: saved), .unavailable)
        // Only the legacy owner may go without an account mirror.
        XCTAssertEqual(resolve(index, state: state, account: nil, signIns: saved), .unavailable)
        // The bearer goes only to the sign-in's own address.
        XCTAssertEqual(resolve(index, state: state, account: "13", url: "https://elsewhere.example", signIns: saved),
                       .unavailable)
    }

    /// The legacy owner is Home's, but this Apple TV user linked an account
    /// on Friend's: nothing shows while the app has Home open.
    func testALinkedAccountOnAnotherServerShowsNothing() {
        let samFriend = SignInKey.make(F.friend, "13")
        let index = SiloAccountIndex(accounts: [.signIn(alexHome), .signIn(samFriend)],
                                     migrated: true, legacyDataOwnerByServerID: [F.home: "12"])
        let state = ProfileLaunchState(linkedAccount: SiloAccountRef.signIn(samFriend).storageKey)
        let saved = [signIn(alexHome), signIn(samFriend, origin: F.friendURL)]

        XCTAssertEqual(resolve(index, state: state, account: "12", signIns: saved), .unavailable)
        XCTAssertEqual(resolve(index, state: state, signIns: saved), .unavailable)
    }

    /// For an Apple TV user who used Silo before accounts existed (no link
    /// yet), the account that took over the active server's session.
    func testTheLegacyOwnerIsUsedWithoutALink() {
        let index = SiloAccountIndex(accounts: [.signIn(samHome), .signIn(alexHome)],
                                     migrated: true, legacyDataOwnerByServerID: [F.home: "12"])
        let saved = [signIn(alexHome), signIn(samHome)]

        guard case .signIn(let owner) = resolve(index, signIns: saved) else {
            return XCTFail("the legacy owner, before the app set an account mirror")
        }
        XCTAssertEqual(owner.key, alexHome)

        // Once this Apple TV user linked an account, now removed, the two
        // left are a choice the app hasn't made.
        let linkedGone = ProfileLaunchState(linkedAccount: SiloAccountRef.signIn(.make(F.home, "99")).storageKey)
        XCTAssertEqual(resolve(index, state: linkedGone, account: "12", signIns: saved), .unavailable)

        // A link made while Home was pending names the sign-in that took over.
        let linkedLegacy = ProfileLaunchState(linkedAccount: SiloAccountRef.pendingLegacy(serverID: F.home).storageKey)
        guard case .signIn(let stale) = resolve(index, state: linkedLegacy, account: "12", signIns: saved) else {
            return XCTFail("the pending legacy link resolved")
        }
        XCTAssertEqual(stale.key, alexHome)
    }

    func testAPendingLegacyAccountReadsTheServersSlots() {
        let index = SiloAccountIndex(accounts: [.signIn(SignInKey.make(F.friend, "13")), .pendingLegacy(serverID: F.home)],
                                     migrated: true)

        XCTAssertEqual(resolve(index), .legacy(serverID: F.home))
        let linked = ProfileLaunchState(linkedAccount: SiloAccountRef.pendingLegacy(serverID: F.home).storageKey)
        XCTAssertEqual(resolve(index, state: linked), .legacy(serverID: F.home))
        XCTAssertEqual(resolve(SiloAccountIndex(accounts: [.pendingLegacy(serverID: F.home)])), .legacy(serverID: F.home))
    }

    func testTheOnlyAccountIsUsedOnItsOwnServer() {
        let index = SiloAccountIndex(accounts: [.signIn(alexHome)])
        guard case .signIn(let only) = resolve(index, account: "12", signIns: [signIn(alexHome)]) else {
            return XCTFail("the only account")
        }
        XCTAssertEqual(only.key, alexHome)

        let onFriend = SignInKey.make(F.friend, "12")
        XCTAssertEqual(resolve(SiloAccountIndex(accounts: [.signIn(onFriend)]), account: "12",
                               signIns: [signIn(onFriend, origin: F.friendURL)]), .unavailable)
        // A server missing from the saved list can't be opened.
        XCTAssertEqual(resolve(index, saved: [F.friend], account: "12", signIns: [signIn(alexHome)]), .unavailable)
        // An account on a server no longer saved doesn't count, as the app's
        // launch rules don't count it: Home's account is still the only one.
        let withRemoved = SiloAccountIndex(accounts: [.signIn(onFriend), .signIn(alexHome)])
        guard case .signIn(let stillOnly) = resolve(withRemoved, saved: [F.home], account: "12",
                                                     signIns: [signIn(alexHome)]) else {
            return XCTFail("the only account on a saved server")
        }
        XCTAssertEqual(stillOnly.key, alexHome)
    }

    func testWithoutALinkTwoAccountsAndNoLegacyOwnerShowNothing() {
        let index = SiloAccountIndex(accounts: [.signIn(alexHome), .signIn(samHome)])
        let saved = [signIn(alexHome), signIn(samHome)]

        XCTAssertEqual(resolve(index, account: "12", signIns: saved), .unavailable)
        XCTAssertEqual(resolve(nil), .legacy(serverID: F.home))
        XCTAssertEqual(resolve(nil, server: nil), .unavailable)
    }

    func testExpiredSignInsAndOtherProfilesProofsAreNotUsed() {
        let index = SiloAccountIndex(accounts: [.signIn(alexHome)], legacyDataOwnerByServerID: [F.home: "12"])
        var expired = signIn(alexHome)
        expired.accessToken = nil
        expired.refreshToken = nil
        expired.epoch = nil
        XCTAssertEqual(resolve(index, account: "12", signIns: [expired]), .unavailable)

        let saved = [signIn(alexHome)]
        let otherProfile = resolve(index, account: "12", signIns: saved,
                                   proofs: [alexHome: SignInProfileProof(profileID: "kids", token: "kids-proof")],
                                   legacyProof: "old-proof")
        guard case .signIn(let credential) = otherProfile else { return XCTFail() }
        XCTAssertNil(credential.profileToken, "a proof for another profile is never sent")

        let adopted = resolve(index, account: "12", signIns: saved,
                              proofs: [alexHome: SignInProfileProof(profileID: nil, token: "adopted")])
        guard case .signIn(let withProof) = adopted else { return XCTFail() }
        XCTAssertEqual(withProof.profileToken, "adopted")

        // A listed sign-in whose item can't be read.
        XCTAssertEqual(resolve(index, account: "12", signIns: []), .unavailable)
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
/// Saved sign-ins and the accounts index are shared by every Apple TV user;
/// PIN proofs belong to the one who entered the PIN.
final class SignInKeychainAudienceTests: XCTestCase {
    func testSignInsAndIndexAreSharedAndProofsArePerAppleTVUser() async throws {
        XCTAssertEqual(SavedSignInStore.audience, .userIndependent)
        XCTAssertEqual(SignInProofStore.audience, .currentUser)

        let f = try SignInStoreFixture.make(self)
        let keychain = f.keychain
        let store = TokenStore(keychain: keychain, defaults: f.defaults)
        try SavedSignInStore(keychain: keychain).saveIndex(SiloAccountIndex())
        await f.activate(SignInStoreFixture.home, url: SignInStoreFixture.homeURL, in: store)
        try await f.install("12", access: "a", refresh: "r", in: store)
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

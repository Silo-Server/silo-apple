import Foundation
import Observation
import SwiftUI
import XCTest
@testable import Silo

/// The accounts `Device.threeAccounts()` saves, in order: alex on Home Silo
/// and on Friend's Silo, then sam on Home Silo.
private let alexHome = SignInKey.make(SignInStoreFixture.home, "12")
private let alexFriend = SignInKey.make(SignInStoreFixture.friend, "40")
private let samHome = SignInKey.make(SignInStoreFixture.home, "13")

/// `SiloAccountCoordinator` on an isolated device: its own token store,
/// server list, launch state, and a stubbed network that answers every
/// request (logouts included) with no content. Each test drives the flows
/// the screens drive and checks the saved accounts, the selection, the
/// launch state, the router, and which sessions were revoked.
@MainActor
final class SiloAccountCoordinatorTests: XCTestCase {
    private typealias F = SignInStoreFixture
    private static let logout = "/api/v2/auth/logout"

    /// Resolves the registry's dependency on the service built after it.
    private final class AuthBox: @unchecked Sendable {
        weak var auth: AuthService?
    }

    /// Values the coordinator's injected closures read, settable mid-test.
    private final class Knobs: @unchecked Sendable {
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var allowsEndingTemporaryIdentity = true
        /// Servers whose pushes sign-out turned off, in order.
        var pushTurnedOff: [String] = []
    }

    @MainActor
    private final class Device {
        let f: F
        let stub: APIv2TestStub
        let preferences: ProfileLaunchPreferences
        let registry: ServerRegistry
        let auth: AuthService
        let accounts: SiloAccountCoordinator
        let router: AppRouter
        let knobs: Knobs
        /// The access tokens each sign-in was issued, oldest first.
        private(set) var issuedTokens: [SignInKey: [String]] = [:]
        private var issued = 0

        var now: Date {
            get { knobs.now }
            set { knobs.now = newValue }
        }

        var allowsEndingTemporaryIdentity: Bool {
            get { knobs.allowsEndingTemporaryIdentity }
            set { knobs.allowsEndingTemporaryIdentity = newValue }
        }

        var pushTurnedOff: [String] { knobs.pushTurnedOff }

        /// `migrated: false` leaves the device before sign-in migration, with
        /// no accounts index yet.
        init(_ test: XCTestCase, migrated: Bool = true) throws {
            f = try F.make(test)
            if migrated { try f.startAccountModel() }
            f.defaults.set(true, forKey: ServerRegistry.migratedKey)
            stub = APIv2TestStub()
            stub.reply(204, "")
            let http = HTTPClient(session: stub.makeSession(), tokenStore: f.store)
            preferences = ProfileLaunchPreferences(defaults: f.defaults)
            let box = AuthBox()
            registry = ServerRegistry(
                defaults: f.defaults, keychain: f.keychain, launchPreferences: preferences,
                tokenStore: f.store, httpClient: http,
                unregisterPush: { _ in }, restorePush: { _ in },
                clearCaches: {},
                isLoggedIn: { box.auth?.isLoggedIn ?? false },
                resolveProfile: { lease in await box.auth?.resolveActiveProfileForSession(holding: lease) ?? false }
            )
            let store = f.store
            let validator = RestoredSessionValidator(
                setupProbe: { _ in APIv2SetupStatus(needsSetup: false) },
                accountProbe: {},
                identityReader: { await store.refreshAccountIdentity() },
                accessTokenReader: { _ in await store.hasUsableCredential() }
            )
            let knobs = Knobs()
            self.knobs = knobs
            auth = AuthService(
                serverRegistry: registry, launchPreferences: preferences, restoredSessionValidator: validator,
                httpClient: http, tokenStore: f.store, defaults: f.defaults, sessionPersistence: f.sessions.sessions,
                purgeDiagnostics: { _ in true }, unregisterPush: { knobs.pushTurnedOff.append($0) },
                restorePush: { _ in }
            )
            box.auth = auth
            accounts = SiloAccountCoordinator(
                auth: auth,
                now: { knobs.now },
                endTemporaryIdentity: { knobs.allowsEndingTemporaryIdentity },
                device: .appleTV
            )
            router = AppRouter()
            router.accountsOverride = accounts
            XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: F.home, url: F.homeURL, fetchedName: "Home Silo",
                                                             lastUsedAt: Date(timeIntervalSinceReferenceDate: 2))))
            XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: F.friend, url: F.friendURL, fetchedName: "Friend's Silo",
                                                             lastUsedAt: Date(timeIntervalSinceReferenceDate: 1))))
        }

        /// A sign-in finishing on the screen `context` opened for `serverID`.
        @discardableResult
        func signIn(_ accountID: String, _ username: String, on serverID: String,
                    context: SignInContext) async throws -> SignInCompletion {
            router.signInContext = context
            let began = await accounts.beginSignIn(serverID: serverID, context: context, router: router)
            XCTAssertTrue(began)
            return try await finishSignIn(accountID, username, on: serverID)
        }

        /// The token pair the server answered, placed in the running sign-in.
        @discardableResult
        func finishSignIn(_ accountID: String, _ username: String, on serverID: String) async throws -> SignInCompletion {
            let identity = await f.store.refreshAccountIdentity()
            let expected = try XCTUnwrap(identity)
            XCTAssertEqual(expected.serverId, serverID)
            return try await accounts.completeSignIn(pending(accountID, username, expected: expected), router: router)
        }

        /// A token pair the server issued for `accountID`; every one is new.
        func pending(_ accountID: String, _ username: String, expected: RefreshAccountIdentity) -> PendingSignIn {
            issued += 1
            let access = "\(accountID)@\(expected.serverId == F.home ? "home" : "friend")-\(issued)"
            issuedTokens[.make(expected.serverId, accountID), default: []].append(access)
            return PendingSignIn(accessToken: access, refreshToken: access + "-refresh",
                                 account: SignInAccount(id: accountID, username: username), expected: expected)
        }

        /// The access token the `nth` sign-in of `accountID` on `serverID`
        /// was issued.
        func token(_ accountID: String, on serverID: String, _ nth: Int = 0) -> String {
            issuedTokens[.make(serverID, accountID)]?[nth] ?? "none"
        }

        func index() throws -> SiloAccountIndex { try XCTUnwrap(try f.index()) }

        /// The accounts index's list, in order.
        func savedAccounts() throws -> [SiloAccountRef] { try index().accounts }

        var selection: CredentialSelection {
            get async { await f.store.currentSelection() }
        }

        func revokedAccessTokens() -> [String] {
            stub.requests.filter { $0.path == SiloAccountCoordinatorTests.logout }
                .compactMap { $0.header("Authorization")?.replacingOccurrences(of: "Bearer ", with: "") }
        }

        func waitForRevocations(_ count: Int) async throws {
            for _ in 0..<300 where revokedAccessTokens().count < count {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(revokedAccessTokens().count, count, "revocations: \(revokedAccessTokens())")
        }

        /// alex on Home Silo and Friend's Silo, then sam on Home Silo. sam
        /// is open, and linked.
        func threeAccounts() async throws {
            try await signIn("12", "alex", on: F.home, context: .firstRun)
            try await signIn("40", "alex", on: F.friend, context: .addAccount)
            try await signIn("13", "sam", on: F.home, context: .addAccount)
        }

        /// Ends the selected sign-in's session the way a rejected refresh
        /// does.
        func rejectRefresh() async throws {
            let identity = await f.store.refreshAccountIdentity()
            let captured = await f.store.captureRefreshCredential(expected: try XCTUnwrap(identity))
            let disposition = await f.store.invalidateRejectedRefresh(try XCTUnwrap(captured))
            XCTAssertEqual(disposition, .persistentSessionCleared)
        }
    }

    // MARK: - Signing in

    func testFirstSignInAddsAndLinksTheFirstAccount() async throws {
        let d = try Device(self)

        let completion = try await d.signIn("12", "alex", on: F.home, context: .firstRun)

        XCTAssertEqual(completion, .opened(alexHome))
        XCTAssertEqual(try d.savedAccounts(), [.signIn(alexHome)])
        XCTAssertEqual(d.preferences.state.linkedAccountRef, .signIn(alexHome))
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexHome))
        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertTrue(d.router.skipsSingleProfilePicker)
    }

    /// Another person on the same server is another account; the first
    /// keeps its session.
    func testSigningInToAnotherAccountOnTheSameServerAddsIt() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)

        let completion = try await d.signIn("13", "sam", on: F.home, context: .addAccount)

        XCTAssertEqual(completion, .opened(samHome))
        XCTAssertEqual(try d.savedAccounts(), [.signIn(alexHome), .signIn(samHome)])
        XCTAssertEqual(try d.f.signIn(alexHome)?.accessToken, d.token("12", on: F.home), "alex stays signed in")
        XCTAssertEqual(try d.f.signIn(samHome)?.isSignedIn, true)
        XCTAssertEqual(d.preferences.state.linkedAccountRef, .signIn(samHome))
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(samHome))
        XCTAssertTrue(d.revokedAccessTokens().isEmpty)
    }

    /// Signing in to an account already saved refreshes it: the same
    /// account opens with the new session, nothing is added, and the
    /// session it replaced is revoked.
    func testSigningInToASavedAccountRefreshesIt() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        try await d.signIn("13", "sam", on: F.home, context: .addAccount)

        let completion = try await d.signIn("12", "alex", on: F.home, context: .addAccount)

        XCTAssertEqual(completion, .opened(alexHome))
        XCTAssertEqual(try d.savedAccounts(), [.signIn(alexHome), .signIn(samHome)])
        XCTAssertEqual(try d.f.signIn(alexHome)?.accessToken, d.token("12", on: F.home, 1))
        XCTAssertEqual(d.preferences.state.linkedAccountRef, .signIn(alexHome))
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexHome))
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [d.token("12", on: F.home)], "the superseded session")
    }

    /// "Signed in as …" names the open account's server once the device's
    /// accounts span more than one server (spec §5.1).
    func testAccountLineNamesTheServerWhenAccountsSpanServers() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        XCTAssertEqual(d.accounts.accountLine(fallbackUsername: nil), "Signed in as alex")

        try await d.signIn("40", "alex", on: F.friend, context: .addAccount)
        XCTAssertEqual(d.accounts.accountLine(fallbackUsername: nil), "Signed in as alex · Friend's Silo")

        await d.accounts.openAccount(.signIn(alexHome), router: d.router)
        XCTAssertEqual(d.accounts.accountLine(fallbackUsername: nil), "Signed in as alex · Home Silo")
    }

    // MARK: - The server step

    /// Add Account with saved servers shows "Sign in to…" as its own root;
    /// Back on the sign-in screen returns to it, and Cancel goes back to
    /// the account and screens showing before.
    func testAddAccountListsTheSavedServersAndCancelReturns() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        d.router.navigate(to: .chooseAccount())

        await d.accounts.startAddAccount(router: d.router)

        XCTAssertEqual(d.router.authState, .needsSignInTarget(.addAccount))
        XCTAssertEqual(d.router.path.count, 0)
        XCTAssertEqual(d.router.signInReturnPoint?.authState, .needsProfile)
        let targets = SignInTargetViewModel(context: .addAccount, servers: d.registry.sortedEntries)
        XCTAssertEqual(targets.rows.map(\.id), [F.home, F.friend])

        await d.accounts.beginSignIn(serverID: F.friend, context: .addAccount, router: d.router)
        XCTAssertEqual(d.router.authState, .needsLogin)
        XCTAssertEqual(d.registry.activeServerId, F.friend)
        let none = await d.selection
        XCTAssertEqual(none, .none)

        await d.accounts.leaveSignIn(router: d.router)
        XCTAssertEqual(d.router.authState, .needsSignInTarget(.addAccount))

        await d.accounts.cancelSignIn(router: d.router)

        XCTAssertEqual(d.registry.activeServerId, F.home)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexHome))
        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertEqual(d.router.path.count, 1, "Choose an Account again, on Who's Watching")
        XCTAssertNil(d.router.signInReturnPoint)
    }

    /// Add Account on a server that isn't saved (a TV approval link naming
    /// it) goes straight to server setup as its own root, with nothing
    /// behind it; Cancel goes back to Who's Watching as it was.
    func testAddAccountOnANewServerOpensSetupAlone() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        XCTAssertEqual(d.router.authState, .needsProfile)

        await d.accounts.startAddAccountOnNewServer(router: d.router)

        XCTAssertEqual(d.router.authState, .needsServerSetup)
        XCTAssertEqual(d.router.path.count, 0, "nothing behind setup")
        XCTAssertEqual(d.router.signInContext, .addAccount)
        XCTAssertEqual(d.router.signInReturnPoint?.authState, .needsProfile)

        await d.accounts.cancelSignIn(router: d.router)

        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertEqual(d.router.path.count, 0)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexHome))
        XCTAssertNil(d.router.signInReturnPoint)
    }

    /// From Choose an Account as the root, the server step goes on the
    /// chooser's stack, and Cancel lands on that chooser again with nothing
    /// selected.
    func testAddAccountFromTheChooserReturnsToIt() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        await d.accounts.apply(.chooseAccount(focus: .signIn(samHome)), router: d.router)
        XCTAssertEqual(d.router.authState, .needsAccount(focus: .signIn(samHome)))

        await d.accounts.startAddAccount(router: d.router)
        XCTAssertEqual(d.router.authState, .needsAccount(focus: .signIn(samHome)))
        XCTAssertEqual(d.router.path.count, 1, "Sign in to… on top of the chooser")

        await d.accounts.beginSignIn(serverID: F.friend, context: .addAccount, router: d.router)
        XCTAssertEqual(d.router.authState, .needsLogin)
        await d.accounts.cancelSignIn(router: d.router)

        XCTAssertEqual(d.router.authState, .needsAccount(focus: .signIn(samHome)))
        XCTAssertEqual(d.router.path.count, 0)
        XCTAssertEqual(d.registry.activeServerId, F.home)
        let selection = await d.selection
        XCTAssertEqual(selection, .none)
    }

    // MARK: - Cancel

    /// Cancel on Add Account started on Home goes back to the profile that
    /// was open, with its PIN proof, even when Profile Selection asks every
    /// time: the person never left it. After time away, Profile Selection
    /// asks again, as it would have on return.
    func testCancellingAddAccountFromHomeReopensTheProfile() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        d.preferences.behavior = .askEveryLaunch
        let identity = await d.f.store.refreshAccountIdentity()
        let opened = await d.f.store.activateProfile(profileID: "jamie", profileToken: "jamie-proof",
                                                     expectedAccount: try XCTUnwrap(identity))
        XCTAssertTrue(opened)
        d.router.resetToHome()

        await d.accounts.startAddAccount(router: d.router)
        await d.accounts.beginSignIn(serverID: F.friend, context: .addAccount, router: d.router)
        XCTAssertNil(d.auth.profileId, "no profile while signing in")
        await d.accounts.cancelSignIn(router: d.router)

        XCTAssertEqual(d.router.authState, .authenticated)
        XCTAssertEqual(d.auth.profileId, "jamie")
        let proof = await d.f.store.getProfileToken()
        XCTAssertEqual(proof, "jamie-proof")
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexHome))

        XCTAssertTrue(d.preferences.markBackgrounded(at: d.now))
        await d.accounts.startAddAccount(router: d.router)
        await d.accounts.cancelSignIn(router: d.router)
        XCTAssertEqual(d.router.authState, .needsProfile, "time away asks again")
        XCTAssertNil(d.auth.profileId)
    }

    /// Settings › Accounts, a saved server alex has no account on, then
    /// Cancel (found live as an assertion in `ContentView.destinationView`):
    /// back on the profile and Settings › Accounts, with Settings' routes
    /// only on the main screens' stack. The sign-in stack, which can stay on
    /// screen for a moment while it is swapped out, sees none of them and
    /// can't write over them.
    func testCancellingASignInFromSettingsKeepsSettingsOffTheSignInStack() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        let identity = await d.f.store.refreshAccountIdentity()
        let opened = await d.f.store.activateProfile(profileID: "jamie", profileToken: "jamie-proof",
                                                     expectedAccount: try XCTUnwrap(identity))
        XCTAssertTrue(opened)
        d.router.resetToHome()
        d.router.navigate(to: .manageAccounts)
        let settings = d.router.path

        await d.accounts.beginSignIn(forServer: F.friend, router: d.router)
        XCTAssertEqual(d.router.authState, .needsLogin)
        XCTAssertEqual(d.router.signInContext, .addAccount)
        let signInStack = d.router.path(for: .needsLogin)
        XCTAssertTrue(signInStack.wrappedValue.isEmpty)

        await d.accounts.cancelSignIn(router: d.router)

        XCTAssertEqual(d.router.authState, .authenticated)
        XCTAssertEqual(d.auth.profileId, "jamie")
        XCTAssertEqual(d.router.path, settings, "Settings › Accounts again")
        XCTAssertEqual(d.router.path(for: .authenticated).wrappedValue, settings)
        XCTAssertTrue(signInStack.wrappedValue.isEmpty, "none of Settings' routes reach the sign-in stack")
        signInStack.wrappedValue = NavigationPath()
        XCTAssertEqual(d.router.path, settings, "the swapped-out sign-in stack writes nothing")
    }

    /// A sign-in that finishes after its screen was left (Back to "Sign in
    /// to…" while it was in flight) is revoked and saved nowhere, and Cancel
    /// on the screen now showing still goes back where the sign-in started.
    func testASignInFinishingAfterItsScreenWasLeftIsRevoked() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        let before = try d.index()
        await d.accounts.startAddAccount(router: d.router)
        await d.accounts.beginSignIn(serverID: F.friend, context: .addAccount, router: d.router)
        let identity = await d.f.store.refreshAccountIdentity()
        let pending = d.pending("13", "sam", expected: try XCTUnwrap(identity))

        await d.accounts.leaveSignIn(router: d.router)
        XCTAssertEqual(d.router.authState, .needsSignInTarget(.addAccount))
        do {
            _ = try await d.accounts.completeSignIn(pending, router: d.router)
            XCTFail("a sign-in for a screen that's gone was saved")
        } catch is CancellationError {}

        XCTAssertEqual(try d.index(), before)
        XCTAssertNotNil(d.router.signInReturnPoint, "Cancel still goes back")
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [pending.accessToken])
    }

    /// Before sign-in migration, a sign-in started on one server that
    /// finishes on another server's sign-in screen is refused and revoked:
    /// its tokens never land in that server's own session, which stays as
    /// it was, so they are never sent there.
    func testALegacySignInFinishingOnAnotherServersScreenIsRefused() async throws {
        let d = try Device(self, migrated: false)
        try d.f.seedLegacySession(F.friend, url: F.friendURL, accountID: "40", access: "friend",
                                  refresh: "friend-refresh")
        let beganHome = await d.accounts.beginSignIn(serverID: F.home, context: .firstRun, router: d.router)
        XCTAssertTrue(beganHome)
        let identity = await d.f.store.refreshAccountIdentity()
        let pending = d.pending("12", "alex", expected: try XCTUnwrap(identity))
        let beganFriend = await d.accounts.beginSignIn(serverID: F.friend, context: .firstRun, router: d.router)
        XCTAssertTrue(beganFriend)
        XCTAssertEqual(d.router.authState, .needsLogin)

        do {
            _ = try await d.accounts.completeSignIn(pending, router: d.router)
            XCTFail("Home's sign-in was saved on Friend's screen")
        } catch HTTPError.requestIdentityChanged {}

        guard case .session(let friend) = try d.f.sessions.sessions.load(F.friend) else {
            return XCTFail("Friend's own session is gone")
        }
        XCTAssertEqual(friend.accessToken, "friend")
        XCTAssertEqual(friend.origin, F.friendURL)
        guard case .legacy = try d.f.sessions.sessions.load(F.home) else {
            return XCTFail("nothing is saved for Home")
        }
        XCTAssertNil(try d.f.index(), "still before migration")
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [pending.accessToken])
    }

    // MARK: - Switching

    /// Switch Account on Who's Watching pushes Choose an Account and
    /// changes nothing until a pick; the pick opens its account on its
    /// server and links it. On the chooser as the root there's nothing to
    /// push.
    func testSwitchAccountPushesTheChooserAndOpensThePick() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        XCTAssertEqual(d.router.authState, .needsProfile)

        await d.accounts.beginSwitchAccount(router: d.router)
        XCTAssertEqual(d.router.path.count, 1, "Switch Account pushes Choose an Account")
        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertEqual(d.accounts.directory.currentAccountID, .signIn(samHome))
        var selection = await d.selection
        XCTAssertEqual(selection, .signIn(samHome), "nothing changes before a pick")

        await d.accounts.openAccount(.signIn(alexFriend), router: d.router)

        selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexFriend))
        XCTAssertEqual(d.registry.activeServerId, F.friend)
        XCTAssertEqual(d.preferences.state.linkedAccountRef, .signIn(alexFriend))
        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertEqual(d.router.path.count, 0)
        XCTAssertTrue(d.revokedAccessTokens().isEmpty, "switching never signs anyone out")

        await d.accounts.apply(.chooseAccount(focus: .signIn(alexFriend)), router: d.router)
        await d.accounts.beginSwitchAccount(router: d.router)
        XCTAssertEqual(d.router.authState, .needsAccount(focus: .signIn(alexFriend)))
        XCTAssertEqual(d.router.path.count, 0, "already choosing")
    }

    /// Picking an expired account opens its sign-in screen, with the expired
    /// sign-in still selected; signing in refreshes it in place.
    func testPickingAnExpiredAccountAsksToSignInAgain() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        await d.accounts.signOut(.signIn(alexHome), router: d.router)
        await d.accounts.beginSwitchAccount(router: d.router)

        await d.accounts.openAccount(.signIn(alexHome), router: d.router)

        XCTAssertEqual(d.router.authState, .needsLogin)
        XCTAssertEqual(d.router.signInContext, .signInAgain(alexHome))
        XCTAssertEqual(d.router.loginNotice, .sessionExpired)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexHome))
        XCTAssertEqual(d.preferences.state.linkedAccountRef, .signIn(alexHome))

        try await d.finishSignIn("12", "alex", on: F.home)

        XCTAssertEqual(try d.f.signIn(alexHome)?.isSignedIn, true)
        XCTAssertEqual(try d.savedAccounts(), [.signIn(alexHome), .signIn(alexFriend), .signIn(samHome)])
        XCTAssertEqual(d.router.authState, .needsProfile)
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [d.token("12", on: F.home)], "only the sign-out's")
    }

    /// Under Automatic, Switch Account opens the picked account's remembered
    /// profile. Settings › Paired Silo Profile goes through the same chooser
    /// but always ends on the picked account's Who's Watching, so the person
    /// picks the profile to pair (spec §5.2, §5.7). Going back past its
    /// chooser makes the next pick ordinary again.
    func testChangingThePairedProfileEndsOnWhoIsWatchingUnderAutomatic() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        func remember(_ profileID: String, for key: SignInKey) throws {
            let epoch = try XCTUnwrap(try d.f.signIn(key)?.epoch?.uuidString)
            XCTAssertTrue(d.preferences.remember(profileID: profileID, requiresPIN: false, accountEpoch: epoch,
                                                 for: key, legacyOwnerAccountID: nil))
        }
        try remember("alex-profile", for: alexHome)
        try remember("sam-profile", for: samHome)
        d.preferences.behavior = .automatic
        XCTAssertEqual(d.router.authState, .needsProfile, "sam, just signed in")

        await d.accounts.beginSwitchAccount(router: d.router)
        await d.accounts.openAccount(.signIn(alexHome), router: d.router)
        XCTAssertEqual(d.router.authState, .authenticated, "Switch Account restores the remembered profile")
        XCTAssertEqual(d.auth.profileId, "alex-profile")

        // From alex, pairing sam: Choose an Account on Who's Watching, then
        // sam's Who's Watching.
        await d.accounts.changePairedProfile(router: d.router)
        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertEqual(d.router.path.count, 1, "Choose an Account on Who's Watching")
        await d.accounts.openAccount(.signIn(samHome), router: d.router)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(samHome))
        XCTAssertEqual(d.router.authState, .needsProfile, "Who's Watching, to pick the profile to pair")
        XCTAssertNil(d.auth.profileId)
        XCTAssertTrue(d.preferences.state.isSelectionRequired(for: samHome, legacyOwnerAccountID: nil),
                      "a relaunch on Who's Watching asks too")
        XCTAssertNil(d.router.pairedProfileChooserDepth)

        // Back past the chooser: the next pick is ordinary again.
        try remember("alex-profile", for: alexHome)
        await d.accounts.changePairedProfile(router: d.router)
        d.router.goBack()
        await d.accounts.openAccount(.signIn(alexHome), router: d.router)
        XCTAssertEqual(d.router.authState, .authenticated)
        XCTAssertEqual(d.auth.profileId, "alex-profile")
    }

    #if os(iOS)
    /// "Not you? Switch Account" on a TV approval (coordinator decision 2):
    /// the card waits while Choose an Account shows, an Add Account
    /// cancelled back to it included, and comes back once the person leaves
    /// it, by picking an account (the one already open too) or by going
    /// back. Nothing is left waiting to show up later.
    func testATVApprovalComesBackWhenSwitchAccountEnds() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        let link = DeviceApprovalLink(server: try XCTUnwrap(d.registry.entry(with: F.home)), code: "48217730")

        await d.router.beginSwitchAccount(forTVApproval: link)
        XCTAssertEqual(d.router.path.count, 1, "Choose an Account on top of Who's Watching")
        XCTAssertNil(d.router.takeDueDeviceApproval(), "waits while the chooser shows")
        await d.accounts.openAccount(.signIn(samHome), router: d.router)
        XCTAssertEqual(d.router.takeDueDeviceApproval(), link, "picking the open account brings it back")
        XCTAssertNil(d.router.pendingDeviceApproval)

        await d.router.beginSwitchAccount(forTVApproval: link)
        await d.accounts.startAddAccount(router: d.router)
        XCTAssertNil(d.router.takeDueDeviceApproval(), "waits during Add Account")
        await d.accounts.cancelSignIn(router: d.router)
        XCTAssertEqual(d.router.path.count, 1, "back on Choose an Account")
        XCTAssertNil(d.router.takeDueDeviceApproval(), "still choosing")
        d.router.goBack()
        XCTAssertEqual(d.router.takeDueDeviceApproval(), link, "going back returns to the card")
        XCTAssertNil(d.router.pendingDeviceApproval, "nothing left to show later")
        XCTAssertTrue(d.revokedAccessTokens().isEmpty, "Switch Account signs nobody out")
    }
    #endif

    func testATemporaryScopeBlocksSwitchingUntilItEnds() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        d.allowsEndingTemporaryIdentity = false
        d.router.showAccountChooser(focus: nil)

        await d.accounts.openAccount(.signIn(alexHome), router: d.router)

        var selection = await d.selection
        XCTAssertEqual(selection, .signIn(samHome))
        XCTAssertEqual(d.router.authState, .needsAccount(focus: nil))
        XCTAssertNotNil(d.router.accountActionError)

        d.allowsEndingTemporaryIdentity = true
        d.router.accountActionError = nil
        await d.accounts.openAccount(.signIn(alexHome), router: d.router)
        selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexHome))
        XCTAssertNil(d.router.accountActionError)
    }

    /// A card pressed twice before the first press finishes opens once, and
    /// Add Account pressed twice keeps the screen it started from as where
    /// Cancel returns.
    func testAPickPressedTwiceRunsOnce() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        d.router.showAccountChooser(focus: .signIn(samHome))
        let revision = d.router.signInRevision

        async let first: Void = d.accounts.openAccount(.signIn(alexHome), router: d.router)
        async let second: Void = d.accounts.openAccount(.signIn(alexHome), router: d.router)
        _ = await (first, second)
        XCTAssertEqual(d.router.signInRevision, revision + 1, "alex opens once")

        d.router.showProfileSelection()
        async let addOnce: Void = d.accounts.startAddAccount(router: d.router)
        async let addAgain: Void = d.accounts.startAddAccount(router: d.router)
        _ = await (addOnce, addAgain)
        XCTAssertEqual(d.router.signInReturnPoint?.authState, .needsProfile)
    }

    /// Opening another account names it before its screen shows: the
    /// account line and menus read a directory already reloaded for it.
    func testOpeningAnAccountUpdatesTheDirectoryBeforeItsScreenShows() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        await d.accounts.reloadDirectory()
        XCTAssertEqual(d.accounts.directory.currentAccountID, .signIn(samHome))
        let seen = ObservedAccount()
        let accounts = d.accounts
        withObservationTracking { _ = d.router.signInRevision } onChange: {
            seen.account = MainActor.assumeIsolated { accounts.directory.currentAccountID }
        }

        await d.accounts.openAccount(.signIn(alexHome), router: d.router)

        XCTAssertEqual(seen.account, .signIn(alexHome))
    }

    /// The selected sign-in is app-wide, so an account opened in one window
    /// re-scopes every window's screens (macOS), even on the same server:
    /// another window must not keep sam's screens while its requests go out
    /// as alex.
    func testOpeningAnAccountInOneWindowReScopesTheOthers() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        let otherWindow = AppRouter()
        otherWindow.accountsOverride = d.accounts
        let before = otherWindow.signInRevision
        let changed = ObservedFlag()
        withObservationTracking { _ = otherWindow.signInRevision } onChange: {
            changed.value = true
        }

        await d.accounts.openAccount(.signIn(alexHome), router: d.router)

        XCTAssertTrue(changed.value, "the other window's identity key follows the switch")
        XCTAssertNotEqual(otherWindow.signInRevision, before)
        XCTAssertEqual(otherWindow.signInRevision, d.router.signInRevision)
    }

    /// Who's Watching reads "Last used" without waiting (tvOS focuses it on
    /// the first frame), for the selected sign-in only.
    func testTheRememberedProfileReadsWithoutWaiting() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        let epoch = try XCTUnwrap(try d.f.signIn(samHome)?.epoch?.uuidString)
        XCTAssertNil(d.auth.rememberedProfileIDForCurrentSelection)
        XCTAssertTrue(d.preferences.remember(profileID: "sam-profile", requiresPIN: false, accountEpoch: epoch,
                                             for: samHome, legacyOwnerAccountID: nil))
        XCTAssertEqual(d.auth.rememberedProfileIDForCurrentSelection, "sam-profile")

        await d.accounts.openAccount(.signIn(alexHome), router: d.router)
        XCTAssertNil(d.auth.rememberedProfileIDForCurrentSelection, "sam's profile isn't alex's")
    }

    /// A server named from outside the account screens (a TV approval
    /// link): its account opens; expired, its sign-in screen shows with the
    /// expired sign-in still selected; a server with several accounts, none
    /// of them current or linked, shows Choose an Account.
    func testSigningInForAServerOpensItsAccountOrSignsInThere() async throws {
        let d = try Device(self)
        try await d.threeAccounts()

        let opened = await d.accounts.beginSignIn(forServer: F.friend, router: d.router)
        XCTAssertTrue(opened)
        var selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexFriend), "Friend's Silo's only account")
        XCTAssertEqual(d.router.authState, .needsProfile)

        await d.accounts.signOut(.signIn(alexFriend), router: d.router)
        let again = await d.accounts.beginSignIn(forServer: F.friend, router: d.router)
        XCTAssertTrue(again)
        XCTAssertEqual(d.router.authState, .needsLogin)
        XCTAssertEqual(d.router.signInContext, .signInAgain(alexFriend))
        XCTAssertEqual(d.router.loginNotice, .sessionExpired)
        selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexFriend))
        try await d.finishSignIn("40", "alex", on: F.friend)
        XCTAssertEqual(try d.f.signIn(alexFriend)?.isSignedIn, true)

        // Home Silo has two accounts, and this Apple TV user is on neither:
        // Choose an Account, on top of what shows, signing nobody in.
        let chose = await d.accounts.beginSignIn(forServer: F.home, router: d.router)
        XCTAssertTrue(chose)
        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertEqual(d.router.path.count, 1, "Choose an Account pushed")
        selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexFriend))
    }

    // MARK: - Sign out and remove

    /// Signing out of the current account keeps its card, showing Sign in
    /// again, and the link to it. With other accounts on the device, Choose
    /// an Account shows with focus on it, whether the sign-out came from
    /// the menus or from its card (spec §5.6, §6.2).
    func testSigningOutOfTheCurrentAccountKeepsItsCardAndShowsTheChooser() async throws {
        let d = try Device(self)
        try await d.threeAccounts()

        await d.accounts.signOutCurrent(alsoRemoveAccount: false, asksForAccountChoice: false, router: d.router)

        XCTAssertEqual(try d.savedAccounts(), [.signIn(alexHome), .signIn(alexFriend), .signIn(samHome)])
        XCTAssertEqual(try d.f.signIn(samHome)?.isSignedIn, false)
        XCTAssertEqual(d.accounts.directory.account(.signIn(samHome))?.needsSignInAgain, true)
        XCTAssertEqual(d.preferences.state.linkedAccountRef, .signIn(samHome))
        XCTAssertEqual(d.router.authState, .needsAccount(focus: .signIn(samHome)))
        var selection = await d.selection
        XCTAssertEqual(selection, .none)
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [d.token("13", on: F.home)])

        await d.accounts.openAccount(.signIn(alexHome), router: d.router)
        await d.accounts.signOut(.signIn(alexHome), router: d.router)

        XCTAssertEqual(d.router.authState, .needsAccount(focus: .signIn(alexHome)))
        XCTAssertEqual(d.preferences.state.linkedAccountRef, .signIn(alexHome))
        selection = await d.selection
        XCTAssertEqual(selection, .none)
        XCTAssertEqual(d.accounts.directory.accounts.count, 3)
    }

    /// With no other account to choose, signing out of the only one shows
    /// its sign-in screen, with the expired sign-in still selected, and
    /// signing in refreshes it.
    func testSigningOutOfTheOnlyAccountShowsItsSignInAgain() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)

        await d.accounts.signOutCurrent(alsoRemoveAccount: false, asksForAccountChoice: false, router: d.router)

        XCTAssertEqual(try d.savedAccounts(), [.signIn(alexHome)])
        XCTAssertEqual(try d.f.signIn(alexHome)?.isSignedIn, false)
        XCTAssertEqual(d.preferences.state.linkedAccountRef, .signIn(alexHome))
        XCTAssertEqual(d.router.authState, .needsLogin)
        XCTAssertEqual(d.router.signInContext, .signInAgain(alexHome))
        XCTAssertEqual(d.router.loginNotice, .sessionExpired)
        XCTAssertNil(d.router.signInReturnPoint, "nothing to cancel back to")
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexHome))
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [d.token("12", on: F.home)])

        try await d.finishSignIn("12", "alex", on: F.home)
        XCTAssertEqual(try d.f.signIn(alexHome)?.isSignedIn, true)
        XCTAssertEqual(try d.savedAccounts(), [.signIn(alexHome)])
        XCTAssertEqual(d.router.authState, .needsProfile)
    }

    /// Signing out of an account that isn't open keeps the screen. A
    /// server's pushes follow the account background work uses there, so
    /// signing out of Friend's Silo's only account turns its pushes off,
    /// while alex on Home Silo isn't what Home pushes to while sam is open.
    func testSigningOutOfAnotherAccountKeepsTheScreen() async throws {
        let d = try Device(self)
        try await d.threeAccounts()

        await d.accounts.signOut(.signIn(alexHome), router: d.router)
        XCTAssertEqual(d.pushTurnedOff, [], "sam is what Home pushes to here")
        await d.accounts.signOut(.signIn(alexFriend), router: d.router)
        XCTAssertEqual(d.pushTurnedOff, [F.friend])

        XCTAssertEqual(try d.savedAccounts(), [.signIn(alexHome), .signIn(alexFriend), .signIn(samHome)])
        XCTAssertEqual(d.accounts.directory.account(.signIn(alexFriend))?.needsSignInAgain, true)
        XCTAssertEqual(d.accounts.directory.account(.signIn(samHome))?.needsSignInAgain, false)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(samHome))
        XCTAssertEqual(d.router.authState, .needsProfile)
        try await d.waitForRevocations(2)
        XCTAssertEqual(Set(d.revokedAccessTokens()), [d.token("12", on: F.home), d.token("40", on: F.friend)])
    }

    /// Remove Account on the sign-out confirmation forgets the account and
    /// this Apple TV user's link to it. Its server stays for the other
    /// account there, and with two accounts left and none linked, Choose an
    /// Account shows.
    func testRemoveAccountOnTheSignOutConfirmationForgetsItAndItsLink() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        await d.accounts.requestRemoval(.currentAccount, router: d.router)
        let request = try XCTUnwrap(d.router.removalRequest)
        XCTAssertEqual(request.copy.additionalDestructiveTitle, SignOutConfirmationCopy.removeAccountTitle)

        await d.accounts.perform(request, removingAccount: true, router: d.router)

        XCTAssertEqual(try d.savedAccounts(), [.signIn(alexHome), .signIn(alexFriend)])
        XCTAssertNil(try d.f.signIn(samHome))
        XCTAssertNil(d.accounts.directory.account(.signIn(samHome)))
        XCTAssertNil(d.preferences.state.linkedAccountRef)
        XCTAssertNotNil(d.registry.entry(with: F.home), "alex is still on Home Silo")
        XCTAssertEqual(d.router.authState, .needsAccount(focus: nil))
        let selection = await d.selection
        XCTAssertEqual(selection, .none)
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [d.token("13", on: F.home)])
    }

    /// A sign-out confirmed after another window opened a different account
    /// is refused: it was asked about the account current when it showed.
    func testAStaleSignOutConfirmationIsRefused() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        await d.accounts.requestRemoval(.currentAccount, router: d.router)
        let request = try XCTUnwrap(d.router.removalRequest)
        XCTAssertEqual(request.account, .signIn(samHome))
        await d.accounts.openAccount(.signIn(alexFriend), router: d.router)

        await d.accounts.perform(request, removingAccount: false, router: d.router)

        XCTAssertNotNil(d.router.accountActionError)
        XCTAssertEqual(try d.f.signIn(alexFriend)?.isSignedIn, true)
        XCTAssertEqual(try d.f.signIn(samHome)?.isSignedIn, true)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexFriend))
    }

    /// Before migration the directory is empty, but the server's own session
    /// is selected and its sign-out confirmation still signs it out.
    func testSignOutConfirmationWorksBeforeMigration() async throws {
        let d = try Device(self, migrated: false)
        try d.f.seedLegacySession(F.friend, url: F.friendURL, accountID: "40", access: "friend",
                                  refresh: "friend-refresh")
        let switched = await d.registry.switchTo(serverId: F.friend, credential: .legacy(serverID: F.friend))
        XCTAssertTrue(switched)
        await d.accounts.requestRemoval(.currentAccount, router: d.router)
        let request = try XCTUnwrap(d.router.removalRequest)
        XCTAssertEqual(request.account, .pendingLegacy(serverID: F.friend))

        await d.accounts.perform(request, removingAccount: false, router: d.router)

        XCTAssertNil(d.router.accountActionError)
        guard case .signedOut = try d.f.sessions.sessions.load(F.friend) else {
            return XCTFail("Friend's own session is still saved")
        }
    }

    /// When the accounts index can't be read, which accounts a server holds
    /// is unknown, so removing its "last" account removes nothing.
    func testRemovingTheLastAccountStopsWhenTheIndexCantBeRead() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        d.f.signIns.failingReads = [SharedStorage.usersIndexAccount, SharedStorage.usersIndexBackupAccount]

        let outcome = await d.registry.removeLastAccount(.signIn(alexFriend))

        XCTAssertEqual(outcome, .failed)
        XCTAssertNotNil(d.registry.entry(with: F.friend))
        d.f.signIns.failingReads = []
        XCTAssertEqual(try d.f.signIn(alexFriend)?.isSignedIn, true)
    }

    /// The last account on a server goes with its server, through the
    /// registry's removal.
    func testRemovingTheLastAccountOnAServerRemovesTheServer() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        await d.accounts.openAccount(.signIn(alexFriend), router: d.router)

        let removed = await d.accounts.removeAccount(.signIn(alexFriend), router: d.router)

        XCTAssertTrue(removed)
        XCTAssertNil(d.registry.entry(with: F.friend))
        XCTAssertEqual(try d.savedAccounts(), [.signIn(alexHome), .signIn(samHome)])
        XCTAssertNil(try d.f.signIn(alexFriend))
        XCTAssertNil(d.preferences.state.linkedAccountRef)
        XCTAssertEqual(d.registry.activeServerId, F.home)
        XCTAssertEqual(d.router.authState, .needsAccount(focus: nil))
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [d.token("40", on: F.friend)])
    }

    /// Removing one of two accounts on a server keeps the server and the
    /// other account, and a removal of an account that isn't open keeps
    /// the screen.
    func testRemovingOneOfTwoAccountsOnAServerKeepsTheServer() async throws {
        let d = try Device(self)
        try await d.threeAccounts()

        let removed = await d.accounts.removeAccount(.signIn(alexHome), router: d.router)

        XCTAssertTrue(removed)
        XCTAssertNotNil(d.registry.entry(with: F.home))
        XCTAssertEqual(try d.savedAccounts(), [.signIn(alexFriend), .signIn(samHome)])
        XCTAssertEqual(try d.f.signIn(samHome)?.isSignedIn, true)
        XCTAssertEqual(d.preferences.state.linkedAccountRef, .signIn(samHome))
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(samHome))
        XCTAssertEqual(d.router.authState, .needsProfile)
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [d.token("12", on: F.home)])
    }

    /// The last-account check is made again once the removal holds the
    /// identity transition: an account another window added meanwhile keeps
    /// the server, and nothing is removed with it.
    func testRemovingTheLastAccountStopsWhenAnotherAppeared() async throws {
        let d = try Device(self)
        try await d.threeAccounts()

        let outcome = await d.registry.removeLastAccount(.signIn(alexHome))

        XCTAssertEqual(outcome, .othersOnServer)
        XCTAssertNotNil(d.registry.entry(with: F.home))
        XCTAssertEqual(try d.savedAccounts(), [.signIn(alexHome), .signIn(alexFriend), .signIn(samHome)])
        XCTAssertEqual(try d.f.signIn(alexHome)?.isSignedIn, true)
    }

    /// A card picked after its account was removed elsewhere: the chooser
    /// on screen redraws without it rather than pushing another one.
    func testPickingARemovedAccountRedrawsTheChooser() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        await d.accounts.beginSwitchAccount(router: d.router)
        let depth = d.router.path.count
        _ = await d.accounts.removeAccount(.signIn(alexHome), router: d.router)

        await d.accounts.openAccount(.signIn(alexHome), router: d.router)

        XCTAssertEqual(d.router.path.count, depth)
        XCTAssertNil(d.accounts.directory.account(.signIn(alexHome)))
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(samHome))
    }

    /// Remove Account on server recovery: the current account goes, and
    /// with it its server. With no account left and a server still saved,
    /// "Sign in to…" lists it (spec §5.4); Back on its sign-in screen
    /// returns there.
    func testRemovingTheCurrentAccountLastOnTheDeviceShowsSignInTo() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)

        let removed = await d.accounts.removeCurrentAccount(router: d.router)

        XCTAssertTrue(removed)
        XCTAssertNil(d.registry.entry(with: F.home))
        XCTAssertEqual(try d.savedAccounts(), [])
        XCTAssertNil(d.preferences.state.linkedAccountRef)
        XCTAssertEqual(d.router.authState, .needsSignInTarget(.firstRun))
        XCTAssertEqual(d.router.signInContext, .firstRun)
        XCTAssertEqual(d.registry.activeServerId, F.friend)
        XCTAssertNil(d.router.signInReturnPoint, "nothing to cancel back to")
        let none = await d.selection
        XCTAssertEqual(none, .none)
        let targets = SignInTargetViewModel(context: .firstRun, servers: d.registry.sortedEntries)
        XCTAssertEqual(targets.rows.map(\.id), [F.friend])
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [d.token("12", on: F.home)])

        await d.accounts.beginSignIn(serverID: F.friend, context: .firstRun, router: d.router)
        XCTAssertEqual(d.router.authState, .needsLogin)
        await d.accounts.leaveSignIn(router: d.router)
        XCTAssertEqual(d.router.authState, .needsSignInTarget(.firstRun))
    }

    /// Each confirmation names the account it acts on and that account's
    /// server; one for an account already gone names its server.
    func testConfirmationsNameTheAccountAndItsServer() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        await d.accounts.reloadDirectory()
        typealias Copy = SignOutConfirmationCopy

        XCTAssertEqual(d.accounts.confirmation(for: .currentAccount),
                       Copy.signOut(accountName: "sam", serverName: "Home Silo", device: .appleTV, offersRemove: true))
        XCTAssertEqual(d.accounts.confirmation(for: .signOut(.signIn(alexFriend))),
                       Copy.signOut(accountName: "alex", serverName: "Friend's Silo", device: .appleTV))
        XCTAssertEqual(d.accounts.confirmation(for: .remove(.signIn(alexHome))),
                       Copy.removeAccount(accountName: "alex", serverName: "Home Silo", device: .appleTV))
        XCTAssertEqual(d.accounts.confirmation(for: .remove(.signIn(.make(F.friend, "99")))),
                       Copy.removeAccount(accountName: "your account", serverName: "Friend's Silo", device: .appleTV))

        // With nothing selected there is no account to remove.
        await d.accounts.apply(.chooseAccount(focus: nil), router: d.router)
        XCTAssertEqual(d.accounts.confirmation(for: .currentAccount),
                       Copy.signOut(accountName: "your account", serverName: "Home Silo", device: .appleTV))
    }

    // MARK: - Launch and Ask For

    /// Ask For: Account + Profile at cold launch shows Choose an Account
    /// with focus on the linked account when Profile Selection asks;
    /// Profile Only opens the linked account.
    func testAskForAtColdLaunch() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        d.preferences.behavior = .askEveryLaunch
        d.preferences.askFor = .accountAndProfile

        let askedLaunch = await d.accounts.resolveLaunch()
        let asked = try XCTUnwrap(askedLaunch)
        XCTAssertEqual(asked.state, .needsAccount(focus: .signIn(samHome)))
        let none = await d.selection
        XCTAssertEqual(none, .none)

        d.preferences.askFor = .profileOnly
        let openedLaunch = await d.accounts.resolveLaunch()
        let opened = try XCTUnwrap(openedLaunch)
        XCTAssertEqual(opened.state, .needsProfile)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(samHome))

        // Automatic never asks.
        d.preferences.behavior = .automatic
        d.preferences.askFor = .accountAndProfile
        let automaticLaunch = await d.accounts.resolveLaunch()
        let automatic = try XCTUnwrap(automaticLaunch)
        XCTAssertNotEqual(automatic.state, .needsAccount(focus: .signIn(samHome)))
    }

    /// A linked account that expired launches into its sign-in screen, with
    /// the expired sign-in selected.
    func testColdLaunchWithAnExpiredLinkedAccountAsksToSignInAgain() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        await d.accounts.signOut(.signIn(alexHome), router: d.router)
        d.preferences.link(.signIn(alexHome))

        let launch = await d.accounts.resolveLaunch()

        let resolution = try XCTUnwrap(launch)
        XCTAssertEqual(resolution.state, .needsLogin)
        XCTAssertEqual(resolution.signInContext, .signInAgain(alexHome))
        XCTAssertEqual(resolution.loginNotice, .sessionExpired)
        XCTAssertNil(resolution.restoredAccount)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexHome))
    }

    func testAskForOnForegroundAfterTheAwayTimeout() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        d.preferences.behavior = .afterOneHour
        d.preferences.askFor = .accountAndProfile
        XCTAssertTrue(d.preferences.markBackgrounded(at: d.now))

        d.now = d.now.addingTimeInterval(30 * 60)
        let early = await d.accounts.resolve(.foregroundAfterAway)
        XCTAssertNotEqual(early, .chooseAccount(focus: .signIn(samHome)), "before the timeout nothing asks")

        d.now = d.now.addingTimeInterval(31 * 60)
        let late = await d.accounts.resolve(.foregroundAfterAway)
        let decision = try XCTUnwrap(late)
        XCTAssertEqual(decision, .chooseAccount(focus: .signIn(samHome)))
        await d.accounts.apply(decision, router: d.router)
        XCTAssertEqual(d.router.authState, .needsAccount(focus: .signIn(samHome)))
        let selection = await d.selection
        XCTAssertEqual(selection, .none, "nobody is selected while choosing")
    }

    /// Ask For on a return to Who's Watching (spec §6.3): no profile is
    /// open, but past the away timeout Account + Profile still shows Choose
    /// an Account with focus on the linked account, and the account opened
    /// from it shows Who's Watching instead of reopening its remembered
    /// profile. Before the timeout, or with Profile Only, Who's Watching
    /// stays and the away interval ends.
    func testAskForOnReturnToWhoIsWatching() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        let epoch = try XCTUnwrap(try d.f.signIn(alexHome)?.epoch?.uuidString)
        XCTAssertTrue(d.preferences.remember(profileID: "alex-profile", requiresPIN: false, accountEpoch: epoch,
                                             for: alexHome, legacyOwnerAccountID: nil))
        d.preferences.behavior = .afterOneHour
        d.preferences.askFor = .accountAndProfile
        XCTAssertEqual(d.router.authState, .needsProfile)

        XCTAssertTrue(d.preferences.markBackgrounded(at: d.now))
        d.now = d.now.addingTimeInterval(30 * 60)
        await d.accounts.applyAskForOnReturnToProfileSelection(router: d.router)
        XCTAssertEqual(d.router.authState, .needsProfile, "before the timeout nothing asks")
        XCTAssertNil(d.preferences.state.backgroundedAt)

        d.preferences.askFor = .profileOnly
        XCTAssertTrue(d.preferences.markBackgrounded(at: d.now))
        d.now = d.now.addingTimeInterval(61 * 60)
        await d.accounts.applyAskForOnReturnToProfileSelection(router: d.router)
        XCTAssertEqual(d.router.authState, .needsProfile, "Profile Only keeps Who's Watching")
        XCTAssertNil(d.preferences.state.backgroundedAt)

        d.preferences.askFor = .accountAndProfile
        XCTAssertTrue(d.preferences.markBackgrounded(at: d.now))
        d.now = d.now.addingTimeInterval(61 * 60)
        await d.accounts.applyAskForOnReturnToProfileSelection(router: d.router)
        XCTAssertEqual(d.router.authState, .needsAccount(focus: .signIn(samHome)))
        let none = await d.selection
        XCTAssertEqual(none, .none)

        await d.accounts.openAccount(.signIn(alexHome), router: d.router)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexHome))
        XCTAssertEqual(d.router.authState, .needsProfile)
        let profile = await d.f.store.getProfileId()
        XCTAssertNil(profile, "the remembered profile waits for Who's Watching")
    }

    /// One saved server and no account is "Sign in to…" at launch; no saved
    /// server is server setup.
    func testLaunchWithSavedServersAndNoAccountsShowsSignInTo() async throws {
        let d = try Device(self)
        _ = await d.registry.remove(serverId: F.friend)

        let oneServer = await d.accounts.resolveLaunch()
        XCTAssertEqual(oneServer?.state, .needsSignInTarget(.firstRun))
        XCTAssertEqual(oneServer?.signInContext, .firstRun)

        _ = await d.registry.remove(serverId: F.home)
        let noServer = await d.accounts.resolveLaunch()
        XCTAssertEqual(noServer?.state, .needsServerSetup)
    }

    /// Server recovery's Try again reopens the current account: unlike a
    /// cold launch, Ask For never shows Choose an Account there.
    func testTryAgainReopensTheCurrentAccountWithoutAskFor() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        d.preferences.behavior = .askEveryLaunch
        d.preferences.askFor = .accountAndProfile

        let current = await d.accounts.resolveCurrentAccount()
        XCTAssertEqual(current?.state, .needsProfile)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(samHome))

        let launch = await d.accounts.resolveLaunch()
        XCTAssertEqual(launch?.state, .needsAccount(focus: .signIn(samHome)), "a cold launch still asks")
    }

    // MARK: - Expiry

    /// A rejected refresh shows the sign-in's screen, with its card kept
    /// (spec §6.2.3). Back there is Choose an Account, and picking the
    /// account again opens the same screen; signing in refreshes it.
    func testExpiryLeadsToSignInAgainWithSwitchAccount() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        try await d.rejectRefresh()

        await d.accounts.handleSessionExpired(router: d.router)

        XCTAssertEqual(d.router.authState, .needsLogin)
        XCTAssertEqual(d.router.signInContext, .signInAgain(samHome))
        XCTAssertEqual(d.router.loginNotice, .sessionExpired)
        XCTAssertEqual(d.accounts.directory.account(.signIn(samHome))?.needsSignInAgain, true)
        var selection = await d.selection
        XCTAssertEqual(selection, .signIn(samHome))

        await d.accounts.leaveSignIn(router: d.router)
        XCTAssertEqual(d.router.authState, .needsAccount(focus: .signIn(samHome)))
        selection = await d.selection
        XCTAssertEqual(selection, .none)

        await d.accounts.openAccount(.signIn(samHome), router: d.router)
        XCTAssertEqual(d.router.authState, .needsLogin)
        XCTAssertEqual(d.router.signInContext, .signInAgain(samHome))
        selection = await d.selection
        XCTAssertEqual(selection, .signIn(samHome))

        try await d.finishSignIn("13", "sam", on: F.home)
        XCTAssertEqual(try d.f.signIn(samHome)?.isSignedIn, true)
        XCTAssertEqual(try d.savedAccounts(), [.signIn(alexHome), .signIn(alexFriend), .signIn(samHome)])
        XCTAssertEqual(d.router.authState, .needsProfile)
    }

    /// "Sign In Again" on an error screen opens the current sign-in's
    /// sign-in screen without signing anyone out.
    func testSignInAgainFromAnErrorKeepsEveryAccount() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        let before = try d.index()

        let shown = await d.accounts.signInAgainForCurrentSession(router: d.router)

        XCTAssertTrue(shown)
        XCTAssertEqual(try d.index(), before)
        XCTAssertEqual(d.router.authState, .needsLogin)
        XCTAssertEqual(d.router.signInContext, .signInAgain(samHome))
        XCTAssertTrue(d.revokedAccessTokens().isEmpty)
    }

    // MARK: - Phone pairing

    /// A phone signing this TV in saves the session as an account like any
    /// other sign-in, links it, and opens it; pairing another server adds
    /// another account. The setup screen stays up meanwhile: leaving it
    /// would cancel the session before the phone's next server.
    func testPairingSavesEachSessionAsAnAccount() async throws {
        let d = try Device(self)
        d.router.resetToServerSetup(context: .firstRun)
        let setup = d.router.authState
        typealias Pairing = ReceiverPairingCoordinator.PersistedPairing
        let homePaired = SignInKey.make(F.home, "12")
        let friendPaired = SignInKey.make(F.friend, "40")

        let first = await d.accounts.completePairing(
            Pairing(url: F.homeURL, fetchedName: "Home Silo", verifiedServerId: nil,
                    accessToken: "paired-home", refreshToken: "r", accountID: "12"),
            router: d.router)
        XCTAssertTrue(first)
        XCTAssertEqual(try d.savedAccounts(), [.signIn(homePaired)])
        XCTAssertEqual(d.preferences.state.linkedAccountRef, .signIn(homePaired))
        XCTAssertEqual(d.registry.activeServerId, F.home)
        XCTAssertEqual(d.router.authState, setup)

        let second = await d.accounts.completePairing(
            Pairing(url: F.friendURL, fetchedName: "Friend's Silo", verifiedServerId: nil,
                    accessToken: "paired-friend", refreshToken: "r", accountID: "40"),
            router: d.router)
        XCTAssertTrue(second)
        XCTAssertEqual(try d.savedAccounts(), [.signIn(homePaired), .signIn(friendPaired)])
        XCTAssertEqual(d.preferences.state.linkedAccountRef, .signIn(friendPaired))
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(friendPaired))
        XCTAssertEqual(d.router.authState, setup)
        XCTAssertTrue(d.revokedAccessTokens().isEmpty)
    }

    /// A pairing that stops before anything keeps its session (here,
    /// cancelled) ends that session on the server.
    func testAPairingStoppedBeforeSavingEndsItsSession() async throws {
        let d = try Device(self)
        let accounts = d.accounts
        let router = d.router
        let pairing = Task { @MainActor in
            await accounts.completePairing(
                ReceiverPairingCoordinator.PersistedPairing(
                    url: F.homeURL, fetchedName: "Home Silo", verifiedServerId: nil,
                    accessToken: "paired-home", refreshToken: "r", accountID: "12"),
                router: router)
        }
        pairing.cancel()

        let saved = await pairing.value
        XCTAssertFalse(saved)
        XCTAssertEqual(try d.savedAccounts(), [])
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), ["paired-home"])
    }

    // MARK: - Pending legacy accounts (plan §3.3)

    /// A migrated device: Friend's Silo's session became a saved sign-in,
    /// and Home Silo's, whose account was never read, a pending legacy
    /// account, which is open.
    private func migratedDevice() async throws -> Device {
        let d = try Device(self, migrated: false)
        try d.f.seedLegacySession(F.home, url: F.homeURL, accountID: nil, access: "legacy", refresh: "legacy-refresh")
        try d.f.seedLegacySession(F.friend, url: F.friendURL, accountID: "40", access: "friend", refresh: "r")
        _ = await d.f.store.migrateLegacySessionsIfNeeded(
            servers: [(F.home, F.homeURL), (F.friend, F.friendURL)], activeServerID: F.friend)
        XCTAssertEqual(try d.savedAccounts(), [.signIn(.make(F.friend, "40")), .pendingLegacy(serverID: F.home)])
        let switched = await d.registry.switchTo(serverId: F.home, credential: .legacy(serverID: F.home))
        XCTAssertTrue(switched)
        return d
    }

    /// A pending account's own session counts as signed in only while it is
    /// selected: with nothing selected on its server (a chooser, the server
    /// step, or setup typing its address), Who's Watching must not open.
    func testAPendingLegacyAccountIsSignedOutWhileNothingIsSelected() async throws {
        let d = try await migratedDevice()
        XCTAssertTrue(d.auth.isLoggedIn)

        let cleared = await d.registry.switchTo(serverId: F.home, credential: .none)
        XCTAssertTrue(cleared)
        XCTAssertFalse(d.auth.isLoggedIn)
        XCTAssertFalse(shouldPresentProfileSelectionAfterRecovery(isLoggedIn: d.auth.isLoggedIn, activeProfileID: nil))

        let reselected = await d.registry.switchTo(serverId: F.home, credential: .legacy(serverID: F.home))
        XCTAssertTrue(reselected)
        XCTAssertTrue(d.auth.isLoggedIn)
    }

    /// The credential a background launch selects: an active server the
    /// registry fell back to (a new Apple TV user's first launch, the
    /// survivor of a removal) is no history, so on a server with two
    /// accounts neither opens; a server this Apple TV user opened before
    /// accounts existed opens the account holding its old session, as the
    /// launch rules do.
    func testLaunchSelectionDoesNotTreatAFallbackServerAsHistory() async throws {
        let d = try await migratedDevice()
        try await d.signIn("13", "sam", on: F.home, context: .addAccount)
        XCTAssertEqual(try d.index().accounts(onServer: F.home).count, 2)
        await d.f.store.select(serverID: F.home, credential: .none)
        d.f.defaults.set(try JSONEncoder().encode(ProfileLaunchState()), forKey: SharedStorage.profileLaunchStateKey)
        d.f.defaults.set(F.home, forKey: SharedStorage.activeServerIdKey)

        d.f.defaults.set(true, forKey: ServerRegistry.activeServerFallbackKey)
        let fallback = await d.f.store.launchSelection(forServer: F.home)
        XCTAssertEqual(fallback, .none)

        d.f.defaults.removeObject(forKey: ServerRegistry.activeServerFallbackKey)
        let opened = await d.f.store.launchSelection(forServer: F.home)
        XCTAssertEqual(opened, .legacy(serverID: F.home))
    }

    /// A pending account whose refresh is rejected is dropped (its session
    /// is gone), and signing in on its server adds the account back.
    func testARejectedPendingLegacyAccountIsDroppedAndSignsBackIn() async throws {
        let d = try await migratedDevice()
        try await d.rejectRefresh()

        await d.accounts.handleSessionExpired(router: d.router)

        XCTAssertEqual(try d.savedAccounts(), [.signIn(.make(F.friend, "40"))])
        XCTAssertEqual(d.router.authState, .needsLogin)
        XCTAssertEqual(d.router.signInContext, .addAccount)
        XCTAssertEqual(d.router.loginNotice, .sessionExpired)
        let selection = await d.selection
        XCTAssertEqual(selection, .none)

        try await d.finishSignIn("12", "alex", on: F.home)
        XCTAssertEqual(try d.savedAccounts(), [.signIn(.make(F.friend, "40")), .signIn(.make(F.home, "12"))])
    }

    /// A pending account whose account turns out unsaved becomes its
    /// sign-in, a link to it follows, and the screen's stores re-scope
    /// (`signInRevision`): the account mirror went from none to the
    /// account, so stores keyed by account read again under the keys that
    /// took over their old data.
    func testAMigratedPendingLegacyAccountKeepsItsLinkAndReScopesTheStores() async throws {
        let d = try await migratedDevice()
        d.preferences.link(.pendingLegacy(serverID: F.home))
        let auth = await d.f.store.captureOrdinaryRequestAuth()
        let outcome = try await d.f.store.bindVerifiedAccount(.stub(id: "12", username: "alex"),
                                                              expected: try XCTUnwrap(auth))
        XCTAssertEqual(outcome, .legacyMigrated(.make(F.home, "12")))
        XCTAssertEqual(try d.savedAccounts(), [.signIn(.make(F.friend, "40")), .signIn(.make(F.home, "12"))])
        let before = d.router.signInRevision

        await d.accounts.handleSignInMigrated(outcome, router: d.router)

        XCTAssertNotEqual(d.router.signInRevision, before)
        XCTAssertEqual(d.preferences.state.linkedAccountRef, .signIn(.make(F.home, "12")))
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "12")))
    }

    /// A pending account whose account is already saved: the pending account
    /// goes, that sign-in takes over the server's old local data and a link
    /// to the pending account, and the launch rules open it.
    func testADuplicatePendingLegacyAccountHandsOverToTheSavedSignIn() async throws {
        let d = try await migratedDevice()
        try await d.signIn("12", "sam", on: F.home, context: .addAccount)
        d.preferences.link(.pendingLegacy(serverID: F.home))
        let switched = await d.registry.switchTo(serverId: F.home, credential: .legacy(serverID: F.home))
        XCTAssertTrue(switched)
        let auth = await d.f.store.captureOrdinaryRequestAuth()

        let outcome = try await d.f.store.bindVerifiedAccount(.stub(id: "12"), expected: try XCTUnwrap(auth))
        XCTAssertEqual(outcome, .legacyDuplicate(existing: .make(F.home, "12"), revoking: RevocableCredential(
            serverURL: F.homeURL, accessToken: "legacy", refreshToken: "legacy-refresh")))
        XCTAssertEqual(try d.index().legacyDataOwnerByServerID?[F.home], "12")

        await d.accounts.handleSignInMigrated(outcome, router: d.router)

        XCTAssertEqual(try d.savedAccounts(), [.signIn(.make(F.friend, "40")), .signIn(.make(F.home, "12"))])
        XCTAssertEqual(d.preferences.state.linkedAccountRef, .signIn(.make(F.home, "12")))
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "12")))
    }

    /// The account read that finds a pending account's account already
    /// saved ends the dropped session on that server, with its own tokens,
    /// when they differ from the saved sign-in's; the saved session stays.
    func testReadingADuplicatePendingAccountRevokesItsOwnSession() async throws {
        let d = try await migratedDevice()
        try await d.signIn("12", "sam", on: F.home, context: .addAccount)
        let switched = await d.registry.switchTo(serverId: F.home, credential: .legacy(serverID: F.home))
        XCTAssertTrue(switched)
        d.stub.reply(path: "/api/v2/account/me", 200,
                     #"{"id":"12","username":"sam","email":null,"role":"user","permissions":[],"download_allowed":true}"#)
        let api = APIv2Client(http: d.auth.httpClient, tokenStore: d.f.store, isUpdateRequired: { false })

        _ = try await api.currentUser()

        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), ["legacy"])
        XCTAssertEqual(d.stub.requests.last { $0.path == Self.logout }?.url?.host, "home.example")
        XCTAssertEqual(try d.f.signIn(.make(F.home, "12"))?.accessToken, d.token("12", on: F.home))
    }

    // MARK: - Edges

    /// A profile list read while a remote-playback identity answers requests
    /// is that account's, so it isn't saved for the account cards.
    func testProfilesReadUnderATemporaryIdentityAreNotCachedOnTheSignIn() async throws {
        let d = try Device(self)
        try await d.threeAccounts()
        let guest = UserProfile(id: "guest", name: "Guest", avatarEmoji: nil, hasPin: false, isChild: false)
        await d.f.store.beginTemporaryScope(TemporaryAuthScope(
            serverId: F.home, serverURL: F.homeURL, accessToken: "temporary", refreshToken: "temporary-refresh",
            profileId: "guest", profileToken: "proof", controllerDeviceId: "controller",
            expiresAt: Date().addingTimeInterval(60)))

        await d.auth.updateSignInDisplayCache([guest], for: samHome)
        XCTAssertNotEqual(try d.f.signIn(samHome)?.profiles.map(\.id), ["guest"])

        await d.f.store.endTemporaryScope()
        await d.auth.updateSignInDisplayCache([guest], for: samHome)
        XCTAssertEqual(try d.f.signIn(samHome)?.profiles.map(\.id), ["guest"])
    }
}

/// The value an observation's change handler saw.
private final class ObservedAccount: @unchecked Sendable {
    var account: SiloAccountRef?
}

private final class ObservedFlag: @unchecked Sendable {
    var value = false
}

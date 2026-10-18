import Foundation
import Observation
import XCTest
@testable import Silo

/// `SiloUserCoordinator` on an isolated device: its own token store, server
/// list, launch state, and a stubbed network that answers every request
/// (logouts included) with no content. Each test drives the flows the
/// screens drive and checks the saved users, the selection, the launch
/// state, the router, and which sessions were revoked.
@MainActor
final class SiloUserCoordinatorTests: XCTestCase {
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
        let users: SiloUserCoordinator
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
        /// no user index yet.
        init(_ test: XCTestCase, migrated: Bool = true) throws {
            f = try F.make(test)
            if migrated { try f.startUserModel() }
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
            users = SiloUserCoordinator(
                auth: auth,
                now: { knobs.now },
                endTemporaryIdentity: { knobs.allowsEndingTemporaryIdentity },
                device: .appleTV
            )
            router = AppRouter()
            router.usersOverride = users
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
            let began = await users.beginSignIn(serverID: serverID, context: context, router: router)
            XCTAssertTrue(began)
            return try await finishSignIn(accountID, username, on: serverID)
        }

        /// The token pair the server answered, placed in the running sign-in.
        @discardableResult
        func finishSignIn(_ accountID: String, _ username: String, on serverID: String) async throws -> SignInCompletion {
            let identity = await f.store.refreshAccountIdentity()
            let expected = try XCTUnwrap(identity)
            XCTAssertEqual(expected.serverId, serverID)
            return try await users.completeSignIn(pending(accountID, username, expected: expected), router: router)
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

        func index() throws -> SiloUserIndex { try XCTUnwrap(try f.index()) }

        func user(named username: String) throws -> SiloUser? {
            let index = try index()
            return index.users.first { user in
                user.signIns.contains { (try? f.signIn($0))?.username == username }
            }
        }

        var selection: CredentialSelection {
            get async { await f.store.currentSelection() }
        }

        func revokedAccessTokens() -> [String] {
            stub.requests.filter { $0.path == SiloUserCoordinatorTests.logout }
                .compactMap { $0.header("Authorization")?.replacingOccurrences(of: "Bearer ", with: "") }
        }

        func waitForRevocations(_ count: Int) async throws {
            for _ in 0..<300 where revokedAccessTokens().count < count {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(revokedAccessTokens().count, count, "revocations: \(revokedAccessTokens())")
        }

        /// alex on Home Silo and Friend's Silo, then sam on Home Silo as a
        /// second user. sam is open.
        func twoUsers() async throws -> (alex: SiloUser, sam: SiloUser) {
            try await signIn("12", "alex", on: F.home, context: .firstRun)
            let alex = try XCTUnwrap(try user(named: "alex"))
            try await signIn("40", "alex", on: F.friend, context: .addServer(userID: alex.id))
            try await signIn("13", "sam", on: F.home, context: .addUser)
            let sam = try XCTUnwrap(try user(named: "sam"))
            return (try XCTUnwrap(try user(named: "alex")), sam)
        }
    }

    // MARK: - First run, Add User, Add Server

    func testFirstSignInCreatesAndLinksTheFirstUser() async throws {
        let d = try Device(self)

        let completion = try await d.signIn("12", "alex", on: F.home, context: .firstRun)

        XCTAssertEqual(completion, .opened(.make(F.home, "12")))
        let index = try d.index()
        XCTAssertEqual(index.users.count, 1)
        let alex = try XCTUnwrap(index.users.first)
        XCTAssertEqual(alex.signIns, [.make(F.home, "12")])
        XCTAssertEqual(d.preferences.state.linkedUserID, alex.id)
        XCTAssertEqual(d.preferences.state.lastServer(for: alex.id), F.home)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "12")))
        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertTrue(d.router.skipsSingleProfilePicker)
    }

    func testAddUserCreatesAndLinksANewUser() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)

        try await d.signIn("13", "sam", on: F.home, context: .addUser)

        let index = try d.index()
        XCTAssertEqual(index.users.count, 2)
        let sam = try XCTUnwrap(try d.user(named: "sam"))
        XCTAssertEqual(sam.signIns, [.make(F.home, "13")])
        XCTAssertEqual(d.preferences.state.linkedUserID, sam.id)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "13")))
        XCTAssertEqual(d.users.accountLine(fallbackUsername: nil), "Signed in as sam")
    }

    /// Add User with an account already saved opens that user and creates
    /// nothing; the old session is revoked because the sign-in is refreshed.
    func testAddUserWithASavedAccountSwitchesToItAndCreatesNothing() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        let alex = try XCTUnwrap(try d.user(named: "alex"))
        try await d.signIn("13", "sam", on: F.home, context: .addUser)

        let completion = try await d.signIn("12", "alex", on: F.home, context: .addUser)

        XCTAssertEqual(completion, .opened(.make(F.home, "12")))
        XCTAssertEqual(try d.index().users.map(\.id).count, 2)
        XCTAssertEqual(try d.user(named: "alex")?.id, alex.id)
        XCTAssertEqual(d.preferences.state.linkedUserID, alex.id)
        XCTAssertNil(d.router.signInPrompt)
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [d.token("12", on: F.home)])
    }

    func testAddServerJoinsTheUserWithoutAPrompt() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        let alex = try XCTUnwrap(try d.user(named: "alex"))

        // Another username on a new server still joins (spec §5.4.1).
        let completion = try await d.signIn("40", "alexander", on: F.friend, context: .addServer(userID: alex.id))

        XCTAssertEqual(completion, .opened(.make(F.friend, "40")))
        XCTAssertNil(d.router.signInPrompt)
        XCTAssertEqual(try d.index().users.count, 1)
        XCTAssertEqual(try d.index().users.first?.signIns, [.make(F.home, "12"), .make(F.friend, "40")])
        XCTAssertEqual(d.preferences.state.lastServer(for: alex.id), F.friend)
        XCTAssertEqual(d.users.accountLine(fallbackUsername: nil), "Signed in as alex · Friend's Silo")
    }

    // MARK: - The two questions

    func testSwitchToUserPromptAcceptRefreshesTheSavedSignInAndOpensItsUser() async throws {
        let d = try Device(self)
        let (alex, sam) = try await d.twoUsers()

        let completion = try await d.signIn("40", "alex", on: F.friend, context: .addServer(userID: sam.id))

        XCTAssertEqual(completion, .prompted)
        let prompt = try XCTUnwrap(d.router.signInPrompt)
        XCTAssertEqual(prompt.kind, .switchToUser(userID: alex.id, key: .make(F.friend, "40")))
        XCTAssertTrue(prompt.copy.confirmTitle.contains("alex"))
        XCTAssertEqual(try d.user(named: "sam")?.signIns, [.make(F.home, "13")], "nothing saved while asking")

        await d.users.answer(prompt, accept: true, router: d.router)

        XCTAssertNil(d.router.signInPrompt)
        XCTAssertEqual(try d.user(named: "sam")?.signIns, [.make(F.home, "13")], "the sign-in never moves")
        XCTAssertEqual(d.preferences.state.linkedUserID, alex.id)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.friend, "40")))
        XCTAssertEqual(d.router.authState, .needsProfile)
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [d.token("40", on: F.friend)], "the superseded session")
    }

    /// Cancel revokes the new session, saves nothing, and goes back to the
    /// user and screen showing before the server step.
    func testSwitchToUserPromptCancelRevokesAndReturns() async throws {
        let d = try Device(self)
        let (_, sam) = try await d.twoUsers()
        let before = try d.index()
        d.router.showServerChooser(userID: sam.id, focus: F.home)
        await d.users.startSignIn(.addServer(userID: sam.id), router: d.router)
        XCTAssertNotNil(d.router.signInReturnPoint)

        await d.users.beginSignIn(serverID: F.friend, context: .addServer(userID: sam.id), router: d.router)
        let identity = await d.f.store.refreshAccountIdentity()
        let pending = d.pending("40", "alex", expected: try XCTUnwrap(identity))
        _ = try await d.users.completeSignIn(pending, router: d.router)
        let prompt = try XCTUnwrap(d.router.signInPrompt)

        await d.users.answer(prompt, accept: false, router: d.router)

        XCTAssertEqual(try d.index(), before)
        XCTAssertEqual(try d.f.signIn(.make(F.friend, "40"))?.accessToken, d.token("40", on: F.friend),
                       "the saved sign-in keeps its session")
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [pending.accessToken])
        XCTAssertEqual(d.router.authState, .needsServer(userID: sam.id, focusServerID: F.home))
        XCTAssertNil(d.router.signInReturnPoint)
        XCTAssertEqual(d.registry.activeServerId, F.home)
    }

    func testSeparateUserPromptAcceptCreatesAUser() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        let alex = try XCTUnwrap(try d.user(named: "alex"))

        let completion = try await d.signIn("15", "kim", on: F.home, context: .addServer(userID: alex.id))

        XCTAssertEqual(completion, .prompted)
        let prompt = try XCTUnwrap(d.router.signInPrompt)
        XCTAssertEqual(prompt.kind, .separateUser(existingUserID: alex.id, newUsername: "kim"))
        XCTAssertEqual(prompt.copy.title, "alex already uses Home Silo.")
        XCTAssertEqual(prompt.copy.confirmTitle, "Add kim as a Separate User")

        await d.users.answer(prompt, accept: true, router: d.router)

        let kim = try XCTUnwrap(try d.user(named: "kim"))
        XCTAssertNotEqual(kim.id, alex.id)
        XCTAssertEqual(kim.signIns, [.make(F.home, "15")])
        XCTAssertEqual(try d.user(named: "alex")?.signIns, [.make(F.home, "12")])
        XCTAssertEqual(d.preferences.state.linkedUserID, kim.id)
        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertTrue(d.revokedAccessTokens().isEmpty)
    }

    func testSeparateUserPromptCancelSavesNothingAndRevokes() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        let alex = try XCTUnwrap(try d.user(named: "alex"))
        let before = try d.index()

        try await d.signIn("15", "kim", on: F.home, context: .addServer(userID: alex.id))
        let prompt = try XCTUnwrap(d.router.signInPrompt)
        await d.users.answer(prompt, accept: false, router: d.router)

        XCTAssertEqual(try d.index(), before)
        XCTAssertNil(try d.f.signIn(.make(F.home, "15")))
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [d.token("15", on: F.home)])
    }

    // MARK: - Choose a User, Choose a Server, Who's Watching

    func testWhoIsWatchingActionsPushTheChoosers() async throws {
        let d = try Device(self)
        let (_, sam) = try await d.twoUsers()
        XCTAssertEqual(d.router.authState, .needsProfile)

        await d.users.beginSwitchUser(router: d.router)
        XCTAssertEqual(d.router.path.count, 1, "Switch User pushes Choose a User")

        d.router.popToRoot()
        await d.users.showServers(router: d.router)
        XCTAssertEqual(d.router.path.count, 1, "Change server pushes this user's servers")
        XCTAssertEqual(d.users.directory.currentUserID, sam.id)

        await d.users.requestRemoval(.currentSignIn, router: d.router)
        let request = try XCTUnwrap(d.router.removalRequest)
        XCTAssertEqual(request.copy.title, "Sign out of Home Silo?")
        XCTAssertTrue(request.copy.message.contains("sam on Home Silo"))
    }

    /// Picking a user with one server opens it; with two, its servers, with
    /// focus on its last one (decision 16). Picking a server opens it.
    func testPickingAUserAndAServerOpensIt() async throws {
        let d = try Device(self)
        let (alex, sam) = try await d.twoUsers()
        d.router.showUserChooser(focus: sam.id)

        await d.users.openUser(alex.id, router: d.router)

        XCTAssertEqual(d.preferences.state.linkedUserID, alex.id)
        XCTAssertEqual(d.router.authState, .needsUser(focusUserID: sam.id))
        XCTAssertEqual(d.router.path.count, 1, "alex's servers on top of Choose a User")

        await d.users.openServer(F.home, userID: alex.id, router: d.router)

        XCTAssertEqual(d.preferences.state.lastServer(for: alex.id), F.home)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "12")))
        XCTAssertEqual(d.router.authState, .needsProfile)

        await d.users.openUser(sam.id, router: d.router)
        let samSelection = await d.selection
        XCTAssertEqual(samSelection, .signIn(.make(F.home, "13")), "one server opens directly")
        XCTAssertEqual(d.preferences.state.linkedUserID, sam.id)
        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertTrue(d.revokedAccessTokens().isEmpty, "switching never signs anyone out")
    }

    /// Under Automatic, Switch User opens the picked user's remembered
    /// profile, as Change server does. Settings › Paired Silo Profile goes
    /// through the same chooser but always ends on the picked user's Who's
    /// Watching, after Choose a Server for a user with two servers, so the
    /// person picks the profile to pair (spec §5.2, §5.7). Going back past
    /// its chooser makes the next pick ordinary again.
    func testChangingThePairedProfileEndsOnWhoIsWatchingUnderAutomatic() async throws {
        let d = try Device(self)
        let (alex, sam) = try await d.twoUsers()
        let alexHome = SignInKey.make(F.home, "12")
        let samHome = SignInKey.make(F.home, "13")
        func remember(_ profileID: String, for key: SignInKey) throws {
            let epoch = try XCTUnwrap(try d.f.signIn(key)?.epoch?.uuidString)
            XCTAssertTrue(d.preferences.remember(profileID: profileID, requiresPIN: false, accountEpoch: epoch,
                                                 for: key, legacyOwnerAccountID: nil))
        }
        try remember("alex-profile", for: alexHome)
        try remember("sam-profile", for: samHome)
        d.preferences.behavior = .automatic
        XCTAssertEqual(d.router.authState, .needsProfile, "sam, just signed in")

        await d.users.beginSwitchUser(router: d.router)
        await d.users.openUser(alex.id, router: d.router)
        await d.users.openServer(F.home, userID: alex.id, router: d.router)
        XCTAssertEqual(d.router.authState, .authenticated, "Switch User restores the remembered profile")
        XCTAssertEqual(d.auth.profileId, "alex-profile")

        // From alex, pairing sam: one server, straight to its Who's Watching.
        await d.users.changePairedProfile(router: d.router)
        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertEqual(d.router.path.count, 1, "Choose a User on Who's Watching")
        await d.users.openUser(sam.id, router: d.router)
        var selection = await d.selection
        XCTAssertEqual(selection, .signIn(samHome))
        XCTAssertEqual(d.router.authState, .needsProfile, "Who's Watching, to pick the profile to pair")
        XCTAssertNil(d.auth.profileId)
        XCTAssertTrue(d.preferences.state.isSelectionRequired(for: samHome, legacyOwnerAccountID: nil),
                      "a relaunch on Who's Watching asks too")
        XCTAssertNil(d.router.pairedProfileChooserDepth)

        // From sam, pairing alex: Choose a Server first, then Who's Watching.
        try remember("alex-profile", for: alexHome)
        await d.users.changePairedProfile(router: d.router)
        await d.users.openUser(alex.id, router: d.router)
        XCTAssertEqual(d.router.path.count, 2, "Choose a Server first")
        await d.users.openServer(F.home, userID: alex.id, router: d.router)
        selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexHome))
        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertNil(d.auth.profileId)

        // Back past the chooser: the next pick is ordinary again.
        try remember("sam-profile", for: samHome)
        await d.users.changePairedProfile(router: d.router)
        d.router.goBack()
        await d.users.openServer(F.home, userID: sam.id, router: d.router)
        XCTAssertEqual(d.router.authState, .authenticated)
        XCTAssertEqual(d.auth.profileId, "sam-profile")
    }

    /// Add Server from Who's Watching with every saved server already in the
    /// user goes straight to server setup as its own root, with no "Sign in
    /// to…" left behind it; Cancel goes back to Who's Watching as it was.
    func testAddServerWithEveryServerInTheUserOpensSetupAlone() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        let alex = try XCTUnwrap(try d.user(named: "alex"))
        try await d.signIn("40", "alex", on: F.friend, context: .addServer(userID: alex.id))
        XCTAssertEqual(d.router.authState, .needsProfile)

        await d.users.startSignIn(.addServer(userID: alex.id), router: d.router)

        XCTAssertEqual(d.router.authState, .needsServerSetup)
        XCTAssertEqual(d.router.path.count, 0, "nothing behind setup")
        XCTAssertEqual(d.router.signInContext, .addServer(userID: alex.id))
        XCTAssertEqual(d.router.signInReturnPoint?.authState, .needsProfile)

        await d.users.cancelSignIn(router: d.router)

        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertEqual(d.router.path.count, 0)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.friend, "40")))
        XCTAssertNil(d.router.signInReturnPoint)
    }

    /// Cancel on a sign-in started from Who's Watching restores the user,
    /// server, and screens that were showing.
    func testCancellingSignInReturnsToThePreviousUserAndServer() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        d.router.navigate(to: .chooseUser())
        await d.users.startAddUser(router: d.router)
        await d.users.beginSignIn(serverID: F.friend, context: .addUser, router: d.router)
        XCTAssertEqual(d.registry.activeServerId, F.friend)

        await d.users.cancelSignIn(router: d.router)

        XCTAssertEqual(d.registry.activeServerId, F.home)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "12")))
        XCTAssertEqual(d.router.authState, .needsProfile)
        XCTAssertEqual(d.router.path.count, 1, "Choose a User again, on Who's Watching")
        XCTAssertNil(d.router.signInReturnPoint)
    }

    /// Cancel on Add User started on Home goes back to the profile that was
    /// open, with its PIN proof, even when Profile Selection asks every
    /// time: the person never left it. After time away, Profile Selection
    /// asks again, as it would have on return.
    func testCancellingAddUserFromHomeReopensTheProfile() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        d.preferences.behavior = .askEveryLaunch
        let identity = await d.f.store.refreshAccountIdentity()
        let opened = await d.f.store.activateProfile(profileID: "jamie", profileToken: "jamie-proof",
                                                     expectedAccount: try XCTUnwrap(identity))
        XCTAssertTrue(opened)
        d.router.resetToHome()

        await d.users.startAddUser(router: d.router)
        await d.users.beginSignIn(serverID: F.friend, context: .addUser, router: d.router)
        XCTAssertNil(d.auth.profileId, "no profile while signing in")
        await d.users.cancelSignIn(router: d.router)

        XCTAssertEqual(d.router.authState, .authenticated)
        XCTAssertEqual(d.auth.profileId, "jamie")
        let proof = await d.f.store.getProfileToken()
        XCTAssertEqual(proof, "jamie-proof")
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "12")))

        XCTAssertTrue(d.preferences.markBackgrounded(at: d.now))
        await d.users.startAddUser(router: d.router)
        await d.users.cancelSignIn(router: d.router)
        XCTAssertEqual(d.router.authState, .needsProfile, "time away asks again")
        XCTAssertNil(d.auth.profileId)
    }

    #if os(iOS)
    /// "Not you? Switch User" on a TV approval (coordinator decision 2): the
    /// card waits while Choose a User shows, an Add User cancelled back to
    /// it included, and comes back once the person leaves it, by picking a
    /// user (the one already open too) or by going back. Nothing is left
    /// waiting to show up later.
    func testATVApprovalComesBackWhenSwitchUserEnds() async throws {
        let d = try Device(self)
        let (_, sam) = try await d.twoUsers()
        let link = DeviceApprovalLink(server: try XCTUnwrap(d.registry.entry(with: F.home)), code: "48217730")

        await d.router.beginSwitchUser(forTVApproval: link)
        XCTAssertEqual(d.router.path.count, 1, "Choose a User on top of Who's Watching")
        XCTAssertNil(d.router.takeDueDeviceApproval(), "waits while the chooser shows")
        await d.users.openUser(sam.id, router: d.router)
        XCTAssertEqual(d.router.takeDueDeviceApproval(), link, "picking the open user brings it back")
        XCTAssertNil(d.router.pendingDeviceApproval)

        await d.router.beginSwitchUser(forTVApproval: link)
        await d.users.startAddUser(router: d.router)
        XCTAssertNil(d.router.takeDueDeviceApproval(), "waits during Add User")
        await d.users.cancelSignIn(router: d.router)
        XCTAssertEqual(d.router.path.count, 1, "back on Choose a User")
        XCTAssertNil(d.router.takeDueDeviceApproval(), "still choosing")
        d.router.goBack()
        XCTAssertEqual(d.router.takeDueDeviceApproval(), link, "going back returns to the card")
        XCTAssertNil(d.router.pendingDeviceApproval, "nothing left to show later")
        XCTAssertTrue(d.revokedAccessTokens().isEmpty, "Switch User signs nobody out")
    }
    #endif

    // MARK: - Sign out and remove

    /// Sign out falls back per spec §6.2: another server in the user, then
    /// the chooser, then the server step, then server setup.
    func testSignOutFallsBackThroughTheLaunchRules() async throws {
        let d = try Device(self)
        let (alex, sam) = try await d.twoUsers()
        await d.users.openServer(F.friend, userID: alex.id, router: d.router)

        // alex on Friend's Silo: alex still has Home Silo.
        await d.users.signOutCurrent(alsoRemoveServer: false, asksForAccountChoice: false, router: d.router)
        var selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "12")))
        XCTAssertNil(try d.f.signIn(.make(F.friend, "40")))
        XCTAssertEqual(d.router.authState, .needsProfile)

        // alex's last sign-in: alex goes; two users became one, so sam opens.
        await d.users.signOutCurrent(alsoRemoveServer: false, asksForAccountChoice: false, router: d.router)
        XCTAssertNil(try d.user(named: "alex"))
        XCTAssertNil(d.preferences.state.lastServer(for: alex.id))
        selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "13")))
        XCTAssertEqual(d.preferences.state.linkedUserID, sam.id)

        // No users, servers saved: "Sign in to…".
        await d.users.signOutCurrent(alsoRemoveServer: false, asksForAccountChoice: false, router: d.router)
        XCTAssertEqual(try d.index().users, [])
        XCTAssertEqual(d.router.authState, .needsSignInTarget(.firstRun))

        // No servers either: server setup.
        _ = await d.registry.remove(serverId: F.home)
        await d.users.removeServer(F.friend, router: d.router)
        XCTAssertEqual(d.router.authState, .needsServerSetup)

        try await d.waitForRevocations(3)
        XCTAssertEqual(Set(d.revokedAccessTokens()),
                       [d.token("40", on: F.friend), d.token("12", on: F.home), d.token("13", on: F.home)])
    }

    /// With two users left and the linked one gone, Choose a User.
    func testRemovingTheLinkedUserShowsTheChooser() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        try await d.signIn("13", "sam", on: F.home, context: .addUser)
        try await d.signIn("15", "kim", on: F.friend, context: .addUser)
        let kim = try XCTUnwrap(try d.user(named: "kim"))

        await d.users.removeUser(kim.id, router: d.router)

        XCTAssertNil(try d.user(named: "kim"))
        XCTAssertNil(d.preferences.state.linkedUserID)
        XCTAssertEqual(d.router.authState, .needsUser(focusUserID: nil))
        let selection = await d.selection
        XCTAssertEqual(selection, .none)
        try await d.waitForRevocations(1)
    }

    func testSigningOutOfAUsersLastSignInRemovesTheUser() async throws {
        let d = try Device(self)
        let (_, sam) = try await d.twoUsers()

        await d.users.signOut(.make(F.home, "13"), router: d.router)

        XCTAssertNil(try d.index().users.first { $0.id == sam.id })
        XCTAssertNil(try d.f.signIn(.make(F.home, "13")))
    }

    /// Sign Out of {server} on a sign-in that isn't open keeps the screen.
    func testSigningOutOfAnotherSignInKeepsTheCurrentOne() async throws {
        let d = try Device(self)
        let (alex, _) = try await d.twoUsers()
        d.router.showServerChooser(userID: alex.id, focus: nil)

        await d.users.signOut(.make(F.friend, "40"), router: d.router)

        XCTAssertEqual(try d.user(named: "alex")?.signIns, [.make(F.home, "12")])
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "13")))
        XCTAssertEqual(d.router.authState, .needsServer(userID: alex.id, focusServerID: nil))
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [d.token("40", on: F.friend)])
    }

    /// Sign Out & Remove Server signs every user out of the server; a user
    /// whose only server it was goes too.
    func testSignOutAndRemoveServerRemovesItsSingleSignInUsers() async throws {
        let d = try Device(self)
        let (alex, _) = try await d.twoUsers()
        let copy = d.users.confirmation(for: .server(F.home))
        XCTAssertTrue(copy.message.contains("alex"), copy.message)
        XCTAssertTrue(copy.message.contains("sam"), copy.message)

        await d.users.signOutCurrent(alsoRemoveServer: true, asksForAccountChoice: false, router: d.router)

        XCTAssertNil(d.registry.entry(with: F.home))
        XCTAssertNil(try d.user(named: "sam"))
        XCTAssertEqual(try d.user(named: "alex")?.signIns, [.make(F.friend, "40")])
        XCTAssertEqual(d.preferences.state.lastServer(for: alex.id), F.friend)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.friend, "40")), "the one user left opens")
        try await d.waitForRevocations(2)
        XCTAssertEqual(Set(d.revokedAccessTokens()), [d.token("12", on: F.home), d.token("13", on: F.home)])
    }

    // MARK: - Rename

    func testRenameAndClearingTheName() async throws {
        let d = try Device(self)
        let (alex, sam) = try await d.twoUsers()

        let renamed = await d.users.renameUser(sam.id, to: "  Living Room  ")
        XCTAssertTrue(renamed)
        XCTAssertEqual(d.users.directory.user(sam.id)?.name, "Living Room")
        XCTAssertEqual(d.users.directory.user(sam.id)?.servers.first?.username, "sam")
        XCTAssertEqual(d.users.directory.user(sam.id)?.servers.first?.showsUsername, true,
                       "a renamed user's rows name the account")

        await d.users.requestRename(sam.id, router: d.router)
        XCTAssertEqual(d.router.renameRequest, UserRenameRequest(id: sam.id, currentName: "Living Room"))

        let cleared = await d.users.renameUser(sam.id, to: "   ")
        XCTAssertTrue(cleared)
        XCTAssertEqual(d.users.directory.user(sam.id)?.name, "sam")
        XCTAssertNil(try d.index().users.first { $0.id == sam.id }?.displayName)
        XCTAssertEqual(d.users.directory.user(alex.id)?.name, "alex")
    }

    /// Rename saved as pre-filled, or set back to the default name, is no
    /// rename: rows don't start naming the account, and the default keeps
    /// following the oldest sign-in (spec §4).
    func testSavingTheDefaultNameIsNoRename() async throws {
        let d = try Device(self)
        let (alex, _) = try await d.twoUsers()
        await d.users.requestRename(alex.id, router: d.router)
        let prefilled = try XCTUnwrap(d.router.renameRequest?.currentName)

        let saved = await d.users.renameUser(alex.id, to: prefilled)

        XCTAssertTrue(saved)
        XCTAssertNil(try d.index().users.first { $0.id == alex.id }?.displayName)
        XCTAssertEqual(d.users.directory.user(alex.id)?.isRenamed, false)
        XCTAssertEqual(d.users.directory.user(alex.id)?.servers.map(\.showsUsername), [false, false])

        _ = await d.users.renameUser(alex.id, to: "Living Room")
        let restored = await d.users.renameUser(alex.id, to: " alex ")
        XCTAssertTrue(restored)
        XCTAssertNil(try d.index().users.first { $0.id == alex.id }?.displayName)
        XCTAssertEqual(d.users.directory.user(alex.id)?.name, "alex")
    }

    /// "Signed in as …" names the open server once, even for a name told
    /// apart by that server (spec §5.1).
    func testAccountLineNamesTheServerOnce() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        let homeAlex = try XCTUnwrap(try d.user(named: "alex"))
        try await d.signIn("40", "alex2", on: F.friend, context: .addServer(userID: homeAlex.id))
        try await d.signIn("41", "alex", on: F.friend, context: .addUser)
        XCTAssertEqual(try d.index().users.count, 2)

        await d.users.openServer(F.home, userID: homeAlex.id, router: d.router)

        XCTAssertEqual(d.users.directory.user(homeAlex.id)?.name, "alex · Home Silo")
        XCTAssertEqual(d.users.accountLine(fallbackUsername: nil), "Signed in as alex · Home Silo")
    }

    /// A server's pushes follow the current user's sign-in there, so Sign
    /// Out of {server} on one of the current user's other servers turns that
    /// server's pushes off before the sign-in goes; signing another user out
    /// leaves the current user's registration alone.
    func testSigningOutOfTheCurrentUsersOtherServerTurnsItsPushesOff() async throws {
        let d = try Device(self)
        let (alex, sam) = try await d.twoUsers()
        await d.users.openServer(F.home, userID: alex.id, router: d.router)
        XCTAssertEqual(d.pushTurnedOff, [])

        await d.users.signOut(.make(F.home, "13"), router: d.router)
        XCTAssertEqual(d.pushTurnedOff, [], "sam's sign-in isn't what Home pushes to here")
        XCTAssertNil(try d.index().users.first { $0.id == sam.id })

        await d.users.signOut(.make(F.friend, "40"), router: d.router)
        XCTAssertEqual(d.pushTurnedOff, [F.friend])
        XCTAssertEqual(try d.index().users.first { $0.id == alex.id }?.signIns, [.make(F.home, "12")])
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "12")), "Home stays open")
    }

    // MARK: - Launch and Ask For

    /// Ask For: User + Profile at cold launch shows Choose a User with focus
    /// on the linked user when Profile Selection asks; Profile Only opens
    /// the linked user's last server.
    func testAskForAtColdLaunch() async throws {
        let d = try Device(self)
        let (_, sam) = try await d.twoUsers()
        d.preferences.behavior = .askEveryLaunch
        d.preferences.askFor = .userAndProfile

        let askedLaunch = await d.users.resolveLaunch()
        let asked = try XCTUnwrap(askedLaunch)
        XCTAssertEqual(asked.state, .needsUser(focusUserID: sam.id))
        let none = await d.selection
        XCTAssertEqual(none, .none)

        d.preferences.askFor = .profileOnly
        let openedLaunch = await d.users.resolveLaunch()
        let opened = try XCTUnwrap(openedLaunch)
        XCTAssertEqual(opened.state, .needsProfile)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "13")))

        // Automatic never asks.
        d.preferences.behavior = .automatic
        d.preferences.askFor = .userAndProfile
        let automaticLaunch = await d.users.resolveLaunch()
        let automatic = try XCTUnwrap(automaticLaunch)
        XCTAssertNotEqual(automatic.state, .needsUser(focusUserID: sam.id))
    }

    func testAskForOnForegroundAfterTheAwayTimeout() async throws {
        let d = try Device(self)
        let (_, sam) = try await d.twoUsers()
        d.preferences.behavior = .afterOneHour
        d.preferences.askFor = .userAndProfile
        XCTAssertTrue(d.preferences.markBackgrounded(at: d.now))

        d.now = d.now.addingTimeInterval(30 * 60)
        let early = await d.users.resolve(.foregroundAfterAway)
        XCTAssertNotEqual(early, .chooseUser(focusUserID: sam.id), "before the timeout nothing asks")

        d.now = d.now.addingTimeInterval(31 * 60)
        let late = await d.users.resolve(.foregroundAfterAway)
        let decision = try XCTUnwrap(late)
        XCTAssertEqual(decision, .chooseUser(focusUserID: sam.id))
        await d.users.apply(decision, router: d.router)
        XCTAssertEqual(d.router.authState, .needsUser(focusUserID: sam.id))
        let selection = await d.selection
        XCTAssertEqual(selection, .none, "nobody is selected while choosing")
    }

    /// Ask For on a return to Who's Watching (spec §6.3): no profile is
    /// open, but past the away timeout User + Profile still shows Choose a
    /// User with focus on the linked user, and the user opened from it shows
    /// Who's Watching instead of reopening its remembered profile. Before the
    /// timeout, or with Profile Only, Who's Watching stays and the away
    /// interval ends.
    func testAskForOnReturnToWhoIsWatching() async throws {
        let d = try Device(self)
        let (alex, sam) = try await d.twoUsers()
        let alexHome = SignInKey.make(F.home, "12")
        let epoch = try XCTUnwrap(try d.f.signIn(alexHome)?.epoch?.uuidString)
        XCTAssertTrue(d.preferences.remember(profileID: "alex-profile", requiresPIN: false, accountEpoch: epoch,
                                             for: alexHome, legacyOwnerAccountID: nil))
        d.preferences.behavior = .afterOneHour
        d.preferences.askFor = .userAndProfile
        XCTAssertEqual(d.router.authState, .needsProfile)

        XCTAssertTrue(d.preferences.markBackgrounded(at: d.now))
        d.now = d.now.addingTimeInterval(30 * 60)
        await d.users.applyAskForOnReturnToProfileSelection(router: d.router)
        XCTAssertEqual(d.router.authState, .needsProfile, "before the timeout nothing asks")
        XCTAssertNil(d.preferences.state.backgroundedAt)

        d.preferences.askFor = .profileOnly
        XCTAssertTrue(d.preferences.markBackgrounded(at: d.now))
        d.now = d.now.addingTimeInterval(61 * 60)
        await d.users.applyAskForOnReturnToProfileSelection(router: d.router)
        XCTAssertEqual(d.router.authState, .needsProfile, "Profile Only keeps Who's Watching")
        XCTAssertNil(d.preferences.state.backgroundedAt)

        d.preferences.askFor = .userAndProfile
        XCTAssertTrue(d.preferences.markBackgrounded(at: d.now))
        d.now = d.now.addingTimeInterval(61 * 60)
        await d.users.applyAskForOnReturnToProfileSelection(router: d.router)
        XCTAssertEqual(d.router.authState, .needsUser(focusUserID: sam.id))
        let none = await d.selection
        XCTAssertEqual(none, .none)

        await d.users.openUser(alex.id, router: d.router)
        await d.users.openServer(F.home, userID: alex.id, router: d.router)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(alexHome))
        XCTAssertEqual(d.router.authState, .needsProfile)
        let profile = await d.f.store.getProfileId()
        XCTAssertNil(profile, "the remembered profile waits for Who's Watching")
    }

    // MARK: - Expiry

    /// A rejected refresh shows the sign-in's screen with Change server and
    /// Switch User (spec §6.2.3); signing in again refreshes it.
    func testExpiryLeadsToSignInAgainWithChangeServerAndSwitchUser() async throws {
        let d = try Device(self)
        let (alex, _) = try await d.twoUsers()
        await d.users.openServer(F.home, userID: alex.id, router: d.router)
        let key = SignInKey.make(F.home, "12")
        let identity = await d.f.store.refreshAccountIdentity()
        let captured = await d.f.store.captureRefreshCredential(expected: try XCTUnwrap(identity))
        let disposition = await d.f.store.invalidateRejectedRefresh(try XCTUnwrap(captured))
        XCTAssertEqual(disposition, .persistentSessionCleared)

        await d.users.handleSessionExpired(router: d.router)

        XCTAssertEqual(d.router.authState, .needsLogin)
        XCTAssertEqual(d.router.signInContext, .signInAgain(userID: alex.id, key: key))
        XCTAssertEqual(d.router.loginNotice, .sessionExpired)
        XCTAssertEqual(d.users.directory.user(alex.id)?.needsSignInAgain, true)

        await d.users.changeSignInServer(router: d.router)
        XCTAssertEqual(d.router.authState, .needsServer(userID: alex.id, focusServerID: F.home))
        XCTAssertTrue(d.router.path.isEmpty, "Choose a Server as the root, which offers Switch User")
        await d.users.beginSwitchUser(router: d.router)
        XCTAssertEqual(d.router.path.count, 1, "Choose a User on top, with Back to the servers")
        d.router.goBack()

        await d.users.switchUserFromSignIn(router: d.router)
        XCTAssertEqual(d.router.authState, .needsUser(focusUserID: alex.id))

        // Picking alex's Home Silo again opens its sign-in screen; the same
        // account refreshes the saved sign-in.
        await d.users.openServer(F.home, userID: alex.id, router: d.router)
        XCTAssertEqual(d.router.signInContext, .signInAgain(userID: alex.id, key: key))
        try await d.finishSignIn("12", "alex", on: F.home)
        XCTAssertEqual(try d.f.signIn(key)?.isSignedIn, true)
        XCTAssertEqual(try d.user(named: "alex")?.signIns, [key, .make(F.friend, "40")])
        XCTAssertEqual(d.router.authState, .needsProfile)
    }

    /// Cancel on a question that Sign in again raised lands on that sign-in
    /// screen again, which starts over instead of keeping its finished state.
    func testCancellingAQuestionFromSignInAgainRestartsTheSignInScreen() async throws {
        let d = try Device(self)
        let (alex, _) = try await d.twoUsers()
        await d.users.openServer(F.home, userID: alex.id, router: d.router)
        let identity = await d.f.store.refreshAccountIdentity()
        let captured = await d.f.store.captureRefreshCredential(expected: try XCTUnwrap(identity))
        _ = await d.f.store.invalidateRejectedRefresh(try XCTUnwrap(captured))
        await d.users.handleSessionExpired(router: d.router)
        let generation = d.router.signInScreenGeneration

        try await d.finishSignIn("15", "kim", on: F.home)
        let prompt = try XCTUnwrap(d.router.signInPrompt)
        await d.users.answer(prompt, accept: false, router: d.router)

        XCTAssertEqual(d.router.authState, .needsLogin)
        XCTAssertEqual(d.router.signInContext, .signInAgain(userID: alex.id, key: .make(F.home, "12")))
        XCTAssertEqual(d.router.signInScreenGeneration, generation + 1)
    }

    // MARK: - Remote playback

    func testATemporaryScopeBlocksSwitchingUntilItEnds() async throws {
        let d = try Device(self)
        let (alex, _) = try await d.twoUsers()
        d.allowsEndingTemporaryIdentity = false
        d.router.showUserChooser(focus: nil)

        await d.users.openServer(F.home, userID: alex.id, router: d.router)

        var selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "13")))
        XCTAssertEqual(d.router.authState, .needsUser(focusUserID: nil))
        XCTAssertNotNil(d.router.accountActionError)

        d.allowsEndingTemporaryIdentity = true
        d.router.accountActionError = nil
        await d.users.openServer(F.home, userID: alex.id, router: d.router)
        selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "12")))
        XCTAssertNil(d.router.accountActionError)
    }

    // MARK: - Phone pairing

    /// A phone signing this TV in during first run creates the first user;
    /// a later server in the same pairing joins that user.
    func testPairingPlacesTheSessionInTheRunningSignIn() async throws {
        let d = try Device(self)
        d.router.resetToServerSetup(context: .firstRun)
        typealias Pairing = ReceiverPairingCoordinator.PersistedPairing

        let first = await d.users.completePairing(
            Pairing(url: F.homeURL, fetchedName: "Home Silo", verifiedServerId: nil,
                    accessToken: "paired-home", refreshToken: "r", accountID: "12"),
            router: d.router)
        XCTAssertTrue(first)
        let user = try XCTUnwrap(try d.index().users.first)
        XCTAssertEqual(user.signIns, [.make(F.home, "12")])
        XCTAssertEqual(d.preferences.state.linkedUserID, user.id)
        XCTAssertEqual(d.registry.activeServerId, F.home)

        let second = await d.users.completePairing(
            Pairing(url: F.friendURL, fetchedName: "Friend's Silo", verifiedServerId: nil,
                    accessToken: "paired-friend", refreshToken: "r", accountID: "40"),
            router: d.router)
        XCTAssertTrue(second)
        XCTAssertEqual(try d.index().users.count, 1)
        XCTAssertEqual(try d.index().users.first?.signIns, [.make(F.home, "12"), .make(F.friend, "40")])
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.friend, "40")))
    }

    // MARK: - A device with one user and one server

    /// Signing out of the only server's last sign-in shows "Sign in to…" with
    /// that server and Add a New Server (spec §5.4); only a device with no
    /// saved server goes straight to server setup. Picking the server opens
    /// its sign-in, and Change server there comes back to the list.
    func testSigningOutOfTheOnlyServerShowsSignInTo() async throws {
        let d = try Device(self)
        _ = await d.registry.remove(serverId: F.friend)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)

        await d.users.signOutCurrent(alsoRemoveServer: false, asksForAccountChoice: false, router: d.router)

        XCTAssertEqual(try d.index().users, [])
        XCTAssertEqual(d.router.authState, .needsSignInTarget(.firstRun))
        XCTAssertEqual(d.router.signInContext, .firstRun)
        XCTAssertEqual(d.registry.activeServerId, F.home)
        XCTAssertNil(d.router.signInReturnPoint, "nothing to cancel back to")
        let none = await d.selection
        XCTAssertEqual(none, .none)
        let targets = SignInTargetViewModel(context: .firstRun, servers: d.registry.sortedEntries,
                                            snapshot: d.users.snapshot)
        XCTAssertEqual(targets.rows.map(\.id), [F.home])

        await d.users.beginSignIn(serverID: F.home, context: .firstRun, router: d.router)
        XCTAssertEqual(d.router.authState, .needsLogin)
        await d.users.changeSignInServer(router: d.router)
        XCTAssertEqual(d.router.authState, .needsSignInTarget(.firstRun))
    }

    /// The same rule at launch: one saved server and no user is "Sign in
    /// to…"; no saved server is server setup.
    func testLaunchWithSavedServersAndNoUsersShowsSignInTo() async throws {
        let d = try Device(self)
        _ = await d.registry.remove(serverId: F.friend)

        let oneServer = await d.users.resolveLaunch()
        XCTAssertEqual(oneServer?.state, .needsSignInTarget(.firstRun))
        XCTAssertEqual(oneServer?.signInContext, .firstRun)

        _ = await d.registry.remove(serverId: F.home)
        let noServer = await d.users.resolveLaunch()
        XCTAssertEqual(noServer?.state, .needsServerSetup)
    }

    // MARK: - Pending legacy servers (plan §3.3)

    /// A migrated user's server that was still on its old per-server session.
    private func migratedDevice() async throws -> (Device, SiloUser) {
        let d = try Device(self, migrated: false)
        try d.f.seedLegacySession(F.home, url: F.homeURL, accountID: nil, access: "legacy", refresh: "legacy-refresh")
        try d.f.seedLegacySession(F.friend, url: F.friendURL, accountID: "40", access: "friend", refresh: "r")
        _ = await d.f.store.migrateLegacySessionsIfNeeded(
            servers: [(F.home, F.homeURL), (F.friend, F.friendURL)], activeServerID: F.friend)
        let user = try XCTUnwrap(try d.index().users.first)
        XCTAssertEqual(user.pendingLegacyServerIDs, [F.home])
        let switched = await d.registry.switchTo(serverId: F.home, credential: .legacy(serverID: F.home), userID: user.id)
        XCTAssertTrue(switched)
        return (d, user)
    }

    /// A pending server's own session counts as signed in only while it is
    /// selected: with nothing selected on it (a chooser, the server step, or
    /// setup typing its address), Who's Watching must not open.
    func testAPendingServerIsSignedOutWhileNothingIsSelected() async throws {
        let (d, user) = try await migratedDevice()
        XCTAssertTrue(d.auth.isLoggedIn)

        let cleared = await d.registry.switchTo(serverId: F.home, credential: .none, userID: user.id)
        XCTAssertTrue(cleared)
        XCTAssertFalse(d.auth.isLoggedIn)
        XCTAssertFalse(shouldPresentProfileSelectionAfterRecovery(isLoggedIn: d.auth.isLoggedIn, activeProfileID: nil))

        let reselected = await d.registry.switchTo(serverId: F.home, credential: .legacy(serverID: F.home),
                                                   userID: user.id)
        XCTAssertTrue(reselected)
        XCTAssertTrue(d.auth.isLoggedIn)
    }

    /// The credential a background launch selects: an active server the
    /// registry fell back to (a new Apple TV user's first launch, the
    /// survivor of a removal) is no history, so with two users neither
    /// opens; a server this Apple TV user opened before users existed opens
    /// the migrated user, as the launch rules do.
    func testLaunchSelectionDoesNotTreatAFallbackServerAsHistory() async throws {
        let (d, migrated) = try await migratedDevice()
        try await d.signIn("13", "sam", on: F.home, context: .addUser)
        XCTAssertEqual(try d.index().users.count, 2)
        await d.f.store.select(serverID: F.friend, credential: .none, userID: nil)
        d.f.defaults.set(try JSONEncoder().encode(ProfileLaunchState()), forKey: SharedStorage.profileLaunchStateKey)
        d.f.defaults.set(F.friend, forKey: SharedStorage.activeServerIdKey)

        d.f.defaults.set(true, forKey: ServerRegistry.activeServerFallbackKey)
        let fallback = await d.f.store.launchSelection(forServer: F.friend)
        XCTAssertEqual(fallback.credential, .none)
        XCTAssertNil(fallback.userID)

        d.f.defaults.removeObject(forKey: ServerRegistry.activeServerFallbackKey)
        let opened = await d.f.store.launchSelection(forServer: F.friend)
        XCTAssertEqual(opened.userID, migrated.id)
        XCTAssertEqual(opened.credential, .signIn(.make(F.friend, "40")))
    }

    /// A pending server whose refresh is rejected leaves its user (its
    /// session is gone), and signing in adds it back to that user.
    func testARejectedPendingServerIsDroppedAndSignsBackIntoItsUser() async throws {
        let (d, user) = try await migratedDevice()
        let identity = await d.f.store.refreshAccountIdentity()
        let captured = await d.f.store.captureRefreshCredential(expected: try XCTUnwrap(identity))
        let disposition = await d.f.store.invalidateRejectedRefresh(try XCTUnwrap(captured))
        XCTAssertEqual(disposition, .persistentSessionCleared)

        await d.users.handleSessionExpired(router: d.router)

        XCTAssertNil(try d.index().users.first?.pendingLegacyServerIDs)
        XCTAssertEqual(d.router.authState, .needsLogin)
        XCTAssertEqual(d.router.signInContext, .addServer(userID: user.id))
        XCTAssertEqual(d.router.loginNotice, .sessionExpired)

        try await d.finishSignIn("12", "alex", on: F.home)
        XCTAssertEqual(try d.index().users.first?.signIns, [.make(F.friend, "40"), .make(F.home, "12")])
    }

    /// A pending server whose account turns out unsaved becomes its sign-in
    /// in place, and the screen's stores re-scope (`signInRevision`): the
    /// account mirror went from none to the account, so stores keyed by
    /// account read again under the keys that took over their old data.
    func testAMigratedPendingServerReScopesTheSessionsStores() async throws {
        let (d, migrated) = try await migratedDevice()
        let auth = await d.f.store.captureOrdinaryRequestAuth()
        let outcome = try await d.f.store.bindVerifiedAccount(.stub(id: "12", username: "alex"),
                                                              expected: try XCTUnwrap(auth))
        XCTAssertEqual(outcome, .legacyMigrated(.make(F.home, "12")))
        let before = d.router.signInRevision

        await d.users.handleSignInMigrated(outcome, router: d.router)

        XCTAssertNotEqual(d.router.signInRevision, before)
        XCTAssertEqual(d.preferences.state.lastServer(for: migrated.id), F.home)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "12")))
    }

    /// A pending server's account already saved in another user: the pending
    /// server goes, that sign-in takes over the server's old local data, and
    /// the launch rules pick what opens.
    func testADuplicatePendingServerHandsOverToTheSavedSignIn() async throws {
        let (d, migrated) = try await migratedDevice()
        try await d.signIn("12", "sam", on: F.home, context: .addUser)
        let sam = try XCTUnwrap(try d.user(named: "sam"))
        let switched = await d.registry.switchTo(serverId: F.home, credential: .legacy(serverID: F.home),
                                                 userID: migrated.id)
        XCTAssertTrue(switched)
        let auth = await d.f.store.captureOrdinaryRequestAuth()

        let outcome = try await d.f.store.bindVerifiedAccount(.stub(id: "12"), expected: try XCTUnwrap(auth))
        XCTAssertEqual(outcome, .legacyDuplicate(existing: .make(F.home, "12"), revoking: RevocableCredential(
            serverURL: F.homeURL, accessToken: "legacy", refreshToken: "legacy-refresh")))
        XCTAssertEqual(try d.index().legacyDataOwnerByServerID?[F.home], "12")

        await d.users.handleSignInMigrated(outcome, router: d.router)

        XCTAssertNil(try d.index().users.first { $0.id == migrated.id }?.pendingLegacyServerIDs)
        XCTAssertEqual(d.preferences.state.linkedUserID, sam.id)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "12")))
    }

    /// The account read that finds a pending server's account already saved
    /// ends the dropped session on that server, with its own tokens, when
    /// they differ from the saved sign-in's; the saved session stays.
    func testReadingADuplicatePendingServersAccountRevokesItsOwnSession() async throws {
        let (d, migrated) = try await migratedDevice()
        try await d.signIn("12", "sam", on: F.home, context: .addUser)
        let switched = await d.registry.switchTo(serverId: F.home, credential: .legacy(serverID: F.home),
                                                 userID: migrated.id)
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

    /// "Sign In Again" on an error screen opens the current sign-in's
    /// sign-in screen without signing anyone out.
    func testSignInAgainFromAnErrorKeepsEverySignIn() async throws {
        let d = try Device(self)
        let (_, sam) = try await d.twoUsers()
        let before = try d.index()

        let shown = await d.users.signInAgainForCurrentSession(router: d.router)

        XCTAssertTrue(shown)
        XCTAssertEqual(try d.index(), before)
        XCTAssertEqual(d.router.authState, .needsLogin)
        XCTAssertEqual(d.router.signInContext, .signInAgain(userID: sam.id, key: .make(F.home, "13")))
        XCTAssertTrue(d.revokedAccessTokens().isEmpty)
    }

    /// Signing a user out of its last server while its servers are the root
    /// leaves nothing to pick there: the launch rules run.
    func testRemovingTheShownUsersLastServerLeavesItsChooser() async throws {
        let d = try Device(self)
        let (alex, sam) = try await d.twoUsers()
        await d.users.apply(.chooseServer(userID: alex.id, focusServerID: nil), router: d.router)
        XCTAssertEqual(d.router.authState, .needsServer(userID: alex.id, focusServerID: nil))

        await d.users.signOut(.make(F.home, "12"), router: d.router)
        XCTAssertEqual(d.router.authState, .needsServer(userID: alex.id, focusServerID: nil), "alex still has a server")
        await d.users.signOut(.make(F.friend, "40"), router: d.router)

        XCTAssertNil(try d.user(named: "alex"))
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "13")), "the one user left opens")
        XCTAssertEqual(d.preferences.state.linkedUserID, sam.id)
    }

    /// A question answers once; a newer one replaces an unanswered one and
    /// revokes the session it was holding.
    func testPromptsAnswerOnceAndAReplacedOneIsRevoked() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        let alex = try XCTUnwrap(try d.user(named: "alex"))
        try await d.signIn("15", "kim", on: F.home, context: .addServer(userID: alex.id))
        let first = try XCTUnwrap(d.router.signInPrompt)

        try await d.finishSignIn("16", "lee", on: F.home)
        let second = try XCTUnwrap(d.router.signInPrompt)
        XCTAssertNotEqual(first.id, second.id)
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), [first.pending.accessToken])

        await d.users.answer(first, accept: true, router: d.router)
        XCTAssertNil(try d.user(named: "kim"), "the replaced question can't be answered")
        await d.users.answer(second, accept: true, router: d.router)
        await d.users.answer(second, accept: true, router: d.router)
        XCTAssertEqual(try d.index().users.count, 2)
        XCTAssertNotNil(try d.user(named: "lee"))
    }

    /// A sign-in that finishes after its screen was left (Change server while
    /// it was in flight) is revoked and saved nowhere, and Cancel on the
    /// screen now showing still goes back where the sign-in started.
    func testASignInFinishingAfterItsScreenWasLeftIsRevoked() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        let before = try d.index()
        await d.users.startAddUser(router: d.router)
        await d.users.beginSignIn(serverID: F.friend, context: .addUser, router: d.router)
        let identity = await d.f.store.refreshAccountIdentity()
        let pending = d.pending("13", "sam", expected: try XCTUnwrap(identity))

        await d.users.changeSignInServer(router: d.router)
        XCTAssertEqual(d.router.authState, .needsSignInTarget(.addUser))
        do {
            _ = try await d.users.completeSignIn(pending, router: d.router)
            XCTFail("a sign-in for a screen that's gone was saved")
        } catch is CancellationError {}

        XCTAssertEqual(try d.index(), before)
        XCTAssertNil(d.router.signInPrompt)
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
        let beganHome = await d.users.beginSignIn(serverID: F.home, context: .firstRun, router: d.router)
        XCTAssertTrue(beganHome)
        let identity = await d.f.store.refreshAccountIdentity()
        let pending = d.pending("12", "alex", expected: try XCTUnwrap(identity))
        let beganFriend = await d.users.beginSignIn(serverID: F.friend, context: .firstRun, router: d.router)
        XCTAssertTrue(beganFriend)
        XCTAssertEqual(d.router.authState, .needsLogin)

        do {
            _ = try await d.users.completeSignIn(pending, router: d.router)
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

    /// Removing a server from the device while Choose a Server shows a user
    /// whose only server it was leaves nothing to pick: the launch rules run.
    func testRemovingTheShownUsersOnlyServerLeavesItsChooser() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        let alex = try XCTUnwrap(try d.user(named: "alex"))
        try await d.signIn("15", "kim", on: F.friend, context: .addUser)
        let kim = try XCTUnwrap(try d.user(named: "kim"))
        await d.users.apply(.chooseServer(userID: alex.id, focusServerID: nil), router: d.router)
        XCTAssertEqual(d.registry.activeServerId, F.friend, "alex's server isn't the active one")

        await d.users.removeServer(F.home, router: d.router)

        XCTAssertNil(try d.user(named: "alex"))
        XCTAssertEqual(d.preferences.state.linkedUserID, kim.id)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.friend, "15")))
        XCTAssertEqual(d.router.authState, .needsProfile)
    }

    /// Opening another user names it before its screen shows: the account
    /// line and menus read a directory already reloaded for it.
    func testOpeningAUserUpdatesTheDirectoryBeforeItsScreenShows() async throws {
        let d = try Device(self)
        let (alex, sam) = try await d.twoUsers()
        await d.users.reloadDirectory()
        XCTAssertEqual(d.users.directory.currentUserID, sam.id)
        let seen = ObservedUser()
        let users = d.users
        withObservationTracking { _ = d.router.signInRevision } onChange: {
            seen.userID = MainActor.assumeIsolated { users.directory.currentUserID }
        }

        await d.users.openServer(F.home, userID: alex.id, router: d.router)

        XCTAssertEqual(seen.userID, alex.id)
    }

    /// The selected sign-in is app-wide, so a user opened in one window
    /// re-scopes every window's screens (macOS), even on the same server:
    /// another window must not keep alex's screens while its requests go
    /// out as sam.
    func testOpeningAUserInOneWindowReScopesTheOthers() async throws {
        let d = try Device(self)
        let (alex, _) = try await d.twoUsers()
        let otherWindow = AppRouter()
        otherWindow.usersOverride = d.users
        let before = otherWindow.signInRevision
        let changed = ObservedFlag()
        withObservationTracking { _ = otherWindow.signInRevision } onChange: {
            changed.value = true
        }

        await d.users.openServer(F.home, userID: alex.id, router: d.router)

        XCTAssertTrue(changed.value, "the other window's identity key follows the switch")
        XCTAssertNotEqual(otherWindow.signInRevision, before)
        XCTAssertEqual(otherWindow.signInRevision, d.router.signInRevision)
    }

    /// Who's Watching reads "Last used" without waiting (tvOS focuses it on
    /// the first frame), for the selected sign-in only.
    func testTheRememberedProfileReadsWithoutWaiting() async throws {
        let d = try Device(self)
        let (alex, _) = try await d.twoUsers()
        let samHome = SignInKey.make(F.home, "13")
        let epoch = try XCTUnwrap(try d.f.signIn(samHome)?.epoch?.uuidString)
        XCTAssertNil(d.auth.rememberedProfileIDForCurrentSelection)
        XCTAssertTrue(d.preferences.remember(profileID: "sam-profile", requiresPIN: false, accountEpoch: epoch,
                                             for: samHome, legacyOwnerAccountID: nil))
        XCTAssertEqual(d.auth.rememberedProfileIDForCurrentSelection, "sam-profile")

        await d.users.openServer(F.home, userID: alex.id, router: d.router)
        XCTAssertNil(d.auth.rememberedProfileIDForCurrentSelection, "sam's profile isn't alex's")
    }

    /// A profile list read while a remote-playback identity answers requests
    /// is that account's, so it isn't saved for the user cards.
    func testProfilesReadUnderATemporaryIdentityAreNotCachedOnTheSignIn() async throws {
        let d = try Device(self)
        _ = try await d.twoUsers()
        let samHome = SignInKey.make(F.home, "13")
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

    /// A pairing that stops before anything keeps its session (here,
    /// cancelled) ends that session on the server.
    func testAPairingStoppedBeforeSavingEndsItsSession() async throws {
        let d = try Device(self)
        let users = d.users
        let router = d.router
        let pairing = Task { @MainActor in
            await users.completePairing(
                ReceiverPairingCoordinator.PersistedPairing(
                    url: F.homeURL, fetchedName: "Home Silo", verifiedServerId: nil,
                    accessToken: "paired-home", refreshToken: "r", accountID: "12"),
                router: router)
        }
        pairing.cancel()

        let saved = await pairing.value
        XCTAssertFalse(saved)
        XCTAssertEqual(try d.index().users, [])
        try await d.waitForRevocations(1)
        XCTAssertEqual(d.revokedAccessTokens(), ["paired-home"])
    }

    /// Server recovery's Try again reopens the current user's current server:
    /// unlike a cold launch, Ask For never shows Choose a User there.
    func testTryAgainReopensTheCurrentServerWithoutAskFor() async throws {
        let d = try Device(self)
        let (_, sam) = try await d.twoUsers()
        d.preferences.behavior = .askEveryLaunch
        d.preferences.askFor = .userAndProfile

        let current = await d.users.resolveCurrentServer()
        XCTAssertEqual(current?.state, .needsProfile)
        let selection = await d.selection
        XCTAssertEqual(selection, .signIn(.make(F.home, "13")))

        let launch = await d.users.resolveLaunch()
        XCTAssertEqual(launch?.state, .needsUser(focusUserID: sam.id), "a cold launch still asks")
    }

    /// A card pressed twice before the first press finishes opens once: its
    /// servers aren't pushed twice, and Add User pressed twice keeps the
    /// screen it started from as where Cancel returns.
    func testAPickPressedTwiceRunsOnce() async throws {
        let d = try Device(self)
        let (alex, sam) = try await d.twoUsers()
        d.router.showUserChooser(focus: sam.id)

        async let first: Void = d.users.openUser(alex.id, router: d.router)
        async let second: Void = d.users.openUser(alex.id, router: d.router)
        _ = await (first, second)
        XCTAssertEqual(d.router.path.count, 1, "alex's servers, once")

        d.router.showProfileSelection()
        async let addOnce: Void = d.users.startAddUser(router: d.router)
        async let addAgain: Void = d.users.startAddUser(router: d.router)
        _ = await (addOnce, addAgain)
        XCTAssertEqual(d.router.signInReturnPoint?.authState, .needsProfile)
    }

    /// Sign-out and removal sentences name their server, so a user told
    /// apart by that server isn't named with it again ("alex · Home Silo on
    /// Home Silo"), while users sharing a name are still told apart.
    func testSignOutCopyNeverRepeatsTheServer() async throws {
        let d = try Device(self)
        try await d.signIn("12", "alex", on: F.home, context: .firstRun)
        let homeAlex = try XCTUnwrap(try d.index().users.first)
        try await d.signIn("40", "alex", on: F.friend, context: .addUser)
        let friendAlex = try XCTUnwrap(try d.index().users.first { $0.id != homeAlex.id })
        try await d.signIn("41", "alexander", on: F.home, context: .addServer(userID: friendAlex.id))
        await d.users.reloadDirectory()
        XCTAssertEqual(d.users.directory.user(homeAlex.id)?.name, "alex · Home Silo")
        XCTAssertEqual(d.users.directory.user(friendAlex.id)?.name, "alex · Friend's Silo")

        let current = d.users.confirmation(for: .currentSignIn)
        XCTAssertEqual(current.message, "Everyone on this Apple TV will need to sign in again to use alex · Friend's Silo on "
                       + "Home Silo. Sign Out & Remove Server also signs out alex.")
        let friend = d.users.confirmation(for: .signIn(.make(F.friend, "40")))
        XCTAssertEqual(friend.message, "Everyone on this Apple TV will need to sign in again to use alex on Friend's Silo.")
        let server = d.users.confirmation(for: .server(F.home))
        XCTAssertEqual(server.message, "alex and alex · Friend's Silo will be signed out of Home Silo for everyone on this "
                       + "Apple TV. Profiles and watch history stay on the server.")
        let remove = d.users.confirmation(for: .user(homeAlex.id))
        XCTAssertEqual(remove.title, "Remove alex from this Apple TV?")
        XCTAssertEqual(remove.message, "alex will be signed out of Home Silo for everyone on this Apple TV. "
                       + "Profiles and watch history stay on the server.")
    }

    /// The sign-out confirmation offers Sign Out & Remove Server, so it names
    /// the other users that also signs out.
    func testSignOutConfirmationNamesOthersOnTheServer() async throws {
        let d = try Device(self)
        _ = try await d.twoUsers()
        await d.users.reloadDirectory()

        let copy = d.users.confirmation(for: .currentSignIn)

        XCTAssertEqual(copy.title, "Sign out of Home Silo?")
        XCTAssertTrue(copy.message.contains("also signs out alex"), copy.message)
        let friendCopy = d.users.confirmation(for: .signIn(.make(F.friend, "40")))
        XCTAssertFalse(friendCopy.message.contains("also signs out"), "nobody else uses Friend's Silo")
    }
}

/// The value an observation's change handler saw.
private final class ObservedUser: @unchecked Sendable {
    var userID: String?
}

private final class ObservedFlag: @unchecked Sendable {
    var value = false
}

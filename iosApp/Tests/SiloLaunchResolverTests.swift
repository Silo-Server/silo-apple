import Foundation
import XCTest
@testable import Silo

/// Spec §6.2 (pick the user, the server, the credential), §6.3 (Ask For),
/// decision 16, and the migration hints in plan §2.8.
final class SiloLaunchResolverTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let saved = ["home", "friend", "cabin"]

    private func key(_ server: String, _ account: String) -> SignInKey {
        SignInKey(serverID: server, accountID: account)!
    }

    private func user(
        _ id: String,
        _ signIns: [(server: String, account: String, signedIn: Bool)] = [],
        pending: [String] = []
    ) -> SiloLaunchInput.UserSnapshot {
        SiloLaunchInput.UserSnapshot(
            id: id,
            signIns: signIns.map { .init(key: key($0.server, $0.account), isSignedIn: $0.signedIn) },
            pendingLegacyServerIDs: pending
        )
    }

    private var alex: SiloLaunchInput.UserSnapshot {
        user("alex", [("home", "a1", true), ("friend", "a2", true)])
    }

    private var sam: SiloLaunchInput.UserSnapshot {
        user("sam", [("home", "s1", true)])
    }

    private func state(
        behavior: ProfileLaunchBehavior = .automatic,
        linked: String? = nil,
        lastServer: [String: String]? = nil,
        askFor: ProfileLaunchAskFor? = nil,
        backgroundedAt: Date? = nil
    ) -> ProfileLaunchState {
        ProfileLaunchState(
            behavior: behavior,
            backgroundedAt: backgroundedAt,
            askFor: askFor,
            linkedUserID: linked,
            lastServerByUserID: lastServer
        )
    }

    private func resolve(
        _ users: [SiloLaunchInput.UserSnapshot],
        saved: [String]? = nil,
        migrated: String? = nil,
        state: ProfileLaunchState = ProfileLaunchState(),
        mirror: String? = nil,
        trigger: SiloLaunchTrigger = .coldLaunch
    ) -> SiloLaunchDecision {
        SiloLaunchResolver.resolve(SiloLaunchInput(
            users: users,
            savedServerIDs: saved ?? self.saved,
            migratedUserID: migrated,
            state: state,
            currentServerMirror: mirror,
            trigger: trigger,
            now: now
        ))
    }

    private func open(_ userID: String, _ server: String, _ account: String, link: Bool) -> SiloLaunchDecision {
        .open(userID: userID, serverID: server, credential: .signIn(key(server, account)), linkUser: link)
    }

    // MARK: - §6.2 step 1: pick the user

    func testLinkedUserOpensWithoutLinkingAgain() {
        let decision = resolve([alex, sam], state: state(linked: "sam"))
        XCTAssertEqual(decision, open("sam", "home", "s1", link: false))
    }

    func testOnlyUserOpensAndIsLinked() {
        XCTAssertEqual(resolve([sam]), open("sam", "home", "s1", link: true))
    }

    func testTwoUsersWithoutALinkShowChooseAUser() {
        XCTAssertEqual(resolve([alex, sam]), .chooseUser(focusUserID: nil))
    }

    func testNoUsersAndNoServersGoToServerSetup() {
        XCTAssertEqual(resolve([], saved: []), .serverSetup(.firstRun))
    }

    func testNoUsersWithSavedServersShowSignInTo() {
        XCTAssertEqual(resolve([]), .signInTarget(.firstRun))
    }

    func testRemovedLinkedUserFallsThroughToTheOtherRules() {
        XCTAssertEqual(resolve([sam], state: state(linked: "gone")), open("sam", "home", "s1", link: true))
        XCTAssertEqual(resolve([alex, sam], state: state(linked: "gone")), .chooseUser(focusUserID: nil))
    }

    // MARK: - §6.2 step 2: pick the server

    func testLastServerStillInTheUserOpens() {
        let decision = resolve([alex], state: state(linked: "alex", lastServer: ["alex": "friend"]))
        XCTAssertEqual(decision, open("alex", "friend", "a2", link: false))
    }

    func testRemovedLastServerFallsBackToTheOnlyServer() {
        let decision = resolve([sam], state: state(linked: "sam", lastServer: ["sam": "friend"]))
        XCTAssertEqual(decision, open("sam", "home", "s1", link: false))
    }

    func testTwoServersWithoutAUsableLastServerShowChooseAServer() {
        XCTAssertEqual(
            resolve([alex], state: state(linked: "alex")),
            .chooseServer(userID: "alex", focusServerID: nil)
        )
        XCTAssertEqual(
            resolve([alex], state: state(linked: "alex", lastServer: ["alex": "cabin"])),
            .chooseServer(userID: "alex", focusServerID: nil)
        )
    }

    func testAUserWithNoSavedServersShowsChooseAServer() {
        let orphan = user("alex", [("gone", "a1", true)])
        XCTAssertEqual(
            resolve([orphan], state: state(linked: "alex", lastServer: ["alex": "gone"])),
            .chooseServer(userID: "alex", focusServerID: nil)
        )
    }

    func testSignInsOnServersThatArentSavedAreIgnored() {
        let alex = user("alex", [("gone", "a1", true), ("home", "a2", true)])
        XCTAssertEqual(
            resolve([alex], state: state(linked: "alex", lastServer: ["alex": "gone"])),
            open("alex", "home", "a2", link: false)
        )
    }

    // MARK: - §6.2 step 3: the credential

    func testExpiredSignInShowsSignInAgain() {
        let expired = user("sam", [("home", "s1", false)])
        XCTAssertEqual(resolve([expired]), .signInAgain(userID: "sam", key: key("home", "s1")))
    }

    func testPendingLegacyServerOpensItsOldSignIn() {
        let migrated = user("u", pending: ["home"])
        XCTAssertEqual(
            resolve([migrated], migrated: "u"),
            .open(userID: "u", serverID: "home", credential: .legacy(serverID: "home"), linkUser: true)
        )
    }

    func testUnreadableSignInCountsAsExpired() {
        let k = key("home", "s1")
        let directory = SiloUserDirectorySnapshot(
            users: [SiloUser(id: "sam", createdAt: now, signIns: [k])],
            signIns: [:]
        )
        let input = SiloLaunchInput(
            directory: directory,
            savedServerIDs: saved,
            state: ProfileLaunchState(),
            currentServerMirror: nil,
            trigger: .coldLaunch,
            now: now
        )
        XCTAssertEqual(SiloLaunchResolver.resolve(input), .signInAgain(userID: "sam", key: k))
    }

    func testDirectoryInputCarriesMembershipAndMigration() {
        let k = key("home", "s1")
        let summary = SignInSummary(key: k, userID: "u", username: "sam", isSignedIn: true, profiles: [], addedAt: now)
        let directory = SiloUserDirectorySnapshot(
            users: [SiloUser(id: "u", createdAt: now, signIns: [k], pendingLegacyServerIDs: ["friend"])],
            signIns: [k: summary],
            migratedUserID: "u"
        )
        let input = SiloLaunchInput(
            directory: directory,
            savedServerIDs: saved,
            state: ProfileLaunchState(),
            currentServerMirror: "friend",
            trigger: .coldLaunch,
            now: now
        )
        XCTAssertEqual(input.users, [user("u", [("home", "s1", true)], pending: ["friend"])])
        XCTAssertEqual(input.migratedUserID, "u")
        XCTAssertEqual(
            SiloLaunchResolver.resolve(input),
            .open(userID: "u", serverID: "friend", credential: .legacy(serverID: "friend"), linkUser: true)
        )
    }

    // MARK: - Migration hints (plan §2.8 rules 4 and 6, spec §9)

    func testLegacyRememberedProfileLinksTheMigratedUser() {
        var legacy = state()
        legacy.rememberedByServerID = ["home": RememberedProfile(profileID: "p", requiredPINAtSelection: false, accountEpoch: "e")]
        XCTAssertEqual(
            resolve([alex, sam], migrated: "alex", state: legacy),
            .chooseServer(userID: "alex", focusServerID: nil)
        )
        XCTAssertEqual(
            resolve([user("alex", [("home", "a1", true)]), sam], migrated: "alex", state: legacy),
            open("alex", "home", "a1", link: true)
        )
    }

    func testLegacyActiveServerOpensTheMigratedUserThere() {
        XCTAssertEqual(
            resolve([alex, sam], migrated: "alex", mirror: "friend"),
            open("alex", "friend", "a2", link: true)
        )
    }

    func testActiveServerOutsideTheMigratedUserShowsChooseAServer() {
        XCTAssertEqual(
            resolve([alex, sam], migrated: "alex", mirror: "cabin"),
            .chooseServer(userID: "alex", focusServerID: nil)
        )
    }

    func testNoLegacyHistoryShowsChooseAUserEvenWithAMigratedUser() {
        XCTAssertEqual(resolve([alex, sam], migrated: "alex"), .chooseUser(focusUserID: nil))
    }

    func testRemovedMigratedUserIsNotOpened() {
        XCTAssertEqual(resolve([alex, sam], migrated: "gone", mirror: "home"), .chooseUser(focusUserID: nil))
    }

    func testMigrationHintIgnoredOnceThisAppleTVUserOpenedAUser() {
        let opened = state(lastServer: ["sam": "home"])
        XCTAssertEqual(resolve([alex, sam], migrated: "alex", state: opened, mirror: "home"), .chooseUser(focusUserID: nil))
    }

    func testMigrationHintIgnoredAfterRemoval() {
        XCTAssertEqual(
            resolve([alex, sam], migrated: "alex", mirror: "home", trigger: .afterRemoval),
            .chooseUser(focusUserID: nil)
        )
    }

    func testActiveServerIsOnlyAHintForTheMigratedUser() {
        XCTAssertEqual(
            resolve([alex], state: state(linked: "alex"), mirror: "friend"),
            .chooseServer(userID: "alex", focusServerID: nil)
        )
    }

    func testRecordedLastServerWinsOverTheActiveServer() {
        let decision = resolve([alex], migrated: "alex", state: state(linked: "alex", lastServer: ["alex": "home"]), mirror: "friend")
        XCTAssertEqual(decision, open("alex", "home", "a1", link: false))
    }

    func testStaleLastServerDoesNotFallBackToTheActiveServer() {
        let decision = resolve([alex], migrated: "alex", state: state(linked: "alex", lastServer: ["alex": "cabin"]), mirror: "friend")
        XCTAssertEqual(decision, .chooseServer(userID: "alex", focusServerID: nil))
    }

    // MARK: - §6.3 Ask For

    func testProfileOnlyOpensTheLinkedUserWhenSelectionIsRequired() {
        let everyTime = state(behavior: .askEveryLaunch, linked: "sam", askFor: .profileOnly)
        XCTAssertEqual(resolve([alex, sam], state: everyTime), open("sam", "home", "s1", link: false))
    }

    func testUnsetAskForMeansProfileOnly() {
        let everyTime = state(behavior: .askEveryLaunch, linked: "sam")
        XCTAssertEqual(resolve([alex, sam], state: everyTime), open("sam", "home", "s1", link: false))
    }

    func testUserAndProfileShowsChooseAUserFocusedOnTheLinkedUser() {
        let everyTime = state(behavior: .askEveryLaunch, linked: "sam", askFor: .userAndProfile)
        XCTAssertEqual(resolve([alex, sam], state: everyTime), .chooseUser(focusUserID: "sam"))
    }

    func testUserAndProfileFocusesTheMigratedUserBeforeItIsLinked() {
        let everyTime = state(behavior: .askEveryLaunch, askFor: .userAndProfile)
        XCTAssertEqual(resolve([alex, sam], migrated: "alex", state: everyTime, mirror: "home"), .chooseUser(focusUserID: "alex"))
    }

    func testUserAndProfileWithOneUserOpensIt() {
        let everyTime = state(behavior: .askEveryLaunch, linked: "sam", askFor: .userAndProfile)
        XCTAssertEqual(resolve([sam], state: everyTime), open("sam", "home", "s1", link: false))
    }

    func testAutomaticIgnoresAskFor() {
        let automatic = state(behavior: .automatic, linked: "sam", askFor: .userAndProfile, backgroundedAt: now.addingTimeInterval(-86_400))
        XCTAssertEqual(resolve([alex, sam], state: automatic), open("sam", "home", "s1", link: false))
        XCTAssertEqual(resolve([alex, sam], state: automatic, trigger: .foregroundAfterAway), open("sam", "home", "s1", link: false))
    }

    func testPendingSwitchProfileDoesNotShowChooseAUser() {
        var pending = state(behavior: .automatic, linked: "sam", askFor: .userAndProfile)
        pending.selectionRequiredSignIns = [key("home", "s1").storageKey]
        pending.selectionRequiredServerIDs = ["home"]
        XCTAssertEqual(resolve([alex, sam], state: pending), open("sam", "home", "s1", link: false))
    }

    func testTimedSelectionAsksOnlyAfterTheAwayTimeout() {
        let away = state(behavior: .afterOneHour, linked: "sam", askFor: .userAndProfile, backgroundedAt: now.addingTimeInterval(-3_600))
        XCTAssertEqual(resolve([alex, sam], state: away), .chooseUser(focusUserID: "sam"))
        XCTAssertEqual(resolve([alex, sam], state: away, trigger: .foregroundAfterAway), .chooseUser(focusUserID: "sam"))

        let brief = state(behavior: .afterOneHour, linked: "sam", askFor: .userAndProfile, backgroundedAt: now.addingTimeInterval(-60))
        XCTAssertEqual(resolve([alex, sam], state: brief), open("sam", "home", "s1", link: false))
        XCTAssertEqual(resolve([alex, sam], state: brief, trigger: .foregroundAfterAway), open("sam", "home", "s1", link: false))
    }

    func testEveryTimeAsksAtLaunchButOnReturnOnlyAfterRealBackgrounding() {
        let everyTime = state(behavior: .askEveryLaunch, linked: "sam", askFor: .userAndProfile)
        XCTAssertEqual(resolve([alex, sam], state: everyTime), .chooseUser(focusUserID: "sam"))
        XCTAssertEqual(resolve([alex, sam], state: everyTime, trigger: .foregroundAfterAway), open("sam", "home", "s1", link: false))

        var backgrounded = everyTime
        backgrounded.backgroundedAt = now.addingTimeInterval(-1)
        XCTAssertEqual(resolve([alex, sam], state: backgrounded, trigger: .foregroundAfterAway), .chooseUser(focusUserID: "sam"))
    }

    func testAskForNeverAppliesToPicksOrRemovals() {
        let everyTime = state(behavior: .askEveryLaunch, linked: "sam", askFor: .userAndProfile, backgroundedAt: now)
        XCTAssertEqual(resolve([alex, sam], state: everyTime, trigger: .afterRemoval), open("sam", "home", "s1", link: false))
        XCTAssertEqual(resolve([alex, sam], state: everyTime, trigger: .userPicked("sam")), open("sam", "home", "s1", link: false))
        XCTAssertEqual(
            resolve([alex, sam], state: everyTime, trigger: .serverPicked(userID: "sam", serverID: "home")),
            open("sam", "home", "s1", link: false)
        )
    }

    // MARK: - Decision 16 and the pick triggers

    func testPickedUserWithTwoServersShowsChooseAServerFocusedOnItsLastServer() {
        let decision = resolve([alex, sam], state: state(linked: "alex", lastServer: ["alex": "friend"]), trigger: .userPicked("alex"))
        XCTAssertEqual(decision, .chooseServer(userID: "alex", focusServerID: "friend"))
    }

    func testLinkedUserWithTwoServersOpensItsLastServerAtLaunch() {
        let decision = resolve([alex, sam], state: state(linked: "alex", lastServer: ["alex": "friend"]))
        XCTAssertEqual(decision, open("alex", "friend", "a2", link: false))
    }

    func testPickedUserFocusOnlyNamesAServerStillInTheUser() {
        let decision = resolve([alex], state: state(lastServer: ["alex": "cabin"]), trigger: .userPicked("alex"))
        XCTAssertEqual(decision, .chooseServer(userID: "alex", focusServerID: nil))
    }

    func testPickedUserWithOneServerOpensItAndLinks() {
        let decision = resolve([alex, sam], state: state(linked: "alex"), trigger: .userPicked("sam"))
        XCTAssertEqual(decision, open("sam", "home", "s1", link: true))
    }

    func testPickedUserWithAnExpiredServerShowsSignInAgain() {
        let expired = user("sam", [("home", "s1", false)])
        XCTAssertEqual(resolve([alex, expired], trigger: .userPicked("sam")), .signInAgain(userID: "sam", key: key("home", "s1")))
    }

    func testPickedUserThatWasRemovedShowsChooseAUserAgain() {
        XCTAssertEqual(resolve([alex, sam], trigger: .userPicked("gone")), .chooseUser(focusUserID: nil))
        XCTAssertEqual(resolve([], trigger: .userPicked("gone")), .signInTarget(.firstRun))
    }

    func testPickedServerOpensIt() {
        let decision = resolve([alex, sam], state: state(linked: "alex", lastServer: ["alex": "home"]), trigger: .serverPicked(userID: "alex", serverID: "friend"))
        XCTAssertEqual(decision, open("alex", "friend", "a2", link: false))
    }

    func testPickedServerLinksAUserThatWasNotLinked() {
        let decision = resolve([alex, sam], trigger: .serverPicked(userID: "alex", serverID: "friend"))
        XCTAssertEqual(decision, open("alex", "friend", "a2", link: true))
    }

    func testPickedServerThatExpiredShowsSignInAgain() {
        let alex = user("alex", [("home", "a1", true), ("friend", "a2", false)])
        let decision = resolve([alex], trigger: .serverPicked(userID: "alex", serverID: "friend"))
        XCTAssertEqual(decision, .signInAgain(userID: "alex", key: key("friend", "a2")))
    }

    func testPickedPendingLegacyServerOpensItsOldSignIn() {
        let migrated = user("u", [("home", "a1", true)], pending: ["friend"])
        let decision = resolve([migrated], migrated: "u", trigger: .serverPicked(userID: "u", serverID: "friend"))
        XCTAssertEqual(decision, .open(userID: "u", serverID: "friend", credential: .legacy(serverID: "friend"), linkUser: true))
    }

    func testPickedServerNoLongerInTheUserShowsChooseAServerAgain() {
        XCTAssertEqual(
            resolve([alex], trigger: .serverPicked(userID: "alex", serverID: "cabin")),
            .chooseServer(userID: "alex", focusServerID: nil)
        )
        XCTAssertEqual(resolve([alex, sam], trigger: .serverPicked(userID: "gone", serverID: "home")), .chooseUser(focusUserID: nil))
    }

    // MARK: - After removal (spec §5.6)

    func testAfterRemovalOpensAnotherServerInTheSameUser() {
        let alex = user("alex", [("friend", "a2", true)])
        let decision = resolve([alex, sam], state: state(linked: "alex", lastServer: ["alex": "home"]), mirror: "home", trigger: .afterRemoval)
        XCTAssertEqual(decision, open("alex", "friend", "a2", link: false))
    }

    func testAfterRemovalShowsChooseAServerWhenTheUserStillHasSeveral() {
        let alex = user("alex", [("friend", "a2", true), ("cabin", "a3", true)])
        let decision = resolve([alex], state: state(linked: "alex", lastServer: ["alex": "home"]), trigger: .afterRemoval)
        XCTAssertEqual(decision, .chooseServer(userID: "alex", focusServerID: nil))
    }

    func testAfterRemovingTheLinkedUserShowsTheChooserOrTheOnlyUser() {
        XCTAssertEqual(resolve([alex, sam], state: state(linked: "gone"), trigger: .afterRemoval), .chooseUser(focusUserID: nil))
        XCTAssertEqual(resolve([sam], state: state(linked: "gone"), trigger: .afterRemoval), open("sam", "home", "s1", link: true))
    }

    func testAfterRemovingTheLastUserGoesToTheServerStep() {
        XCTAssertEqual(resolve([], trigger: .afterRemoval), .signInTarget(.firstRun))
        XCTAssertEqual(resolve([], saved: [], trigger: .afterRemoval), .serverSetup(.firstRun))
    }

    // MARK: - Foreground without Ask For

    func testForegroundKeepsTheCurrentUserAndServer() {
        let decision = resolve([alex, sam], state: state(linked: "alex", lastServer: ["alex": "friend"]), trigger: .foregroundAfterAway)
        XCTAssertEqual(decision, open("alex", "friend", "a2", link: false))
    }
}

import Foundation
import XCTest
@testable import Silo

/// Spec §6.2 (pick the account, then the credential), §6.3 (Ask For), and
/// the migration hints in plan §2.8.
final class SiloLaunchResolverTests: XCTestCase {
    private typealias Account = SiloAccountDirectoryFixture.Account

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let saved = ["home", "friend", "cabin"]

    private func key(_ server: String, _ account: String) -> SignInKey {
        SignInKey.make(server, account)
    }

    private func ref(_ server: String, _ account: String) -> SiloAccountRef {
        .signIn(key(server, account))
    }

    private func signIn(_ server: String, _ account: String, signedIn: Bool = true) -> Account {
        Account(serverID: server, accountID: account, isSignedIn: signedIn)
    }

    private func pending(_ server: String) -> Account {
        Account(serverID: server)
    }

    /// Two people on home and one on friend.
    private var alex: Account { signIn("home", "a1") }
    private var sam: Account { signIn("home", "s1") }
    private var kim: Account { signIn("friend", "k1") }

    private func state(
        behavior: ProfileLaunchBehavior = .automatic,
        linked: SiloAccountRef? = nil,
        askFor: ProfileLaunchAskFor? = nil,
        backgroundedAt: Date? = nil
    ) -> ProfileLaunchState {
        ProfileLaunchState(
            behavior: behavior,
            backgroundedAt: backgroundedAt,
            askFor: askFor,
            linkedAccount: linked?.storageKey
        )
    }

    private func resolve(
        _ accounts: [Account],
        saved: [String]? = nil,
        legacyOwners: [String: String] = [:],
        state: ProfileLaunchState = ProfileLaunchState(),
        mirror: String? = nil,
        trigger: SiloLaunchTrigger = .coldLaunch
    ) -> SiloLaunchDecision {
        var directory = SiloAccountDirectoryFixture.snapshot(accounts)
        directory.legacyDataOwnerByServerID = legacyOwners
        return SiloLaunchResolver.resolve(SiloLaunchInput(
            directory: directory,
            savedServerIDs: saved ?? self.saved,
            state: state,
            currentServerMirror: mirror,
            trigger: trigger,
            now: now
        ))
    }

    // MARK: - No accounts

    func testNoAccountsAndNoServersGoToServerSetup() {
        XCTAssertEqual(resolve([], saved: []), .serverSetup(.firstRun))
    }

    func testNoAccountsWithSavedServersShowSignInTo() {
        XCTAssertEqual(resolve([]), .signInTarget(.firstRun))
    }

    func testAccountsOnlyOnUnsavedServersCountAsNone() {
        XCTAssertEqual(resolve([signIn("gone", "x1")]), .signInTarget(.firstRun))
        XCTAssertEqual(resolve([signIn("gone", "x1")], saved: []), .serverSetup(.firstRun))
    }

    // MARK: - §6.2 step 1: pick the account

    func testLinkedAccountOpensWithoutLinkingAgain() {
        let decision = resolve([alex, sam, kim], state: state(linked: sam.ref))
        XCTAssertEqual(decision, .open(sam.ref, linkAccount: false))
    }

    func testOnlyAccountOpensAndIsLinked() {
        XCTAssertEqual(resolve([sam]), .open(sam.ref, linkAccount: true))
    }

    func testTwoAccountsWithoutALinkShowChooseAnAccount() {
        XCTAssertEqual(resolve([alex, sam]), .chooseAccount(focus: nil))
        XCTAssertEqual(resolve([alex, kim]), .chooseAccount(focus: nil))
    }

    func testRemovedLinkedAccountFallsThroughToTheOtherRules() {
        let gone = state(linked: ref("home", "gone"))
        XCTAssertEqual(resolve([sam], state: gone), .open(sam.ref, linkAccount: true))
        XCTAssertEqual(resolve([alex, sam], state: gone), .chooseAccount(focus: nil))
    }

    func testStaleLegacyLinkOpensTheSignInThatTookOverItsServer() {
        // Linked while home's session was still unverified; verifying it
        // turned the account into sam's sign-in.
        let decision = resolve([alex, sam], legacyOwners: ["home": "s1"],
                               state: state(linked: .pendingLegacy(serverID: "home")))
        XCTAssertEqual(decision, .open(sam.ref, linkAccount: false))
    }

    func testAccountsOnServersThatArentSavedAreIgnored() {
        let orphan = signIn("gone", "x1")
        XCTAssertEqual(resolve([orphan, sam]), .open(sam.ref, linkAccount: true))
        XCTAssertEqual(resolve([orphan, sam], state: state(linked: orphan.ref)), .open(sam.ref, linkAccount: true))
    }

    // MARK: - §6.2 step 2: the credential

    func testExpiredSignInShowsSignInAgain() {
        XCTAssertEqual(resolve([signIn("home", "s1", signedIn: false)]), .signInAgain(key("home", "s1")))
    }

    func testUnreadableSignInCountsAsExpired() {
        let k = key("home", "s1")
        let input = SiloLaunchInput(
            directory: SiloAccountDirectorySnapshot(accounts: [.signIn(k)], signIns: [:]),
            savedServerIDs: saved,
            state: ProfileLaunchState(),
            currentServerMirror: nil,
            trigger: .coldLaunch,
            now: now
        )
        XCTAssertEqual(SiloLaunchResolver.resolve(input), .signInAgain(k))
    }

    func testPendingLegacyAccountOpensItsOldSignIn() {
        XCTAssertEqual(resolve([pending("home")]), .open(.pendingLegacy(serverID: "home"), linkAccount: true))
    }

    // MARK: - Migration hints (plan §2.8, spec §9)

    func testLegacyActiveServerOpensItsPendingLegacyAccount() {
        XCTAssertEqual(
            resolve([alex, pending("friend")], mirror: "friend"),
            .open(.pendingLegacy(serverID: "friend"), linkAccount: true)
        )
    }

    func testLegacyActiveServerOpensTheSignInThatTookOverItsSession() {
        XCTAssertEqual(
            resolve([alex, sam, kim], legacyOwners: ["home": "s1"], mirror: "home"),
            .open(sam.ref, linkAccount: true)
        )
    }

    func testActiveServerWithoutALegacyAccountShowsChooseAnAccount() {
        XCTAssertEqual(resolve([alex, sam, kim], legacyOwners: ["home": "s1"], mirror: "friend"),
                       .chooseAccount(focus: nil))
    }

    func testRemovedLegacyAccountIsNotOpened() {
        XCTAssertEqual(resolve([alex, sam], legacyOwners: ["home": "gone"], mirror: "home"), .chooseAccount(focus: nil))
    }

    func testLegacyHistoryIgnoredOnceThisAppleTVUserLinkedAnAccount() {
        // The linked account was removed since; this Apple TV user chooses
        // instead of landing in the legacy account.
        let linked = state(linked: kim.ref)
        XCTAssertEqual(resolve([alex, sam], legacyOwners: ["home": "s1"], state: linked, mirror: "home"),
                       .chooseAccount(focus: nil))
    }

    func testLegacyHistoryIgnoredAfterRemoval() {
        XCTAssertEqual(
            resolve([alex, sam], legacyOwners: ["home": "s1"], mirror: "home", trigger: .afterRemoval),
            .chooseAccount(focus: nil)
        )
    }

    // MARK: - §6.3 Ask For

    func testProfileOnlyOpensTheLinkedAccountWhenSelectionIsRequired() {
        let everyTime = state(behavior: .askEveryLaunch, linked: sam.ref, askFor: .profileOnly)
        XCTAssertEqual(resolve([alex, sam], state: everyTime), .open(sam.ref, linkAccount: false))
    }

    func testUnsetAskForMeansProfileOnly() {
        let everyTime = state(behavior: .askEveryLaunch, linked: sam.ref)
        XCTAssertEqual(resolve([alex, sam], state: everyTime), .open(sam.ref, linkAccount: false))
    }

    func testAccountAndProfileShowsChooseAnAccountFocusedOnTheLinkedAccount() {
        let everyTime = state(behavior: .askEveryLaunch, linked: sam.ref, askFor: .accountAndProfile)
        XCTAssertEqual(resolve([alex, sam, kim], state: everyTime), .chooseAccount(focus: sam.ref))
    }

    func testAccountAndProfileFocusesTheLegacyAccountBeforeOneIsLinked() {
        let everyTime = state(behavior: .askEveryLaunch, askFor: .accountAndProfile)
        XCTAssertEqual(
            resolve([alex, sam], legacyOwners: ["home": "a1"], state: everyTime, mirror: "home"),
            .chooseAccount(focus: alex.ref)
        )
    }

    func testAccountAndProfileWithOneAccountOpensIt() {
        let everyTime = state(behavior: .askEveryLaunch, linked: sam.ref, askFor: .accountAndProfile)
        XCTAssertEqual(resolve([sam], state: everyTime), .open(sam.ref, linkAccount: false))
        // An account on a server that isn't saved isn't a second choice.
        XCTAssertEqual(resolve([signIn("gone", "x1"), sam], state: everyTime), .open(sam.ref, linkAccount: false))
    }

    func testAutomaticIgnoresAskFor() {
        let automatic = state(behavior: .automatic, linked: sam.ref, askFor: .accountAndProfile,
                              backgroundedAt: now.addingTimeInterval(-86_400))
        XCTAssertEqual(resolve([alex, sam], state: automatic), .open(sam.ref, linkAccount: false))
        XCTAssertEqual(resolve([alex, sam], state: automatic, trigger: .foregroundAfterAway),
                       .open(sam.ref, linkAccount: false))
    }

    func testPendingSwitchProfileDoesNotShowChooseAnAccount() {
        var pending = state(behavior: .automatic, linked: sam.ref, askFor: .accountAndProfile)
        pending.selectionRequiredSignIns = [key("home", "s1").storageKey]
        pending.selectionRequiredServerIDs = ["home"]
        XCTAssertEqual(resolve([alex, sam], state: pending), .open(sam.ref, linkAccount: false))
    }

    func testTimedSelectionAsksOnlyAfterTheAwayTimeout() {
        let away = state(behavior: .afterOneHour, linked: sam.ref, askFor: .accountAndProfile,
                         backgroundedAt: now.addingTimeInterval(-3_600))
        XCTAssertEqual(resolve([alex, sam], state: away), .chooseAccount(focus: sam.ref))
        XCTAssertEqual(resolve([alex, sam], state: away, trigger: .foregroundAfterAway), .chooseAccount(focus: sam.ref))

        let brief = state(behavior: .afterOneHour, linked: sam.ref, askFor: .accountAndProfile,
                          backgroundedAt: now.addingTimeInterval(-60))
        XCTAssertEqual(resolve([alex, sam], state: brief), .open(sam.ref, linkAccount: false))
        XCTAssertEqual(resolve([alex, sam], state: brief, trigger: .foregroundAfterAway),
                       .open(sam.ref, linkAccount: false))
    }

    func testEveryTimeAsksAtLaunchButOnReturnOnlyAfterRealBackgrounding() {
        let everyTime = state(behavior: .askEveryLaunch, linked: sam.ref, askFor: .accountAndProfile)
        XCTAssertEqual(resolve([alex, sam], state: everyTime), .chooseAccount(focus: sam.ref))
        XCTAssertEqual(resolve([alex, sam], state: everyTime, trigger: .foregroundAfterAway),
                       .open(sam.ref, linkAccount: false))

        var backgrounded = everyTime
        backgrounded.backgroundedAt = now.addingTimeInterval(-1)
        XCTAssertEqual(resolve([alex, sam], state: backgrounded, trigger: .foregroundAfterAway),
                       .chooseAccount(focus: sam.ref))
    }

    func testAskForNeverAppliesToPicksOrRemovals() {
        let everyTime = state(behavior: .askEveryLaunch, linked: sam.ref, askFor: .accountAndProfile, backgroundedAt: now)
        XCTAssertEqual(resolve([alex, sam], state: everyTime, trigger: .afterRemoval), .open(sam.ref, linkAccount: false))
        XCTAssertEqual(resolve([alex, sam], state: everyTime, trigger: .accountPicked(sam.ref)),
                       .open(sam.ref, linkAccount: false))
    }

    // MARK: - Picked in Choose an Account

    func testPickedAccountOpensAndLinks() {
        let decision = resolve([alex, sam, kim], state: state(linked: alex.ref), trigger: .accountPicked(kim.ref))
        XCTAssertEqual(decision, .open(kim.ref, linkAccount: true))
    }

    func testPickedExpiredAccountShowsSignInAgain() {
        let expired = signIn("home", "s1", signedIn: false)
        XCTAssertEqual(resolve([alex, expired], trigger: .accountPicked(expired.ref)), .signInAgain(key("home", "s1")))
    }

    func testPickedPendingLegacyAccountOpensItsOldSignIn() {
        let legacy = pending("friend")
        XCTAssertEqual(resolve([alex, legacy], trigger: .accountPicked(legacy.ref)),
                       .open(.pendingLegacy(serverID: "friend"), linkAccount: true))
    }

    func testPickedPendingLegacyAccountVerifiedSinceOpensItsSignIn() {
        let decision = resolve([alex, sam], legacyOwners: ["home": "s1"],
                               trigger: .accountPicked(.pendingLegacy(serverID: "home")))
        XCTAssertEqual(decision, .open(sam.ref, linkAccount: true))
    }

    func testPickedAccountThatWasRemovedShowsChooseAnAccountAgain() {
        XCTAssertEqual(resolve([alex, sam], trigger: .accountPicked(ref("home", "gone"))), .chooseAccount(focus: nil))
        XCTAssertEqual(resolve([alex, sam], trigger: .accountPicked(.pendingLegacy(serverID: "cabin"))),
                       .chooseAccount(focus: nil))
        XCTAssertEqual(resolve([], trigger: .accountPicked(ref("home", "gone"))), .signInTarget(.firstRun))
    }

    func testPickedAccountOnAnUnsavedServerShowsChooseAnAccountAgain() {
        let orphan = signIn("gone", "x1")
        XCTAssertEqual(resolve([orphan, alex, sam], trigger: .accountPicked(orphan.ref)), .chooseAccount(focus: nil))
    }

    // MARK: - After removal (spec §5.6)

    func testAfterRemovingTheLinkedAccountShowsTheChooserOrTheOnlyAccount() {
        let gone = state(linked: ref("home", "gone"))
        XCTAssertEqual(resolve([alex, sam], state: gone, trigger: .afterRemoval), .chooseAccount(focus: nil))
        XCTAssertEqual(resolve([sam], state: gone, trigger: .afterRemoval), .open(sam.ref, linkAccount: true))
    }

    func testAfterSigningOutWithOtherAccountsShowsTheChooserFocusedOnTheSignedOutCard() {
        let signedOut = signIn("home", "s1", signedIn: false)
        let linked = state(linked: signedOut.ref)
        XCTAssertEqual(resolve([alex, signedOut], state: linked, trigger: .afterRemoval),
                       .chooseAccount(focus: signedOut.ref))
        // At launch an expired linked account still shows its sign-in.
        XCTAssertEqual(resolve([alex, signedOut], state: linked), .signInAgain(key("home", "s1")))
    }

    func testAfterSigningOutOfTheOnlyAccountShowsItsSignIn() {
        let signedOut = signIn("home", "s1", signedIn: false)
        XCTAssertEqual(resolve([signedOut], state: state(linked: signedOut.ref), trigger: .afterRemoval),
                       .signInAgain(key("home", "s1")))
        // An account on a server that isn't saved isn't another to pick.
        XCTAssertEqual(resolve([signIn("gone", "x1"), signedOut], trigger: .afterRemoval),
                       .signInAgain(key("home", "s1")))
    }

    func testAfterRemovingTheLastAccountGoesToTheServerStep() {
        XCTAssertEqual(resolve([], trigger: .afterRemoval), .signInTarget(.firstRun))
        XCTAssertEqual(resolve([], saved: [], trigger: .afterRemoval), .serverSetup(.firstRun))
    }

    // MARK: - Foreground without Ask For

    func testForegroundKeepsTheLinkedAccount() {
        let decision = resolve([alex, sam, kim], state: state(linked: kim.ref), trigger: .foregroundAfterAway)
        XCTAssertEqual(decision, .open(kim.ref, linkAccount: false))
    }
}

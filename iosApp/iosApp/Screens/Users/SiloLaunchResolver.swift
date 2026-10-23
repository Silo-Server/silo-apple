import Foundation

/// What asks for a launch decision.
enum SiloLaunchTrigger: Equatable, Sendable {
    case coldLaunch
    /// Back in the foreground. Only Ask For can change what's showing.
    case foregroundAfterAway
    /// An account was just signed out of or removed (spec §5.6).
    case afterRemoval
    /// A card picked in Choose an Account.
    case accountPicked(SiloAccountRef)
}

/// Where Silo goes next for this Apple TV user (spec §6.2, §6.3).
enum SiloLaunchDecision: Equatable, Sendable {
    /// No saved servers: today's server setup (spec §5.4).
    case serverSetup(SignInContext)
    /// Saved servers but no account: "Sign in to…".
    case signInTarget(SignInContext)
    case chooseAccount(focus: SiloAccountRef?)
    /// Open the account. `linkAccount` is true when this Apple TV user isn't
    /// linked to it yet; opening an account links it.
    case open(SiloAccountRef, linkAccount: Bool)
    /// The account's sign-in expired: its sign-in screen.
    case signInAgain(SignInKey)
}

struct SiloLaunchInput: Equatable, Sendable {
    var directory: SiloAccountDirectorySnapshot
    /// `ServerRegistry.sortedEntries` IDs. An account on a server that isn't
    /// saved can't be opened, so launch ignores it.
    var savedServerIDs: [String]
    var state: ProfileLaunchState
    /// The `activeServerId` defaults mirror: the server this Apple TV user
    /// last had open, before accounts existed or since.
    var currentServerMirror: String?
    var trigger: SiloLaunchTrigger
    var now: Date
}

/// Picks the account, then its credential (spec §6.2), with Ask For applied
/// at launch (spec §6.3). After a sign-out, an expired account with others
/// beside it shows Choose an Account instead of its sign-in screen. Profile
/// selection runs afterwards, keyed by the sign-in. No default account is
/// stored, so a removed one falls through to the next rule.
enum SiloLaunchResolver {
    static func resolve(_ input: SiloLaunchInput) -> SiloLaunchDecision {
        let accounts = input.openableAccounts
        guard !accounts.isEmpty else {
            return input.savedServerIDs.isEmpty ? .serverSetup(.firstRun) : .signInTarget(.firstRun)
        }

        switch input.trigger {
        case .accountPicked(let picked):
            // An account removed while its card was showing: choose again.
            guard let account = input.directory.index.resolve(picked), accounts.contains(account) else {
                return .chooseAccount(focus: nil)
            }
            return input.credentialDecision(account)

        case .coldLaunch, .foregroundAfterAway, .afterRemoval:
            guard let account = input.launchAccount() else { return .chooseAccount(focus: nil) }
            if input.asksForAccount {
                return .chooseAccount(focus: account)
            }
            // Signed out of just now: its card stays, so with other accounts
            // to pick, the chooser shows rather than its sign-in screen.
            if input.trigger == .afterRemoval, accounts.count >= 2, !input.directory.isSignedIn(account) {
                return .chooseAccount(focus: account)
            }
            return input.credentialDecision(account)
        }
    }
}

private extension SiloLaunchInput {
    /// Index order, leaving out accounts on servers that aren't saved.
    var openableAccounts: [SiloAccountRef] {
        let saved = Set(savedServerIDs)
        return directory.accounts.filter { saved.contains($0.serverID) }
    }

    /// Spec §6.2 step 1: the linked account; otherwise, for an Apple TV user
    /// who used Silo before accounts existed, the account that took over the
    /// session of the server they had open; otherwise the only account. Nil
    /// shows Choose an Account.
    func launchAccount() -> SiloAccountRef? {
        let accounts = openableAccounts
        let index = directory.index
        if let linked = state.linkedAccountRef.flatMap(index.resolve), accounts.contains(linked) {
            return linked
        }
        if trigger != .afterRemoval, hasLegacyHistory, let currentServerMirror,
           let owner = index.legacyAccount(onServer: currentServerMirror), accounts.contains(owner) {
            return owner
        }
        return accounts.count == 1 ? accounts[0] : nil
    }

    /// Remembered profiles or an active server from before accounts
    /// existed, and no account opened since: every open links one. Without
    /// the link check, an Apple TV user whose linked account was removed
    /// would land in the legacy account instead of choosing.
    var hasLegacyHistory: Bool {
        guard state.linkedAccount == nil else { return false }
        return !state.rememberedByServerID.isEmpty || currentServerMirror != nil
    }

    /// Spec §6.3: Account + Profile shows Choose an Account first when
    /// Profile Selection requires a selection at launch or on return, and
    /// the device has two or more accounts. Automatic never requires one. A
    /// pending explicit Switch Profile doesn't count: Switch Profile opens
    /// Who's Watching as it always has.
    var asksForAccount: Bool {
        guard openableAccounts.count >= 2, state.effectiveAskFor == .accountAndProfile else { return false }
        switch trigger {
        case .coldLaunch:
            return state.requiresSelectionAtLaunch(at: now)
        case .foregroundAfterAway:
            return state.requiresSelectionAfterBackground(at: now)
        case .afterRemoval, .accountPicked:
            return false
        }
    }

    /// Spec §6.2 step 2: an expired sign-in shows its sign-in screen. A
    /// pending legacy account opens its old per-server sign-in.
    func credentialDecision(_ account: SiloAccountRef) -> SiloLaunchDecision {
        let linkAccount = state.linkedAccountRef.flatMap(directory.index.resolve) != account
        if case .signIn(let key) = account, !directory.isSignedIn(account) {
            return .signInAgain(key)
        }
        return .open(account, linkAccount: linkAccount)
    }
}

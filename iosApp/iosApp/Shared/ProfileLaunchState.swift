import Foundation

struct ProfileLaunchState: Codable, Equatable, Sendable {
    var behavior: ProfileLaunchBehavior = .automatic
    var rememberedByServerID: [String: RememberedProfile] = [:]
    var selectionRequiredServerIDs: Set<String> = []
    /// The start of the current interval away from Silo. Persisting this in
    /// the current device-user domain makes timed policies independent of
    /// whether the process survives in the background.
    var backgroundedAt: Date? = nil
    /// Set on a fresh Apple TV: the first profile picked there is offered as
    /// the one to open automatically. Optional so state saved by earlier
    /// builds still decodes; nil means no offer is due.
    var rememberOfferPending: Bool? = nil

    // Fields for Silo users. Every one is optional so state saved by earlier
    // builds still decodes; a required field would reset Profile Selection.
    // `rememberedByServerID` and `selectionRequiredServerIDs` stay for a
    // server's own session (before migration, or a pending legacy server),
    // and saved sign-ins read them as the fallback for state recorded
    // before sign-ins existed.

    /// Nil means `.profileOnly`.
    var askFor: ProfileLaunchAskFor? = nil
    /// The Silo user this Apple TV user (or this device) opens.
    var linkedUserID: String? = nil
    /// User ID to the server it last opened.
    var lastServerByUserID: [String: String]? = nil
    /// Keyed by `SignInKey.storageKey`.
    var rememberedBySignIn: [String: RememberedProfile]? = nil
    /// `SignInKey.storageKey` of each sign-in with an explicit Switch Profile
    /// pending.
    var selectionRequiredSignIns: Set<String>? = nil

    /// The state of a device with nothing saved yet. A TV asks who's watching
    /// until someone chooses to remember a profile; phones, tablets and Macs
    /// reopen the last profile.
    static func fresh(isTV: Bool) -> ProfileLaunchState {
        guard isTV else { return ProfileLaunchState() }
        return ProfileLaunchState(behavior: .askEveryLaunch, rememberOfferPending: true)
    }

    static var freshForCurrentDevice: ProfileLaunchState {
        #if os(tvOS)
        return fresh(isTV: true)
        #else
        return fresh(isTV: false)
        #endif
    }

    func resolution(
        for serverID: String,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        knownProfileIDs: Set<String>? = nil,
        now: Date = .now
    ) -> ProfileLaunchResolution {
        resolution(
            remembered: rememberedByServerID[serverID],
            selectionRequired: selectionRequiredServerIDs.contains(serverID),
            accountEpoch: accountEpoch,
            hasStoredProfileToken: hasStoredProfileToken,
            knownProfileIDs: knownProfileIDs,
            now: now
        )
    }

    /// The same rule as the server-keyed resolution, for a saved sign-in.
    /// `legacyOwnerAccountID` is the account that owns the sign-in's server's
    /// state from before sign-ins existed.
    func resolution(
        for key: SignInKey,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        knownProfileIDs: Set<String>? = nil,
        legacyOwnerAccountID: String?,
        now: Date = .now
    ) -> ProfileLaunchResolution {
        resolution(
            remembered: rememberedProfile(for: key, accountEpoch: accountEpoch),
            selectionRequired: isSelectionRequired(for: key, legacyOwnerAccountID: legacyOwnerAccountID),
            accountEpoch: accountEpoch,
            hasStoredProfileToken: hasStoredProfileToken,
            knownProfileIDs: knownProfileIDs,
            now: now
        )
    }

    /// The profile remembered for this sign-in. An entry recorded per server
    /// before sign-ins existed counts only when its epoch is the sign-in's:
    /// epochs are unique per sign-in and migration keeps them, so a match
    /// proves the entry was recorded for this sign-in.
    func rememberedProfile(for key: SignInKey, accountEpoch: String?) -> RememberedProfile? {
        if let remembered = rememberedBySignIn?[key.storageKey] {
            return remembered
        }
        guard let accountEpoch,
              let legacy = rememberedByServerID[key.serverID],
              legacy.accountEpoch == accountEpoch else {
            return nil
        }
        return legacy
    }

    /// A pending Switch Profile recorded per server before sign-ins existed
    /// applies only to the server's legacy owner.
    func isSelectionRequired(for key: SignInKey, legacyOwnerAccountID: String?) -> Bool {
        if selectionRequiredSignIns?.contains(key.storageKey) == true {
            return true
        }
        return legacyOwnerAccountID == key.accountID
            && selectionRequiredServerIDs.contains(key.serverID)
    }

    func lastServer(for userID: String) -> String? {
        lastServerByUserID?[userID]
    }

    var effectiveAskFor: ProfileLaunchAskFor {
        askFor ?? .profileOnly
    }

    /// Cold starts preserve the original Every Time contract even when the
    /// previous process never recorded a background transition. Timed modes
    /// only expire when a persisted away interval has actually elapsed.
    func requiresSelectionAtLaunch(at now: Date = .now) -> Bool {
        if behavior == .askEveryLaunch { return true }
        return hasExpiredAwayInterval(at: now)
    }

    /// Warm foreground returns require an actual background marker, avoiding
    /// false locks for inactive-only interruptions such as system prompts.
    func requiresSelectionAfterBackground(at now: Date = .now) -> Bool {
        guard backgroundedAt != nil else { return false }
        if behavior == .askEveryLaunch { return true }
        return hasExpiredAwayInterval(at: now)
    }

    static func load(from defaults: SharedDefaults) -> ProfileLaunchState {
        guard let data = defaults.data(forKey: SharedStorage.profileLaunchStateKey),
              let decoded = try? JSONDecoder().decode(ProfileLaunchState.self, from: data) else {
            return freshForCurrentDevice
        }
        return decoded
    }

    private func resolution(
        remembered: RememberedProfile?,
        selectionRequired: Bool,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        knownProfileIDs: Set<String>?,
        now: Date
    ) -> ProfileLaunchResolution {
        guard !requiresSelectionAtLaunch(at: now),
              !selectionRequired,
              let remembered,
              let accountEpoch,
              remembered.accountEpoch == accountEpoch,
              !remembered.profileID.isEmpty,
              knownProfileIDs?.contains(remembered.profileID) != false,
              !remembered.requiredPINAtSelection || hasStoredProfileToken else {
            return .needsSelection
        }
        return .restore(remembered)
    }

    private func hasExpiredAwayInterval(at now: Date) -> Bool {
        guard let backgroundedAt,
              let timeout = behavior.awayTimeout else {
            return false
        }
        return now.timeIntervalSince(backgroundedAt) >= timeout
    }
}

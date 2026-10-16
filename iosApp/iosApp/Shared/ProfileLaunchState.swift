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
    /// TV history belongs to the current Apple TV user, with a distinct entry
    /// for each authenticated account epoch. The server map remains the active
    /// projection for existing UI callers. Optional fields decode older state.
    var rememberedByAccountEpoch: [String: RememberedProfile]? = nil
    var selectionRequiredByAccountEpoch: Set<String>? = nil
    var activeAccountEpochByServerID: [String: String]? = nil

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
        guard !requiresSelectionAtLaunch(at: now),
              !requiresSelection(for: serverID, accountEpoch: accountEpoch),
              let remembered = rememberedProfile(for: serverID, accountEpoch: accountEpoch),
              let accountEpoch,
              remembered.accountEpoch == accountEpoch,
              !remembered.profileID.isEmpty,
              knownProfileIDs?.contains(remembered.profileID) != false,
              !remembered.requiredPINAtSelection || hasStoredProfileToken else {
            return .needsSelection
        }
        return .restore(remembered)
    }

    func rememberedProfile(for serverID: String, accountEpoch: String?) -> RememberedProfile? {
        guard let accountEpoch else { return nil }
        if let remembered = rememberedByAccountEpoch?[Self.accountHistoryKey(serverID, accountEpoch)] {
            return remembered.accountEpoch == accountEpoch ? remembered : nil
        }
        guard let remembered = rememberedByServerID[serverID], remembered.accountEpoch == accountEpoch else {
            return nil
        }
        return remembered
    }

    static func accountHistoryPrefix(_ serverID: String) -> String {
        "\(serverID.utf8.count):\(serverID)"
    }

    static func accountHistoryKey(_ serverID: String, _ accountEpoch: String) -> String {
        accountHistoryPrefix(serverID) + "\(accountEpoch.utf8.count):\(accountEpoch)"
    }

    /// Capture the outgoing legacy projection before replacing it. A different
    /// account never receives its profile or its pending selection requirement.
    mutating func activateAccountHistory(for serverID: String, accountEpoch: String?) {
        var history = rememberedByAccountEpoch ?? [:]
        var pending = selectionRequiredByAccountEpoch ?? []
        var active = activeAccountEpochByServerID ?? [:]
        let projected = rememberedByServerID[serverID]
        let previousEpoch = active[serverID] ?? projected?.accountEpoch
        if let projected {
            history[Self.accountHistoryKey(serverID, projected.accountEpoch)] = projected
        }
        if let previousEpoch {
            let previousKey = Self.accountHistoryKey(serverID, previousEpoch)
            if selectionRequiredServerIDs.contains(serverID) { pending.insert(previousKey) }
            else { pending.remove(previousKey) }
        }
        if let accountEpoch {
            let key = Self.accountHistoryKey(serverID, accountEpoch)
            rememberedByServerID[serverID] = history[key]
            active[serverID] = accountEpoch
            if pending.contains(key) { selectionRequiredServerIDs.insert(serverID) }
            else { selectionRequiredServerIDs.remove(serverID) }
        } else {
            rememberedByServerID[serverID] = nil
            active[serverID] = nil
            selectionRequiredServerIDs.remove(serverID)
        }
        rememberedByAccountEpoch = history
        selectionRequiredByAccountEpoch = pending
        activeAccountEpochByServerID = active
        if previousEpoch != accountEpoch { backgroundedAt = nil }
    }

    private func requiresSelection(for serverID: String, accountEpoch: String?) -> Bool {
        guard let pending = selectionRequiredByAccountEpoch, let accountEpoch else {
            return selectionRequiredServerIDs.contains(serverID)
        }
        if pending.contains(Self.accountHistoryKey(serverID, accountEpoch)) { return true }
        let projectedEpoch = activeAccountEpochByServerID?[serverID] ?? rememberedByServerID[serverID]?.accountEpoch
        return projectedEpoch == accountEpoch && selectionRequiredServerIDs.contains(serverID)
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

    private func hasExpiredAwayInterval(at now: Date) -> Bool {
        guard let backgroundedAt,
              let timeout = behavior.awayTimeout else {
            return false
        }
        return now.timeIntervalSince(backgroundedAt) >= timeout
    }
}

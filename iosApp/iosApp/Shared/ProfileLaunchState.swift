import Foundation

struct ProfileLaunchState: Codable, Equatable, Sendable {
    var behavior: ProfileLaunchBehavior = .automatic
    /// The profile each account opens with, keyed by `Account.localAccountId`.
    var rememberedByAccountID: [String: RememberedProfile] = [:]
    var selectionRequiredAccountIDs: Set<String> = []
    /// Per-server memory from builds before accounts. Read only so
    /// `ProfileLaunchPreferences.adoptLegacyServerMemory` can move it onto
    /// the account that adopted each server's data; still written (empty
    /// once adopted) so an older build can decode this state.
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

    init(
        behavior: ProfileLaunchBehavior = .automatic,
        rememberedByAccountID: [String: RememberedProfile] = [:],
        selectionRequiredAccountIDs: Set<String> = [],
        backgroundedAt: Date? = nil,
        rememberOfferPending: Bool? = nil
    ) {
        self.behavior = behavior
        self.rememberedByAccountID = rememberedByAccountID
        self.selectionRequiredAccountIDs = selectionRequiredAccountIDs
        self.backgroundedAt = backgroundedAt
        self.rememberOfferPending = rememberOfferPending
    }

    private enum CodingKeys: String, CodingKey {
        case behavior, rememberedByAccountID, selectionRequiredAccountIDs
        case rememberedByServerID, selectionRequiredServerIDs, backgroundedAt, rememberOfferPending
    }

    /// Every field but the behavior is optional, so state saved by any
    /// earlier build decodes.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        behavior = try container.decode(ProfileLaunchBehavior.self, forKey: .behavior)
        rememberedByAccountID = try container.decodeIfPresent(
            [String: RememberedProfile].self, forKey: .rememberedByAccountID) ?? [:]
        selectionRequiredAccountIDs = try container.decodeIfPresent(
            Set<String>.self, forKey: .selectionRequiredAccountIDs) ?? []
        rememberedByServerID = try container.decodeIfPresent(
            [String: RememberedProfile].self, forKey: .rememberedByServerID) ?? [:]
        selectionRequiredServerIDs = try container.decodeIfPresent(
            Set<String>.self, forKey: .selectionRequiredServerIDs) ?? []
        backgroundedAt = try container.decodeIfPresent(Date.self, forKey: .backgroundedAt)
        rememberOfferPending = try container.decodeIfPresent(Bool.self, forKey: .rememberOfferPending)
    }

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
        forAccount localAccountID: String,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        knownProfileIDs: Set<String>? = nil,
        now: Date = .now
    ) -> ProfileLaunchResolution {
        guard !requiresSelectionAtLaunch(at: now),
              !selectionRequiredAccountIDs.contains(localAccountID),
              let remembered = rememberedByAccountID[localAccountID],
              let accountEpoch,
              remembered.accountEpoch == accountEpoch,
              !remembered.profileID.isEmpty,
              knownProfileIDs?.contains(remembered.profileID) != false,
              !remembered.requiredPINAtSelection || hasStoredProfileToken else {
            return .needsSelection
        }
        return .restore(remembered)
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

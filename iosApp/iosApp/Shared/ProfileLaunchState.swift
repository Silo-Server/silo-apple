import Foundation

struct ProfileLaunchState: Codable, Equatable, Sendable {
    var behavior: ProfileLaunchBehavior = .automatic
    var rememberedByServerID: [String: RememberedProfile] = [:]
    var selectionRequiredServerIDs: Set<String> = []
    /// The start of the current interval away from Silo. Persisting this in
    /// the current device-user domain makes timed policies independent of
    /// whether the process survives in the background.
    var backgroundedAt: Date? = nil

    func resolution(
        for serverID: String,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        knownProfileIDs: Set<String>? = nil,
        now: Date = .now
    ) -> ProfileLaunchResolution {
        guard !requiresSelectionAtLaunch(at: now),
              !selectionRequiredServerIDs.contains(serverID),
              let remembered = rememberedByServerID[serverID],
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
            return ProfileLaunchState()
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

import Foundation
import OSLog

@Observable
final class ProfileLaunchPreferences {
    static let shared = ProfileLaunchPreferences()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "ProfileLaunchPreferences"
    )

    private let defaults: SharedDefaults
    private(set) var state: ProfileLaunchState

    init(defaults: SharedDefaults = .shared) {
        self.defaults = defaults
        self.state = ProfileLaunchState.load(from: defaults)
        _ = persist()
    }

    var behavior: ProfileLaunchBehavior {
        get { state.behavior }
        set {
            guard state.behavior != newValue else { return }
            state.behavior = newValue
            _ = persist()
        }
    }

    var behaviorID: String {
        get { behavior.rawValue }
        set {
            guard let behavior = ProfileLaunchBehavior(rawValue: newValue) else { return }
            self.behavior = behavior
        }
    }

    func rememberedProfile(for serverID: String?) -> RememberedProfile? {
        guard let serverID else { return nil }
        return state.rememberedByServerID[serverID]
    }

    func resolution(
        for serverID: String,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        knownProfileIDs: Set<String>? = nil
    ) -> ProfileLaunchResolution {
        state.resolution(
            for: serverID,
            accountEpoch: accountEpoch,
            hasStoredProfileToken: hasStoredProfileToken,
            knownProfileIDs: knownProfileIDs
        )
    }

    @discardableResult
    func remember(
        profileID: String,
        requiresPIN: Bool,
        accountEpoch: String,
        for serverID: String
    ) -> Bool {
        let previousState = state
        state.rememberedByServerID[serverID] = RememberedProfile(
            profileID: profileID,
            requiredPINAtSelection: requiresPIN,
            accountEpoch: accountEpoch
        )
        state.selectionRequiredServerIDs.remove(serverID)
        guard persist() else {
            state = previousState
            return false
        }
        return true
    }

    @discardableResult
    func markSelectionRequired(for serverID: String) -> Bool {
        guard !state.selectionRequiredServerIDs.contains(serverID) else { return true }
        let previousState = state
        state.selectionRequiredServerIDs.insert(serverID)
        guard persist() else {
            state = previousState
            return false
        }
        return true
    }

    func clearSelectionRequired(for serverID: String) {
        guard state.selectionRequiredServerIDs.remove(serverID) != nil else { return }
        _ = persist()
    }

    @discardableResult
    func clearRememberedProfile(for serverID: String) -> Bool {
        let previousState = state
        let removedProfile = state.rememberedByServerID.removeValue(forKey: serverID) != nil
        let removedPending = state.selectionRequiredServerIDs.remove(serverID) != nil
        guard removedProfile || removedPending else { return true }
        guard persist() else {
            state = previousState
            return false
        }
        return true
    }

    @discardableResult
    func migrateLegacyProfile(
        profileID: String?,
        requiresPIN: Bool,
        accountEpoch: String?,
        for serverID: String
    ) -> Bool {
        if let existing = state.rememberedByServerID[serverID] {
            return existing.profileID == profileID && existing.accountEpoch == accountEpoch
        }
        guard state.rememberedByServerID[serverID] == nil,
              let profileID,
              !profileID.isEmpty,
              let accountEpoch,
              !accountEpoch.isEmpty else {
            return false
        }
        return remember(
            profileID: profileID,
            requiresPIN: requiresPIN,
            accountEpoch: accountEpoch,
            for: serverID
        )
    }

    private func persist() -> Bool {
        do {
            let data = try JSONEncoder().encode(state)
            defaults.set(data, forKey: SharedStorage.profileLaunchStateKey)
            return defaults.data(forKey: SharedStorage.profileLaunchStateKey) == data
        } catch {
            Self.logger.error("Profile launch state encode failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

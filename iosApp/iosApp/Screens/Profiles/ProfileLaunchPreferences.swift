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
        persist()
    }

    var behavior: ProfileLaunchBehavior {
        get { state.behavior }
        set {
            guard state.behavior != newValue else { return }
            state.behavior = newValue
            persist()
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

    func remember(
        profileID: String,
        requiresPIN: Bool,
        accountEpoch: String,
        for serverID: String
    ) {
        state.rememberedByServerID[serverID] = RememberedProfile(
            profileID: profileID,
            requiredPINAtSelection: requiresPIN,
            accountEpoch: accountEpoch
        )
        state.selectionRequiredServerIDs.remove(serverID)
        persist()
    }

    func markSelectionRequired(for serverID: String) {
        state.selectionRequiredServerIDs.insert(serverID)
        persist()
    }

    func clearSelectionRequired(for serverID: String) {
        guard state.selectionRequiredServerIDs.remove(serverID) != nil else { return }
        persist()
    }

    func clearRememberedProfile(for serverID: String) {
        let removedProfile = state.rememberedByServerID.removeValue(forKey: serverID) != nil
        let removedPending = state.selectionRequiredServerIDs.remove(serverID) != nil
        guard removedProfile || removedPending else { return }
        persist()
    }

    func migrateLegacyProfile(
        profileID: String?,
        requiresPIN: Bool,
        accountEpoch: String?,
        for serverID: String
    ) {
        guard state.rememberedByServerID[serverID] == nil,
              let profileID,
              !profileID.isEmpty,
              let accountEpoch,
              !accountEpoch.isEmpty else {
            return
        }
        remember(
            profileID: profileID,
            requiresPIN: requiresPIN,
            accountEpoch: accountEpoch,
            for: serverID
        )
    }

    private func persist() {
        do {
            defaults.set(
                try JSONEncoder().encode(state),
                forKey: SharedStorage.profileLaunchStateKey
            )
        } catch {
            Self.logger.error("Profile launch state encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

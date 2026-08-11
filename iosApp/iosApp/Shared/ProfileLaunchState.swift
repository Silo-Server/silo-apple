import Foundation

struct ProfileLaunchState: Codable, Equatable, Sendable {
    var behavior: ProfileLaunchBehavior = .automatic
    var rememberedByServerID: [String: RememberedProfile] = [:]
    var selectionRequiredServerIDs: Set<String> = []

    func resolution(
        for serverID: String,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        knownProfileIDs: Set<String>? = nil
    ) -> ProfileLaunchResolution {
        guard behavior == .automatic,
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

    static func load(from defaults: SharedDefaults) -> ProfileLaunchState {
        guard let data = defaults.data(forKey: SharedStorage.profileLaunchStateKey),
              let decoded = try? JSONDecoder().decode(ProfileLaunchState.self, from: data) else {
            return ProfileLaunchState()
        }
        return decoded
    }
}

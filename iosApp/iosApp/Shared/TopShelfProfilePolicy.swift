import Foundation

enum TopShelfProfilePolicy {
    static func allowsPersonalizedContent(
        state: ProfileLaunchState,
        serverID: String?,
        activeProfileID: String?,
        accountEpoch: String?,
        hasStoredProfileToken: Bool
    ) -> Bool {
        guard let serverID,
              let activeProfileID,
              let remembered = state.rememberedByServerID[serverID],
              state.behavior == .automatic,
              !state.selectionRequiredServerIDs.contains(serverID),
              remembered.profileID == activeProfileID,
              remembered.accountEpoch == accountEpoch,
              !remembered.requiredPINAtSelection || hasStoredProfileToken else {
            return false
        }
        return true
    }
}

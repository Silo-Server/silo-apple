import Foundation

enum TopShelfProfilePolicy {
    static func allowsPersonalizedContent(
        state: ProfileLaunchState,
        serverID: String?,
        activeProfileID: String?,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        now: Date = .now
    ) -> Bool {
        guard let serverID,
              let activeProfileID,
              let remembered = state.rememberedByServerID[serverID],
              state.behavior != .askEveryLaunch,
              !state.requiresSelectionAfterBackground(at: now),
              !state.selectionRequiredServerIDs.contains(serverID),
              remembered.profileID == activeProfileID,
              remembered.accountEpoch == accountEpoch,
              !remembered.requiredPINAtSelection || hasStoredProfileToken else {
            return false
        }
        return true
    }
}

import Foundation

enum TopShelfProfilePolicy {
    static func allowsPersonalizedContent(
        state: ProfileLaunchState,
        localAccountID: String?,
        activeProfileID: String?,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        now: Date = .now
    ) -> Bool {
        guard let localAccountID,
              let activeProfileID,
              let remembered = state.rememberedByAccountID[localAccountID],
              state.behavior != .askEveryLaunch,
              !state.requiresSelectionAfterBackground(at: now),
              !state.selectionRequiredAccountIDs.contains(localAccountID),
              remembered.profileID == activeProfileID,
              remembered.accountEpoch == accountEpoch,
              !remembered.requiredPINAtSelection || hasStoredProfileToken else {
            return false
        }
        return true
    }
}

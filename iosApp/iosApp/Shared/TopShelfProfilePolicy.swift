import Foundation

enum TopShelfProfilePolicy {
    /// A server's own session, before sign-ins existed or for a pending
    /// legacy server.
    static func allowsPersonalizedContent(
        state: ProfileLaunchState,
        serverID: String?,
        activeProfileID: String?,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        now: Date = .now
    ) -> Bool {
        guard let serverID else { return false }
        return allowsPersonalizedContent(
            state: state,
            remembered: state.rememberedByServerID[serverID],
            selectionRequired: state.selectionRequiredServerIDs.contains(serverID),
            activeProfileID: activeProfileID,
            accountEpoch: accountEpoch,
            hasStoredProfileToken: hasStoredProfileToken,
            now: now
        )
    }

    /// A saved sign-in. The remembered profile and pending selection are the
    /// sign-in's own, or the server's from before sign-ins existed when they
    /// were recorded for this sign-in (`ProfileLaunchState`'s epoch and
    /// legacy-owner rules).
    static func allowsPersonalizedContent(
        state: ProfileLaunchState,
        key: SignInKey,
        legacyOwnerAccountID: String?,
        activeProfileID: String?,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        now: Date = .now
    ) -> Bool {
        allowsPersonalizedContent(
            state: state,
            remembered: state.rememberedProfile(for: key, accountEpoch: accountEpoch),
            selectionRequired: state.isSelectionRequired(for: key, legacyOwnerAccountID: legacyOwnerAccountID),
            activeProfileID: activeProfileID,
            accountEpoch: accountEpoch,
            hasStoredProfileToken: hasStoredProfileToken,
            now: now
        )
    }

    private static func allowsPersonalizedContent(
        state: ProfileLaunchState,
        remembered: RememberedProfile?,
        selectionRequired: Bool,
        activeProfileID: String?,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        now: Date
    ) -> Bool {
        guard let activeProfileID,
              let remembered,
              state.behavior != .askEveryLaunch,
              !state.requiresSelectionAfterBackground(at: now),
              !selectionRequired,
              remembered.profileID == activeProfileID,
              remembered.accountEpoch == accountEpoch,
              !remembered.requiredPINAtSelection || hasStoredProfileToken else {
            return false
        }
        return true
    }
}

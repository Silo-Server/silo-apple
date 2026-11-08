import Foundation

/// Pure rules for the download capability check: which scope the store loads
/// and when to read the capability again. `DownloadManager` owns the state;
/// these stay free of it so tests can pin them down.
extension DownloadManager {
    /// The account requests run as (`TokenStore.captureOrdinaryRequestAuth`).
    /// `localAccountId` is nil without a signed-in session, and under a
    /// temporary remote scope.
    struct SignedInIdentity: Equatable {
        let serverId: String
        let localAccountId: String?
        let profileId: String?
    }

    /// The `(server, account, profile)` whose store to load. Empty fields
    /// mean no scope.
    struct ScopeChoice: Equatable {
        let serverId: String
        let localAccountId: String
        let profileId: String
        /// The selection mirror was missing or named another account than
        /// the session. Logged: it is the state that used to leave
        /// Download hidden until a relaunch.
        let selectionDisagreed: Bool
    }

    /// The signed-in account wins, because `captureScopeOwner` only lets a
    /// store read the server under that same identity. A store loaded for
    /// the mirror's account while requests ran as another could never read
    /// its capability. Without a session, the mirror keeps the selected
    /// account's downloads playable offline.
    nonisolated static func downloadScope(
        activeServerId: String,
        signedIn: SignedInIdentity?,
        selection: AccountScope?
    ) -> ScopeChoice {
        if !activeServerId.isEmpty, let signedIn, signedIn.serverId == activeServerId,
           let account = signedIn.localAccountId, !account.isEmpty {
            return ScopeChoice(
                serverId: activeServerId,
                localAccountId: account,
                profileId: signedIn.profileId ?? "",
                selectionDisagreed: selection?.serverId != activeServerId || selection?.localAccountId != account
            )
        }
        let onServer = selection?.serverId == activeServerId ? selection : nil
        return ScopeChoice(
            serverId: activeServerId,
            localAccountId: onServer?.localAccountId ?? "",
            profileId: onServer?.profileId ?? "",
            selectionDisagreed: false
        )
    }

    /// How long a usable capability counts as fresh for a detail page.
    nonisolated static let capabilityMaxAge: TimeInterval = 5 * 60

    /// Whether to read the capability again. An unusable or missing one is
    /// always read: hiding Download is the costly mistake, and the read is
    /// one small request.
    nonisolated static func capabilityReadIsDue(usable: Bool, fetchedAt: Date?, now: Date,
                                                maxAge: TimeInterval = capabilityMaxAge) -> Bool {
        guard usable, let fetchedAt, fetchedAt <= now else { return true }
        return now.timeIntervalSince(fetchedAt) >= maxAge
    }

    /// The wait before the next read after `failures` failed in a row, or
    /// nil once the retries for this app-active pass are spent. The next
    /// foreground or detail page starts again.
    nonisolated static func capabilityRetryDelay(afterFailures failures: Int) -> Duration? {
        let delays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)]
        guard failures >= 1, failures <= delays.count else { return nil }
        return delays[failures - 1]
    }
}

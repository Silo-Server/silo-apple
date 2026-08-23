import Foundation

/// Pure decision rules for retargeting the download coordinator across
/// server/profile identity changes. Kept free of SwiftUI and the
/// `DownloadManager` singleton so the high-risk contracts are testable
/// without a background `URLSession`.
enum DownloadScopePolicy {
    /// The in-memory registry must reload whenever the signed-in server or
    /// profile changes. An empty destination is a signed-out / picker state
    /// and also requires dropping the current scope.
    static func requiresReload(
        currentServerId: String,
        currentProfileId: String,
        nextServerId: String,
        nextProfileId: String
    ) -> Bool {
        currentServerId != nextServerId || currentProfileId != nextProfileId
    }

    /// Background `URLSession` completions can arrive after the coordinator
    /// has already switched to a different `(server, profile)` scope.
    /// Deleting that staged media loses a finished download that still
    /// belongs to the previous identity. Hold it until the owning scope is
    /// loaded again.
    static func shouldDeleteUnmatchedStagedMedia() -> Bool { false }
}

#if !os(tvOS)
import Foundation

extension AppRouter {
    /// Present offline playback for a download record: the playable-offline
    /// guard plus the leaf's locally stored resume point, shared by every
    /// Downloads play affordance. `fromStart` is the explicit "Play from
    /// Beginning" variant, which ignores that resume point.
    @MainActor
    func presentOfflinePlayer(
        for record: DownloadRecord,
        manager: DownloadManager,
        fromStart: Bool = false
    ) {
        guard record.isPlayableOffline else { return }
        let leafId = record.leafMediaItemId
        presentOfflinePlayer(
            downloadId: record.id,
            contentId: leafId,
            resumePosition: fromStart
                ? 0
                : manager.localProgress(forMediaItemId: leafId)?.position
        )
    }
}
#endif

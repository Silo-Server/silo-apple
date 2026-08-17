#if os(iOS)
import Foundation
import UserNotifications

/// Posts local notifications for download lifecycle events: completion,
/// terminal failure, and monitoring-queued episodes.
///
/// Authorization is owned by `ApplePushRegistrationCoordinator` — it
/// requests permission on the first authenticated profile — so this only
/// checks the current status and stays silent when the user declined,
/// never re-prompting.
@MainActor
enum DownloadNotifier {
    /// Tapping any download notification lands on the Downloads screen via
    /// the same userInfo key the push pipeline uses, so
    /// `SiloAppDelegate.userNotificationCenter(_:didReceive:)` routes both
    /// kinds through one code path.
    private static let downloadsDeepLink = "\(SiloDeepLink.preferredScheme)://downloads"

    static func downloadCompleted(_ record: DownloadRecord) {
        post(
            id: "download-completed-\(record.id)",
            body: "\(displayName(for: record)) is ready to watch offline"
        )
    }

    static func downloadFailed(_ record: DownloadRecord) {
        post(
            id: "download-failed-\(record.id)",
            body: "Download failed: \(displayName(for: record))"
        )
    }

    /// One notification per monitoring-sync batch. When every queued
    /// episode belongs to one series the body names the show; a
    /// multi-series batch falls back to a count-only summary.
    static func newEpisodesQueued(count: Int, seriesTitles: Set<String>) {
        guard count > 0 else { return }
        let noun = count == 1 ? "episode" : "episodes"
        let verb = count == 1 ? "is" : "are"
        let body: String
        if seriesTitles.count == 1, let title = seriesTitles.first {
            body = "\(count) new \(noun) of \(title) \(verb) downloading"
        } else {
            body = "\(count) new \(noun) \(verb) downloading"
        }
        post(id: "downloads-monitoring-\(UUID().uuidString)", body: body)
    }

    /// "Exodus (S2E8)" for episodes, plain title for movies. The series
    /// title is preferred for episodes because the S/E marker already
    /// disambiguates which entry finished.
    private static func displayName(for record: DownloadRecord) -> String {
        let base = record.seriesTitle ?? record.title ?? "Download"
        if let season = record.seasonNumber, let episode = record.episodeNumber {
            return "\(base) (S\(season)E\(episode))"
        }
        return base
    }

    /// No title: banners then lead with the app name, keeping the copy a
    /// single sentence. Foreground presentation is intentionally not
    /// suppressed — the app-wide delegate already presents banners for
    /// every notification while active.
    private static func post(id: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            default:
                return
            }
            let content = UNMutableNotificationContent()
            content.body = body
            content.sound = .default
            content.userInfo = [ApplePushDisplayWire.urlUserInfoKey: downloadsDeepLink]
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
#endif

// os(iOS) rather than canImport: the macOS SDK ships ActivityKit but marks
// its API unavailable, so the import alone doesn't gate compilation.
#if os(iOS)
import ActivityKit
import Foundation

/// Content schema for the downloads Live Activity, shared between the app
/// (which starts/updates the activity) and the SiloDownloadsActivity widget
/// extension (which renders it on the lock screen and in the Dynamic
/// Island). One activity summarizes the whole active queue rather than one
/// per item — iOS caps concurrent Live Activities per app, and a queue
/// summary reads better than N competing cards.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            /// At least one transfer (or asset fetch) is running.
            case downloading
            /// Every active record is user-paused.
            case paused
            /// Registered/preparing/queued only — nothing moving yet.
            case preparing
            /// Terminal state used for the linger-after-finish content.
            case completed
        }

        var phase: Phase
        /// Headline: the transferring item's title, or a queue summary.
        var title: String
        /// Secondary line, e.g. "Severance · S1 · E4".
        var subtitle: String?
        /// Item-weighted overall progress across the queue (0…1); completed
        /// items count as 1 so the bar never moves backwards when a new
        /// episode joins mid-queue.
        var fraction: Double
        /// Aggregate transfer bytes across active records with known sizes.
        var bytesDownloaded: Int64
        var bytesExpected: Int64
        /// "2 of 5" numbers: items finished since the activity started and
        /// the total it is tracking.
        var completedCount: Int
        var totalCount: Int
        /// Smoothed aggregate rate; nil when nothing is transferring.
        var bytesPerSecond: Double?
    }
}
#endif

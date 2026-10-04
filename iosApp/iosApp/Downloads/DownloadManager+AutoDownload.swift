#if !os(tvOS)
import Foundation

/// The per-series reads behind the auto-download screens.
extension DownloadManager {
    /// The series' downloads still on their way to this device. A paused
    /// download is the user's choice, not something the series is waiting on.
    func autoDownloadActivity(forSeriesId seriesId: String) -> [AutoDownloadActivity] {
        file.records.values
            .filter { Self.seriesKey(for: $0) == seriesId && $0.localStatus.isActive && $0.localStatus != .paused }
            .map { record in
                AutoDownloadActivity(
                    seasonNumber: record.seasonNumber,
                    episodeNumber: record.episodeNumber,
                    phase: autoDownloadPhase(for: record)
                )
            }
    }

    /// Episodes of the series this device already holds a download for, in
    /// any state, so "what's next" never names one of them.
    /// Episodes of the series this device has or is getting. A failed
    /// download doesn't count, so its episode can still be named as next.
    func knownEpisodeIds(forSeriesId seriesId: String) -> Set<String> {
        Set(file.records.values
            .filter { Self.seriesKey(for: $0) == seriesId && $0.localStatus != .failed }
            .compactMap(\.episodeId))
    }

    func autoDownloadStatus(
        for subscription: DownloadSubscription,
        upcoming: [UpcomingEpisode],
        scheduleKnown: Bool = true
    ) -> AutoDownloadStatus {
        AutoDownloadRules.status(
            for: subscription,
            activity: autoDownloadActivity(forSeriesId: subscription.seriesId),
            upcoming: upcoming,
            knownEpisodeIds: knownEpisodeIds(forSeriesId: subscription.seriesId),
            scheduleKnown: scheduleKnown
        )
    }

    private func autoDownloadPhase(for record: DownloadRecord) -> AutoDownloadActivity.Phase {
        switch wait(for: record) {
        case .storageLimit: return .storageLimit
        case .wifi: return .waitingForWiFi
        case .connection: return .waitingForConnection
        case nil: break
        }
        switch record.localStatus {
        case .downloading, .fetchingAssets: return .downloading(fraction: record.progressFraction)
        case .registering, .preparing: return .preparing
        default: return .queued
        }
    }
}
#endif

#if !os(tvOS)
import Foundation
import Observation
import OSLog

/// What the auto-download screens need beyond the download store: the
/// episodes that air in the next month, from the airing calendar
/// (`GET /api/v2/calendar`), and each monitored series' title and poster.
/// Held per server profile and dropped when the profile changes.
@Observable
@MainActor
final class AutoDownloadSchedule {
    static let shared = AutoDownloadSchedule()

    struct SeriesInfo: Hashable {
        let title: String
        let posterUrl: String?
        let posterThumbhash: String?
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Downloads"
    )
    /// The calendar answers at most 31 days at once.
    private static let windowDays = 30
    private static let refreshInterval: TimeInterval = 15 * 60

    private(set) var upcomingBySeries: [String: [UpcomingEpisode]] = [:]
    private(set) var seriesInfo: [String: SeriesInfo] = [:]

    private var scopeKey = ""
    private var loadedAt: Date?
    private var loading: Task<Void, Never>?

    private var manager: DownloadManager { DownloadManager.shared }

    func upcoming(forSeriesId seriesId: String) -> [UpcomingEpisode] {
        upcomingBySeries[seriesId] ?? []
    }

    /// The status an auto-download row or banner shows for `subscription`.
    func status(for subscription: DownloadSubscription) -> AutoDownloadStatus {
        manager.autoDownloadStatus(for: subscription, upcoming: upcoming(forSeriesId: subscription.seriesId))
    }

    /// Reloads the calendar when it is older than the refresh interval, or
    /// always with `force`. Skipped offline, and when nothing is monitored
    /// unless `evenWithoutMonitors` (a series about to be monitored).
    /// Concurrent callers share one load.
    func refresh(force: Bool = false, evenWithoutMonitors: Bool = false) async {
        resetIfScopeChanged()
        guard ConnectionMonitor.shared.isDeviceOnline,
              evenWithoutMonitors || !manager.subscriptions.isEmpty else { return }
        if let loading {
            await loading.value
            return
        }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.refreshInterval {
            await loadMissingSeriesInfo()
            return
        }
        let task = Task { await self.load() }
        loading = task
        await task.value
        loading = nil
    }

    /// Call after a monitor is created, edited or stopped so a new series
    /// gets its title and poster.
    func subscriptionsChanged() {
        Task { await loadMissingSeriesInfo() }
    }

    // MARK: - Loading

    private var currentScopeKey: String {
        "\(manager.scopeServerId)|\(manager.scopeProfileId)"
    }

    private func resetIfScopeChanged() {
        let key = currentScopeKey
        guard key != scopeKey else { return }
        scopeKey = key
        upcomingBySeries = [:]
        seriesInfo = [:]
        loadedAt = nil
    }

    private func load() async {
        let key = currentScopeKey
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: Self.windowDays, to: today) else { return }
        do {
            let response = try await SiloAPI.shared.calendarEvents(
                start: Self.dayString(today, calendar: calendar),
                end: Self.dayString(end, calendar: calendar),
                filter: CalendarFilter.everything.rawValue,
                timezone: calendar.timeZone.identifier
            )
            guard key == currentScopeKey else { return }
            upcomingBySeries = Self.upcoming(from: response, now: Date(), calendar: calendar)
            loadedAt = Date()
        } catch {
            Self.logger.warning("auto-download calendar read failed: \(String(describing: error), privacy: .public)")
        }
        await loadMissingSeriesInfo()
    }

    private func loadMissingSeriesInfo() async {
        let key = currentScopeKey
        let missing = manager.subscriptions.map(\.seriesId).filter { seriesInfo[$0] == nil }
        for seriesId in Set(missing) {
            guard let detail = try? await SiloAPI.shared.itemDetail(contentId: seriesId),
                  key == currentScopeKey else { continue }
            seriesInfo[seriesId] = SeriesInfo(
                title: detail.title,
                posterUrl: detail.posterUrl,
                posterThumbhash: detail.posterThumbhash
            )
        }
    }

    // MARK: - Calendar parsing

    /// Episode airings still to come, by series. An airing with an exact
    /// time counts until that time; one dated only by day counts from the
    /// next day on, since the calendar can't say whether today's has aired.
    /// An aired episode in the library is the monitor sync's to register,
    /// not "next". A season premiere placeholder stands for its first
    /// episode.
    nonisolated static func upcoming(
        from response: CalendarResponse,
        now: Date,
        calendar: Calendar
    ) -> [String: [UpcomingEpisode]] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let dates = AirDateParser(calendar: calendar)
        var bySeries: [String: [UpcomingEpisode]] = [:]
        for day in response.events {
            for event in day.items where event.type == "episode" || event.type == "season_premiere" {
                guard let seriesId = event.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !seriesId.isEmpty,
                      let seasonNumber = event.seasonNumber,
                      let episodeNumber = event.episodeNumber ?? (event.type == "season_premiere" ? 1 : nil),
                      let airDate = dates.airDate(of: event),
                      airDate >= (dates.exactAirTime(of: event) == nil ? tomorrow : now) else { continue }
                bySeries[seriesId, default: []].append(UpcomingEpisode(
                    contentId: event.contentId,
                    seriesId: seriesId,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber,
                    title: event.episodeTitle,
                    airDate: airDate
                ))
            }
        }
        return bySeries
    }

    /// Reads calendar air dates with formatters built once per parse.
    private struct AirDateParser {
        let day: DateFormatter
        let exact = ISO8601DateFormatter()
        let exactFractional: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        init(calendar: Calendar) {
            day = AutoDownloadSchedule.dayFormatter(calendar: calendar)
        }

        /// The exact airing when the server knows it, else the viewer-local day.
        func airDate(of event: CalendarEvent) -> Date? {
            if let exactTime = exactAirTime(of: event) { return exactTime }
            guard let date = event.localAirDate ?? event.airDate else { return nil }
            return day.date(from: date)
        }

        func exactAirTime(of event: CalendarEvent) -> Date? {
            guard let airAt = event.airAt else { return nil }
            return exact.date(from: airAt) ?? exactFractional.date(from: airAt)
        }
    }

    nonisolated private static func dayString(_ date: Date, calendar: Calendar) -> String {
        dayFormatter(calendar: calendar).string(from: date)
    }

    nonisolated fileprivate static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
#endif

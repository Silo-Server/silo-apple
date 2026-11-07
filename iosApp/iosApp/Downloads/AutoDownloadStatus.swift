#if !os(tvOS)
import Foundation

/// An episode of a series that airs soon, read from the airing calendar.
struct UpcomingEpisode: Hashable, Sendable {
    let contentId: String
    let seriesId: String
    let seasonNumber: Int
    let episodeNumber: Int
    let title: String?
    let airDate: Date
}

/// One of a series' downloads that is still on its way to this device.
struct AutoDownloadActivity: Hashable, Sendable {
    enum Phase: Hashable, Sendable {
        case downloading(fraction: Double)
        case preparing
        case queued
        case waitingForWiFi
        case waitingForConnection
        case storageLimit
    }

    let seasonNumber: Int?
    let episodeNumber: Int?
    let phase: Phase
}

/// What an auto-downloaded series does next, as the Downloads tab and the
/// series page describe it.
enum AutoDownloadStatus: Hashable, Sendable {
    case paused
    /// Its next episode would push the series past its storage limit.
    case storageLimit(maxBytes: Int64)
    case downloading(episodeNumber: Int?, fraction: Double)
    case waiting(episodeNumber: Int?, phase: AutoDownloadActivity.Phase)
    /// Nothing is on its way; the next in-scope episode airs on this date.
    case next(UpcomingEpisode)
    case upToDate
    /// Nothing is on its way, and the airing calendar hasn't loaded, so
    /// whether anything is due is unknown.
    case monitoring
}

/// The rules of a series monitor in the words the auto-download screens use.
/// Pure, so the copy and the "what's next" choice are testable.
enum AutoDownloadRules {
    /// Whether a monitor's rule covers an episode of `seasonNumber`. Every
    /// mode covers episodes that haven't aired yet unless it names seasons.
    static func covers(
        mode: SubscriptionMode,
        targetSeason: Int?,
        seasonNumbers: [Int]?,
        seasonNumber: Int
    ) -> Bool {
        switch mode {
        case .all, .future:
            return true
        case .latestSeason:
            return seasonNumber >= (targetSeason ?? 0)
        case .specificSeasons:
            return (seasonNumbers ?? []).contains(seasonNumber)
        }
    }

    /// The first episode the monitor covers that is still to air and isn't
    /// already on its way, by air date.
    static func nextEpisode(
        mode: SubscriptionMode,
        targetSeason: Int?,
        seasonNumbers: [Int]?,
        upcoming: [UpcomingEpisode],
        excluding knownEpisodeIds: Set<String> = [],
        now: Date = Date()
    ) -> UpcomingEpisode? {
        upcoming
            .filter {
                $0.airDate > now
                    && !knownEpisodeIds.contains($0.contentId)
                    && covers(mode: mode, targetSeason: targetSeason, seasonNumbers: seasonNumbers, seasonNumber: $0.seasonNumber)
            }
            .min { lhs, rhs in
                if lhs.airDate != rhs.airDate { return lhs.airDate < rhs.airDate }
                if lhs.seasonNumber != rhs.seasonNumber { return lhs.seasonNumber < rhs.seasonNumber }
                return lhs.episodeNumber < rhs.episodeNumber
            }
    }

    /// A paused monitor says so first. Otherwise a download held back by the
    /// storage limit outranks one in flight, which outranks one waiting, and
    /// only a series with nothing on its way names its next air date.
    static func status(
        for subscription: DownloadSubscription,
        activity: [AutoDownloadActivity],
        upcoming: [UpcomingEpisode],
        knownEpisodeIds: Set<String>,
        scheduleKnown: Bool = true,
        now: Date = Date()
    ) -> AutoDownloadStatus {
        guard subscription.active else { return .paused }
        if activity.contains(where: { $0.phase == .storageLimit }) {
            return .storageLimit(maxBytes: subscription.maxStorageBytes)
        }
        let ordered = activity.sorted {
            ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
        }
        for item in ordered {
            if case .downloading(let fraction) = item.phase {
                return .downloading(episodeNumber: item.episodeNumber, fraction: fraction)
            }
        }
        if let first = ordered.first {
            return .waiting(episodeNumber: first.episodeNumber, phase: first.phase)
        }
        if let mode = SubscriptionMode(rawValue: subscription.mode),
           let next = nextEpisode(
               mode: mode,
               targetSeason: subscription.targetSeason,
               seasonNumbers: subscription.seasonNumbers,
               upcoming: upcoming,
               excluding: knownEpisodeIds,
               now: now
           ) {
            return .next(next)
        }
        return scheduleKnown ? .upToDate : .monitoring
    }

    // MARK: - Copy

    /// What the monitor downloads, e.g. "Season 3 and new episodes".
    static func ruleSummary(
        mode: SubscriptionMode,
        targetSeason: Int?,
        seasonNumbers: [Int]?
    ) -> String {
        switch mode {
        case .all:
            return AppLanguage.string(.downloadsMonitorRuleAll)
        case .future:
            return AppLanguage.string(.downloadsMonitorRuleFuture)
        case .latestSeason:
            guard let targetSeason else { return AppLanguage.string(.downloadsMonitorRuleLastSeason) }
            return AppLanguage.string(.downloadsMonitorRuleLastSeasonFrom(LocaleFormat.integer(targetSeason)))
        case .specificSeasons:
            return seasonList(seasonNumbers ?? [])
        }
    }

    /// The rule, plus the quality when it isn't original:
    /// "Future episodes · 10 Mbps".
    static func ruleSummary(for subscription: DownloadSubscription) -> String {
        guard let mode = SubscriptionMode(rawValue: subscription.mode) else {
            return AppLanguage.string(.downloadsMonitorRuleUnknown)
        }
        let rule = ruleSummary(mode: mode, targetSeason: subscription.targetSeason, seasonNumbers: subscription.seasonNumbers)
        guard let quality = subscription.quality.flatMap(DownloadFormat.init(rawValue:)), quality != .original else {
            return rule
        }
        return "\(rule) · \(quality.displayName)"
    }

    /// "Season 4", "Seasons 2 and 3", "Seasons 1, 2, and 4".
    static func seasonList(_ seasons: [Int]) -> String {
        let sorted = Array(Set(seasons)).sorted()
        switch sorted.count {
        case 0: return AppLanguage.string(.downloadsMonitorSeasonsNone)
        case 1: return AppLanguage.string(.downloadsMonitorSeasonsSingle(LocaleFormat.integer(sorted[0])))
        default:
            let joined = sorted.map { LocaleFormat.integer($0) }.formatted(.list(type: .and).locale(AppLanguage.formattingLocale))
            return AppLanguage.string(.downloadsMonitorSeasonsList(joined))
        }
    }

    /// One line for a list row, e.g. "Episode 6 on Thursday".
    static func statusLine(
        _ status: AutoDownloadStatus,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        switch status {
        case .paused:
            return AppLanguage.string(.downloadsMonitorStatusPaused)
        case .storageLimit(let maxBytes):
            return AppLanguage.string(.downloadsMonitorStatusOutOfSpace(limitText(maxBytes)))
        case .downloading(let episode, let fraction):
            let percent = LocaleFormat.integer(Int((fraction * 100).rounded()))
            guard let episode else {
                return AppLanguage.string(.downloadsMonitorStatusDownloadingUnnamed(percent))
            }
            return AppLanguage.string(.downloadsMonitorStatusDownloading(LocaleFormat.integer(episode), percent))
        case .waiting(let episode, let phase):
            return waitingLine(episode: episode, phase: phase)
        case .next(let upcoming):
            let season = "\(upcoming.seasonNumber)"
            let episode = "\(upcoming.episodeNumber)"
            let premiere = upcoming.episodeNumber == 1
            switch day(upcoming.airDate, now: now, calendar: calendar) {
            case .today:
                return AppLanguage.string(premiere
                    ? .downloadsMonitorNextSeasonStartsToday(season)
                    : .downloadsMonitorNextEpisodeToday(episode))
            case .tomorrow:
                return AppLanguage.string(premiere
                    ? .downloadsMonitorNextSeasonStartsTomorrow(season)
                    : .downloadsMonitorNextEpisodeTomorrow(episode))
            case .date(let date):
                return AppLanguage.string(premiere
                    ? .downloadsMonitorNextSeasonStartsOn(season, date)
                    : .downloadsMonitorNextEpisodeOn(episode, date))
            }
        case .upToDate:
            return AppLanguage.string(.downloadsMonitorStatusUpToDate)
        case .monitoring:
            return AppLanguage.string(.downloadsMonitorStatusMonitoring)
        }
    }

    /// The series-page headline, e.g. "Episode 6 downloads Thursday".
    static func headline(
        _ status: AutoDownloadStatus,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        switch status {
        case .paused:
            return AppLanguage.string(.downloadsMonitorHeadlinePaused)
        case .next(let upcoming):
            let season = "\(upcoming.seasonNumber)"
            let episode = "\(upcoming.episodeNumber)"
            let premiere = upcoming.episodeNumber == 1
            switch day(upcoming.airDate, now: now, calendar: calendar) {
            case .today:
                return AppLanguage.string(premiere
                    ? .downloadsMonitorHeadlineSeasonToday(season)
                    : .downloadsMonitorHeadlineEpisodeToday(episode))
            case .tomorrow:
                return AppLanguage.string(premiere
                    ? .downloadsMonitorHeadlineSeasonTomorrow(season)
                    : .downloadsMonitorHeadlineEpisodeTomorrow(episode))
            case .date(let date):
                return AppLanguage.string(premiere
                    ? .downloadsMonitorHeadlineSeasonOn(season, date)
                    : .downloadsMonitorHeadlineEpisodeOn(episode, date))
            }
        case .upToDate:
            return AppLanguage.string(.downloadsMonitorStatusUpToDate)
        default:
            return statusLine(status, now: now, calendar: calendar)
        }
    }

    /// When an air date falls, for callers that build whole messages per
    /// case rather than joining "today" into a sentence.
    enum RelativeDay: Hashable, Sendable {
        case today
        case tomorrow
        /// A weekday within the week ("Thursday"), otherwise "Oct 15".
        case date(String)
    }

    static func day(_ date: Date, now: Date, calendar: Calendar) -> RelativeDay {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        if days <= 0 { return .today }
        if days == 1 { return .tomorrow }
        // A format style, unlike a new DateFormatter per call, caches its
        // formatter; this runs in Downloads bodies.
        let style = Date.FormatStyle(locale: AppLanguage.formattingLocale, calendar: calendar, timeZone: calendar.timeZone)
        return .date(days < 7
            ? date.formatted(style.weekday(.wide))
            : date.formatted(style.month(.abbreviated).day()))
    }

    /// "10 GB" for the limit picker's whole GiB values; other limits another
    /// client set read as "1.5 GB" or "500 MB".
    static func limitText(_ maxBytes: Int64) -> String {
        if maxBytes > 0, maxBytes % DownloadSettings.bytesPerGB == 0 {
            return "\(LocaleFormat.integer(maxBytes / DownloadSettings.bytesPerGB)) GB"
        }
        return LocaleFormat.bytes(maxBytes, style: .binary)
    }

    private static func waitingLine(episode: Int?, phase: AutoDownloadActivity.Phase) -> String {
        guard let episode else {
            switch phase {
            case .waitingForWiFi: return AppLanguage.string(.downloadsMonitorWaitingUnnamedWifi)
            case .waitingForConnection: return AppLanguage.string(.downloadsMonitorWaitingUnnamedConnection)
            case .preparing: return AppLanguage.string(.downloadsMonitorWaitingUnnamedPreparing)
            default: return AppLanguage.string(.downloadsMonitorWaitingUnnamedNext)
            }
        }
        let number = "\(episode)"
        switch phase {
        case .waitingForWiFi: return AppLanguage.string(.downloadsMonitorWaitingWifi(number))
        case .waitingForConnection: return AppLanguage.string(.downloadsMonitorWaitingConnection(number))
        case .preparing: return AppLanguage.string(.downloadsMonitorWaitingPreparing(number))
        default: return AppLanguage.string(.downloadsMonitorWaitingNext(number))
        }
    }
}
#endif

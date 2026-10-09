import SwiftUI

/// Drives the Calendar tab: one Monday-anchored week of day-grouped
/// events for the active filter preset, with stale-while-revalidate
/// caching per (week, filter) pair.
@Observable
@MainActor
final class CalendarViewModel {
    typealias FetchCalendarWeek = (
        _ start: String, _ end: String, _ filter: String, _ timezone: String
    ) async throws -> CalendarResponse

    private static let filterDefaultsKey = "calendar.filter"

    private(set) var days: [CalendarDay] = []
    /// Each day's events keyed by its "YYYY-MM-DD" date; set with `days`.
    private var eventsByDay: [String: [CalendarEvent]] = [:]
    var isLoading = false
    var error: ErrorState?

    var week: CalendarWeek
    /// Day highlighted in the week strip; drives scroll-to-day.
    var selectedDay: Date = Date()

    var filter: CalendarFilter

    /// Monotonic token so a slow response for a week/filter the user has
    /// already navigated away from can't clobber the visible state.
    @ObservationIgnored private var requestToken = 0

    @ObservationIgnored private let fetchWeek: FetchCalendarWeek
    /// The device timezone, read on every load so a change is picked up.
    @ObservationIgnored private let deviceTimeZone: () -> TimeZone

    init(
        deviceTimeZone: @escaping () -> TimeZone = { .current },
        fetchWeek: @escaping FetchCalendarWeek = { start, end, filter, timezone in
            try await SiloAPI.shared.calendarEvents(
                start: start, end: end, filter: filter, timezone: timezone
            )
        }
    ) {
        self.deviceTimeZone = deviceTimeZone
        self.fetchWeek = fetchWeek
        week = CalendarWeek(containing: Date(), timeZone: deviceTimeZone())
        let stored = UserDefaults.standard.string(forKey: Self.filterDefaultsKey) ?? ""
        filter = CalendarFilter(rawValue: stored) ?? .following
    }

    // MARK: - Derived

    var isCurrentWeek: Bool { week.containsToday() }

    var isEmpty: Bool {
        days.allSatisfy { $0.items.isEmpty }
    }

    func events(on date: Date) -> [CalendarEvent] {
        eventsByDay[week.dateString(date)] ?? []
    }

    func hasEvents(on date: Date) -> Bool {
        !events(on: date).isEmpty
    }

    /// Day-shelf heading: "Today" / "Tomorrow" / "Monday, June 9".
    func sectionHeading(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    // MARK: - Actions

    func selectDay(_ date: Date) {
        selectedDay = date
    }

    func select(filter newFilter: CalendarFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        UserDefaults.standard.set(newFilter.rawValue, forKey: Self.filterDefaultsKey)
        Task { await load() }
    }

    func goToPreviousWeek() {
        week = week.advanced(by: -1)
        selectedDay = week.startDate
        Task { await load() }
    }

    func goToNextWeek() {
        week = week.advanced(by: 1)
        selectedDay = week.startDate
        Task { await load() }
    }

    /// Returns to the current week and awaits its load so callers can scroll
    /// to today's shelf once the data is in place.
    func goToToday() async {
        week = CalendarWeek(containing: Date(), timeZone: deviceTimeZone())
        selectedDay = Date()
        await load()
    }

    // MARK: - Loading

    /// After a device timezone change, rebuilds the shown week in the new
    /// zone so its dates, the day keys and the request's timezone agree.
    private func rebuildWeekIfTimeZoneChanged() {
        let timeZone = deviceTimeZone()
        guard timeZone.identifier != week.timeZone.identifier else { return }
        week = week.rebuilt(in: timeZone)
        selectedDay = week.containsToday() ? Date() : week.startDate
    }

    func load() async {
        rebuildWeekIfTimeZoneChanged()
        requestToken += 1
        let token = requestToken
        let week = week
        let filter = filter
        let timeZone = week.timeZone.identifier
        let key = CacheKey.calendarWeek(week.startString, filter: filter.rawValue, timeZone: timeZone)
        // Read before the fetch so a week that lands after a profile
        // boundary cleared "calendar:" cannot refill it for the next profile.
        let writeToken = ResponseCache.shared.writeToken

        if let cached: CalendarResponse = ResponseCache.shared.get(key) {
            setDays(cached.events)
            isLoading = false
        } else {
            setDays([])
            isLoading = true
        }
        error = nil

        do {
            let response = try await fetchWeek(
                week.startString,
                week.endString,
                filter.rawValue,
                timeZone
            )
            guard token == requestToken else { return }
            ResponseCache.shared.set(response, for: key, fetchedAt: writeToken)
            setDays(response.events)
        } catch let err {
            guard token == requestToken else { return }
            // A cancelled load (the tab was switched away mid-fetch) is
            // not a failure — the next `.task` run reloads from scratch,
            // so don't leave an error screen behind.
            if err is CancellationError || (err as? URLError)?.code == .cancelled { return }
            if days.isEmpty {
                error = ErrorState(err)
            }
        }
        isLoading = false
    }

    private func setDays(_ newDays: [CalendarDay]) {
        days = newDays
        eventsByDay = Dictionary(newDays.map { ($0.date, $0.items) }, uniquingKeysWith: { first, _ in first })
    }

    /// Revalidates the displayed week over its cached copy. `load()` always
    /// fetches from the network and only seeds its first paint from the
    /// cache, so the week stays on screen while the request runs. A failed
    /// refresh keeps the displayed days; the error screen appears only when
    /// there is nothing to show.
    func refresh() async {
        await load()
    }
}

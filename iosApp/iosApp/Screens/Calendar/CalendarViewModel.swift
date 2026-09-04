import SwiftUI

/// Drives the Calendar tab: one Monday-anchored week of day-grouped
/// events for the active filter preset, with stale-while-revalidate
/// caching per (week, filter) pair.
@Observable
@MainActor
final class CalendarViewModel {
    private static let filterDefaultsKey = "calendar.filter"

    var days: [CalendarDay] = []
    var isLoading = false
    var error: ErrorState?

    var week = CalendarWeek(containing: Date())
    /// Day highlighted in the week strip; drives scroll-to-day.
    var selectedDay: Date = Date()

    var filter: CalendarFilter

    /// Monotonic token so a slow response for a week/filter the user has
    /// already navigated away from can't clobber the visible state.
    @ObservationIgnored private var requestToken = 0

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.filterDefaultsKey) ?? ""
        filter = CalendarFilter(rawValue: stored) ?? .following
    }

    // MARK: - Derived

    var isCurrentWeek: Bool { week.containsToday() }

    var isEmpty: Bool {
        days.allSatisfy { $0.items.isEmpty }
    }

    func events(on date: Date) -> [CalendarEvent] {
        let key = DateFormatters.isoDate.string(from: date)
        return days.first(where: { $0.date == key })?.items ?? []
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
        week = CalendarWeek(containing: Date())
        selectedDay = Date()
        await load()
    }

    // MARK: - Loading

    func load() async {
        requestToken += 1
        let token = requestToken
        let week = week
        let filter = filter
        let key = CacheKey.calendarWeek(week.startString, filter: filter.rawValue)

        if let cached: CalendarResponse = ResponseCache.shared.get(key) {
            days = cached.events
            isLoading = false
        } else {
            days = []
            isLoading = true
        }
        error = nil

        do {
            let response = try await SiloAPI.shared.calendarEvents(
                start: week.startString,
                end: week.endString,
                filter: filter.rawValue,
                timezone: TimeZone.current.identifier
            )
            guard token == requestToken else { return }
            ResponseCache.shared.set(response, for: key)
            days = response.events
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

    func refresh() async {
        ResponseCache.shared.remove(
            CacheKey.calendarWeek(week.startString, filter: filter.rawValue)
        )
        await load()
    }
}

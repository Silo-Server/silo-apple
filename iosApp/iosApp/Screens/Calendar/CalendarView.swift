import SwiftUI

/// Upcoming-media calendar tab: a week-at-a-time agenda of movie
/// releases, episode airings, and season premieres from the library,
/// mirroring the server web UI's calendar.
struct CalendarView: View {
    /// Active focus hand-down token from `TVMainTabView`. When this
    /// changes (the Calendar root was selected), focus is pushed onto
    /// the filter bar so the screen never opens with a dead remote.
    var focusRequest: Int = 0
    var isTopMenuFocused: Bool = false
    var onTopMenuFocusRequest: (() -> Void)? = nil

    @State private var viewModel = CalendarViewModel()
    @Environment(AppRouter.self) private var router
    #if os(tvOS)
    @State private var entryFocusRequest = 0
    /// Focus hand-off for day selection: picking a day in the week strip
    /// scrolls to that day's shelf and kicks focus onto its first card.
    @State private var shelfFocusRequest = 0
    @State private var shelfFocusDay: Date?
    /// Day of the shelf that last took focus.
    @State private var focusedShelfDay: Date?
    /// Scroll target for the page's opening position.
    private static let topContentId = "calendar-top"
    #endif

    var body: some View {
        rootLayout
            .task {
                await viewModel.load()
            }
        #if !os(tvOS)
            .refreshable {
                await viewModel.load()
            }
        #endif
    }

    @ViewBuilder
    private var rootLayout: some View {
        #if os(tvOS)
        ZStack(alignment: .top) {
            TVRootHeroBackdrop(
                tintColor: .siloBackground,
                artworkURL: nil,
                artworkThumbhash: nil,
                isVisible: false
            )

            tvContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        // No standalone title bar: the search / profile actions live inside
        // the floating calendar card so the agenda reclaims that height.
        phoneContent
            .siloPageBackground()
        #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
        #endif
        #endif
    }

    // MARK: - iOS / macOS

    #if !os(tvOS)
    private var phoneContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The scope control scrolls away; only the week card
                    // (the safe-area inset below) stays pinned.
                    CalendarFilterBar(
                        selected: viewModel.filter,
                        onSelect: { viewModel.select(filter: $0) }
                    )
                    .padding(.horizontal, SiloTheme.safePadding)
                    .padding(.top, SiloTheme.smallPadding)
                    .padding(.bottom, SiloTheme.padding)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    shelfArea(proxy: proxy)
                }
                .padding(.bottom, SiloTheme.largePadding)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                phoneWeekStrip(proxy: proxy)
            }
            .siloScrollEdgeEffect()
        }
    }

    /// Pinned glass card holding the top-bar actions and week strip; content
    /// scrolls under it. The top safe-area inset offsets `scrollTo`, so a
    /// tapped day's shelf lands just below the card.
    private func phoneWeekStrip(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SidebarToggleButton()

                Text(viewModel.week.monthLabel)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.siloOnSurface)

                if !viewModel.isCurrentWeek {
                    Button("Today") { returnToToday(proxy: proxy) }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .siloGlass(in: .capsule)
                        .accessibilityLabel("Jump to today")
                }

                Spacer(minLength: 8)

                TabTopBarActions(
                    onSearch: { router.navigate(to: .search) },
                    onOpenSettings: { router.navigate(to: .settings) },
                    onOpenRequests: { router.navigate(to: .requestsHub) },
                    onSwitchProfile: {
                        router.switchProfile()
                    },
                    onSwitchServer: { router.navigate(to: .serverList) },
                    onSignOut: { router.signOutAndReset() }
                )
            }

            CalendarWeekStrip(
                week: viewModel.week,
                selectedDay: viewModel.selectedDay,
                isCurrentWeek: viewModel.isCurrentWeek,
                hasEvents: { viewModel.hasEvents(on: $0) },
                eventCount: { viewModel.events(on: $0).count },
                onSelectDay: { selectDay($0, proxy: proxy) },
                onPreviousWeek: { viewModel.goToPreviousWeek() },
                onNextWeek: { viewModel.goToNextWeek() },
                onToday: { returnToToday(proxy: proxy) }
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .siloGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, SiloTheme.safePadding)
        .padding(.top, SiloTheme.smallPadding)
        .padding(.bottom, SiloTheme.smallPadding)
        .frame(maxWidth: .infinity)
    }

    /// "Today" returns to the current week *and* scrolls to today's shelf —
    /// otherwise the user lands at the top of the week. The week reload is
    /// awaited so today's shelf exists, then the scroll is deferred one
    /// runloop tick so the reloaded week's shelves are laid out first (the
    /// same hand-off `CalendarDayShelf` uses for focus). Scrolling inline
    /// would target the previous week's shelves, before SwiftUI re-renders.
    private func returnToToday(proxy: ScrollViewProxy) {
        Task {
            await viewModel.goToToday()
            guard let today = viewModel.week.days.first(where: {
                Calendar.current.isDateInToday($0)
            }) else { return }
            viewModel.selectDay(today)
            DispatchQueue.main.async {
                withAnimation(SiloTheme.springAnimation) {
                    proxy.scrollTo(today, anchor: .top)
                }
            }
        }
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Not lazy: a recycled filter bar or shelf would lose its
                // applied focus token and replay it from `onAppear`, and the
                // focus engine can only move to views that are mounted.
                VStack(alignment: .leading, spacing: 30) {
                    CalendarFilterBar(
                        selected: viewModel.filter,
                        onSelect: { viewModel.select(filter: $0) },
                        focusRequest: entryFocusRequest,
                        onMoveUp: onTopMenuFocusRequest
                    )
                    .padding(.horizontal, SiloTheme.safePadding)

                    CalendarWeekStrip(
                        week: viewModel.week,
                        selectedDay: viewModel.selectedDay,
                        isCurrentWeek: viewModel.isCurrentWeek,
                        hasEvents: { viewModel.hasEvents(on: $0) },
                        eventCount: { viewModel.events(on: $0).count },
                        onSelectDay: { selectDay($0, proxy: proxy) },
                        onPreviousWeek: { viewModel.goToPreviousWeek() },
                        onNextWeek: { viewModel.goToNextWeek() },
                        onToday: { Task { await viewModel.goToToday() } },
                        onFocusGained: { returnToTop(proxy: proxy) }
                    )

                    shelfArea(proxy: proxy)
                }
                .padding(.top, TVTopMenuLayout.contentTopInset)
                .padding(.bottom, SiloTheme.largePadding)
                .id(Self.topContentId)
            }
            .modifier(TVMenuEntryScroll(request: focusRequest, isTopMenuFocused: isTopMenuFocused) { entryFocusRequest = $0 })
        }
    }
    #endif

    // MARK: - Shared shelf area

    @ViewBuilder
    private func shelfArea(proxy: ScrollViewProxy) -> some View {
        if let error = viewModel.error {
            ErrorView(state: error, onRetry: { Task { await viewModel.load() } })
                .frame(minHeight: 320)
        } else if viewModel.isLoading {
            loadingState
        } else if viewModel.isEmpty {
            emptyState
        } else {
            ForEach(viewModel.week.days, id: \.self) { day in
                CalendarDayShelf(
                    heading: viewModel.sectionHeading(for: day),
                    events: viewModel.events(on: day),
                    onEventTap: { event in
                        router.navigate(to: event.detailRoute)
                    },
                    // Every shelf, not just the first: the focus engine
                    // otherwise keeps the horizontal position focus had
                    // before a default-focus redirect, so Down from a
                    // shelf's first card can land mid-row in the next one.
                    prefersDefaultFocusOnFirstItem: true,
                    focusRequest: shelfFocusRequest(for: day),
                    onFocusGained: shelfFocusHandler(for: day, proxy: proxy)
                )
                .id(day)
                .padding(.bottom, shelfBottomPadding)
            }
        }
    }

    /// Holds the shelf area's height while a week loads. Focusable on tvOS
    /// so focus moving down from the week strip has somewhere to land.
    private var loadingState: some View {
        Color.clear
            .frame(minHeight: 320)
            #if os(tvOS)
            .focusable()
            #endif
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundColor(.siloOnSurface.opacity(0.3))

            Text(emptyTitle)
                .font(.siloSubheadline)
                .foregroundColor(.siloOnSurface)

            Text(emptySubtitle)
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, SiloTheme.largePadding)

            // Every view links to the other two, which also gives tvOS
            // focus a target below the week strip so d-pad down from it
            // doesn't dead-end.
            HStack(spacing: SiloTheme.padding) {
                ForEach(viewModel.filter.emptyStateLinks) { filter in
                    Button {
                        viewModel.select(filter: filter)
                    } label: {
                        // Fill the fixed width so iOS 26 glass pills match.
                        Text(filter.displayLabel)
                            .frame(maxWidth: .infinity)
                    }
                    .siloPrimaryButton()
                    .frame(width: emptyButtonWidth)
                    .accessibilityLabel("Show \(filter.displayLabel)")
                }
            }
            .padding(.top, SiloTheme.smallPadding)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        #if os(tvOS)
        // Full-width section so down from any day in the strip reaches
        // the centered buttons, not just from the days above them.
        .focusSection()
        #endif
    }

    private var emptyTitle: String {
        switch viewModel.filter {
        case .following: return "Nothing from shows you follow"
        case .trending: return "Nothing trending this week"
        case .everything: return "Nothing scheduled this week"
        }
    }

    private var emptySubtitle: String {
        switch viewModel.filter {
        case .following:
            return "No upcoming releases this week from shows you watch, favorite, or watchlist."
        case .trending:
            return "No trending movie releases or episode airings in this week."
        case .everything:
            return "No movie releases or episode airings in this week."
        }
    }

    private var emptyButtonWidth: CGFloat {
        #if os(tvOS)
        return 300
        #else
        return 150
        #endif
    }

    private var shelfBottomPadding: CGFloat {
        #if os(tvOS)
        return 6
        #else
        return SiloTheme.padding
        #endif
    }

    // MARK: - Helpers

    private func selectDay(_ day: Date, proxy: ScrollViewProxy) {
        viewModel.selectDay(day)
        withAnimation(SiloTheme.springAnimation) {
            proxy.scrollTo(day, anchor: .top)
        }
        #if os(tvOS)
        // Hand focus to the selected day's shelf so the remote lands on
        // its first card instead of staying parked in the week strip.
        // A day-less shelf has nothing to focus, and the strip scrolls
        // off-screen, so focus the nearest day with events instead.
        if let target = shelfFocusTarget(forSelected: day) {
            focusedShelfDay = target
            shelfFocusDay = target
            shelfFocusRequest += 1
        }
        #endif
    }

    #if os(tvOS)
    /// The selected day if it has events, otherwise the next day with
    /// events, otherwise the previous one.
    private func shelfFocusTarget(forSelected day: Date) -> Date? {
        let days = viewModel.week.days.filter { viewModel.hasEvents(on: $0) }
        if days.contains(day) { return day }
        return days.first { $0 > day } ?? days.last { $0 < day }
    }
    #endif

    /// Per-shelf kick token: only the most recently selected day sees a
    /// non-zero, changing value, so exactly one shelf claims focus.
    private func shelfFocusRequest(for day: Date) -> Int {
        #if os(tvOS)
        return day == shelfFocusDay ? shelfFocusRequest : 0
        #else
        return 0
        #endif
    }

    private func shelfFocusHandler(for day: Date, proxy: ScrollViewProxy) -> (() -> Void)? {
        #if os(tvOS)
        return { shelfGainedFocus(day, proxy: proxy) }
        #else
        return nil
        #endif
    }

    #if os(tvOS)
    /// The focus engine reveals a shelf with the least scrolling. Moving up,
    /// or down onto the last shelf, that leaves the heading under the top
    /// menu. Frame every shelf-to-shelf move where the engine places rows
    /// on the way down: bottom-aligned.
    private func shelfGainedFocus(_ day: Date, proxy: ScrollViewProxy) {
        defer { focusedShelfDay = day }
        guard let previous = focusedShelfDay, day != previous else { return }
        DispatchQueue.main.async {
            withAnimation(Self.focusScrollAnimation) {
                proxy.scrollTo(day, anchor: .bottom)
            }
        }
    }

    /// Focus reaching the week strip restores the opening scroll position.
    private func returnToTop(proxy: ScrollViewProxy) {
        focusedShelfDay = nil
        DispatchQueue.main.async {
            withAnimation(Self.focusScrollAnimation) {
                proxy.scrollTo(Self.topContentId, anchor: .top)
            }
        }
    }

    /// Match the pace of the focus engine's own reveal scrolls.
    private static let focusScrollAnimation = Animation.easeInOut(duration: 0.45)
    #endif
}

import SwiftUI

/// Upcoming-media calendar tab: a week-at-a-time agenda of movie
/// releases, episode airings, and season premieres from the library,
/// mirroring the server web UI's calendar.
struct CalendarView: View {
    /// Active focus hand-down token from `TVMainTabView`. When this
    /// changes (the Calendar root was selected), focus is pushed onto
    /// the filter bar so the screen never opens with a dead remote.
    var focusRequest: Int = 0
    var onTopMenuFocusRequest: (() -> Void)? = nil

    @State private var viewModel = CalendarViewModel()
    @Environment(AppRouter.self) private var router
    #if os(tvOS)
    /// Focus hand-off for day selection: picking a day in the week strip
    /// scrolls to that day's shelf and kicks focus onto its first card.
    @State private var shelfFocusRequest = 0
    @State private var shelfFocusDay: Date?
    /// Focus hand-back for the boundary up-move: a shelf whose up-press the
    /// focus engine couldn't resolve (empty days above, strip off-screen)
    /// asks the week strip to reclaim focus.
    @State private var stripFocusRequest = 0
    /// Scroll target for the ride home to the strip/filter area.
    private static let topContentId = "calendar-top"
    #endif

    var body: some View {
        rootLayout
            .task {
                await viewModel.load()
            }
        #if !os(tvOS)
            .refreshable {
                await viewModel.refresh()
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
                    // The scope sits in the scrolling content so it slides
                    // away as you read down the agenda — only the week rail
                    // (pinned via the safe-area inset below) stays put. That
                    // is the room win: one slim sticky bar instead of three.
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

    /// The single pinned element: a floating Liquid-Glass calendar card. It
    /// carries the relocated top-bar actions (so the agenda reclaims the old
    /// title bar's height) and rides the scroll view's top safe-area inset —
    /// the agenda scrolls *under* its glass. Tapping a day still lands its
    /// shelf just below the card (the inset offsets `scrollTo`). No opaque
    /// backing, so content refracts through the glass as it passes beneath.
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
                LazyVStack(alignment: .leading, spacing: 30) {
                    // Full-width focus section: the filter capsule only
                    // occupies the leading corner, and a narrow section
                    // can't catch up-moves from day buttons on the right
                    // side of the strip below — the focus engine would
                    // skip past it to the (full-width) top menu. The
                    // spacer stretches the section across the row so
                    // every up-move from the strip lands here first.
                    HStack(spacing: 0) {
                        CalendarFilterBar(
                            selected: viewModel.filter,
                            onSelect: { viewModel.select(filter: $0) },
                            focusRequest: focusRequest,
                            onMoveUp: onTopMenuFocusRequest
                        )

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, SiloTheme.safePadding)
                    .focusSection()
                    .id(Self.topContentId)

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
                        focusRequest: stripFocusRequest
                    )

                    shelfArea(proxy: proxy)
                }
                .padding(.top, TVTopMenuLayout.contentTopInset)
                .padding(.bottom, SiloTheme.largePadding)
            }
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
            let firstNonEmptyDay = viewModel.week.days.first { viewModel.hasEvents(on: $0) }
            ForEach(viewModel.week.days, id: \.self) { day in
                CalendarDayShelf(
                    heading: viewModel.sectionHeading(for: day),
                    events: viewModel.events(on: day),
                    onEventTap: { event in
                        router.navigate(to: .itemDetail(contentId: event.navigationContentId))
                    },
                    prefersDefaultFocusOnFirstItem: day == firstNonEmptyDay,
                    focusRequest: shelfFocusRequest(for: day),
                    onMoveUp: shelfMoveUpHandler(for: day, proxy: proxy)
                )
                .id(day)
                .padding(.bottom, shelfBottomPadding)
            }
        }
    }

    /// On tvOS the loading state must contain at least one focusable
    /// element so Menu/Back keeps working — see `RecommendationsView`.
    /// Here the always-rendered filter bar already provides one; the
    /// clear spacer just keeps the layout from collapsing.
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

            if viewModel.filter != .everything {
                Button("Show Everything") {
                    viewModel.select(filter: .everything)
                }
                .siloPrimaryButton()
                .frame(width: emptyButtonWidth)
                .padding(.top, SiloTheme.smallPadding)
            } else {
                // tvOS focus needs at least one target below the filter
                // bar so d-pad down from it doesn't dead-end (see
                // RecommendationsView's empty state).
                #if os(tvOS)
                Button("Refresh") {
                    Task { await viewModel.refresh() }
                }
                .buttonStyle(SiloPrimaryButtonStyle())
                .frame(width: emptyButtonWidth)
                .padding(.top, SiloTheme.smallPadding)
                #endif
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var emptyTitle: String {
        viewModel.filter == .following
            ? "Nothing from shows you follow"
            : "Nothing scheduled this week"
    }

    private var emptySubtitle: String {
        viewModel.filter == .following
            ? "No upcoming releases this week from shows you watch, favorite, or watchlist."
            : "No movie releases or episode airings in this week."
    }

    private var emptyButtonWidth: CGFloat {
        #if os(tvOS)
        return 360
        #else
        return 220
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
        // Day-less shelves have nothing to focus — leave focus on the
        // strip so the user can pick another day.
        if viewModel.hasEvents(on: day) {
            shelfFocusDay = day
            shelfFocusRequest += 1
        }
        #endif
    }

    /// Per-shelf kick token: only the most recently selected day sees a
    /// non-zero, changing value, so exactly one shelf claims focus.
    private func shelfFocusRequest(for day: Date) -> Int {
        #if os(tvOS)
        return day == shelfFocusDay ? shelfFocusRequest : 0
        #else
        return 0
        #endif
    }

    /// tvOS: boundary up-move escape hatch. When the focus engine can't
    /// resolve an up-press out of a shelf natively — the days above are
    /// empty "Nothing scheduled" stubs and the week strip has scrolled
    /// off-screen — the press bubbles to the shelf's `onMoveCommand` and
    /// lands here: hop to the previous day with events, or ride home to
    /// the week strip when nothing focusable is above.
    private func shelfMoveUpHandler(for day: Date, proxy: ScrollViewProxy) -> (() -> Void)? {
        #if os(tvOS)
        guard viewModel.hasEvents(on: day) else { return nil }
        return { handleShelfMoveUp(from: day, proxy: proxy) }
        #else
        return nil
        #endif
    }

    #if os(tvOS)
    private func handleShelfMoveUp(from day: Date, proxy: ScrollViewProxy) {
        if let previous = viewModel.week.days.last(where: {
            $0 < day && viewModel.hasEvents(on: $0)
        }) {
            withAnimation(SiloTheme.springAnimation) {
                proxy.scrollTo(previous, anchor: .top)
            }
            shelfFocusDay = previous
            shelfFocusRequest += 1
        } else {
            withAnimation(SiloTheme.springAnimation) {
                proxy.scrollTo(Self.topContentId, anchor: .top)
            }
            stripFocusRequest += 1
        }
    }
    #endif

}

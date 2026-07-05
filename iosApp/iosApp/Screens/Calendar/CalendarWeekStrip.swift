import SwiftUI

/// Week navigator.
///
/// - iOS / macOS: a Trakt-style two-row block meant to live inside the
///   pinned calendar card — a month-year label and `‹ Today ›` controls on
///   top, then a full-width row of rich day cells (weekday / boxed number /
///   event-count) below.
/// - tvOS: the original focus-driven strip (prev/next chevrons around seven
///   day buttons, plus a `Today` shortcut), unchanged.
struct CalendarWeekStrip: View {
    let week: CalendarWeek
    let selectedDay: Date
    let isCurrentWeek: Bool
    let hasEvents: (Date) -> Bool
    /// Number of airings on a day — drives the per-cell count badge.
    let eventCount: (Date) -> Int
    let onSelectDay: (Date) -> Void
    let onPreviousWeek: () -> Void
    let onNextWeek: () -> Void
    let onToday: () -> Void
    /// tvOS: programmatic focus kick — when this changes to a new non-zero
    /// token, focus rides home onto the selected day's button. Used by the
    /// shelf area's boundary up-move when nothing focusable sits between a
    /// shelf and the strip.
    var focusRequest: Int = 0

    #if os(tvOS)
    @FocusState private var focusedControl: StripControl?
    /// Each kick token claims focus exactly once (see `CalendarDayShelf`).
    @State private var lastAppliedFocusRequest = 0
    #endif

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        phoneBody
        #endif
    }

    // MARK: - iOS / macOS

    #if !os(tvOS)
    /// The week-cells row: seven full-width rich cells flanked by prev/next
    /// chevrons. The month label, Today button and top-bar actions live in
    /// the card chrome above this (assembled by `CalendarView`).
    private var phoneBody: some View {
        HStack(spacing: 6) {
            phoneNavButton(systemImage: "chevron.left", action: onPreviousWeek)
                .accessibilityLabel("Previous week")

            HStack(spacing: 0) {
                ForEach(week.days, id: \.self) { date in
                    CalendarRichDayCell(
                        date: date,
                        isSelected: Calendar.current.isDate(date, inSameDayAs: selectedDay),
                        isToday: Calendar.current.isDateInToday(date),
                        eventCount: eventCount(date),
                        action: { onSelectDay(date) }
                    )
                    .frame(maxWidth: .infinity)
                }
            }

            phoneNavButton(systemImage: "chevron.right", action: onNextWeek)
                .accessibilityLabel("Next week")
        }
        .animation(ContinuumTheme.springAnimation, value: selectedDay)
    }

    private func phoneNavButton(
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.continuumOnSurface.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.07)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.continuumFlat)
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvBody: some View {
        HStack(spacing: stripSpacing) {
            chevronButton(systemImage: "chevron.left", control: .previous, action: onPreviousWeek)
                .accessibilityLabel("Previous week")

            HStack(spacing: dayButtonSpacing) {
                ForEach(week.days, id: \.self) { date in
                    CalendarDayButton(
                        date: date,
                        isSelected: Calendar.current.isDate(date, inSameDayAs: selectedDay),
                        isToday: Calendar.current.isDateInToday(date),
                        hasEvents: hasEvents(date),
                        isFocused: isFocused(.day(date)),
                        action: { onSelectDay(date) }
                    )
                    .applyStripFocus(self, control: .day(date))
                }
            }

            chevronButton(systemImage: "chevron.right", control: .next, action: onNextWeek)
                .accessibilityLabel("Next week")

            if !isCurrentWeek {
                Button("Today", action: onToday)
                    .font(todayFont)
                    .foregroundColor(isFocused(.today) ? .continuumBackground : .continuumOnSurface)
                    .buttonStyle(.continuumFlat)
                    .padding(.horizontal, todayHorizontalPadding)
                    .frame(height: chevronHeight)
                    .background(
                        Capsule().fill(
                            isFocused(.today)
                                ? Color.continuumOnSurface.opacity(0.94)
                                : Color.white.opacity(0.08)
                        )
                    )
                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .applyStripFocus(self, control: .today)
                    .accessibilityLabel("Jump to today")
            }

            Spacer(minLength: 0)

            Text(week.monthLabel)
                .font(monthFont)
                .foregroundColor(.continuumSecondaryText)
        }
        .padding(.horizontal, ContinuumTheme.safePadding)
        .focusSection()
        .animation(ContinuumTheme.springAnimation, value: isCurrentWeek)
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request) }
        .onAppear { applyFocusRequest(focusRequest) }
    }

    private func applyFocusRequest(_ request: Int) {
        guard request > 0, request != lastAppliedFocusRequest else { return }
        lastAppliedFocusRequest = request
        // The kick arrives together with a scroll-to-top; the strip may
        // still be sliding into view, and the focus engine silently drops
        // writes to off-screen targets. Claim, verify, re-claim until the
        // scroll settles — same pattern as `MediaRow.claimFirstItemFocus`.
        let target = StripControl.day(selectedStripDay)
        DispatchQueue.main.async {
            claimFocus(on: target)
        }
    }

    private func claimFocus(on control: StripControl, attempt: Int = 0) {
        focusedControl = control
        guard attempt < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard focusedControl != control else { return }
            claimFocus(on: control, attempt: attempt + 1)
        }
    }

    /// The strip's day-button focus values are the exact `week.days` dates;
    /// `selectedDay` is same-day but not guaranteed same-instant, so resolve
    /// it back to the matching strip date before claiming focus.
    private var selectedStripDay: Date {
        week.days.first { Calendar.current.isDate($0, inSameDayAs: selectedDay) }
            ?? week.days.first
            ?? selectedDay
    }

    private func chevronButton(
        systemImage: String,
        control: StripControl,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(chevronFont)
                .foregroundColor(
                    isFocused(control) ? .continuumBackground : .continuumOnSurface.opacity(0.7)
                )
                .frame(width: chevronWidth, height: chevronHeight)
                .background(
                    Circle().fill(
                        isFocused(control)
                            ? Color.continuumOnSurface.opacity(0.94)
                            : Color.white.opacity(0.08)
                    )
                )
        }
        .buttonStyle(.continuumFlat)
        .applyStripFocus(self, control: control)
    }

    // MARK: - Focus plumbing

    enum StripControl: Hashable {
        case previous
        case next
        case today
        case day(Date)
    }

    fileprivate func isFocused(_ control: StripControl) -> Bool {
        return focusedControl == control
    }

    fileprivate var focusBinding: FocusState<StripControl?>.Binding { $focusedControl }

    // MARK: - Metrics

    private var stripSpacing: CGFloat { 18 }
    private var dayButtonSpacing: CGFloat { 10 }
    private var chevronFont: Font { .system(size: 24, weight: .semibold) }
    private var chevronWidth: CGFloat { 64 }
    private var chevronHeight: CGFloat { 64 }
    private var todayFont: Font { .system(size: 22, weight: .semibold) }
    private var todayHorizontalPadding: CGFloat { 24 }
    private var monthFont: Font { .system(size: 24, weight: .semibold) }
    #endif
}

#if os(tvOS)
private extension View {
    /// tvOS: bind a strip control to the shared `@FocusState`.
    @ViewBuilder
    func applyStripFocus(
        _ strip: CalendarWeekStrip,
        control: CalendarWeekStrip.StripControl
    ) -> some View {
        self.focused(strip.focusBinding, equals: control)
    }
}
#endif

// MARK: - iOS rich day cell

#if !os(tvOS)
/// Trakt-style day cell: weekday over a boxed day-number over an event-count
/// badge. Selected fills the number box; today outlines it.
private struct CalendarRichDayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let eventCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(weekdayLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.continuumSecondaryText)

                Text(dayNumber)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(isSelected ? .continuumBackground : .continuumOnSurface)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(isSelected ? Color.continuumOnSurface : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(
                                isToday && !isSelected
                                    ? Color.continuumOnSurface.opacity(0.45)
                                    : Color.clear,
                                lineWidth: 1.5
                            )
                    )

                countIndicator
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.continuumFlat)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var countIndicator: some View {
        if eventCount > 0 {
            Text("\(eventCount)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.continuumOnSurface.opacity(0.85))
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        } else {
            Color.clear.frame(height: 16)
        }
    }

    private var weekdayLabel: String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }

    private var dayNumber: String {
        date.formatted(.dateTime.day())
    }

    private var accessibilityDescription: String {
        let base = date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        guard eventCount > 0 else { return base }
        return base + ", \(eventCount) event\(eventCount == 1 ? "" : "s")"
    }
}
#endif

// MARK: - tvOS day button

#if os(tvOS)
private struct CalendarDayButton: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let hasEvents: Bool
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: labelSpacing) {
                Text(weekdayLabel)
                    .font(weekdayFont)
                    .foregroundColor(secondaryColor)

                Text(dayNumber)
                    .font(numberFont)
                    .foregroundColor(primaryColor)

                Circle()
                    .fill(hasEvents ? dotColor : .clear)
                    .frame(width: dotSize, height: dotSize)
            }
            .frame(width: buttonWidth, height: buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius, style: .continuous)
                    .fill(backgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius, style: .continuous)
                    .stroke(
                        isToday && !isSelected && !isFocused
                            ? Color.white.opacity(0.35)
                            : .clear,
                        lineWidth: 1
                    )
            )
            .scaleEffect(isFocused ? 1.06 : 1.0)
        }
        .buttonStyle(.continuumFlat)
        .animation(ContinuumTheme.springAnimation, value: isFocused)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var weekdayLabel: String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }

    private var dayNumber: String {
        date.formatted(.dateTime.day())
    }

    private var accessibilityDescription: String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day())
            + (hasEvents ? ", has events" : "")
    }

    private var inverted: Bool { isSelected || isFocused }

    private var primaryColor: Color {
        inverted ? .continuumBackground : .continuumOnSurface
    }

    private var secondaryColor: Color {
        inverted ? Color.continuumBackground.opacity(0.7) : .continuumSecondaryText
    }

    private var dotColor: Color {
        inverted ? .continuumBackground : .continuumOnSurface.opacity(0.8)
    }

    private var backgroundFill: Color {
        if isFocused { return Color.continuumOnSurface.opacity(0.94) }
        if isSelected { return Color.continuumOnSurface.opacity(0.88) }
        return Color.white.opacity(0.05)
    }

    // MARK: - Metrics

    private var labelSpacing: CGFloat { 6 }
    private var weekdayFont: Font { .system(size: 18, weight: .semibold) }
    private var numberFont: Font { .system(size: 26, weight: .bold) }
    private var dotSize: CGFloat { 8 }
    private var buttonWidth: CGFloat { 84 }
    private var buttonHeight: CGFloat { 96 }
}
#endif

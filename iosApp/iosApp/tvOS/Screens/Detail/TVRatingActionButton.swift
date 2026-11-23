#if os(tvOS)
import SwiftUI

/// The viewer's rating of the page's movie or series, as the action row
/// shows it. `score` is on the server's 1...10 scale, nil when unrated; on a
/// series page it is the series' rating, never the displayed episode's.
struct TVDetailRating {
    let score: Int?
    let isSeries: Bool
    /// The title is watched (for a series, the whole series): an unrated,
    /// unfocused button gets the accent nudge ring.
    let isWatched: Bool
    /// False on the card's provisional copy of the page. The button is
    /// already in place, so the row does not reflow when the page loads, but
    /// it takes no input until it can save.
    let isAvailable: Bool
    /// Nil removes the rating.
    let onChange: (Int?) -> Void
}

/// The star button in `TVDetailActionRow`. Select turns this same view into
/// the editing pill; the row owns the editor state and handles Left and
/// Right, so the focus host and its `.focused` binding never change.
struct TVRatingActionButton: View {
    let rating: TVDetailRating
    let editor: TVRatingEditor
    let onSelect: () -> Void
    let onHold: () -> Void
    let onCancel: () -> Void
    let onAdjust: (TVRatingEditor.Step) -> Void

    /// Whether holding Select removes the rating. See `supportsHold`.
    static let supportsHold = false
    private static let holdDuration: Duration = .milliseconds(700)

    @Environment(\.locale) private var locale
    @FocusState private var isFocused: Bool
    @State private var isPressed = false
    @State private var holdTask: Task<Void, Never>?
    /// Set when a hold has removed the rating, so the release that ends the
    /// same press does not also open editing.
    @State private var holdFired = false

    private var score: RatingScore { RatingScore(server: rating.score) }

    var body: some View {
        TVRatingPillSurface(
            score: score,
            draft: editor.draft,
            isSeries: rating.isSeries,
            isWatched: rating.isWatched,
            isFocused: isFocused,
            isPressed: isPressed
        )
        .accessibilityHidden(true)
        .overlay {
            // The Button is only the focus and press host, as in
            // `TVCircleActionButton`; it stays the accessibility element.
            Button(action: activate) {
                Color.clear
            }
            .buttonStyle(TVCircleFocusHostButtonStyle(isPressed: $isPressed))
            .focused($isFocused)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityAdjustableAction { direction in
                guard editor.isEditing else { return }
                switch direction {
                case .increment: onAdjust(.up)
                case .decrement: onAdjust(.down)
                @unknown default: break
                }
            }
            .accessibilityAction(.escape) { onCancel() }
        }
        // Back cancels an edit and never pops the page. Both stay attached in
        // every state; only whether they act changes.
        .onExitCommand(perform: editor.isEditing ? onCancel : nil)
        .background(
            TVWindowMenuPressCatcher(isActive: editor.isEditing, onExit: onCancel)
                .frame(width: 0, height: 0)
        )
        .onChange(of: isPressed) { _, pressed in
            pressChanged(pressed)
        }
        .onDisappear {
            holdTask?.cancel()
            holdTask = nil
        }
    }

    private func activate() {
        if holdFired {
            holdFired = false
            return
        }
        guard rating.isAvailable else { return }
        onSelect()
    }

    private func pressChanged(_ pressed: Bool) {
        holdTask?.cancel()
        holdTask = nil
        guard pressed else { return }
        holdFired = false
        guard Self.supportsHold, rating.isAvailable, !editor.isEditing, score.isRated else { return }
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: Self.holdDuration)
            guard !Task.isCancelled, isPressed else { return }
            holdFired = true
            onHold()
        }
    }

    private var accessibilityLabel: String {
        if editor.isEditing {
            return AppLanguage.string(.detailRatingA11YLabel, locale: locale)
        }
        if score.isRated {
            let value = score.display(locale: locale)
            return AppLanguage.string(
                rating.isSeries ? .detailRatingA11YYoursSeries(value) : .detailRatingA11YYours(value),
                locale: locale
            )
        }
        return AppLanguage.string(
            rating.isSeries ? .detailRatingHintRateSeries : .detailRatingRate,
            locale: locale
        )
    }

    private var accessibilityValue: String {
        guard let draft = editor.draft else { return "" }
        return draft.accessibilityValue(locale: locale)
    }
}

// MARK: - Surface

/// What the star button draws: a 76pt circle with a star, widening to show
/// its title while focused like the row's other circles, and the editing
/// pill (chevrons, five stars, the value) at the same height.
private struct TVRatingPillSurface: View {
    let score: RatingScore
    let draft: RatingScore?
    let isSeries: Bool
    let isWatched: Bool
    let isFocused: Bool
    let isPressed: Bool

    @Environment(\.locale) private var locale
    @State private var isExpanded = false

    private static let height: CGFloat = 76
    private static let pillFill = Color(hex: "#0B0D12")
    private static let dimChevron = Color(hex: "#4A4F5A")
    private static let captionColor = Color(hex: "#C9CCD3")

    private var isEditing: Bool { draft != nil }
    private var showsNudge: Bool { isWatched && !score.isRated && !isFocused && !isEditing }

    var body: some View {
        HStack(spacing: 14) {
            if let draft {
                editingContent(draft: draft)
                    .transition(.opacity.animation(TVCircleFocusMotion.reveal))
            } else {
                idleStar
                if isExpanded {
                    Text(title)
                        .font(.system(size: 26, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.animation(TVCircleFocusMotion.reveal.delay(0.06)),
                                removal: .opacity.animation(TVCircleFocusMotion.dismiss)
                            )
                        )
                }
            }
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        .foregroundColor(isFocused && !isEditing ? .black : .white)
        .frame(minWidth: Self.height)
        .frame(height: Self.height)
        .background(Capsule().fill(background))
        .overlay {
            if isEditing {
                Capsule().strokeBorder(Color.white, lineWidth: 2)
            }
        }
        .clipShape(Capsule())
        // The nudge ring sits just outside the circle, as a 2pt halo.
        .overlay {
            Capsule()
                .inset(by: -2)
                .strokeBorder(Color.siloRatingStar, lineWidth: 2)
                .opacity(showsNudge ? 1 : 0)
        }
        .scaleEffect(isPressed && !isEditing ? 0.95 : 1)
        .shadow(
            color: .black.opacity(isEditing ? 0.5 : (isFocused ? 0.34 : 0)),
            radius: isEditing ? 24 : (isFocused ? 16 : 0),
            y: isEditing ? 12 : (isFocused ? 6 : 0)
        )
        .animation(TVCircleFocusMotion.resize, value: isFocused)
        .animation(TVCircleFocusMotion.resize, value: isEditing)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: isPressed)
        .onChange(of: isFocused && !isEditing, initial: true) { _, expanded in
            guard expanded != isExpanded else { return }
            withAnimation(TVCircleFocusMotion.resize) {
                isExpanded = expanded
            }
        }
    }

    private var title: String {
        AppLanguage.string(isSeries ? .detailRatingRateSeries : .detailRatingRate, locale: locale)
    }

    private var background: Color {
        if isEditing { return Self.pillFill }
        return isFocused ? .white : Color.white.opacity(0.10)
    }

    private var leadingPadding: CGFloat {
        if isEditing { return 21 }
        return isExpanded ? 28 : 0
    }

    private var trailingPadding: CGFloat {
        if isEditing { return 27 }
        return isExpanded ? 28 : 0
    }

    // MARK: Idle

    /// Outline when unrated, accent-filled when rated, dark on the white
    /// focused surface. Watched and unrated, the outline turns accent.
    private var idleStar: some View {
        let size: CGFloat = 34
        let stroke: Color
        let fill: Color
        if isFocused {
            stroke = Self.pillFill
            fill = score.isRated ? Self.pillFill : .clear
        } else {
            stroke = score.isRated || isWatched ? .siloRatingStar : .white
            fill = score.isRated ? .siloRatingStar : .clear
        }
        let style = StrokeStyle(lineWidth: size * 2 / 24, lineJoin: .round)
        return ZStack {
            RatingStarShape().fill(fill)
            RatingStarShape().stroke(stroke, style: style)
        }
        .frame(width: size, height: size)
        .frame(width: 38, height: 38)
        .animation(.easeInOut(duration: 0.18), value: score)
    }

    // MARK: Editing

    private func editingContent(draft: RatingScore) -> some View {
        HStack(spacing: 9) {
            if isSeries {
                Text(.detailRatingSeriesCaption)
                    .font(.system(size: 18, weight: .bold))
                    .tracking(1.8)
                    .foregroundColor(Self.captionColor)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 6)
                    .padding(.trailing, 9)
            }
            chevron(pointsForward: false, isEnabled: draft.isRated)
            RatingStarsView(score: draft, starSize: 48, spacing: 9)
            chevron(pointsForward: true, isEnabled: !draft.isMax)
            Text(draft.isRated ? draft.display(locale: locale) : "–")
                .font(.system(size: 30, weight: .bold).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .frame(width: 51, alignment: .trailing)
                .contentTransition(.numericText(value: draft.stars))
                .animation(.easeOut(duration: 0.12), value: draft)
        }
    }

    private func chevron(pointsForward: Bool, isEnabled: Bool) -> some View {
        TVRatingChevronShape()
            .fill(isEnabled ? Color.white : Self.dimChevron)
            .frame(width: 13, height: 21)
            .scaleEffect(x: pointsForward ? 1 : -1)
            .flipsForRightToLeftLayoutDirection(true)
            .frame(width: 24, height: 24)
            .animation(.easeOut(duration: 0.12), value: isEnabled)
    }
}

/// The design's solid chevron, pointing right (toward the trailing side).
private struct TVRatingChevronShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Hint line

/// The one-line hint under the action row. It is drawn in a fixed-height
/// slot and never takes part in layout, so nothing on the page moves when
/// its text comes and goes.
struct TVRatingHintLine: View {
    let hint: TVRatingEditor.Hint?

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let slotHeight: CGFloat = 34

    var body: some View {
        ZStack(alignment: .leading) {
            if let text {
                Text(text)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.80))
                    .lineLimit(1)
                    .fixedSize()
                    .id(text)
                    .transition(.opacity)
            }
        }
        .frame(height: Self.slotHeight, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: text)
        // VoiceOver hears the button's label and value, and the saves and
        // removals are announced, so the visual hint stays out of its way.
        .accessibilityHidden(true)
    }

    private var text: String? {
        guard let hint else { return nil }
        return Self.text(for: hint, locale: locale)
    }

    static func text(for hint: TVRatingEditor.Hint, locale: Locale) -> String {
        switch hint {
        case .rate(let isSeries):
            return AppLanguage.string(isSeries ? .detailRatingHintRateSeries : .detailRatingHintRateMovie, locale: locale)
        case .rated(let score, let isSeries, let mentionsHold):
            let value = score.display(locale: locale)
            let key: LocalizedStringResource
            switch (isSeries, mentionsHold) {
            case (false, true): key = .detailRatingHintRated(value)
            case (true, true): key = .detailRatingHintRatedSeries(value)
            case (false, false): key = .detailRatingHintRatedNoHold(value)
            case (true, false): key = .detailRatingHintRatedSeriesNoHold(value)
            }
            return AppLanguage.string(key, locale: locale)
        case .editing(let isSeries):
            return AppLanguage.string(isSeries ? .detailRatingHintEditingSeries : .detailRatingHintEditing, locale: locale)
        case .editingNone:
            return AppLanguage.string(.detailRatingHintEditingNone, locale: locale)
        case .saved(let isSeries):
            return AppLanguage.string(isSeries ? .detailRatingSavedSeries : .detailRatingSaved, locale: locale)
        case .removed:
            return AppLanguage.string(.detailRatingRemoved, locale: locale)
        }
    }
}
#endif

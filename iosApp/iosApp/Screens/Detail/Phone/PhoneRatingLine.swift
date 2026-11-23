#if !os(tvOS)
import SwiftUI

/// What a movie or series hero needs to draw the viewer's own rating. Only
/// pages that can rate pass one (see `ItemDetailViewModel.canRate`).
struct PhoneRatingSlot {
    /// The page's saved rating (optimistic while a write runs).
    let score: RatingScore
    /// Marks the chip with the accent outline while unrated.
    let isWatched: Bool
    let controller: PhoneRatingController
}

extension View {
    /// Hosts a title page's rating control: a tap anywhere outside the open
    /// row commits it, as does the page going away; removals show the Undo
    /// toast at the bottom. `savedScore` is the page's saved rating and
    /// `write` saves one (nil removes it).
    func phoneRatingPage(
        _ controller: PhoneRatingController,
        savedScore: RatingScore,
        write: @escaping (Int?) -> Void
    ) -> some View {
        modifier(PhoneRatingPageHost(controller: controller, savedScore: savedScore, write: write))
    }
}

private struct PhoneRatingPageHost: ViewModifier {
    let controller: PhoneRatingController
    let savedScore: RatingScore
    let write: (Int?) -> Void

    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        content
            .coordinateSpace(.named(PhoneRatingController.pageSpace))
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named(PhoneRatingController.pageSpace))
                    .onEnded { controller.pageTapped(at: $0.location) },
                including: controller.editor.isOpen ? .all : .subviews
            )
            .undoToast(toast) {
                controller.undo()
            } onTimeout: { id in
                controller.dismissRemoval(id: id)
            }
            .onAppear { controller.send = write }
            .onDisappear { controller.commit() }
    }

    /// The removal toast, while the rating it removed is still gone. A
    /// removal the server refused puts the rating back and hides it.
    private var toast: UndoToastContent? {
        guard let removal = controller.editor.removal,
              !controller.editor.shown(saved: savedScore).isRated else { return nil }
        return UndoToastContent(
            id: removal.id,
            message: AppLanguage.string(.detailRatingRemoved, locale: locale),
            actionTitle: AppLanguage.string(.detailRatingUndo, locale: locale),
            actionColor: .siloRatingStar
        )
    }
}

/// The hero line under the facts: the external scores and, after them, the
/// rating chip, which opens into the rating row in place. The line keeps one
/// height in both states so nothing below it moves, and scores drop from the
/// end before the chip loses room.
struct PhoneRatingLine: View {
    let ratings: [DisplayRating]
    let ratingSize: CGFloat
    /// The most scores shown; they drop from the end when the line is short.
    let ratingLimit: Int
    let alignment: Alignment
    let slot: PhoneRatingSlot

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Namespace private var starSpace
    @State private var width: CGFloat = 0

    private var controller: PhoneRatingController { slot.controller }
    private var isOpen: Bool { controller.editor.isOpen }
    /// At accessibility text sizes the open row takes two lines, and the
    /// line keeps that height closed too.
    private var stacksRow: Bool { dynamicTypeSize.isAccessibilitySize }
    private var shownScore: RatingScore { controller.editor.shown(saved: slot.score) }
    private var lineHeight: CGFloat {
        stacksRow ? PhoneRatingRowFit.lineHeight * 2 + PhoneRatingRowFit.gap : PhoneRatingRowFit.lineHeight
    }

    var body: some View {
        ZStack(alignment: alignment) {
            if isOpen {
                PhoneRatingRow(
                    controller: controller,
                    fit: PhoneRatingRowFit(width: width, stacked: stacksRow),
                    stacked: stacksRow,
                    starSpace: reduceMotion ? nil : starSpace
                )
                .transition(swapTransition)
            } else {
                closedLine
                    .transition(swapTransition)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .frame(height: lineHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : SiloTheme.springAnimation, value: isOpen)
        .animation(reduceMotion ? nil : SiloTheme.springAnimation, value: shownScore)
        .onChange(of: slot.score) { _, _ in controller.savedRatingChanged() }
        #if os(iOS)
        .sensoryFeedback(.impact(weight: .medium), trigger: controller.savedCount)
        .sensoryFeedback(.impact(weight: .light), trigger: controller.removedCount)
        #endif
    }

    /// The outgoing layout clears quickly and the incoming one fades in just
    /// behind it, so the scores and the stars never sit on top of each other
    /// while the star and the value travel. Reduce Motion keeps a plain
    /// cross-fade.
    private var swapTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.16).delay(0.06)),
            removal: .opacity.animation(.easeOut(duration: 0.08))
        )
    }

    private var closedLine: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                ForEach(Array(DisplayRating.rowCandidates(ratings, limit: ratingLimit).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, rating in
                            RatingEntryView(rating: rating, size: ratingSize)
                        }
                    }
                    .padding(.trailing, 14)
                }
                // With no room for any score the chip sits alone.
                Color.clear.frame(width: 0, height: 0)
            }
            .foregroundStyle(Color.siloOnSurface)

            PhoneRatingChip(
                score: shownScore,
                isWatched: slot.isWatched,
                starSpace: reduceMotion ? nil : starSpace
            ) {
                controller.open(saved: shownScore)
            }
            .layoutPriority(1)
        }
    }
}

/// The open row's measurements: the design's 332pt row, with star cells
/// shrinking from 36pt to 28pt on a narrower line, then the readout dropping.
struct PhoneRatingRowFit: Equatable {
    static let lineHeight: CGFloat = 44
    static let gap: CGFloat = 6
    static let clearWidth: CGFloat = 52
    static let controlHeight: CGFloat = 36
    static let trackInset: CGFloat = 16
    static let readoutWidth: CGFloat = 30
    static let doneSize: CGFloat = 36
    static let fullCell: CGFloat = 36
    static let minimumCell: CGFloat = 28
    /// Below this a cell stops shrinking even without the readout.
    static let smallestCell: CGFloat = 22

    let cell: CGFloat
    let showsReadout: Bool

    /// `width` is the line's; 0 (not measured yet) gives the full row.
    /// `stacked` puts the track on a line of its own.
    init(width: CGFloat, stacked: Bool = false) {
        guard width > 0 else {
            self.init(cell: Self.fullCell, showsReadout: true)
            return
        }
        if stacked {
            let cell = (width - Self.trackInset) / CGFloat(RatingScore.starCount)
            self.init(cell: min(Self.fullCell, max(Self.smallestCell, cell)), showsReadout: true)
            return
        }
        let buttons = Self.clearWidth + Self.doneSize + Self.trackInset
        let withReadout = (width - buttons - Self.readoutWidth - 3 * Self.gap) / CGFloat(RatingScore.starCount)
        if withReadout >= Self.minimumCell {
            self.init(cell: min(Self.fullCell, withReadout), showsReadout: true)
        } else {
            let withoutReadout = (width - buttons - 2 * Self.gap) / CGFloat(RatingScore.starCount)
            self.init(cell: min(Self.fullCell, max(Self.smallestCell, withoutReadout)), showsReadout: false)
        }
    }

    init(cell: CGFloat, showsReadout: Bool) {
        self.cell = cell
        self.showsReadout = showsReadout
    }

    /// The design's 32pt star in a 36pt cell.
    var starSize: CGFloat { (cell * 32 / 36).rounded() }
    var trackWidth: CGFloat { Self.trackInset + cell * CGFloat(RatingScore.starCount) }
}

private enum RatingPalette {
    static let mutedText = Color(hex: "#A9ADB8")
    static let chipBorder = Color(hex: "#2A2E38")
    static let nudgeFill = Color(hex: "#1A1D25")
    static let clearFill = Color(hex: "#1C1F26")
    static let clearText = Color(hex: "#C9CCD3")
    static let doneGlyph = Color(hex: "#0B0D12")
}

private let ratingStarMatchID = "rating-star"
/// Track movement under this is a tap, not a drag.
private let ratingTapSlop: CGFloat = 6
private let ratingValueMatchID = "rating-value"

// MARK: - Chip

/// The closed control: "Rate" with an outline star, an accent outline when
/// the title is watched but unrated, or "You ★ 4.5" once rated.
private struct PhoneRatingChip: View {
    let score: RatingScore
    let isWatched: Bool
    let starSpace: Namespace.ID?
    let action: () -> Void

    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .subheadline) private var starSize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 32

    private var isRated: Bool { score.isRated }
    private var nudges: Bool { isWatched && !isRated }

    private var valueWeight: Font.Weight {
        if isRated { return .bold }
        return nudges ? .semibold : .medium
    }

    private var borderColor: Color {
        if isRated { return .clear }
        return nudges ? .siloRatingStar : RatingPalette.chipBorder
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isRated {
                    Text(.detailRatingYou)
                        .siloScaledFont(size: 14, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(RatingPalette.mutedText)
                }
                star
                    .frame(width: starSize, height: starSize)
                    .matchedRating(ratingStarMatchID, starSpace)
                Text(isRated ? score.display(locale: locale) : AppLanguage.string(.detailRatingRate, locale: locale))
                    .siloScaledFont(
                        size: isRated ? 16 : 14,
                        weight: valueWeight,
                        relativeTo: .subheadline
                    )
                    .monospacedDigit()
                    .foregroundStyle(isRated || nudges ? Color.white : RatingPalette.mutedText)
                    .contentTransition(.numericText(value: score.stars))
                    .matchedRating(ratingValueMatchID, isRated ? starSpace : nil)
            }
            .lineLimit(1)
            .padding(.horizontal, isRated ? 2 : 11)
            .frame(height: min(height, 40))
            .background(Capsule().fill(nudges ? RatingPalette.nudgeFill : Color.clear))
            .overlay(
                Capsule().strokeBorder(borderColor, lineWidth: 1)
            )
            .frame(minHeight: PhoneRatingRowFit.lineHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(
            isRated
                ? Text(.detailRatingA11YYours(score.display(locale: locale)))
                : Text(.detailRatingA11YRateThis)
        )
        .accessibilityHint(isRated ? Text(.detailRatingA11YChange) : Text(verbatim: ""))
    }

    /// The design's chip star: stroked at 2 of its 24 units, filled when rated.
    private var star: some View {
        ZStack {
            if isRated {
                RatingStarShape().fill(Color.siloRatingStar)
            }
            RatingStarShape().stroke(
                isRated || nudges ? Color.siloRatingStar : RatingPalette.mutedText,
                style: StrokeStyle(lineWidth: starSize * 2 / 24, lineJoin: .round)
            )
        }
    }
}

// MARK: - Open row

/// Clear, the star track, the draft's readout and Done.
private struct PhoneRatingRow: View {
    let controller: PhoneRatingController
    let fit: PhoneRatingRowFit
    let stacked: Bool
    let starSpace: Namespace.ID?

    @Environment(\.locale) private var locale
    /// The readout grows with the text only on the stacked row, which has
    /// the room; the one-line row keeps the design's 30pt.
    @ScaledMetric(relativeTo: .callout) private var stackedReadoutWidth: CGFloat = PhoneRatingRowFit.readoutWidth

    private var draft: RatingScore { controller.editor.draft }

    var body: some View {
        Group {
            if stacked {
                VStack(spacing: PhoneRatingRowFit.gap) {
                    // Balances the track's leading inset so the stars centre.
                    track.padding(.trailing, PhoneRatingRowFit.trackInset)
                    HStack(spacing: PhoneRatingRowFit.gap) {
                        clearButton
                        readout
                        doneButton
                    }
                    .frame(height: PhoneRatingRowFit.lineHeight)
                }
            } else {
                HStack(spacing: PhoneRatingRowFit.gap) {
                    clearButton
                    track
                    if fit.showsReadout { readout }
                    doneButton
                }
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(PhoneRatingController.pageSpace))
        } action: { frame in
            controller.openRowFrame = frame
        }
        .onDisappear { controller.openRowFrame = .null }
    }

    private var track: some View {
        PhoneRatingTrack(
            draft: draft,
            fit: fit,
            starSpace: starSpace,
            onChange: { controller.setDraft($0) },
            onDone: { controller.commit() },
            onCancel: { controller.cancel() }
        )
    }

    private var clearButton: some View {
        Button { controller.clear() } label: {
            Text(.detailRatingClear)
                .siloScaledFont(size: 13, weight: .medium, relativeTo: .footnote)
                .foregroundStyle(RatingPalette.clearText)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minWidth: PhoneRatingRowFit.clearWidth, minHeight: PhoneRatingRowFit.controlHeight)
                .background(Capsule().fill(RatingPalette.clearFill))
                .frame(minHeight: PhoneRatingRowFit.lineHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        // Keeps its place while the draft has no stars, so the track never shifts.
        .opacity(draft.isRated ? 1 : 0)
        .allowsHitTesting(draft.isRated)
        .accessibilityHidden(!draft.isRated)
        .accessibilityLabel(Text(.detailRatingA11YRemove))
        .animation(.easeInOut(duration: 0.15), value: draft.isRated)
    }

    private var readout: some View {
        Text(draft.isRated ? draft.display(locale: locale) : "")
            .siloScaledFont(size: 16, weight: .bold, relativeTo: .callout)
            .monospacedDigit()
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .matchedRating(ratingValueMatchID, starSpace)
            .frame(width: stacked ? stackedReadoutWidth : PhoneRatingRowFit.readoutWidth)
            .accessibilityHidden(true)
    }

    private var doneButton: some View {
        Button { controller.commit() } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(RatingPalette.doneGlyph)
                .frame(width: PhoneRatingRowFit.doneSize, height: PhoneRatingRowFit.doneSize)
                .background(Circle().fill(Color.white))
                .frame(width: PhoneRatingRowFit.lineHeight, height: PhoneRatingRowFit.lineHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The hit area is wider than the circle; keep the circle on the grid.
        .padding(.horizontal, -(PhoneRatingRowFit.lineHeight - PhoneRatingRowFit.doneSize) / 2)
        .accessibilityLabel(Text(.commonDone))
    }
}

// MARK: - Track

/// Five stars the viewer drags across or taps. A drag follows the finger in
/// half stars; a tap fills the star under it, and tapping the star that
/// already is the whole value steps it to its half. The draft is all it
/// changes; the row commits.
private struct PhoneRatingTrack: View {
    let draft: RatingScore
    let fit: PhoneRatingRowFit
    let starSpace: Namespace.ID?
    let onChange: (RatingScore) -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    @FocusState private var isFocused: Bool
    @AccessibilityFocusState private var isAccessibilityFocused: Bool
    /// One counter per star; each bump pops that star once.
    @State private var pops = Array(repeating: 0, count: RatingScore.starCount)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<RatingScore.starCount, id: \.self) { index in
                RatingStarView(fill: draft.fill(ofStar: index), size: fit.starSize)
                    .keyframeAnimator(initialValue: CGFloat(1), trigger: pops[index]) { star, scale in
                        star.scaleEffect(scale)
                    } keyframes: { _ in
                        SpringKeyframe(1.18, duration: 0.08, spring: .snappy)
                        SpringKeyframe(1, duration: 0.1, spring: .smooth)
                    }
                    .matchedRating(ratingStarMatchID, index == 0 ? starSpace : nil)
                    .frame(width: fit.cell, height: PhoneRatingRowFit.lineHeight)
            }
        }
        .padding(.leading, PhoneRatingRowFit.trackInset)
        .frame(width: fit.trackWidth, height: PhoneRatingRowFit.lineHeight)
        .contentShape(Rectangle())
        .ratingTrackInput(
            leadingOffset: { x in
                // Measured from the first cell's leading edge.
                RatingScore.leadingOffset(
                    x: x,
                    width: fit.trackWidth,
                    isRightToLeft: layoutDirection == .rightToLeft && Self.locationsStartAtLeft
                ) - PhoneRatingRowFit.trackInset
            },
            onDrag: { x in
                onChange(RatingScore.fromTrack(x: x, cellWidth: fit.cell))
            },
            onTap: { x in
                onChange(RatingScore.tapped(x: x, cellWidth: fit.cell, current: draft))
            }
        )
        .onChange(of: draft) { old, new in
            guard !reduceMotion else { return }
            for index in 0..<RatingScore.starCount
            where new.fill(ofStar: index) == .full && old.fill(ofStar: index) != .full {
                pops[index] += 1
            }
        }
        #if os(iOS)
        .sensoryFeedback(trigger: draft) { _, new in
            // The ends are felt a little firmer than each half star between.
            new.isRated && !new.isMax ? .selection : .impact(weight: .light)
        }
        #endif
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let forward: Bool
            switch press.key {
            case .upArrow: forward = true
            case .downArrow: forward = false
            case .rightArrow: forward = layoutDirection == .leftToRight
            default: forward = layoutDirection == .rightToLeft
            }
            onChange(forward ? draft.steppedUp : draft.steppedDown)
            return .handled
        }
        .onKeyPress(.return) { onDone(); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(.detailRatingA11YLabel))
        .accessibilityValue(Text(draft.accessibilityValue(locale: locale)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(draft.steppedUp)
            case .decrement: onChange(draft.steppedDown)
            @unknown default: break
            }
        }
        .accessibilityAction(.escape) { onCancel() }
        .accessibilityFocused($isAccessibilityFocused)
        .onAppear {
            isFocused = true
            isAccessibilityFocused = true
        }
    }

    /// Whether the input below reports x from the track's left edge even
    /// right to left. UIKit's touch locations do (checked on an iOS 27
    /// simulator in Arabic: the fill ran from the wrong end until mirrored).
    #if os(iOS)
    private static let locationsStartAtLeft = true
    #else
    private static let locationsStartAtLeft = false
    #endif
}

private extension View {
    /// The chip's star and the track's first star share one identity, as do
    /// the chip's value and the readout, so each travels between the two as
    /// the row opens and closes. Nil (Reduce Motion) leaves the plain
    /// cross-fade.
    @ViewBuilder
    func matchedRating(_ id: String, _ namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace, properties: .position)
        } else {
            self
        }
    }
}

// MARK: - Track input

private extension View {
    /// Drag and tap on the star track. `leadingOffset` turns a location's x
    /// in the track's own coordinates into the distance the score math
    /// expects.
    func ratingTrackInput(
        leadingOffset: @escaping (_ x: CGFloat) -> CGFloat,
        onDrag: @escaping (CGFloat) -> Void,
        onTap: @escaping (CGFloat) -> Void
    ) -> some View {
        #if os(iOS)
        gesture(RatingTrackGesture(leadingOffset: leadingOffset, onDrag: onDrag, onTap: onTap))
        #else
        modifier(RatingTrackDrag(leadingOffset: leadingOffset, onDrag: onDrag, onTap: onTap))
        #endif
    }
}

#if os(iOS)
/// A tap or a horizontal drag on the track. The drag claims the touch once it
/// has moved 6pt more sideways than up or down, ahead of the page's scroll; a
/// clearly vertical movement fails it, so the page scrolls. Once claimed it
/// keeps tracking wherever the finger goes.
private struct RatingTrackGesture: UIGestureRecognizerRepresentable {
    let leadingOffset: (CGFloat) -> CGFloat
    let onDrag: (CGFloat) -> Void
    let onTap: (CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> Recognizer {
        Recognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        let x = leadingOffset(context.converter.localLocation.x)
        switch recognizer.state {
        case .began, .changed:
            onDrag(x)
        case .ended:
            recognizer.endedAsTap ? onTap(x) : onDrag(x)
        default:
            break
        }
    }

    final class Recognizer: UIGestureRecognizer {
        private var start: CGPoint?
        private(set) var endedAsTap = false

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard start == nil, touches.count == 1, let touch = touches.first else {
                if state == .possible { state = .failed }
                return
            }
            start = touch.location(in: view)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let start, let point = touches.first?.location(in: view) else { return }
            guard state == .possible else {
                state = .changed
                return
            }
            let dx = point.x - start.x
            let dy = point.y - start.y
            guard dx * dx + dy * dy >= ratingTapSlop * ratingTapSlop else { return }
            state = abs(dx) >= abs(dy) ? .began : .failed
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            switch state {
            case .possible:
                endedAsTap = true
                state = .ended
            case .began, .changed:
                state = .ended
            default:
                break
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            state = state == .possible ? .failed : .cancelled
        }

        override func reset() {
            super.reset()
            start = nil
            endedAsTap = false
        }
    }
}
#else
/// Click and click-drag on the Mac: under `ratingTapSlop` of movement is a
/// click.
private struct RatingTrackDrag: ViewModifier {
    let leadingOffset: (CGFloat) -> CGFloat
    let onDrag: (CGFloat) -> Void
    let onTap: (CGFloat) -> Void

    @State private var isDragging = false

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let moved = hypot(value.translation.width, value.translation.height)
                        guard isDragging || moved >= ratingTapSlop else { return }
                        isDragging = true
                        onDrag(leadingOffset(value.location.x))
                    }
                    .onEnded { value in
                        let x = leadingOffset(value.location.x)
                        isDragging ? onDrag(x) : onTap(x)
                        isDragging = false
                    }
            )
    }
}
#endif
#endif

#if !os(tvOS)
import SwiftUI

/// A–Z index on the trailing edge of a title-ordered library grid on iPhone,
/// iPad and Mac, like Contacts' section index.
///
/// Dragging along the rail previews letters with a selection tick and a
/// bubble; the grid jumps to a letter's first title when the finger rests on
/// it or lifts, so a drag across the alphabet scrolls the grid once, not once
/// per letter. The whole library stays in the grid, so the titles before the
/// letter are a scroll away. Letters with no titles are dimmed; a touch on
/// one goes to the next letter that has some. The letter jumped to stays
/// softly marked until the grid is scrolled by hand; the index doesn't track
/// the letter at the top while scrolling, which would cost work every frame.
struct BrowseLetterIndex: View {
    /// Letters with at least one title, from the catalog's letter index.
    let available: Set<String>
    /// The letter last jumped to, marked until the grid is scrolled.
    let jumped: JumpedLetter
    /// Called when a touch starts, before any jump.
    let onEngage: () -> Void
    /// Called with each letter the finger reaches, before it rests or lifts
    /// there, so the grid can read that letter's titles ahead of the jump.
    var onPreview: (String) -> Void = { _ in }
    let onJump: (String) -> Void

    /// Room the grid leaves on its trailing edge. The index takes touches
    /// across all of it, wider than the letters themselves.
    static let reservedWidth: CGFloat = 28

    /// "#" holds titles that start with a digit, a symbol or another script.
    private static let entries = ["#"] + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }
    private static let railWidth: CGFloat = 20
    private static let maxRowHeight: CGFloat = 17
    /// Below this, rows alternate letters with dots, as UIKit's index does
    /// in a short window, while touches still reach every letter.
    private static let minRowHeight: CGFloat = 13
    private static let bubbleSize: CGFloat = 64
    private static let bubbleGap: CGFloat = 18
    /// How far from the finger letters still swell (points).
    private static let lensRadius: CGFloat = 54

    /// Where the finger is along the rail while it is down. Resets on its own
    /// when the system cancels the touch.
    @GestureState(resetTransaction: Transaction(animation: BrowseLetterIndex.settle))
    private var fingerY: CGFloat?
    /// Whether the last move went down the alphabet; picks the way the
    /// bubble's letter rolls.
    @State private var movedDown = true
    /// The letter this touch last jumped to, so lifting the finger on the
    /// letter it rested on doesn't jump again.
    @State private var jumpedThisTouch: String?
    /// The last letter jumped to, where VoiceOver's adjustments step from.
    @State private var lastJumped: String?
    @Namespace private var markSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private static let settle = Animation.spring(response: 0.34, dampingFraction: 0.78)
    /// How long the finger rests on a letter before the grid jumps to it.
    private static let restDelay: Duration = .milliseconds(220)

    var body: some View {
        GeometryReader { proxy in
            let height = min(proxy.size.height, CGFloat(Self.entries.count) * Self.maxRowHeight)
            rail(height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.reservedWidth)
        .padding(.vertical, SiloTheme.smallPadding)
    }

    // MARK: - Rail

    private func rail(height: CGFloat) -> some View {
        let touched = fingerY.map { Self.entryIndex(at: $0, height: height) }
        let target = touched.flatMap(target(for:))
        let marked = jumped.letter.flatMap { Self.entries.firstIndex(of: $0) }
        let rows = Self.rows(height: height, showing: [marked, touched].compactMap { $0 })
        let rowHeight = height / CGFloat(rows.count)
        return VStack(spacing: 0) {
            ForEach(rows) { row in
                rowView(row, rowHeight: rowHeight, touchedEntry: touched)
            }
        }
        .frame(width: Self.railWidth, height: height)
        .overlay(alignment: .topTrailing) {
            if let touched, let target {
                bubble(for: target)
                    .padding(.trailing, Self.railWidth + Self.bubbleGap)
                    .offset(y: Self.entryCenter(touched, height: height) - Self.bubbleSize / 2)
                    .transition(bubbleTransition)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: Self.reservedWidth, height: height)
        .contentShape(Rectangle())
        .gesture(drag(height: height))
        .onChange(of: touched != nil) { _, isTouching in
            if isTouching { onEngage() }
        }
        .onChange(of: target) { old, new in
            if let old, let new,
               let oldIndex = Self.entries.firstIndex(of: old), let newIndex = Self.entries.firstIndex(of: new) {
                movedDown = newIndex > oldIndex
            }
            if let new { onPreview(new) }
        }
        // A resting finger jumps; a moving one only previews. The task
        // restarts with each new letter and ends when the finger lifts.
        .task(id: target) {
            guard let target else { return }
            try? await Task.sleep(for: Self.restDelay)
            guard !Task.isCancelled else { return }
            jump(to: target)
        }
        .sensoryFeedback(.selection, trigger: target) { _, new in new != nil }
        // The lens follows the finger directly; only the touch starting,
        // ending and moving to another letter animate.
        .animation(reduceMotion ? .easeOut(duration: SiloTheme.fastDuration) : Self.settle, value: touched)
        .animation(reduceMotion ? .easeOut(duration: SiloTheme.fastDuration) : Self.settle, value: jumped.letter)
        .accessibilityElement()
        .accessibilityLabel(Text(.libraryDirectionAz))
        .accessibilityValue(lastJumped.map(Self.accessibilityValue(for:)) ?? Text(verbatim: ""))
        .accessibilityAdjustableAction { direction in
            let letters = Self.entries.filter(available.contains)
            guard !letters.isEmpty else { return }
            let at = lastJumped.flatMap { letters.firstIndex(of: $0) }
            let next: Int
            switch direction {
            case .increment: next = at.map { min($0 + 1, letters.count - 1) } ?? 0
            case .decrement: next = at.map { max($0 - 1, 0) } ?? 0
            @unknown default: return
            }
            lastJumped = letters[next]
            jumped.letter = letters[next]
            onJump(letters[next])
        }
    }

    private func rowView(_ row: Row, rowHeight: CGFloat, touchedEntry: Int?) -> some View {
        let entry = Self.entries[row.entry]
        let isTouched = !row.isDot && row.entry == touchedEntry
        let isMarked = !row.isDot && entry == jumped.letter
        let hasTitles = available.contains(entry)
        let swell = reduceMotion ? 0 : lensAmount(rowCenter: (CGFloat(row.id) + 0.5) * rowHeight)
        let fontSize = min(11.5, rowHeight * 0.74)
        return label(for: row, entry: entry)
            .font(.system(size: fontSize, weight: isTouched || isMarked ? .heavy : .semibold, design: .rounded))
            .foregroundStyle(isTouched || isMarked || swell > 0.5 ? Color.siloOnSurface : Color.siloSecondaryText)
            .opacity(hasTitles || row.isDot ? 1 : 0.35)
            .frame(width: Self.railWidth, height: rowHeight)
            .background {
                if isMarked {
                    // A soft disc, not a solid one: a reminder of where the
                    // jump went, quieter than the bubble.
                    Circle()
                        .fill(Color.siloOnSurface.opacity(0.18))
                        .frame(width: min(rowHeight + 4, 20), height: min(rowHeight + 4, 20))
                        .matchedGeometryEffect(id: "jumped", in: markSpace)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .scaleEffect(1 + 0.55 * swell)
            // Leans toward the grid: trailing room pushes it to the leading
            // side in either reading direction.
            .padding(.trailing, 10 * swell)
            .frame(width: Self.railWidth, alignment: .trailing)
    }

    @ViewBuilder
    private func label(for row: Row, entry: String) -> some View {
        if row.isDot {
            Circle().frame(width: 3, height: 3)
        } else {
            Text(verbatim: entry)
        }
    }

    /// 0 away from the finger, 1 under it, eased so the swell reads as a lens
    /// rather than a cone.
    private func lensAmount(rowCenter: CGFloat) -> CGFloat {
        guard let fingerY else { return 0 }
        let t = max(0, 1 - abs(fingerY - rowCenter) / Self.lensRadius)
        return t * t * (3 - 2 * t)
    }

    /// The letter a touch on `entry` goes to: itself when it has titles,
    /// otherwise the next letter that does, or the last one before it.
    private func target(for entry: Int) -> String? {
        let entries = Self.entries
        return entries[entry...].first(where: available.contains)
            ?? entries[..<entry].last(where: available.contains)
    }

    // MARK: - Bubble

    private func bubble(for letter: String) -> some View {
        Text(verbatim: letter)
            .font(.system(size: 32, weight: .bold, design: .rounded))
            .contentTransition(.numericText(countsDown: !movedDown))
            .foregroundStyle(Color.siloBackground)
            .frame(width: Self.bubbleSize, height: Self.bubbleSize)
            .background(Circle().fill(Color.siloOnSurface))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    /// Grows out of the rail and shrinks back into it.
    private var bubbleTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let rail: UnitPoint = layoutDirection == .rightToLeft ? .leading : .trailing
        return .asymmetric(
            insertion: .scale(scale: 0.4, anchor: rail).combined(with: .opacity),
            removal: .scale(scale: 0.25, anchor: rail).combined(with: .opacity)
        )
    }

    // MARK: - Touch

    private func drag(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($fingerY) { value, state, _ in
                state = min(max(value.location.y, 0), height)
            }
            .onEnded { value in
                let lifted = self.target(for: Self.entryIndex(at: min(max(value.location.y, 0), height), height: height))
                if let lifted, lifted != jumpedThisTouch { jump(to: lifted) }
                jumpedThisTouch = nil
            }
    }

    private func jump(to letter: String) {
        jumpedThisTouch = letter
        lastJumped = letter
        jumped.letter = letter
        onJump(letter)
    }

    // MARK: - Layout

    private struct Row: Identifiable {
        let id: Int
        /// The entry this row stands for and that a touch on its centre picks.
        let entry: Int
        let isDot: Bool
    }

    /// Every entry when the rail is tall enough; otherwise an odd number of
    /// rows alternating letters and dots, each row standing for the entry its
    /// centre maps to, so a letter's label sits where a touch picks it. The
    /// entry under the finger takes over the row it falls in, so it never
    /// hides behind a dot or a neighbour.
    private static func rows(height: CGFloat, showing shown: [Int]) -> [Row] {
        let count = entries.count
        guard height < CGFloat(count) * minRowHeight else {
            return (0..<count).map { Row(id: $0, entry: $0, isDot: false) }
        }
        var rowCount = max(3, Int(height / minRowHeight))
        if rowCount.isMultiple(of: 2) { rowCount -= 1 }
        var rows = (0..<rowCount).map { row in
            let entry = min(count - 1, Int((CGFloat(row) + 0.5) / CGFloat(rowCount) * CGFloat(count)))
            return Row(id: row, entry: entry, isDot: !row.isMultiple(of: 2))
        }
        for entry in shown {
            let row = min(rowCount - 1, Int((CGFloat(entry) + 0.5) / CGFloat(count) * CGFloat(rowCount)))
            rows[row] = Row(id: row, entry: entry, isDot: false)
        }
        return rows
    }

    private static func entryIndex(at y: CGFloat, height: CGFloat) -> Int {
        guard height > 0 else { return 0 }
        let index = Int(y / height * CGFloat(entries.count))
        return min(max(index, 0), entries.count - 1)
    }

    private static func entryCenter(_ index: Int, height: CGFloat) -> CGFloat {
        (CGFloat(index) + 0.5) * height / CGFloat(entries.count)
    }

    private static func accessibilityValue(for letter: String) -> Text {
        letter == "#" ? Text(.libraryStartsWithSymbol) : Text(.libraryStartsWithLetter(letter))
    }
}
#endif

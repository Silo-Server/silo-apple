#if !os(tvOS)
import SwiftUI

// MARK: - Labelled secondary action

/// One named secondary action: a filled circle over a caption.
struct PhoneLabeledAction: View {
    let icon: String
    var iconActive: String? = nil
    var isActive: Bool = false
    let label: String
    /// Spoken instead of `label` when set, so VoiceOver can say "Remove from
    /// Favorites" where the visual only changes tint and fill. A caption that
    /// reads the same in both states tells a VoiceOver user neither what is
    /// true now nor what activating will do.
    var accessibilityLabelOverride: String? = nil
    /// False for one-shot commands (Start Over, Delete), which have no
    /// on/off state for VoiceOver to announce.
    var isToggle = true
    let action: () -> Void

    @State private var toggleCount = 0

    private var resolvedIcon: String {
        if isActive, let iconActive { return iconActive }
        return icon
    }

    var body: some View {
        Button {
            if isToggle { toggleCount += 1 }
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: resolvedIcon)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color.siloOnSurface)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle().fill(Color.white.opacity(isActive ? 0.18 : 0.10))
                    )
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))

                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.siloOnSurface.opacity(isActive ? 0.92 : 0.6))
                    .phoneActionCaption()
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Lands with the optimistic icon flip; a failed change reverts the
        // icon and raises the page's notice alert instead.
        .sensoryFeedback(.impact(weight: .light), trigger: toggleCount)
        .accessibilityLabel(accessibilityLabelOverride ?? label)
        .accessibilityValue(isToggle ? (isActive ? "On" : "Off") : "")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// Menu-backed peer of `PhoneLabeledAction`, for the overflow entry.
struct PhoneLabeledMenu<MenuContent: View>: View {
    var icon: String = "ellipsis"
    let label: String
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        Menu {
            menu()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color.siloOnSurface)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.6))
                    .phoneActionCaption()
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        #if os(macOS)
        // A Mac menu flattens its label into a bordered text button with a
        // chevron; the plain button style keeps the circle-over-caption
        // label so More matches the actions beside it.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        #endif
        .accessibilityLabel(label)
    }
}

// MARK: - Action row container

/// Evenly distributes the named actions across the content width and rules
/// them off from the overview below, so the cluster reads as one band of
/// controls rather than loose ornaments. When large text makes a caption too
/// wide for its share of the row, the actions wrap onto balanced lines
/// instead of breaking the caption inside a word.
struct PhoneLabeledActionRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 12) {
            PhoneLabeledActionLayout {
                content()
            }
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }
}

extension View {
    /// Caption treatment for every entry in `PhoneLabeledActionRow`: one
    /// line, shrinking slightly before the row wraps onto another line.
    func phoneActionCaption() -> some View {
        lineLimit(1)
            .minimumScaleFactor(PhoneLabeledActionColumns.minimumCaptionScale)
            .multilineTextAlignment(.center)
    }
}

/// How many equal-width columns the action row uses.
enum PhoneLabeledActionColumns {
    /// Captions may shrink this far to stay on one row.
    static let minimumCaptionScale: CGFloat = 0.8

    /// Every action on one line while the widest one fits its equal share
    /// (allowing its caption to shrink to `minimumCaptionScale`). Otherwise
    /// the fewest lines that fit, balanced so five actions split 3 + 2
    /// rather than 4 + 1.
    static func count(itemCount: Int, widestItemWidth: CGFloat, availableWidth: CGFloat) -> Int {
        guard itemCount > 0 else { return 0 }
        guard availableWidth.isFinite, availableWidth > 0 else { return itemCount }
        let required = widestItemWidth * minimumCaptionScale
        var columns = itemCount
        while columns > 1, availableWidth / CGFloat(columns) < required {
            columns -= 1
        }
        let lines = (itemCount + columns - 1) / columns
        return (itemCount + lines - 1) / lines
    }
}

/// Equal-width columns, wrapping onto centred lines when
/// `PhoneLabeledActionColumns` asks for fewer columns than actions. With one
/// line this matches an `HStack(alignment: .top, spacing: 0)` of
/// full-width actions.
struct PhoneLabeledActionLayout: Layout {
    var lineSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let widest = widestIdealWidth(subviews)
        let width = proposal.width ?? widest * CGFloat(subviews.count)
        let lines = lines(subviews: subviews, width: width, widest: widest)
        let height = lines.reduce(0) { $0 + $1.height }
            + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let widest = widestIdealWidth(subviews)
        var y = bounds.minY
        for line in lines(subviews: subviews, width: bounds.width, widest: widest) {
            let lineWidth = line.columnWidth * CGFloat(line.indices.count)
            var x = bounds.minX + (bounds.width - lineWidth) / 2
            for index in line.indices {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: line.columnWidth, height: nil)
                )
                x += line.columnWidth
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: Range<Int>
        var columnWidth: CGFloat
        var height: CGFloat
    }

    private func widestIdealWidth(_ subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }

    private func lines(subviews: Subviews, width: CGFloat, widest: CGFloat) -> [Line] {
        let columns = PhoneLabeledActionColumns.count(
            itemCount: subviews.count,
            widestItemWidth: widest,
            availableWidth: width
        )
        let columnWidth = width / CGFloat(columns)
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            let indices = start..<min(start + columns, subviews.count)
            let height = indices.map {
                subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            }.max() ?? 0
            return Line(indices: indices, columnWidth: columnWidth, height: height)
        }
    }
}
#endif

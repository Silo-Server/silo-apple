#if os(iOS)
import SwiftUI

/// One page a dock switches between.
protocol PageDockSegment: Hashable, Identifiable {
    /// Stands in for the title at accessibility text sizes.
    var dockIcon: String { get }
    var dockTitle: LocalizedStringResource { get }
}

/// What a tab gives the dock: its pages, the one on screen, and the button
/// that leads the row. The tab owns it; the tab bar's accessory slot reads
/// it through `PageDockHost`.
@MainActor
protocol PageDockModel: AnyObject, Observable {
    associatedtype Segment: PageDockSegment
    associatedtype LeadingButton: View

    /// The page on screen.
    var selectedTab: Segment { get }
    /// The pages the dock offers now, in order.
    var visibleTabs: [Segment] { get }
    /// Every page the dock can offer, so the leading button stays put when
    /// one is hidden.
    var allTabs: [Segment] { get }
    /// Bumped on every segment tap, for the selection haptic.
    var feedbackCount: Int { get }
    /// The leading button opens something, so its glass responds to touch.
    var leadingButtonIsInteractive: Bool { get }

    /// A segment was tapped: show its page, or scroll the page already on
    /// screen back to its top.
    func select(_ tab: Segment)
    /// A drag across the switcher ended over `tab`: show its page. Ending
    /// where it started changes nothing, and never scrolls to the top.
    func commitDrag(to tab: Segment)
    /// The button that leads the row, drawn for `style`.
    func leadingButton(style: PageDockStyle) -> LeadingButton
}

extension PageDockModel {
    /// The dock for the tab bar's accessory slot.
    func accessory() -> AnyView {
        AnyView(PageDockAccessory(model: self))
    }
}

/// The glyph a dock's leading button shows, sized for the placement.
struct PageDockGlyph: View {
    let systemName: String
    let style: PageDockStyle

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: style.glyphPointSize, weight: .semibold))
            .scaleEffect(style.glyphScale)
            // As bright as an unselected label, so it doesn't outshine them.
            .foregroundStyle(PageDockStyle.unselectedColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}

/// Hands the dock of the tab on screen to the tab bar, which shows it in its
/// bottom accessory slot on iOS 26.1 and later while nothing is playing, so
/// the dock shrinks with the tab bar. One per tab layout, in the environment.
@Observable
@MainActor
final class PageDockHost {
    /// The dock of the tab on screen; nil when that tab has none.
    private(set) var dock: (any PageDockModel)?

    func present(_ dock: any PageDockModel) {
        if self.dock !== dock { self.dock = dock }
    }

    func withdraw(_ dock: any PageDockModel) {
        if self.dock === dock { self.dock = nil }
    }

    /// The tab bar can host the dock: iOS 26.1 and later, where the slot
    /// toggles without rebuilding the tabs. iOS 26.0 could only add the slot
    /// by restructuring the TabView, which would reset every tab whenever
    /// a tab with a dock came and went, so the dock stays in the page there.
    static var slotIsAvailable: Bool {
        if #available(iOS 26.1, *) { return true }
        return false
    }
}

/// How the dock is drawn. The control is the same in every placement; only
/// its size and chrome change.
enum PageDockStyle: Hashable {
    /// Floating in the page: its own glass.
    case floating
    /// In the tab bar's expanded accessory slot, which supplies the glass.
    case accessory
    /// In the slot's inline placement beside a minimised tab bar: smaller.
    case inline

    /// Height of the selected segment's fill, and the side of the leading
    /// icon's box, so the two read as one row.
    var fillHeight: CGFloat {
        isFloating ? 44 : 34
    }

    private var isFloating: Bool { self == .floating }

    /// The labels' size: one size in both slot placements, so the change
    /// between them never draws a label at two sizes.
    var labelFont: Font {
        isFloating ? .siloCaption : .caption2
    }

    /// `labelFont`'s text style and default size, for measuring the labels.
    var labelTextStyle: UIFont.TextStyle { isFloating ? .caption1 : .caption2 }
    var labelBaseSize: CGFloat { isFloating ? 12 : 11 }

    /// The smaller size tried before icons when the labels can't fit (a
    /// narrow phone, a long translation).
    static let fallbackPointSize: CGFloat = 10

    var iconSize: CGFloat {
        switch self {
        case .floating: return 22
        case .accessory: return 19
        case .inline: return 17
        }
    }

    /// The leading glyph is drawn at one size in the slot and scaled for
    /// inline, so it resizes with the placement instead of crossfading.
    var glyphPointSize: CGFloat { isFloating ? 22 : 19 }
    var glyphScale: CGFloat { iconSize / glyphPointSize }

    /// The least room on each side of a segment's label. Inline, the room
    /// left over is shared equally into every segment's padding.
    var labelPadding: CGFloat {
        self == .inline ? 6 : 10
    }

    /// The gap between two segments. Inline, the fills sit edge to edge so
    /// every point goes to label padding.
    var segmentGap: CGFloat {
        self == .inline ? 0 : 4
    }

    /// Inline, the segments fill the width after the leading button, the
    /// room left over shared equally into their padding. Elsewhere they sit
    /// as one tight group at their own widths.
    var segmentsFillWidth: Bool { self == .inline }

    /// The leading cluster in the slot: inset before the icon, the icon's
    /// box, and the gaps either side of the hairline. Inline it tightens to
    /// leave the labels their room.
    var leadingInset: CGFloat? { self == .inline ? 12 : nil }
    /// The leading button's width: fixed inline; in the expanded slot it
    /// grows into the room the tight segments leave, up to `iconBoxMax`.
    var iconBox: CGFloat { self == .inline ? 22 : 44 }
    var iconBoxMax: CGFloat { self == .inline ? 22 : 64 }
    var gapBeforeHairline: CGFloat? { self == .inline ? 10 : nil }
    var gapAfterHairline: CGFloat? { self == .inline ? 8 : nil }

    /// The least room between the selected fill and the capsule's edge.
    static let minimumInset: CGFloat = 4

    /// Unselected labels and the leading glyph: as bright as the tab bar's
    /// own items, so they read as clearly over light artwork.
    static let unselectedColor = Color.primary
}

/// The round leading button and the section switcher.
///
/// One spacing system in every placement: the selected fill sits the same
/// distance from the capsule's top, bottom and trailing edge; the leading
/// icon sits that distance from the leading edge; and a hairline with that
/// distance on each side separates the button from the segments. Segments
/// keep `labelPadding` around their labels and equal gaps between them.
struct PageDock<Model: PageDockModel>: View {
    let model: Model
    var style: PageDockStyle = .floating

    @Namespace private var selection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Height of the slot the dock sits in, for its edge inset.
    @State private var slotHeight: CGFloat = 0
    /// The switcher's width once a placement has stopped resizing, by
    /// placement. The labels' size is chosen from it, never from the
    /// widths the slot passes through while the system animates it.
    @State private var settledWidths: [PageDockStyle: CGFloat] = [:]
    @State private var widthSettle: Task<Void, Never>?
    /// Each segment's frame in the switcher, for following a drag.
    @State private var slotFrames: [Model.Segment: CGRect] = [:]
    /// Where a finger dragging across the switcher is; nil otherwise. A
    /// cancelled drag resets it, which puts the selection back.
    @GestureState(resetTransaction: Transaction(animation: .snappy(duration: 0.25)))
    private var dragX: CGFloat?
    private static var switcherSpace: String { "pageDockSwitcher" }
    @Environment(\.locale) private var locale
    @Environment(\.displayScale) private var displayScale

    private var isFloating: Bool { style == .floating }
    /// At accessibility text sizes the segments show icons; the Large
    /// Content Viewer shows their names.
    private var usesIcons: Bool { dynamicTypeSize.isAccessibilitySize }

    /// The distance from the selected fill to the capsule's edges. Floating,
    /// the dock draws its own capsule around the switcher; in the slot, the
    /// system's capsule is the slot.
    private var edgeInset: CGFloat {
        if isFloating { return PageDockStyle.minimumInset }
        return max(PageDockStyle.minimumInset, ((slotHeight - style.fillHeight) / 2).rounded())
    }

    private static var maxWidth: CGFloat { 480 }
    private static var slotBacking: Color { Color.black.opacity(0.12) }
    private static var floatingHeight: CGFloat { 52 }
    /// Shared by the selected segment's fill and the fill that follows a
    /// drag, so the one hands over to the other smoothly.
    private static var fillID: String { "dockSelection" }

    var body: some View {
        Group {
            if isFloating {
                glassGroup
                    // A phone in landscape keeps the dock a thumb's width, centred.
                    .frame(maxWidth: Self.maxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, SiloTheme.padding)
                    .padding(.vertical, SiloTheme.smallPadding)
            } else {
                slotRow
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: model.selectedTab)
        .sensoryFeedback(.selection, trigger: model.feedbackCount)
    }

    // MARK: Floating

    /// iOS 26 merges the button's and the switcher's Liquid Glass into one
    /// control; iOS 18 draws each in Silo's material glass.
    @ViewBuilder
    private var glassGroup: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: SiloTheme.smallPadding) { floatingRow }
        } else {
            floatingRow
        }
    }

    private var floatingRow: some View {
        // Measured at the width offered, not the row's: labels too wide
        // for the room would otherwise widen the row to fit them, and the
        // dock would never see that they don't.
        PageDockOfferedWidth {
            HStack(spacing: SiloTheme.smallPadding) {
                model.leadingButton(style: style)
                    .frame(width: Self.floatingHeight, height: Self.floatingHeight)
                    .siloGlass(in: Circle(), interactive: model.leadingButtonIsInteractive)
                switcher
                    .padding(edgeInset)
                    .frame(maxWidth: .infinity, minHeight: Self.floatingHeight)
                    .siloGlass(in: Capsule())
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            // As before the labels were fitted here, a row too wide for its
            // room may run into the page's side margins; the labels shrink
            // only when it would run off the screen.
            noteAvailableWidth(width + 2 * SiloTheme.padding - Self.floatingHeight - SiloTheme.smallPadding - 2 * edgeInset)
        }
    }

    // MARK: In the slot

    private var slotRow: some View {
        PageDockSlotRowLayout(
            buttonMinWidth: style.iconBox,
            buttonMaxWidth: style.iconBoxMax,
            referenceSegmentsWidth: fullSetSegmentsWidth
        ) {
            model.leadingButton(style: style)
                .frame(minWidth: style.iconBox, maxWidth: style.iconBoxMax)
                .frame(maxHeight: .infinity)
            Rectangle()
                .fill(Color.siloOnSurface.opacity(0.18))
                .frame(width: 1, height: style.fillHeight * 0.6)
                .padding(.leading, style.gapBeforeHairline ?? edgeInset)
                .padding(.trailing, style.gapAfterHairline ?? edgeInset)
                .accessibilityHidden(true)
            switcher
        }
        .padding(.leading, style.leadingInset ?? edgeInset)
        .padding(.trailing, edgeInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The accessory's glass is clearer than the tab bar's below it;
        // this darkens it to match, filling the slot's capsule.
        .background { Capsule().fill(Self.slotBacking) }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            slotHeight = size.height
            // Expanded, the segments sit as a tight group, so their room is
            // the row less the leading button at its least width and the
            // hairline's gaps. As before the labels were fitted here, a group
            // a little too wide may take the leading inset; they shrink only
            // past that.
            if !style.segmentsFillWidth {
                noteAvailableWidth(size.width - expandedLeadingWidth)
            }
        }
    }

    /// With a section hidden, the width all three labelled segments would
    /// take, so the leading button sits where it does with all three. Nil
    /// when every section shows or the segments are icons.
    private var fullSetSegmentsWidth: CGFloat? {
        let all = model.allTabs
        guard model.visibleTabs.count < all.count, !usesIcons, labelVariant != .icons else { return nil }
        let pointSize: CGFloat? = labelVariant == .smaller ? PageDockStyle.fallbackPointSize : nil
        let labels = all.reduce(0) { total, tab in
            total + PageDockLabelWidths.width(
                of: AppLanguage.string(tab.dockTitle, locale: locale),
                pointSize: pointSize,
                textStyle: style.labelTextStyle,
                baseSize: style.labelBaseSize,
                dynamicTypeSize: dynamicTypeSize,
                roundingScale: displayScale,
                atTextStyleSize: true
            )
        }
        return labels + style.labelPadding * 2 * CGFloat(all.count) + style.segmentGap * CGFloat(all.count - 1)
    }

    /// The expanded slot's leading cluster at its least width.
    private var expandedLeadingWidth: CGFloat {
        (style.leadingInset ?? edgeInset) + style.iconBox
            + (style.gapBeforeHairline ?? edgeInset) + 1 + (style.gapAfterHairline ?? edgeInset)
    }

    // MARK: Switcher

    /// One row of segments, so a placement change never shows two rows.
    /// Its labels are full size; where those can't fit the settled width,
    /// a size smaller; below that, the selected one's label and the
    /// others' icons.
    private var switcher: some View {
        let variant = labelVariant
        return segmentRow(
            font: variant == .regular ? style.labelFont : .system(size: PageDockStyle.fallbackPointSize),
            compactsUnselected: usesIcons || variant == .icons
        )
        .frame(maxWidth: style.segmentsFillWidth ? .infinity : nil, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            // Inline, the segments fill their room, so their width is it.
            if style.segmentsFillWidth { noteAvailableWidth(width) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: LibraryDockPendingText.sectionsLabel))
    }

    private enum LabelVariant { case regular, smaller, icons }

    /// The labels' treatment for the room the segments have once the
    /// placement has settled; full size until that is known.
    private var labelVariant: LabelVariant {
        guard !usesIcons, let width = settledWidths[style] else { return .regular }
        if labelsFit(in: width, pointSize: nil) { return .regular }
        if labelsFit(in: width, pointSize: PageDockStyle.fallbackPointSize) { return .smaller }
        return .icons
    }

    /// Whether every label, in its selected weight with the least padding,
    /// fits `width`. `pointSize` nil is the scaled caption size.
    private func labelsFit(in width: CGFloat, pointSize: CGFloat?) -> Bool {
        let tabs = model.visibleTabs
        let labels = tabs.reduce(0) { total, tab in
            total + PageDockLabelWidths.width(
                of: AppLanguage.string(tab.dockTitle, locale: locale),
                pointSize: pointSize,
                textStyle: style.labelTextStyle,
                baseSize: style.labelBaseSize,
                dynamicTypeSize: dynamicTypeSize,
                // Inline keeps the measure it was tuned with; elsewhere the
                // labels are measured at the size and rounding they draw at.
                roundingScale: style.segmentsFillWidth ? 1 : displayScale,
                atTextStyleSize: !style.segmentsFillWidth
            )
        }
        let room = style.labelPadding * 2 * CGFloat(tabs.count) + style.segmentGap * CGFloat(max(0, tabs.count - 1))
        return labels + room <= width + 0.5
    }

    /// Record the segments' room once it holds still. A placement's first
    /// settle may change the labels' size once, at once; later placement
    /// changes reuse it.
    private func noteAvailableWidth(_ width: CGFloat) {
        let placement = style
        widthSettle?.cancel()
        widthSettle = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled,
                  abs((settledWidths[placement] ?? -1) - width) >= 0.5 else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { settledWidths[placement] = width }
        }
    }

    private func segmentRow(font: Font, compactsUnselected: Bool) -> some View {
        PageDockSegmentsLayout(
            gap: style.segmentGap,
            fillsWidth: style.segmentsFillWidth
        ) {
            ForEach(model.visibleTabs) { tab in
                segment(tab, font: font, showsIcon: showsIcon(tab, compactsUnselected: compactsUnselected))
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(Self.switcherSpace))
                    } action: { frame in
                        slotFrames[tab] = frame
                    }
            }
        }
        .background(alignment: .topLeading) { dragFill }
        .overlay(alignment: .topLeading) { dragHighlightedLabels(font: font, compactsUnselected: compactsUnselected) }
        .coordinateSpace(.named(Self.switcherSpace))
        .contentShape(Rectangle())
        // Press and slide across the segments, as on the tab bar. Taps
        // shorter than the minimum distance still reach the segments.
        .highPriorityGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .named(Self.switcherSpace))
                .updating($dragX) { value, state, transaction in
                    state = value.location.x
                    transaction.animation = nil
                }
                .onEnded { value in
                    guard let tab = nearestTab(to: value.location.x) else { return }
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                        model.commitDrag(to: tab)
                    }
                }
        )
        .sensoryFeedback(trigger: pendingTab) { old, new in
            old != nil && new != nil && old != new ? .selection : nil
        }
    }

    /// Accessibility text sizes show every segment as its icon; a switcher too
    /// narrow for the labels shows only the selected one's label.
    private func showsIcon(_ tab: Model.Segment, compactsUnselected: Bool) -> Bool {
        usesIcons || (compactsUnselected && tab != displayedTab)
    }

    // MARK: Drag

    /// The segment under a dragging finger: the pending selection.
    private var pendingTab: Model.Segment? {
        dragX.flatMap(nearestTab(to:))
    }

    /// The segment drawn as selected: the pending one during a drag.
    private var displayedTab: Model.Segment {
        pendingTab ?? model.selectedTab
    }

    /// The segment whose centre is nearest `x`, so a finger past either end
    /// stays on the first or last.
    private func nearestTab(to x: CGFloat) -> Model.Segment? {
        model.visibleTabs
            .compactMap { tab in slotFrames[tab].map { (tab, abs($0.midX - x)) } }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// During a drag the fill follows the finger, its width blending between
    /// the segments it passes; with Reduce Motion it sits on the pending one.
    @ViewBuilder
    private var dragFill: some View {
        if let x = dragX, let frame = dragFillFrame(at: x) {
            fillCapsule(at: frame) {
                Capsule()
                    .fill(Color.siloOnSurface)
                    .matchedGeometryEffect(id: Self.fillID, in: selection)
            }
            .allowsHitTesting(false)
        }
    }

    /// While dragging, the labels again in the selected colour, masked to the
    /// moving fill, so a label changes colour exactly where the fill covers
    /// it, as on the tab bar. Same layout and place as the labels below.
    @ViewBuilder
    private func dragHighlightedLabels(font: Font, compactsUnselected: Bool) -> some View {
        if let x = dragX, let frame = dragFillFrame(at: x) {
            PageDockSegmentsLayout(gap: style.segmentGap, fillsWidth: style.segmentsFillWidth) {
                ForEach(model.visibleTabs) { tab in
                    segmentLabel(
                        tab,
                        font: font,
                        showsIcon: showsIcon(tab, compactsUnselected: compactsUnselected),
                        isBold: false
                    )
                    .foregroundStyle(Color.siloBackground)
                    .frame(maxHeight: .infinity)
                }
            }
            .mask(alignment: .topLeading) {
                fillCapsule(at: frame) { Capsule() }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// `capsule` at the fill's size, centred on `frame`, in the switcher's
    /// coordinates.
    private func fillCapsule(at frame: CGRect, @ViewBuilder capsule: () -> some View) -> some View {
        Color.clear.overlay(alignment: .topLeading) {
            capsule()
                .frame(width: frame.width, height: style.fillHeight)
                .position(x: frame.midX, y: frame.midY)
        }
    }

    /// A segment's label at its slot's size: the label (or icon), reserving
    /// the bold label's width so the slot never changes width.
    private func segmentLabel(_ tab: Model.Segment, font: Font, showsIcon: Bool, isBold: Bool) -> some View {
        Group {
            if showsIcon {
                Image(systemName: tab.dockIcon)
                    .font(.system(size: style.iconSize - 1, weight: .semibold))
            } else {
                ZStack {
                    Text(tab.dockTitle)
                        .font(font.weight(.bold))
                        .hidden()
                    Text(tab.dockTitle)
                        .font(font.weight(isBold ? .bold : .semibold))
                }
                .lineLimit(1)
                .fixedSize()
            }
        }
        .padding(.horizontal, style.labelPadding)
        .frame(maxWidth: .infinity)
        .frame(height: style.fillHeight)
    }

    private func dragFillFrame(at x: CGFloat) -> CGRect? {
        let frames = model.visibleTabs.compactMap { slotFrames[$0] }.sorted { $0.midX < $1.midX }
        guard let first = frames.first, let last = frames.last else { return nil }
        if reduceMotion, let tab = pendingTab, let frame = slotFrames[tab] { return frame }
        let centre = min(max(x, first.midX), last.midX)
        var width = first.width
        for (a, b) in zip(frames, frames.dropFirst()) where centre >= a.midX && centre <= b.midX {
            let progress = (centre - a.midX) / max(1, b.midX - a.midX)
            width = a.width + (b.width - a.width) * progress
        }
        return CGRect(x: centre - width / 2, y: first.minY, width: width, height: first.height)
    }

    private func segment(_ tab: Model.Segment, font: Font, showsIcon: Bool) -> some View {
        let isSelected = model.selectedTab == tab
        // During a drag every label here is unselected; the masked copy above
        // colours the part under the fill.
        let isHighlighted = dragX == nil && isSelected
        let color = isHighlighted ? Color.siloBackground : PageDockStyle.unselectedColor
        return Button {
            model.select(tab)
        } label: {
            // Every slot is as wide as its label in the selected weight, so
            // no slot moves when the selection does.
            segmentLabel(tab, font: font, showsIcon: showsIcon, isBold: isHighlighted)
            .foregroundStyle(color)
            .background {
                if isSelected && dragX == nil {
                    Capsule()
                        .fill(Color.siloOnSurface)
                        .matchedGeometryEffect(id: Self.fillID, in: selection)
                }
            }
            // The hit area fills the slot's height even where the fill is
            // shorter.
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tab.dockTitle))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label {
                Text(tab.dockTitle)
            } icon: {
                Image(systemName: tab.dockIcon)
            }
        }
    }
}

/// Lays the dock's segments out side by side, each at its own width (its
/// label in the selected weight plus padding) with equal gaps, so no
/// segment moves when the selection does. With `fillsWidth`, the room left
/// over goes equally into every segment, which keeps their padding equal.
private struct PageDockSegmentsLayout: Layout {
    let gap: CGFloat
    var fillsWidth = false

    /// Equal slots across `width`, when each is at least as wide as the
    /// widest segment needs: with two segments, or icons, the segments
    /// share the room evenly instead of leaving an empty stretch.
    private func equalSlotWidth(in width: CGFloat?, ideals: [CGFloat]) -> CGFloat? {
        guard let width, width.isFinite, !ideals.isEmpty else { return nil }
        let slot = (width - gap * CGFloat(ideals.count - 1)) / CGFloat(ideals.count)
        return slot >= (ideals.max() ?? 0) ? slot : nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        let idealWidth = ideals.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, subviews.count - 1))
        let height = proposal.height ?? (ideals.map(\.height).max() ?? 0)
        if equalSlotWidth(in: proposal.width, ideals: ideals.map(\.width)) != nil, let width = proposal.width {
            return CGSize(width: width, height: height)
        }
        let width = fillsWidth ? (proposal.width ?? idealWidth) : idealWidth
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let count = CGFloat(subviews.count)
        let widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        if let slot = equalSlotWidth(in: bounds.width, ideals: widths) {
            var x = bounds.minX
            for subview in subviews {
                subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: slot, height: bounds.height))
                x += slot + gap
            }
            return
        }
        let leftover = max(0, bounds.width - widths.reduce(0, +) - gap * (count - 1))
        let extra = fillsWidth ? leftover / count : 0
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: width + extra, height: bounds.height)
            )
            x += width + extra + gap
        }
    }
}

/// Takes the width it is offered whatever its content would like, so the
/// floating dock measures the room it has. Its height is the content's.
private struct PageDockOfferedWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let content = subviews.first?.sizeThatFits(proposal) ?? .zero
        guard let width = proposal.width, width.isFinite else { return content }
        return CGSize(width: width, height: content.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height)
        )
    }
}

/// The slot row: the leading button, the hairline, the segments. The
/// button grows into spare room up to `buttonMaxWidth`; the segments then
/// take the rest when they can share it as equal slots, and otherwise sit
/// as a tight group with any room left on the leading side, so the last
/// segment always keeps its trailing inset. With `referenceSegmentsWidth`
/// (a section hidden), the button and the leading room are worked out for
/// that width, so the button stays where it is with every section, and the
/// segments shown share everything after it.
private struct PageDockSlotRowLayout: Layout {
    let buttonMinWidth: CGFloat
    let buttonMaxWidth: CGFloat
    var referenceSegmentsWidth: CGFloat?

    private struct Widths {
        var button: CGFloat
        var hairline: CGFloat
        var segments: CGFloat
    }

    private func widths(for width: CGFloat, height: CGFloat?, subviews: Subviews) -> Widths? {
        guard subviews.count == 3 else { return nil }
        let hairline = subviews[1].sizeThatFits(.unspecified).width
        let segmentsIdeal = referenceSegmentsWidth ?? subviews[2].sizeThatFits(.unspecified).width
        let spare = width - hairline - buttonMinWidth - segmentsIdeal
        let button = buttonMinWidth + min(max(spare, 0), buttonMaxWidth - buttonMinWidth)
        let leadingRoom = referenceSegmentsWidth == nil ? 0 : max(0, width - hairline - button - segmentsIdeal)
        let room = max(0, width - hairline - button - leadingRoom)
        // Segments wider than their room overhang the leading side, as the
        // row always has, so the last keeps its trailing inset.
        let segments = subviews[2].sizeThatFits(ProposedViewSize(width: room, height: height)).width
        return Widths(button: button, hairline: hairline, segments: segments)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let widths = widths(for: bounds.width, height: bounds.height, subviews: subviews) else { return }
        var x = bounds.maxX - widths.segments - widths.hairline - widths.button
        for (subview, width) in zip(subviews, [widths.button, widths.hairline, widths.segments]) {
            // Centred in its share, so a glyph wider than its box overhangs
            // both sides evenly.
            subview.place(
                at: CGPoint(x: x + width / 2, y: bounds.midY),
                anchor: .center,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width
        }
    }
}

/// The dock in the tab bar's accessory slot on iOS 26.1 and later. The same
/// control in both placements: when the tab bar minimises it resizes to
/// the inline slot instead of changing into something else.
struct PageDockAccessory<Model: PageDockModel>: View {
    let model: Model

    @Environment(\.nowPlayingAccessoryIsInline) private var isInline

    var body: some View {
        // The system animates the change between placements; the dock adds
        // no animation of its own on top.
        PageDock(model: model, style: isInline ? .inline : .accessory)
    }
}

/// The widths of the dock's labels in their selected (bold) weight,
/// measured once per text, size and text size setting.
@MainActor
private enum PageDockLabelWidths {
    private static var cache: [String: CGFloat] = [:]

    /// `pointSize` nil is `baseSize` in `textStyle`, scaled for
    /// `dynamicTypeSize`, or with `atTextStyleSize` the text style's own
    /// size there, the size the label draws at. Rounded up to whole points,
    /// or with `roundingScale` to that many steps a point, as a label lays
    /// out.
    static func width(
        of text: String,
        pointSize: CGFloat?,
        textStyle: UIFont.TextStyle,
        baseSize: CGFloat,
        dynamicTypeSize: DynamicTypeSize,
        roundingScale: CGFloat = 1,
        atTextStyleSize: Bool = false
    ) -> CGFloat {
        let key = "\(text)|\(pointSize ?? 0)|\(textStyle.rawValue)|\(baseSize)|\(dynamicTypeSize)|\(atTextStyleSize)"
        let width: CGFloat
        if let cached = cache[key] {
            width = cached
        } else {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
            let size = pointSize ?? (atTextStyleSize
                ? UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits).pointSize
                : UIFontMetrics(forTextStyle: textStyle).scaledValue(for: baseSize, compatibleWith: traits))
            let font = UIFont.systemFont(ofSize: size, weight: .bold)
            width = (text as NSString).size(withAttributes: [.font: font]).width
            cache[key] = width
        }
        let scale = max(roundingScale, 1)
        return ceil(width * scale) / scale
    }
}

#endif

#if os(tvOS)
import SwiftUI
import UIKit

/// One row in an app-owned action popover.
struct TVActionPopoverItem: Identifiable, Equatable {
    let id: String
    let title: String
    var detail: String? = nil
    var systemImage: String? = nil
    var isSelected = false
    var isEnabled = true
    /// Draws a subtle divider above this row when it is not the first row.
    var startsSection = false
    /// Non-empty children turn this row into an in-place submenu trigger.
    var children: [TVActionPopoverItem]? = nil

    var hasSubmenu: Bool {
        guard let children else { return false }
        return !children.isEmpty
    }
}

/// Anchored popover that replaces the system `Menu` on the detail action
/// row. tvOS presents a `Menu` as a context-menu interaction whose spring
/// present and dismiss each run over a second, and the interaction owns
/// input until the dismiss spring completes. That was the 1–2 s dead zone
/// after confirming a Version/Audio/Subtitle choice.
///
/// Options are native focus targets so touchpad swipes and directional presses
/// use the same focus graph. Selection and dismissal return directly to the
/// trigger without presenting a system context menu.
struct TVActionPopoverMenu: View {
    let title: String
    let items: [TVActionPopoverItem]
    var maxHeight: CGFloat? = nil
    let onSelect: (TVActionPopoverItem) -> Void
    let onClose: () -> Void

    @FocusState private var highlightedId: String?
    @Namespace private var optionFocusScope
    /// Stack of entered parent item IDs. Submenu rows are resolved live from
    /// `items` so dynamic state updates (e.g. `isEnabled`) stay fresh while open.
    @State private var submenuPath: [String] = []
    /// Target row for the next focus resolution (e.g. returning to the submenu
    /// trigger when popping a submenu) so tvOS lands on it on the first frame
    /// instead of flashing on the top row first.
    @State private var preferredFocusId: String?
    @State private var focusTask: Task<Void, Never>?
    @State private var measuredListHeight: CGFloat = 0

    static let width: CGFloat = 560
    private static let maxRows = 8
    private static let shape = RoundedRectangle(
        cornerRadius: SiloTheme.Skyline.dropdownCornerRadius,
        style: .continuous
    )

    private var currentItems: [TVActionPopoverItem] {
        var list = items
        for parentId in submenuPath {
            guard let parent = list.first(where: { $0.id == parentId }),
                  let children = parent.children, !children.isEmpty else {
                break
            }
            list = children
        }
        return list
    }

    private var currentSubmenuTitle: String? {
        guard !submenuPath.isEmpty else { return nil }
        var list = items
        var title: String?
        for parentId in submenuPath {
            guard let parent = list.first(where: { $0.id == parentId }),
                  let children = parent.children, !children.isEmpty else {
                break
            }
            title = parent.title
            list = children
        }
        return title
    }

    private var isInSubmenu: Bool {
        !submenuPath.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let submenuTitle = currentSubmenuTitle {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text(submenuTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.horizontal, SiloTheme.Skyline.cascadeRowPaddingHorizontal)
                .padding(.top, 4)
                .padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
            }
            rows
        }
        .padding(SiloTheme.Skyline.dropdownPadding)
        .frame(width: Self.width, alignment: .leading)
        // Native tvOS context-menu look: Liquid Glass with a dark tint so
        // the page shows through, plus a faint lip so the edge reads on
        // bright backdrops.
        .siloGlass(in: Self.shape, tint: Color.black.opacity(0.45))
        .overlay(Self.shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 32, y: 18)
        .contentShape(Self.shape)
        .focusScope(optionFocusScope)
        .defaultFocus($highlightedId, initialOptionId, priority: .userInitiated)
        .onMoveCommand { direction in
            switch direction {
            case .left:
                if isInSubmenu {
                    handleExit()
                }
            case .right:
                if let current = currentItems.first(where: { $0.id == highlightedId }),
                   current.hasSubmenu, current.isEnabled {
                    enterSubmenu(current)
                }
            default:
                break
            }
        }
        .onExitCommand(perform: handleExit)
        // A Menu press that races a focus move would otherwise pop the page.
        .background(
            TVWindowMenuPressCatcher(onExit: handleExit)
                .frame(width: 0, height: 0)
        )
        .task {
            await Task.yield()
            guard !Task.isCancelled, highlightedId == nil else { return }
            highlightedId = initialOptionId
        }
        .onChange(of: currentItems) { _, _ in
            measuredListHeight = 0
        }
        .onDisappear {
            focusTask?.cancel()
            focusTask = nil
        }
        .accessibilityAction(.escape, handleExit)
    }

    private var initialOptionId: String? {
        if let preferredFocusId,
           currentItems.contains(where: { $0.id == preferredFocusId && $0.isEnabled }) {
            return preferredFocusId
        }
        return firstOptionId(in: currentItems)
    }

    private func firstOptionId(in list: [TVActionPopoverItem]) -> String? {
        list.first(where: { $0.isSelected && $0.isEnabled })?.id
            ?? list.first(where: \.isEnabled)?.id
    }

    private func handleRowAction(_ item: TVActionPopoverItem) {
        if item.hasSubmenu {
            enterSubmenu(item)
        } else {
            onSelect(item)
        }
    }

    private func enterSubmenu(_ item: TVActionPopoverItem) {
        guard let children = item.children,
              let targetId = firstOptionId(in: children) else { return }
        focusTask?.cancel()
        preferredFocusId = targetId
        submenuPath.append(item.id)
        highlightedId = targetId
        focusTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, highlightedId == nil else { return }
            highlightedId = targetId
        }
    }

    private func handleExit() {
        focusTask?.cancel()
        focusTask = nil
        if let returnId = submenuPath.popLast() {
            preferredFocusId = returnId
            highlightedId = returnId
            focusTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled, highlightedId == nil else { return }
                highlightedId = returnId
            }
        } else {
            onClose()
        }
    }

    @ViewBuilder
    private var rows: some View {
        let list = VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(currentItems.enumerated()), id: \.element.id) { index, item in
                if index > 0 && item.startsSection {
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 1)
                        .padding(.horizontal, SiloTheme.Skyline.cascadeRowPaddingHorizontal)
                        .padding(.vertical, 6)
                }
                Button { handleRowAction(item) } label: {
                    TVActionPopoverRow(
                        item: item,
                        isHighlighted: item.id == highlightedId
                    )
                }
                .buttonStyle(TVActionPopoverButtonStyle())
                .focused($highlightedId, equals: item.id)
                .prefersDefaultFocus(item.id == initialOptionId, in: optionFocusScope)
                .disabled(!item.isEnabled)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([item.title, item.detail].compactMap { $0 }.joined(separator: ", "))
                .accessibilityAddTraits(item.isSelected ? .isSelected : [])
                .id(item.id)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            measuredListHeight = height
        }
        let maxListHeight = effectiveMaxListHeight
        let needsScroll = currentItems.count > Self.maxRows
            || (maxHeight != nil && max(estimatedListHeight, measuredListHeight) > maxAvailableListHeight)
        if needsScroll {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    list
                }
                .frame(height: min(measuredListHeight > 0 ? measuredListHeight : estimatedListHeight, maxListHeight))
                .onAppear {
                    if let initialOptionId {
                        proxy.scrollTo(initialOptionId, anchor: .center)
                    }
                }
            }
        } else {
            list
        }
    }

    private var maxAvailableListHeight: CGFloat {
        guard let maxHeight else { return .infinity }
        return max(0, maxHeight - SiloTheme.Skyline.dropdownPadding * 2)
    }

    private var effectiveMaxListHeight: CGFloat {
        let rowCap = Self.rowHeightEstimate * CGFloat(Self.maxRows)
        return min(rowCap, maxAvailableListHeight)
    }

    private var estimatedListHeight: CGFloat {
        var total: CGFloat = 0
        for (index, item) in currentItems.enumerated() {
            if index > 0 {
                total += 2
                if item.startsSection {
                    total += 15
                }
            }
            let hasDetail = !(item.detail?.isEmpty ?? true)
            total += hasDetail ? 78 : 56
        }
        return total
    }

    private static let rowHeightEstimate: CGFloat = 72
}

/// Own the focus appearance completely; tvOS's plain style adds a second halo
/// around the row even when a custom rounded highlight is already present.
private struct TVActionPopoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.94 : 1)
            .focusEffectDisabled()
    }
}

private struct TVActionPopoverRow: View {
    let item: TVActionPopoverItem
    let isHighlighted: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.isSelected ? "checkmark" : (item.systemImage ?? "checkmark"))
                .font(.system(size: 20, weight: .bold))
                .frame(width: 26)
                .opacity(item.isSelected || item.systemImage != nil ? 1 : 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: SiloTheme.Skyline.dropdownRowTextSize, weight: .semibold))
                    .lineLimit(1)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(foreground.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if item.hasSubmenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(foreground.opacity(0.55))
            }
        }
        .foregroundStyle(foreground)
        .opacity(item.isEnabled ? 1 : 0.4)
        .padding(.horizontal, SiloTheme.Skyline.cascadeRowPaddingHorizontal)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SiloTheme.Skyline.cascadeRowCornerRadius, style: .continuous)
                .fill(isHighlighted ? Color.white : Color.clear)
        )
        .animation(reduceMotion ? nil : SiloTheme.springAnimation, value: isHighlighted)
    }

    private var foreground: Color {
        isHighlighted ? .siloBackground : .white.opacity(0.9)
    }
}

// MARK: - Page-level hosting

/// A request to show a popover, published by `TVCircleMenuButton` through
/// `TVActionPopoverPreferenceKey` and rendered by `tvActionPopoverHost()`.
///
/// The trigger sits inside the hero's clipped editorial column and the page
/// scroll view, so drawing the popover as the trigger's own overlay clips it
/// and lets later siblings (season chips, episode rail) paint over it. The
/// host draws it above the whole page instead, anchored to the trigger's
/// bounds.
struct TVActionPopoverRequest: Equatable {
    let id: UUID
    let anchor: Anchor<CGRect>
    let title: String
    let items: [TVActionPopoverItem]
    let onSelect: (TVActionPopoverItem) -> Void
    let onClose: () -> Void

    /// Identity only: closures are not comparable, and a request is the same
    /// request while its id holds. Items are read live from the trigger.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct TVActionPopoverPreferenceKey: PreferenceKey {
    static let defaultValue: [TVActionPopoverRequest] = []

    static func reduce(value: inout [TVActionPopoverRequest], nextValue: () -> [TVActionPopoverRequest]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Render any open `TVCircleMenuButton` popover above this view. Apply
    /// once per detail page, outside the page scroll view.
    func tvActionPopoverHost() -> some View {
        modifier(TVActionPopoverHostModifier())
    }
}

private struct TVActionPopoverHostModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Mirrors "a popover is open" out of the preference so the page can be
    /// disabled. While disabled, nothing under the page can take focus, so
    /// the popover is the engine's only candidate: that is the focus lock.
    @State private var isOpen = false
    /// Measured height of the open panel. Zero until the first layout; the
    /// panel is then placed below the anchor, which is right for every
    /// short list and re-evaluates once the real height is known.
    @State private var panelHeight: CGFloat = 0

    private static let anchorGap: CGFloat = 16
    private static let screenInset: CGFloat = 48

    private struct Placement {
        let x: CGFloat
        let y: CGFloat
        let maxHeight: CGFloat
        let opensLeft: Bool
    }

    /// Beside the trigger on its trailing side when there is room (falling
    /// back to the leading side near the right edge). Vertically top-aligned
    /// with the trigger and nudged upward only as much as needed so the bottom
    /// clears the screen inset — keeping the top actions right beside the
    /// button and the menu extending toward the bottom without scrolling.
    private static func placement(
        anchor: CGRect,
        panelHeight: CGFloat,
        in size: CGSize
    ) -> Placement {
        let rightX = anchor.maxX + anchorGap
        let fitsRight = rightX + TVActionPopoverMenu.width <= size.width - screenInset
        let x: CGFloat
        let opensLeft: Bool
        if fitsRight {
            x = rightX
            opensLeft = false
        } else {
            let leftX = anchor.minX - anchorGap - TVActionPopoverMenu.width
            if leftX >= screenInset {
                x = leftX
                opensLeft = true
            } else {
                x = max(screenInset, size.width - screenInset - TVActionPopoverMenu.width)
                opensLeft = false
            }
        }

        let maxHeight = max(0, size.height - screenInset * 2)
        let effectiveHeight = panelHeight > 0 ? min(panelHeight, maxHeight) : 0
        let maxY = size.height - screenInset - effectiveHeight
        let y = max(screenInset, min(anchor.minY, maxY))
        return Placement(x: x, y: y, maxHeight: maxHeight, opensLeft: opensLeft)
    }

    func body(content: Content) -> some View {
        content
            .disabled(isOpen)
            .onPreferenceChange(TVActionPopoverPreferenceKey.self) { requests in
                let open = !requests.isEmpty
                if open != isOpen { isOpen = open }
                if !open { panelHeight = 0 }
            }
            .overlayPreferenceValue(TVActionPopoverPreferenceKey.self) { requests in
                GeometryReader { geo in
                    if let request = requests.last {
                        let anchor = geo[request.anchor]
                        let placement = Self.placement(
                            anchor: anchor,
                            panelHeight: panelHeight,
                            in: geo.size
                        )
                        // Layout padding, never `.offset`: tvOS resolves
                        // focus from layout frames, and an offset panel
                        // would keep its focus frame at the origin.
                        ZStack(alignment: .topLeading) {
                            TVActionPopoverMenu(
                                title: request.title,
                                items: request.items,
                                maxHeight: placement.maxHeight,
                                onSelect: request.onSelect,
                                onClose: request.onClose
                            )
                            .id(request.id)
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                panelHeight = height
                            }
                            .padding(.leading, placement.x)
                            .padding(.top, placement.y)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .opacity.combined(
                                        with: .scale(
                                            scale: 0.96,
                                            anchor: placement.opensLeft ? .topTrailing : .topLeading
                                        )
                                    )
                            )
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
                .ignoresSafeArea()
                .animation(
                    reduceMotion ? nil : .easeOut(duration: SiloTheme.Skyline.cascadeOpenDuration),
                    value: requests.last?.id
                )
            }
    }
}
#endif

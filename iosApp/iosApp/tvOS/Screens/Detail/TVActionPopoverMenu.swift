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
}

/// Anchored popover that replaces the system `Menu` on the detail action
/// row. tvOS presents a `Menu` as a context-menu interaction whose spring
/// present and dismiss each run over a second, and the interaction owns
/// input until the dismiss spring completes. That was the 1–2 s dead zone
/// after confirming a Version/Audio/Subtitle choice.
///
/// The popover is one composite focus item (docs/tvos-focus.md): the panel
/// uses one transparent native Button, rows are passive labels, and d-pad up/down
/// moves an internal highlight. Select commits the highlighted row; Menu/Back
/// closes. Both hand focus straight back to the trigger, so the next d-pad
/// press lands on the row with no system animation to wait out.
struct TVActionPopoverMenu: View {
    let title: String
    let items: [TVActionPopoverItem]
    let onSelect: (TVActionPopoverItem) -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var panelFocused: Bool
    @State private var highlightedId: String?
    @State private var didClaimFocus = false
    @State private var focusClaim: Task<Void, Never>?

    static let width: CGFloat = 560
    private static let maxRows = 7
    private static let shape = RoundedRectangle(
        cornerRadius: SiloTheme.Skyline.dropdownCornerRadius,
        style: .continuous
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
        .accessibilityHidden(true)
        .overlay {
            // The original surface owns layout and appearance. A transparent
            // native Button owns activation and focus without styling the rows.
            Button(action: commitHighlighted) {
                Color.clear.contentShape(Self.shape)
            }
            .buttonStyle(TVPopoverActivationButtonStyle())
            .focused($panelFocused)
            .focusEffectDisabled()
            .onMoveCommand(perform: handleMove)
            .onExitCommand(perform: onClose)
            // VoiceOver: the composite is one adjustable button. Its value is
            // the highlighted row (what Select will commit), swipe up/down moves
            // the highlight, and activate commits it. Rows stay hidden so the
            // cursor cannot land on a label that does not react to Select.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(highlightedAccessibilityValue)
            .accessibilityAddTraits([.isButton, .updatesFrequently])
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: moveHighlight(by: 1)
                case .decrement: moveHighlight(by: -1)
                @unknown default: break
                }
            }
            .accessibilityAction(.escape, onClose)
        }
        .background(
            TVActionPopoverMenuPressCatcher(onExit: onClose)
                .frame(width: 0, height: 0)
        )
        .onAppear {
            highlightedId = items.first(where: { $0.isSelected && $0.isEnabled })?.id
                ?? items.first(where: \.isEnabled)?.id
            claimFocus()
        }
        .onDisappear {
            focusClaim?.cancel()
        }
        .onChange(of: panelFocused) { _, focused in
            if focused {
                didClaimFocus = true
                return
            }
            // The panel is the only focus owner while open. Losing focus
            // after it was held (a cover, the watchdog, an engine repair)
            // means the popover is stale; close instead of lingering
            // unfocusable. A false before the claim landed is just the
            // engine not having moved yet.
            if didClaimFocus { onClose() }
        }
    }

    private var highlightedAccessibilityValue: String {
        guard let item = items.first(where: { $0.id == highlightedId }) else { return "" }
        var parts = [item.title]
        if let detail = item.detail, !detail.isEmpty { parts.append(detail) }
        if item.isSelected { parts.append("selected") }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            parts.append("\(index + 1) of \(items.count)")
        }
        return parts.joined(separator: ", ")
    }

    private var header: some View {
        Text(title.uppercased())
            .font(.system(size: SiloTheme.Skyline.dropdownHeaderSize, design: .monospaced))
            .tracking(SiloTheme.Skyline.dropdownHeaderSize * 0.26)
            .foregroundStyle(Color.white.opacity(0.38))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var rows: some View {
        let list = VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                TVActionPopoverRow(
                    item: item,
                    isHighlighted: item.id == highlightedId
                )
                .id(item.id)
            }
        }
        if items.count > Self.maxRows {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    list
                }
                .frame(maxHeight: Self.rowHeightEstimate * CGFloat(Self.maxRows))
                .onChange(of: highlightedId) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        } else {
            list
        }
    }

    private static let rowHeightEstimate: CGFloat = 72

    private func handleMove(_ direction: MoveCommandDirection) {
        switch direction {
        case .up:
            moveHighlight(by: -1)
        case .down:
            moveHighlight(by: 1)
        case .left, .right:
            // Lateral moves leave the menu: close and let the next press
            // land on the row's neighbour. Consuming them here would
            // trap the user in a one-column list.
            onClose()
        @unknown default:
            break
        }
    }

    private func moveHighlight(by delta: Int) {
        let enabled = items.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        let index = enabled.firstIndex { $0.id == highlightedId } ?? 0
        let next = index + delta
        guard enabled.indices.contains(next) else { return }
        highlightedId = enabled[next].id
    }

    /// A `@FocusState` write in `onAppear` lands only if the engine already
    /// knows the new focusable. Re-assert across a few turns, the same way
    /// `TVCascadeSelector.claimPanelFocus` does, and stop as soon as it
    /// sticks or the user has moved on.
    private func claimFocus() {
        focusClaim?.cancel()
        panelFocused = true
        focusClaim = Task { @MainActor in
            for attempt in 0..<6 {
                if attempt == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(nanoseconds: 32_000_000)
                }
                if Task.isCancelled || didClaimFocus || panelFocused { return }
                panelFocused = true
            }
        }
    }

    private func commitHighlighted() {
        guard let item = items.first(where: { $0.id == highlightedId }),
              item.isEnabled else { return }
        onSelect(item)
    }
}

/// No system padding, tint, scale, or focus decoration on the invisible host.
private struct TVPopoverActivationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
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
        .accessibilityHidden(true)
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

    private static let anchorGap: CGFloat = 14
    private static let screenInset: CGFloat = 48

    private struct Placement {
        let x: CGFloat
        let y: CGFloat
        let opensUpward: Bool
    }

    /// Below the anchor when it fits, otherwise above it; if neither side
    /// has room, pinned to the bottom inset so the last row is on screen.
    /// Horizontal position tracks the anchor's leading edge and is clamped
    /// to the screen inset.
    private static func placement(
        anchor: CGRect,
        panelHeight: CGFloat,
        in size: CGSize
    ) -> Placement {
        let x = min(
            anchor.minX,
            max(screenInset, size.width - screenInset - TVActionPopoverMenu.width)
        )
        let below = anchor.maxY + anchorGap
        let fitsBelow = below + panelHeight <= size.height - screenInset
        if fitsBelow || panelHeight == 0 {
            return Placement(x: x, y: below, opensUpward: false)
        }
        let above = anchor.minY - anchorGap - panelHeight
        if above >= screenInset {
            return Placement(x: x, y: above, opensUpward: true)
        }
        let pinned = max(screenInset, size.height - screenInset - panelHeight)
        return Placement(x: x, y: pinned, opensUpward: false)
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
                                            anchor: placement.opensUpward ? .bottom : .top
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

/// Window-level Menu press catcher. SwiftUI's `onExitCommand` only fires
/// while the popover itself holds focus; a Menu press that races a focus
/// move would otherwise pop the detail page. Same pattern as the top bar.
private struct TVActionPopoverMenuPressCatcher: UIViewRepresentable {
    var onExit: () -> Void

    func makeUIView(context: Context) -> TVActionPopoverMenuPressUIView {
        let view = TVActionPopoverMenuPressUIView()
        view.onExit = onExit
        return view
    }

    func updateUIView(_ uiView: TVActionPopoverMenuPressUIView, context: Context) {
        uiView.onExit = onExit
    }
}

private final class TVActionPopoverMenuPressUIView: UIView, UIGestureRecognizerDelegate {
    var onExit: () -> Void = {}

    private weak var attachedWindow: UIWindow?
    private var recognizer: UITapGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachRecognizerIfNeeded()
    }

    deinit {
        detachRecognizer()
    }

    private func attachRecognizerIfNeeded() {
        guard attachedWindow !== window else { return }
        detachRecognizer()
        guard let window else { return }
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleMenuPress(_:)))
        recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self
        window.addGestureRecognizer(recognizer)
        attachedWindow = window
        self.recognizer = recognizer
    }

    private func detachRecognizer() {
        if let recognizer, let attachedWindow {
            attachedWindow.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        attachedWindow = nil
    }

    @objc private func handleMenuPress(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onExit()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        window != nil
    }
}
#endif

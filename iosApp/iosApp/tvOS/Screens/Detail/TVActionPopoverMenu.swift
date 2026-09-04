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
/// itself is the only focusable, rows are passive labels, and d-pad up/down
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
        cornerRadius: ContinuumTheme.Skyline.dropdownCornerRadius,
        style: .continuous
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            rows
        }
        .padding(ContinuumTheme.Skyline.dropdownPadding)
        .frame(width: Self.width, alignment: .leading)
        // Native tvOS context-menu look: Liquid Glass with a dark tint so
        // the page shows through, plus a faint lip so the edge reads on
        // bright backdrops.
        .siloGlass(in: Self.shape, tint: Color.black.opacity(0.45))
        .overlay(Self.shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 32, y: 18)
        .contentShape(Self.shape)
        .focusable(true)
        .focused($panelFocused)
        .focusEffectDisabled()
        .onMoveCommand(perform: handleMove)
        .onTapGesture(perform: commitHighlighted)
        .onExitCommand(perform: onClose)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var header: some View {
        Text(title.uppercased())
            .font(.system(size: ContinuumTheme.Skyline.dropdownHeaderSize, design: .monospaced))
            .tracking(ContinuumTheme.Skyline.dropdownHeaderSize * 0.26)
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
        let enabled = items.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        let index = enabled.firstIndex { $0.id == highlightedId } ?? 0
        switch direction {
        case .up:
            guard index > 0 else { return }
            highlightedId = enabled[index - 1].id
        case .down:
            guard index < enabled.count - 1 else { return }
            highlightedId = enabled[index + 1].id
        case .left, .right:
            // Lateral moves leave the menu: close and let the next press
            // land on the row's neighbour. Consuming them here would
            // trap the user in a one-column list.
            onClose()
        @unknown default:
            break
        }
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
                    .font(.system(size: ContinuumTheme.Skyline.dropdownRowTextSize, weight: .semibold))
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
        .padding(.horizontal, ContinuumTheme.Skyline.cascadeRowPaddingHorizontal)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ContinuumTheme.Skyline.cascadeRowCornerRadius, style: .continuous)
                .fill(isHighlighted ? Color.white : Color.clear)
        )
        .animation(reduceMotion ? nil : ContinuumTheme.springAnimation, value: isHighlighted)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
    }

    private var foreground: Color {
        isHighlighted ? .continuumBackground : .white.opacity(0.9)
    }

    private var accessibilityText: String {
        guard let detail = item.detail, !detail.isEmpty else { return item.title }
        return "\(item.title), \(detail)"
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

    private static let anchorGap: CGFloat = 14
    private static let screenInset: CGFloat = 48

    func body(content: Content) -> some View {
        content
            .disabled(isOpen)
            .onPreferenceChange(TVActionPopoverPreferenceKey.self) { requests in
                let open = !requests.isEmpty
                if open != isOpen { isOpen = open }
            }
            .overlayPreferenceValue(TVActionPopoverPreferenceKey.self) { requests in
                GeometryReader { geo in
                    if let request = requests.last {
                        let anchor = geo[request.anchor]
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
                            .padding(
                                .leading,
                                min(
                                    anchor.minX,
                                    max(
                                        Self.screenInset,
                                        geo.size.width - Self.screenInset - TVActionPopoverMenu.width
                                    )
                                )
                            )
                            .padding(.top, anchor.maxY + Self.anchorGap)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                            )
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
                .ignoresSafeArea()
                .animation(
                    reduceMotion ? nil : .easeOut(duration: ContinuumTheme.Skyline.cascadeOpenDuration),
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

#if os(iOS)
import SwiftUI

/// The iPhone Duo's folded screen shows the time and connection status in a
/// column down one side instead of across the top. The window reports that
/// column as a side safe-area inset with no top inset, which no other iPhone
/// or iPad window does: portrait phones inset the top, and landscape phones
/// inset both sides.
///
/// Builds against an SDK older than iOS 27.1 run letterboxed on that screen
/// and never see the column, so they keep the bottom tab bar.
struct StatusColumnLayout: Equatable {
    let edge: HorizontalEdge
    let width: CGFloat

    /// A narrower side inset is a rounded corner or sensor housing, not a
    /// column wide enough for navigation.
    static let minimumWidth: CGFloat = 60

    init?(safeArea: EdgeInsets) {
        guard safeArea.top < 1 else { return nil }
        if safeArea.leading < 1, safeArea.trailing >= Self.minimumWidth {
            edge = .trailing
            width = safeArea.trailing
        } else if safeArea.trailing < 1, safeArea.leading >= Self.minimumWidth {
            edge = .leading
            width = safeArea.leading
        } else {
            return nil
        }
    }

    /// The bottom bar's capacity: past five destinations, the fifth slot
    /// becomes More, as it does in the system tab bar.
    static let maximumSlots = 5

    /// The page side the column sits on.
    var edgeSet: Edge.Set { edge == .leading ? .leading : .trailing }

    /// The system centers the time, connection status, and its own vertical
    /// bar this far from the column's page-side edge, under the front
    /// camera rather than mid-column: 6pt toward the page in the folded
    /// iPhone Duo's 84pt column. Measured from the page side, it holds in a
    /// sheet inset from the screen edge too.
    static let axisInset: CGFloat = 36

    static func split<Item>(_ items: [Item]) -> (primary: [Item], overflow: [Item]) {
        guard items.count > maximumSlots else { return (items, []) }
        let primaryCount = maximumSlots - 1
        return (Array(items.prefix(primaryCount)), Array(items.dropFirst(primaryCount)))
    }
}

extension EnvironmentValues {
    /// The status column beside the page, when there is one. Tab-root
    /// headers leave out Search, Remote, and Profile, which the column
    /// carries, and detail pages keep their controls clear of it.
    @Entry var statusColumn: StatusColumnLayout? = nil
}

/// Navigation for the status column, laid out like the iOS 27.1 vertical
/// bars: page actions in a pill under the system status, destinations in a
/// pill along the bottom. The system's own vertical tab bar lists up to seven
/// destinations and leaves no room for the page actions.
struct StatusColumnBar: View {
    let layout: StatusColumnLayout
    let destinations: [MainTabDestination]
    @Binding var selection: MainTabDestinationID
    let topBarActions: TabTopBarActions

    @Namespace private var selectionNamespace

    /// Clears the system time and connection indicators at the top of the
    /// column. iOS 27.1 starts its vertical toolbar at the same height.
    static let actionsTop: CGFloat = 168
    private let bottomMargin: CGFloat = 26
    private let pillWidth: CGFloat = 52
    private let itemHeight: CGFloat = 50

    var body: some View {
        let (primary, overflow) = StatusColumnLayout.split(destinations)
        VStack(spacing: 0) {
            topBarActions
                .padding(.vertical, 4)
                .frame(width: pillWidth)
                .siloGlass(in: Capsule())

            Spacer(minLength: 12)

            VStack(spacing: 0) {
                ForEach(primary) { destination in
                    destinationButton(destination)
                }
                if !overflow.isEmpty {
                    moreMenu(overflow)
                }
            }
            .padding(.vertical, 4)
            .frame(width: pillWidth)
            .siloGlass(in: Capsule())
            .animation(.snappy(duration: 0.25), value: selection)
        }
        .padding(.top, Self.actionsTop)
        .padding(.bottom, bottomMargin)
        .statusColumnCentered(layout)
        .frame(maxHeight: .infinity)
    }

    private func destinationButton(_ destination: MainTabDestination) -> some View {
        let isSelected = selection == destination.id
        return Button {
            selection = destination.id
        } label: {
            itemLabel(
                systemImage: isSelected ? destination.selectedIcon : destination.icon,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func moreMenu(_ overflow: [MainTabDestination]) -> some View {
        let selectedOverflow = overflow.first { $0.id == selection }
        return Menu {
            Picker("More", selection: $selection) {
                ForEach(overflow) { destination in
                    Label(destination.title, systemImage: destination.icon)
                        .tag(destination.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            // An overflow destination takes over the More slot's glyph while
            // it is open, so the column always shows where you are.
            itemLabel(
                systemImage: selectedOverflow?.selectedIcon ?? "ellipsis",
                isSelected: selectedOverflow != nil
            )
        }
        .menuStyle(.borderlessButton)
        // Keep the bar's order instead of flipping it toward the button.
        .menuOrder(.fixed)
        .accessibilityLabel("More")
        .accessibilityValue(selectedOverflow?.title ?? "")
    }

    private func itemLabel(systemImage: String, isSelected: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(isSelected ? Color.siloOnSurface : Color.siloOnSurface.opacity(0.72))
            .frame(width: pillWidth - 8, height: itemHeight - 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                }
            }
            .frame(height: itemHeight)
            .contentShape(Rectangle())
    }
}
extension View {
    /// Fills the status column, centered on the same axis as the system's
    /// time and connection status.
    func statusColumnCentered(_ layout: StatusColumnLayout) -> some View {
        frame(width: min(StatusColumnLayout.axisInset * 2, layout.width))
            .frame(width: layout.width, alignment: layout.edge == .trailing ? .leading : .trailing)
    }

    /// Lets a sheet use the full width of the iPhone Duo's folded screen
    /// while its top sits below the time and connection status. The window
    /// keeps the whole column clear, though only its top holds anything.
    func statusColumnSheetWidth() -> some View {
        modifier(StatusColumnSheetWidthModifier())
    }
}

private struct StatusColumnSheetWidthModifier: ViewModifier {
    @State private var isWidened = false

    func body(content: Content) -> some View {
        content
            // Lists in the widened sheet lose their trailing margin; give
            // both sides the standard one.
            .contentMargins(.horizontal, isWidened ? 16 : nil, for: .scrollContent)
            .background(StatusColumnSheetWidth(isWidened: $isWidened).allowsHitTesting(false))
    }
}

private struct StatusColumnSheetWidth: UIViewRepresentable {
    @Binding var isWidened: Bool

    func makeUIView(context: Context) -> SheetView { SheetView() }

    func updateUIView(_ view: SheetView, context: Context) {
        view.onWidenedChange = { isWidened = $0 }
    }

    final class SheetView: UIView {
        var onWidenedChange: (Bool) -> Void = { _ in }
        private var isWidened = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            update()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            update()
        }

        /// Cancels the column's inset on every controller from this page up
        /// to the sheet: a navigation stack's page takes the inset from the
        /// window rather than from its parent.
        private func update() {
            guard let window, let controllers = controllersUpToSheet, let sheet = controllers.last else { return }
            let windowInsets = window.safeAreaInsets
            let sheetTop = sheet.view.convert(sheet.view.bounds, to: window).minY
            let clearsStatus = windowInsets.top < 1 && sheetTop >= StatusColumnBar.actionsTop
            let cancelsLeft = clearsStatus && windowInsets.left >= StatusColumnLayout.minimumWidth
            let cancelsRight = clearsStatus && windowInsets.right >= StatusColumnLayout.minimumWidth
            for controller in controllers.reversed() {
                var additional = controller.additionalSafeAreaInsets
                let safeArea = controller.view.safeAreaInsets
                additional.left = cancelsLeft ? -(safeArea.left - additional.left) : 0
                additional.right = cancelsRight ? -(safeArea.right - additional.right) : 0
                if additional != controller.additionalSafeAreaInsets {
                    controller.additionalSafeAreaInsets = additional
                }
            }
            let widened = cancelsLeft || cancelsRight
            if widened != isWidened {
                isWidened = widened
                DispatchQueue.main.async { [onWidenedChange] in onWidenedChange(widened) }
            }
        }

        /// This page's controller and its parents, ending with the presented
        /// sheet; nil outside a sheet.
        private var controllersUpToSheet: [UIViewController]? {
            var responder: UIResponder? = self
            while let current = responder, !(current is UIViewController) { responder = current.next }
            guard let nearest = responder as? UIViewController else { return nil }
            let controllers = Array(sequence(first: nearest, next: \.parent))
            return controllers.last?.presentingViewController == nil ? nil : controllers
        }
    }
}
#endif

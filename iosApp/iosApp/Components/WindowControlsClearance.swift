import SwiftUI

extension View {
    /// Moves a custom top bar's leading content clear of the iPadOS window
    /// controls. A resized iPad window draws its close/minimize/resize dots in
    /// the top-leading corner; system navigation bars step around them, but
    /// the root pages' own headers start at the window edge and would sit
    /// underneath. No-op where the window has no controls in that corner.
    func clearsWindowControls() -> some View {
        #if os(iOS)
        modifier(WindowControlsClearance())
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct WindowControlsClearance: ViewModifier {
    @State private var leadingInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.leading, leadingInset)
            // Measured on the unpadded frame, so the padding cannot feed back
            // into the measurement.
            .background {
                WindowControlsInsetReader { leadingInset = $0 }
                    .accessibilityHidden(true)
            }
    }
}

/// Reports how far UIKit's corner-adapted safe area reaches past the plain
/// one at this view's leading edge: the window controls' footprint, or zero.
private struct WindowControlsInsetReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: ((CGFloat) -> Void)?
        private var reported: CGFloat?

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            guard #available(iOS 26.0, *) else { return }
            let adapted = directionalEdgeInsets(for: .safeArea(cornerAdaptation: .horizontal)).leading
            let plain = directionalEdgeInsets(for: .safeArea()).leading
            let inset = max(0, (adapted - plain).rounded())
            guard inset != reported else { return }
            reported = inset
            // Reported during layout; apply on the next turn so SwiftUI does
            // not see a state change mid-update.
            DispatchQueue.main.async { [onChange] in onChange?(inset) }
        }
    }
}
#endif

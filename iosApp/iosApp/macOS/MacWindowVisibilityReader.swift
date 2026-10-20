#if os(macOS)
import AppKit
import SwiftUI

/// Reports whether the window this view is in can be seen. Minimized, hidden
/// with the app, on another Space or covered entirely, it can't, whatever
/// other Silo windows show.
struct MacWindowVisibilityReader: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: @MainActor (Bool) -> Void
        private var observer: NSObjectProtocol?

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.onChange(window.occlusionState.contains(.visible))
                }
            }
            // After SwiftUI finishes the update that placed this view.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.onChange(window.occlusionState.contains(.visible))
            }
        }
    }
}
#endif

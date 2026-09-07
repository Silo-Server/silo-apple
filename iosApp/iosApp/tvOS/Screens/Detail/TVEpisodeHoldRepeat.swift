#if os(tvOS)
import SwiftUI
import UIKit

/// Observes held arrows while the carousel owns focus. Discrete presses and
/// touch swipes continue through SwiftUI's onMoveCommand.
struct TVEpisodeHoldRepeat: UIViewRepresentable {
    var isActive: Bool
    var onMove: (Int) -> Void

    func makeUIView(context: Context) -> RepeatView { RepeatView() }

    func updateUIView(_ uiView: RepeatView, context: Context) {
        uiView.recognizer.onMove = onMove
        uiView.recognizer.isEnabled = isActive
    }

    static func dismantleUIView(_ uiView: RepeatView, coordinator: ()) {
        uiView.detach()
    }

    final class RepeatView: UIView {
        let recognizer = HeldArrowObserver()
        private weak var attachedWindow: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard attachedWindow !== window else { return }
            detach()
            guard let window else { return }
            window.addGestureRecognizer(recognizer)
            attachedWindow = window
        }

        func detach() {
            recognizer.stopRepeating()
            attachedWindow?.removeGestureRecognizer(recognizer)
            attachedWindow = nil
        }
    }

    /// Remains possible until release and never wins gesture recognition. This
    /// lets the focus engine deliver the initial move and keeps its press/swipe
    /// recognizers from cancelling our observation before the repeat delay.
    final class HeldArrowObserver: UIGestureRecognizer {
        var onMove: (Int) -> Void = { _ in }
        private var repeatTask: Task<Void, Never>?

        init() {
            super.init(target: nil, action: nil)
            allowedPressTypes = [UIPress.PressType.leftArrow, .rightArrow].map { NSNumber(value: $0.rawValue) }
            allowedTouchTypes = []
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            isEnabled = false
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            guard let press = presses.first(where: { $0.type == .leftArrow || $0.type == .rightArrow }) else { return }
            stopRepeating()
            let direction = press.type == .leftArrow ? -1 : 1
            repeatTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    while !Task.isCancelled {
                        guard let self, self.isEnabled else { return }
                        self.onMove(direction)
                        try await Task.sleep(for: .milliseconds(120))
                    }
                } catch { }
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            stopRepeating()
            state = .failed
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            stopRepeating()
            state = .failed
        }

        override func reset() {
            super.reset()
            stopRepeating()
        }

        func stopRepeating() {
            repeatTask?.cancel()
            repeatTask = nil
        }
    }
}
#endif

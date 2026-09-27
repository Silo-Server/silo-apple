#if os(tvOS)
import SwiftUI
import UIKit

/// Tells a deliberate move command from the stray one that can end a Siri
/// Remote touch-surface swipe.
///
/// A swipe that drifts can finish with a move command on the other axis, for
/// example a trailing `.down` after a sideways swipe across the top bar. Where
/// a handler turns that command into a programmatic jump (open a panel, close
/// a menu), the gate ignores it if it arrives within `quietPeriod` of a move on
/// the other axis. A physical arrow click that just began in the same
/// direction (clickpad ring, D-pad, IR remote) always passes; touch-surface
/// swipes produce no arrow presses.
struct TVCrossAxisGate {
    enum Axis: Equatable {
        case horizontal
        case vertical

        init(_ direction: MoveCommandDirection) {
            switch direction {
            case .left, .right: self = .horizontal
            default: self = .vertical
            }
        }
    }

    static let quietPeriod: Duration = .milliseconds(700)
    /// How recently a physical press must have begun to vouch for the move
    /// command it produced.
    static let pressWindow: Duration = .milliseconds(250)

    private var lastMove: (axis: Axis, at: ContinuousClock.Instant)?

    mutating func recordMove(_ axis: Axis, at now: ContinuousClock.Instant = .now) {
        lastMove = (axis, now)
    }

    @MainActor
    func allows(_ direction: MoveCommandDirection, at now: ContinuousClock.Instant = .now) -> Bool {
        let axis = Axis(direction)
        return Self.allows(
            axis: axis,
            now: now,
            lastOtherAxisMove: lastMove.flatMap { $0.axis == axis ? nil : $0.at },
            lastPress: TVRemotePressMonitor.shared.lastPressBegan(direction)
        )
    }

    static func allows(
        axis: Axis,
        now: ContinuousClock.Instant,
        lastOtherAxisMove: ContinuousClock.Instant?,
        lastPress: ContinuousClock.Instant?
    ) -> Bool {
        if let lastPress, now - lastPress <= pressWindow { return true }
        guard let lastOtherAxisMove else { return true }
        return now - lastOtherAxisMove >= quietPeriod
    }
}

/// Records when each physical arrow press began. Installed once on the app's
/// window by `.tvRemotePressMonitor()`.
@MainActor
final class TVRemotePressMonitor {
    static let shared = TVRemotePressMonitor()

    private var lastPressBegan: [UIPress.PressType: ContinuousClock.Instant] = [:]

    func lastPressBegan(_ direction: MoveCommandDirection) -> ContinuousClock.Instant? {
        switch direction {
        case .up: lastPressBegan[.upArrow]
        case .down: lastPressBegan[.downArrow]
        case .left: lastPressBegan[.leftArrow]
        case .right: lastPressBegan[.rightArrow]
        @unknown default: nil
        }
    }

    fileprivate func record(_ type: UIPress.PressType) {
        lastPressBegan[type] = .now
    }
}

extension View {
    /// Attaches the app-wide arrow press observer to this view's window.
    func tvRemotePressMonitor() -> some View {
        background(TVRemotePressMonitorInstaller().frame(width: 0, height: 0))
    }
}

private struct TVRemotePressMonitorInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> InstallerView { InstallerView() }
    func updateUIView(_ uiView: InstallerView, context: Context) {}

    final class InstallerView: UIView {
        private let observer = ArrowPressObserver()
        private weak var attachedWindow: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard attachedWindow !== window else { return }
            attachedWindow?.removeGestureRecognizer(observer)
            attachedWindow = window
            window?.addGestureRecognizer(observer)
        }
    }

    /// Never recognizes and never prevents another recognizer, so the focus
    /// engine and SwiftUI still receive every press.
    final class ArrowPressObserver: UIGestureRecognizer {
        private static let arrows: Set<UIPress.PressType> = [.upArrow, .downArrow, .leftArrow, .rightArrow]

        init() {
            super.init(target: nil, action: nil)
            allowedPressTypes = Self.arrows.map { NSNumber(value: $0.rawValue) }
            allowedTouchTypes = []
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            for press in presses where Self.arrows.contains(press.type) {
                MainActor.assumeIsolated { TVRemotePressMonitor.shared.record(press.type) }
            }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            state = .failed
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            state = .failed
        }
    }
}
#endif

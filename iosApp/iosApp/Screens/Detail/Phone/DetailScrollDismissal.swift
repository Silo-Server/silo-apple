import SwiftUI

extension View {
    /// Applied to the vertical scroll surface, never the horizontal rails.
    @ViewBuilder
    func detailScrollDismissal() -> some View {
        #if os(iOS)
        modifier(DetailScrollDismissalModifier())
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct DetailPullBackActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var detailPullBackAction: (() -> Void)? {
        get { self[DetailPullBackActionKey.self] }
        set { self[DetailPullBackActionKey.self] = newValue }
    }
}

enum DetailDismissalPolicy {
    static func isAtTop(offset: CGFloat, topInset: CGFloat) -> Bool {
        // Include the top rubber-band region; do not wait for it to settle.
        offset + topInset <= 1
    }

    static func canBeginBack(isAtTop: Bool, velocity: CGPoint) -> Bool {
        isAtTop && velocity.y > 0 && abs(velocity.x) < velocity.y * 0.6
    }

    static func shouldCompleteBack(translation: CGPoint, velocity: CGPoint) -> Bool {
        translation.y > 0 && abs(translation.x) < translation.y * 0.6
            && (translation.y >= 100 || (translation.y >= 35 && velocity.y >= 900))
    }
}

private struct DetailScrollDismissalModifier: ViewModifier {
    @Environment(\.detailPullBackAction) private var goBack
    @State private var isAtTop = true

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                DetailDismissalPolicy.isAtTop(
                    offset: geometry.contentOffset.y, topInset: geometry.contentInsets.top
                )
            } action: { _, atTop in
                isAtTop = atTop
            }
            // A new pull can move the sheet as soon as content reaches the
            // top, including while its bounce/deceleration is still active.
            .presentationContentInteraction(isAtTop ? .resizes : .scrolls)
            .gesture(DetailBackGesture(isAtTop: isAtTop, goBack: goBack))
    }
}

private struct DetailBackGesture: UIGestureRecognizerRepresentable {
    let isAtTop: Bool
    let goBack: (() -> Void)?

    func makeUIGestureRecognizer(context: Context) -> BackPanRecognizer {
        let recognizer = BackPanRecognizer(target: nil, action: nil)
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = recognizer
        updateUIGestureRecognizer(recognizer, context: context)
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: BackPanRecognizer, context: Context) {
        recognizer.canStartAtTop = isAtTop && goBack != nil
        recognizer.isEnabled = goBack != nil
    }

    func handleUIGestureRecognizerAction(_ recognizer: BackPanRecognizer, context: Context) {
        guard recognizer.state == .ended,
              DetailDismissalPolicy.shouldCompleteBack(
                translation: recognizer.translation(in: recognizer.view),
                velocity: recognizer.velocity(in: recognizer.view)
              ) else { return }
        goBack?()
    }

    final class BackPanRecognizer: UIPanGestureRecognizer, UIGestureRecognizerDelegate {
        var canStartAtTop = false

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            DetailDismissalPolicy.canBeginBack(isAtTop: canStartAtTop, velocity: velocity(in: view))
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif

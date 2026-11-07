#if os(iOS)
import SwiftUI
import UIKit

/// Two-finger trackpad scrubbing; see `TrackpadScrub`.
///
/// Attached at the player's root so it covers the controls and the gesture
/// layer alike. Revealing the controls drops `MobilePlayerGestureLayer` out of
/// hit testing, which would cancel a recognizer attached to it mid-swipe. The
/// recognizer takes scroll events only, never touches, so it can't compete
/// with the touch gestures there. Disabling it mid-swipe cancels the swipe,
/// which abandons the scrub without seeking.
struct PlayerTrackpadScrubRecognizer: UIGestureRecognizerRepresentable {
    let viewModel: PlayerViewModel
    let isEnabled: Bool

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.allowedTouchTypes = []
        pan.allowedScrollTypesMask = .continuous
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let coordinator = context.coordinator
        switch recognizer.state {
        case .began:
            coordinator.lastTranslation = .zero
            viewModel.trackpadScrubBegan()
            fallthrough
        case .changed:
            let translation = recognizer.translation(in: recognizer.view)
            let delta = CGSize(
                width: translation.x - coordinator.lastTranslation.x,
                height: translation.y - coordinator.lastTranslation.y
            )
            coordinator.lastTranslation = translation
            viewModel.trackpadScrubMoved(by: delta)
        case .ended:
            viewModel.trackpadScrubEnded(committing: true)
        case .cancelled, .failed:
            viewModel.trackpadScrubEnded(committing: false)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var lastTranslation = CGPoint.zero

        /// Never claims a mostly vertical scroll, which the swipe wouldn't use.
        /// Ties count as vertical, as in `TrackpadScrub`.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
#endif

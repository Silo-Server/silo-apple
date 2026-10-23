#if os(iOS)
import SwiftUI
import UIKit

extension View {
    /// Swipe toward the trailing edge to go back from the detail card. Pages
    /// pushed inside the card use the system back swipe, which shows the
    /// previous page underneath. On the card's first page the whole card
    /// follows the finger and closes, like the pull-down.
    ///
    /// Apply to the card's root page, inside its navigation stack.
    /// `onProgress` reports how far the card has moved aside, from 0 to 1,
    /// so the page underneath can show through.
    func detailSwipeBack(
        onProgress: @escaping (CGFloat) -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        background(DetailSwipeBackInstaller(progress: onProgress, dismiss: onDismiss))
    }
}

enum DetailSwipeBackPolicy {
    /// The same mostly-sideways test as the pull-down's mostly-downward one.
    static func canBegin(velocity: CGPoint, direction: CGFloat) -> Bool {
        let forward = velocity.x * direction
        return forward > 0 && abs(velocity.y) < forward * 0.6
    }

    static func shouldComplete(translation: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        translation >= width * 0.35 || (translation >= 40 && velocity >= 800)
    }
}

private struct DetailSwipeBackInstaller: UIViewRepresentable {
    let progress: (CGFloat) -> Void
    let dismiss: () -> Void

    func makeCoordinator() -> DetailSwipeBackCoordinator {
        DetailSwipeBackCoordinator()
    }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        context.coordinator.progress = progress
        context.coordinator.dismiss = dismiss
    }

    final class InstallerView: UIView {
        weak var coordinator: DetailSwipeBackCoordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            coordinator?.install(from: self)
        }
    }
}

final class DetailSwipeBackCoordinator: NSObject, UIGestureRecognizerDelegate {
    var progress: (CGFloat) -> Void = { _ in }
    var dismiss: () -> Void = {}

    private weak var navigation: UINavigationController?
    private weak var card: UIView?
    private weak var presented: UIViewController?
    private var popDelegates: [PopGestureDelegate] = []
    private lazy var cardPan = UIPanGestureRecognizer(target: self, action: #selector(handleCardPan))
    private var cardBackground: UIColor?

    func install(from view: UIView) {
        guard navigation == nil, let navigation = view.nearestNavigationController else { return }
        self.navigation = navigation

        // A hidden navigation bar turns the system back swipe off; the card's
        // pages draw their own Back button, so turn it back on.
        var recognizers = [navigation.interactivePopGestureRecognizer]
        if #available(iOS 26.0, *) {
            recognizers.append(navigation.interactiveContentPopGestureRecognizer)
        }
        for case let recognizer? in recognizers {
            let delegate = PopGestureDelegate(navigation: navigation, original: recognizer.delegate)
            recognizer.delegate = delegate
            recognizer.isEnabled = true
            popDelegates.append(delegate)
        }

        var presented: UIViewController = navigation
        while let parent = presented.parent { presented = parent }
        // A full-screen cover takes the page underneath away, so there is
        // nothing to reveal; it closes with its Close button instead.
        guard presented.presentingViewController != nil,
              presented.modalPresentationStyle != .fullScreen,
              let card = presented.presentationController?.presentedView ?? presented.view else { return }
        self.card = card
        self.presented = presented
        cardPan.maximumNumberOfTouches = 1
        cardPan.delegate = self
        card.addGestureRecognizer(cardPan)
    }

    /// +1 when Back is a swipe to the right, -1 in right-to-left layouts.
    private var direction: CGFloat {
        card?.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
    }

    @objc private func handleCardPan(_ pan: UIPanGestureRecognizer) {
        guard let card else { return }
        let width = max(card.bounds.width, 1)
        let translation = max(0, pan.translation(in: card.superview).x * direction)
        switch pan.state {
        case .began:
            // The card's container paints a background that stays put while
            // its contents move; hide it so the page underneath shows.
            if cardBackground == nil { cardBackground = card.backgroundColor }
            card.backgroundColor = .clear
        case .changed:
            offset(card, by: translation * direction)
            reveal(min(translation / width, 1))
        case .ended:
            let velocity = pan.velocity(in: card.superview).x * direction
            if DetailSwipeBackPolicy.shouldComplete(translation: translation, velocity: velocity, width: width) {
                slideAway(card)
            } else {
                springBack(card)
            }
        case .cancelled, .failed:
            springBack(card)
        default:
            break
        }
    }

    /// Moves what the card draws rather than the card itself: the sheet
    /// puts the card's own transform back every time it lays out.
    private func offset(_ card: UIView, by x: CGFloat) {
        let transform = CGAffineTransform(translationX: x, y: 0)
        card.subviews.forEach { $0.transform = transform }
    }

    /// Lightens what covers the page underneath as the card moves aside:
    /// the app's own mask, through `progress`, and the dimming the system
    /// puts over the presenting page.
    private func reveal(_ fraction: CGFloat) {
        progress(fraction)
        presentingDimming.forEach { $0.alpha = 1 - fraction }
    }

    private var presentingDimming: [UIView] {
        guard let container = presented?.presentingViewController?.view.superview else { return [] }
        return container.subviews.filter { String(describing: type(of: $0)).contains("Dimming") }
    }

    /// Slides the card the rest of the way, then closes it without the
    /// system animation, which would first put the card back in place.
    private func slideAway(_ card: UIView) {
        let velocity = abs(cardPan.velocity(in: card.superview).x)
        let remaining = max(card.bounds.width - abs(card.subviews.first?.transform.tx ?? 0), 1)
        let duration = min(max(TimeInterval(remaining / max(velocity, 1)), 0.12), 0.25)
        let offscreen = (card.window?.bounds.width ?? card.bounds.width) * direction
        withAnimation(.easeOut(duration: duration)) { progress(1) }
        UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut) {
            self.offset(card, by: offscreen)
            self.presentingDimming.forEach { $0.alpha = 0 }
        } completion: { _ in
            card.alpha = 0
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, self.dismiss)
        }
    }

    private func springBack(_ card: UIView) {
        withAnimation(.spring(duration: 0.35)) { progress(0) }
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.offset(card, by: 0)
            self.presentingDimming.forEach { $0.alpha = 1 }
        } completion: { _ in
            guard self.cardPan.state == .possible, let background = self.cardBackground else { return }
            card.backgroundColor = background
            self.cardBackground = nil
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === cardPan, let card,
              navigation?.viewControllers.count == 1,
              DetailSwipeBackPolicy.canBegin(velocity: cardPan.velocity(in: card), direction: direction)
        else { return false }
        return !startsOnRailThatCanScrollBack(in: card)
    }

    /// A row that is scrolled away from its start takes the swipe and
    /// scrolls back first, as it does with the system back swipe.
    private func startsOnRailThatCanScrollBack(in card: UIView) -> Bool {
        var view = card.hitTest(cardPan.location(in: card), with: nil)
        while let current = view, current !== card {
            if let scrollView = current as? UIScrollView,
               scrollView.contentSize.width > scrollView.bounds.width + 1,
               scrollView.contentOffset.x > -scrollView.adjustedContentInset.left + 1 {
                return true
            }
            view = current.superview
        }
        return false
    }

    /// Scrolling waits for the card swipe to decline, so a sideways swipe on
    /// a row that is already at its start moves the card instead of
    /// bouncing the row.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === cardPan, let card,
              otherGestureRecognizer is UIPanGestureRecognizer,
              let otherView = otherGestureRecognizer.view else { return false }
        return otherView.isDescendant(of: card)
    }
}

/// Lets the system back swipe receive touches and start whenever there is a
/// page to return to. The system's own delegate refuses both while the
/// navigation bar is hidden.
private final class PopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    private weak var navigation: UINavigationController?
    private weak var original: UIGestureRecognizerDelegate?

    init(navigation: UINavigationController, original: UIGestureRecognizerDelegate?) {
        self.navigation = navigation
        self.original = original
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigation, navigation.viewControllers.count > 1,
              navigation.transitionCoordinator == nil else { return false }
        return true
    }

    /// Leaves conflicts with scroll views and other gestures to the system.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        original?.gestureRecognizer?(gestureRecognizer, shouldRecognizeSimultaneouslyWith: otherGestureRecognizer) ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        original?.gestureRecognizer?(gestureRecognizer, shouldRequireFailureOf: otherGestureRecognizer) ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        original?.gestureRecognizer?(gestureRecognizer, shouldBeRequiredToFailBy: otherGestureRecognizer) ?? false
    }
}

private extension UIView {
    var nearestNavigationController: UINavigationController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let navigation = current as? UINavigationController { return navigation }
            responder = current.next
        }
        return nil
    }
}
#endif

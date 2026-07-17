#if os(tvOS)
import SwiftUI
import UIKit

/// Bridges the Siri Remote's press lifecycle into SwiftUI. `.onMoveCommand`
/// only exposes single press events with no way to distinguish a held
/// press from a tap, so seek-mode entry — where we want a long press to
/// enter a persistent seek session and a short press to trigger a quick
/// skip — isn't expressible in pure SwiftUI. This representable hosts a
/// focusable `UIView` that overrides `pressesBegan` / `pressesEnded` /
/// `pressesCancelled` and fires two callbacks: quick tap (released
/// before the hold threshold), hold begin (crossed the threshold while still
/// held), hold repeat, and hold end.
struct TVPressCaptureView: UIViewRepresentable {
    enum ArrowDirection: Hashable {
        case left, right, up, down
    }

    /// Which arrow directions this view should consume. Directions outside
    /// this set fall through to UIKit so normal focus movement can continue.
    var capturedDirections: Set<ArrowDirection> = [.left, .right, .up, .down]
    /// Press + release within the hold threshold.
    var onArrowTap: (ArrowDirection) -> Void = { _ in }
    /// Crossed the threshold while still held — seek session should start.
    var onArrowHoldBegin: (ArrowDirection) -> Void = { _ in }
    /// Fires repeatedly while an arrow remains held after hold-begin.
    var onArrowHoldRepeat: (ArrowDirection) -> Void = { _ in }
    /// Release after a hold.
    var onArrowHoldEnd: (ArrowDirection) -> Void = { _ in }
    /// Finger contact with the Siri Remote touch surface, without requiring
    /// the clickpad/Select button to be pressed.
    var onTouchSurfaceContactBegan: () -> Void = {}
    var onTouchSurfaceContactEnded: () -> Void = {}
    var onTouchSurfaceContactCancelled: () -> Void = {}
    /// Select (center button) press. Menu is intentionally not intercepted
    /// so SwiftUI's `.onExitCommand` chain continues to own it.
    var onSelect: () -> Void = {}

    func makeUIView(context: Context) -> PressCaptureUIView {
        let v = PressCaptureUIView()
        apply(to: v)
        return v
    }

    func updateUIView(_ uiView: PressCaptureUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: PressCaptureUIView) {
        view.capturedDirections = capturedDirections
        view.onArrowTap = onArrowTap
        view.onArrowHoldBegin = onArrowHoldBegin
        view.onArrowHoldRepeat = onArrowHoldRepeat
        view.onArrowHoldEnd = onArrowHoldEnd
        view.onTouchSurfaceContactBegan = onTouchSurfaceContactBegan
        view.onTouchSurfaceContactEnded = onTouchSurfaceContactEnded
        view.onTouchSurfaceContactCancelled = onTouchSurfaceContactCancelled
        view.onSelect = onSelect
    }
}

/// Window-level press gesture bridge for places where SwiftUI owns focus but
/// we still need press lifecycle. Unlike `TVPressCaptureView`, this view does
/// not need to become focused; UIKit gesture recognizers attached to the window
/// observe the remote press while SwiftUI keeps rendering the focused scrubber.
struct TVDirectionalPressGestureView: UIViewRepresentable {
    var isActive: Bool
    var onArrowTap: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onArrowHoldBegin: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onArrowHoldRepeat: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onArrowHoldEnd: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }

    func makeUIView(context: Context) -> DirectionalPressGestureUIView {
        let view = DirectionalPressGestureUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: DirectionalPressGestureUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: DirectionalPressGestureUIView) {
        view.isActive = isActive
        view.onArrowTap = onArrowTap
        view.onArrowHoldBegin = onArrowHoldBegin
        view.onArrowHoldRepeat = onArrowHoldRepeat
        view.onArrowHoldEnd = onArrowHoldEnd
    }
}

/// Window-level trackpad pan bridge. SwiftUI on tvOS only surfaces the Siri
/// Remote touch surface as discrete `.onMoveCommand` steps, so continuous
/// drag-the-playhead scrubbing needs a `UIPanGestureRecognizer` reading the
/// indirect touch stream. Attached to the window (like
/// `TVDirectionalPressGestureView`) so SwiftUI keeps owning focus while the
/// pan translation streams through the callbacks.
struct TVPanCaptureView: UIViewRepresentable {
    var isActive: Bool
    var onPanBegan: () -> Void = {}
    /// Incremental horizontal translation (points) since the last change.
    var onPanChanged: (CGFloat) -> Void = { _ in }
    var onPanEnded: () -> Void = {}

    func makeUIView(context: Context) -> PanCaptureUIView {
        let view = PanCaptureUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: PanCaptureUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: PanCaptureUIView) {
        view.isActive = isActive
        view.onPanBegan = onPanBegan
        view.onPanChanged = onPanChanged
        view.onPanEnded = onPanEnded
    }
}

final class PanCaptureUIView: UIView, UIGestureRecognizerDelegate {
    var isActive: Bool = false
    var onPanBegan: () -> Void = {}
    var onPanChanged: (CGFloat) -> Void = { _ in }
    var onPanEnded: () -> Void = {}

    private weak var attachedWindow: UIWindow?
    private var panRecognizer: UIPanGestureRecognizer?
    private var lastTranslationX: CGFloat = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Leaving the window (nil) must tear the recognizer off the old
        // window deterministically rather than waiting for deinit.
        if window == nil {
            detachRecognizer()
        } else {
            attachRecognizerIfNeeded()
        }
    }

    deinit {
        detachRecognizer()
    }

    private func attachRecognizerIfNeeded() {
        guard let window, attachedWindow !== window else { return }
        detachRecognizer()
        attachedWindow = window

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.delegate = self
        window.addGestureRecognizer(pan)
        panRecognizer = pan
    }

    private func detachRecognizer() {
        if let attachedWindow, let panRecognizer {
            attachedWindow.removeGestureRecognizer(panRecognizer)
        }
        panRecognizer = nil
        attachedWindow = nil
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard isActive else { return }
            lastTranslationX = recognizer.translation(in: attachedWindow).x
            onPanBegan()
        case .changed:
            guard isActive else { return }
            let x = recognizer.translation(in: attachedWindow).x
            onPanChanged(x - lastTranslationX)
            lastTranslationX = x
        case .ended, .cancelled, .failed:
            // Deliver the end even if `isActive` dropped mid-gesture (e.g.
            // the scrub was cancelled under the finger) so the SwiftUI side
            // never gets stuck thinking a pan is still in flight.
            onPanEnded()
        default:
            break
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isActive
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

final class DirectionalPressGestureUIView: UIView, UIGestureRecognizerDelegate {
    var isActive: Bool = false
    var onArrowTap: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onArrowHoldBegin: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onArrowHoldRepeat: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onArrowHoldEnd: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }

    private static let holdThreshold: TimeInterval = 0.3
    private static let holdRepeatInterval: TimeInterval = 0.1

    private weak var attachedWindow: UIWindow?
    private var recognizers: [UIGestureRecognizer] = []
    private var didFireHold: [TVPressCaptureView.ArrowDirection: Bool] = [:]
    private var repeatTimers: [TVPressCaptureView.ArrowDirection: DispatchWorkItem] = [:]

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Same teardown contract as PanCaptureUIView: leaving the window
        // detaches from the old window immediately, not at deinit.
        if window == nil {
            cancelAllRepeatTimers()
            detachRecognizers()
        } else {
            attachRecognizersIfNeeded()
        }
    }

    deinit {
        cancelAllRepeatTimers()
        detachRecognizers()
    }

    private func attachRecognizersIfNeeded() {
        guard let window, attachedWindow !== window else { return }
        detachRecognizers()
        attachedWindow = window

        for direction in [TVPressCaptureView.ArrowDirection.left, .right] {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.allowedPressTypes = [NSNumber(value: pressType(for: direction).rawValue)]
            tap.delegate = self
            tap.name = gestureName(for: direction)

            let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
            hold.allowedPressTypes = [NSNumber(value: pressType(for: direction).rawValue)]
            hold.minimumPressDuration = Self.holdThreshold
            hold.delegate = self
            hold.name = gestureName(for: direction)

            tap.require(toFail: hold)
            window.addGestureRecognizer(tap)
            window.addGestureRecognizer(hold)
            recognizers.append(tap)
            recognizers.append(hold)
        }
    }

    private func detachRecognizers() {
        guard let attachedWindow else { return }
        for recognizer in recognizers {
            attachedWindow.removeGestureRecognizer(recognizer)
        }
        recognizers.removeAll()
        self.attachedWindow = nil
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard isActive, recognizer.state == .ended, let direction = direction(for: recognizer) else { return }
        onArrowTap(direction)
    }

    @objc private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
        guard isActive, let direction = direction(for: recognizer) else { return }
        switch recognizer.state {
        case .began:
            didFireHold[direction] = true
            onArrowHoldBegin(direction)
            scheduleHoldRepeat(for: direction)
        case .ended, .cancelled, .failed:
            cancelHoldRepeat(for: direction)
            if didFireHold[direction] == true {
                onArrowHoldEnd(direction)
            }
            didFireHold[direction] = false
        default:
            break
        }
    }

    private func scheduleHoldRepeat(for direction: TVPressCaptureView.ArrowDirection) {
        cancelHoldRepeat(for: direction)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, self.didFireHold[direction] == true else { return }
            self.onArrowHoldRepeat(direction)
            self.scheduleHoldRepeat(for: direction)
        }
        repeatTimers[direction] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdRepeatInterval, execute: workItem)
    }

    private func cancelHoldRepeat(for direction: TVPressCaptureView.ArrowDirection) {
        repeatTimers.removeValue(forKey: direction)?.cancel()
    }

    private func cancelAllRepeatTimers() {
        for timer in repeatTimers.values {
            timer.cancel()
        }
        repeatTimers.removeAll()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isActive
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    private func gestureName(for direction: TVPressCaptureView.ArrowDirection) -> String {
        switch direction {
        case .left: return "continuum.leftPress"
        case .right: return "continuum.rightPress"
        case .up, .down: return "continuum.otherPress"
        }
    }

    private func direction(for recognizer: UIGestureRecognizer) -> TVPressCaptureView.ArrowDirection? {
        switch recognizer.name {
        case "continuum.leftPress": return .left
        case "continuum.rightPress": return .right
        default: return nil
        }
    }

    private func pressType(for direction: TVPressCaptureView.ArrowDirection) -> UIPress.PressType {
        switch direction {
        case .left: return .leftArrow
        case .right: return .rightArrow
        case .up: return .upArrow
        case .down: return .downArrow
        }
    }
}

final class PressCaptureUIView: UIView {
    var capturedDirections: Set<TVPressCaptureView.ArrowDirection> = [.left, .right, .up, .down]
    var onArrowTap: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onArrowHoldBegin: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onArrowHoldRepeat: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onArrowHoldEnd: (TVPressCaptureView.ArrowDirection) -> Void = { _ in }
    var onTouchSurfaceContactBegan: () -> Void = {}
    var onTouchSurfaceContactEnded: () -> Void = {}
    var onTouchSurfaceContactCancelled: () -> Void = {}
    var onSelect: () -> Void = {}

    /// Threshold between "tap" and "hold". 300 ms is snappy enough that a
    /// deliberate single press never feels like it missed, but long enough
    /// that a natural press-and-release doesn't trip hold-seek.
    private static let holdThreshold: TimeInterval = 0.3
    private static let holdRepeatInterval: TimeInterval = 0.1

    private struct Pending {
        let direction: TVPressCaptureView.ArrowDirection
        var holdTimer: DispatchWorkItem?
        var repeatTimer: DispatchWorkItem?
        var didFireHold: Bool
    }
    /// In-flight arrow presses keyed by `UIPress.PressType` so multiple
    /// simultaneous presses (rare on the Siri Remote, but possible on a
    /// Bluetooth keyboard) track independently.
    private var pending: [UIPress.PressType: Pending] = [:]
    private var activeIndirectTouchIDs: Set<ObjectIdentifier> = []

    override var canBecomeFocused: Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let indirectTouches = touches.filter { $0.type == .indirect }
        let wasInactive = activeIndirectTouchIDs.isEmpty
        activeIndirectTouchIDs.formUnion(indirectTouches.map(ObjectIdentifier.init))
        if wasInactive, !activeIndirectTouchIDs.isEmpty {
            onTouchSurfaceContactBegan()
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishIndirectTouches(touches, cancelled: false)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishIndirectTouches(touches, cancelled: true)
        super.touchesCancelled(touches, with: event)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let direction = Self.arrowDirection(from: press.type),
               capturedDirections.contains(direction) {
                handled = true
                startArrow(type: press.type, direction: direction)
            } else if press.type == .select {
                handled = true
                onSelect()
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let direction = Self.arrowDirection(from: press.type),
               capturedDirections.contains(direction) {
                handled = true
                endArrow(type: press.type)
            }
        }
        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let direction = Self.arrowDirection(from: press.type),
                  capturedDirections.contains(direction)
            else { continue }
            endArrow(type: press.type)
        }
        super.pressesCancelled(presses, with: event)
    }

    private func startArrow(type: UIPress.PressType, direction: TVPressCaptureView.ArrowDirection) {
        // Schedule the hold-fire callback. If `pressesEnded` runs before
        // it executes, we cancel and emit a tap instead.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, var entry = self.pending[type] else { return }
            entry.didFireHold = true
            self.pending[type] = entry
            self.onArrowHoldBegin(direction)
            self.scheduleHoldRepeat(type: type)
        }
        pending[type] = Pending(direction: direction, holdTimer: workItem, repeatTimer: nil, didFireHold: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdThreshold, execute: workItem)
    }

    private func scheduleHoldRepeat(type: UIPress.PressType) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, var entry = self.pending[type], entry.didFireHold else { return }
            self.onArrowHoldRepeat(entry.direction)
            entry.repeatTimer = nil
            self.pending[type] = entry
            self.scheduleHoldRepeat(type: type)
        }
        guard var entry = pending[type], entry.didFireHold else { return }
        entry.repeatTimer = workItem
        pending[type] = entry
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdRepeatInterval, execute: workItem)
    }

    private func endArrow(type: UIPress.PressType) {
        guard let entry = pending.removeValue(forKey: type) else { return }
        entry.holdTimer?.cancel()
        entry.repeatTimer?.cancel()
        if entry.didFireHold {
            onArrowHoldEnd(entry.direction)
        } else {
            onArrowTap(entry.direction)
        }
    }

    private func finishIndirectTouches(_ touches: Set<UITouch>, cancelled: Bool) {
        let endedIDs = touches
            .filter { $0.type == .indirect }
            .map(ObjectIdentifier.init)
        guard !endedIDs.isEmpty else { return }
        activeIndirectTouchIDs.subtract(endedIDs)
        if activeIndirectTouchIDs.isEmpty {
            if cancelled {
                onTouchSurfaceContactCancelled()
            } else {
                onTouchSurfaceContactEnded()
            }
        }
    }

    private static func arrowDirection(from type: UIPress.PressType) -> TVPressCaptureView.ArrowDirection? {
        switch type {
        case .leftArrow:  return .left
        case .rightArrow: return .right
        case .upArrow:    return .up
        case .downArrow:  return .down
        default:          return nil
        }
    }
}
#endif

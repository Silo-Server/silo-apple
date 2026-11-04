#if os(macOS)
import AppKit
import SwiftUI

/// Marks the horizontal scroll view it sits in as a rail that follows a
/// mouse click-and-drag. An AppKit scroll view only scrolls from a trackpad
/// or wheel, so a mouse user had no way to move a rail sideways.
///
/// Placed inside the rail's content (see `mouseDragScrolling()`), so its
/// enclosing scroll view is the rail rather than the page around it. It never
/// takes clicks itself: `MacMouseDragScroller` watches the window's mouse
/// events and only steps in once a press turns into a sideways drag.
struct MacMouseDragScrollingAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> MacMouseDragScrollingAnchorView {
        MacMouseDragScrollingAnchorView()
    }

    func updateNSView(_ nsView: MacMouseDragScrollingAnchorView, context: Context) {
        nsView.registerEnclosingRail()
    }
}

final class MacMouseDragScrollingAnchorView: NSView {
    /// Never the hit view, so a press resolves to the rail's content.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerEnclosingRail()
    }

    func registerEnclosingRail() {
        guard window != nil, let rail = enclosingScrollView else { return }
        MacMouseDragScroller.shared.register(rail)
    }
}

/// Turns a click-and-drag on a registered rail into scrolling.
///
/// A press that stays within `MouseDragScrollGesture.threshold` passes
/// through untouched, so it still opens the card. Once it becomes a sideways
/// drag, the card's press is ended outside its bounds (so it never fires),
/// the rest of the drag is kept from the card, and the rail follows the
/// pointer, then glides on with momentum after release.
@MainActor
final class MacMouseDragScroller {
    static let shared = MacMouseDragScroller()

    private struct Session {
        weak var rail: NSScrollView?
        let window: NSWindow
        let startOriginX: CGFloat
        var gesture: MouseDragScrollGesture
    }

    private struct Glide {
        weak var rail: NSScrollView?
        var momentum: MouseDragScrollMomentum
        var lastTime: TimeInterval
    }

    private let rails = NSHashTable<NSScrollView>.weakObjects()
    private var monitor: Any?
    private var session: Session?
    private var glide: Glide?
    private var glideTimer: Timer?
    private var showsGrabCursor = false

    private init() {}

    func register(_ rail: NSScrollView) {
        rails.add(rail)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        ) { [weak self] event in
            let input = MainThreadEvent(value: event)
            return MainActor.assumeIsolated {
                guard let self, let event = input.value else { return input }
                return MainThreadEvent(value: self.handle(event))
            }.value
        }
    }

    /// AppKit runs local monitors on the main thread, so the event never
    /// leaves it; the box only carries it into the main-actor closure.
    private struct MainThreadEvent: @unchecked Sendable {
        let value: NSEvent?
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            return mouseDown(event)
        case .leftMouseDragged:
            return mouseDragged(event)
        case .leftMouseUp:
            return mouseUp(event)
        case .scrollWheel:
            // A trackpad or wheel scroll on the gliding rail takes over.
            if let rail = glide?.rail, rail === self.rail(at: event) { stopGlide() }
            return event
        default:
            return event
        }
    }

    private func mouseDown(_ event: NSEvent) -> NSEvent? {
        stopGlide()
        endSession()
        // Modified clicks (Control for the context menu, Command, and so on)
        // and double clicks keep their own meaning.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty, event.clickCount == 1,
              let window = event.window, let rail = rail(at: event) else { return event }
        session = Session(
            rail: rail,
            window: window,
            startOriginX: rail.contentView.bounds.origin.x,
            gesture: MouseDragScrollGesture(start: event.locationInWindow, time: event.timestamp)
        )
        return event
    }

    private func mouseDragged(_ event: NSEvent) -> NSEvent? {
        guard var current = session, event.window === current.window else { return event }
        guard let rail = current.rail else {
            endSession()
            return event
        }
        let wasDragging = current.gesture.phase == .dragging
        let isDragging = current.gesture.move(to: event.locationInWindow, time: event.timestamp)
        session = current
        guard isDragging else { return event }

        // Content follows the pointer, so the origin moves against it.
        setOriginX(current.startOriginX - current.gesture.translation, of: rail)
        if wasDragging { return nil }

        // The drag just began: end the card's press away from it so the
        // button sees a release outside its bounds and doesn't fire.
        setGrabCursor(true)
        return Self.cancellingMouseUp(for: event)
    }

    private func mouseUp(_ event: NSEvent) -> NSEvent? {
        guard let current = session else { return event }
        endSession()
        guard current.gesture.phase == .dragging else { return event }
        startGlide(
            on: current.rail,
            // Pointer velocity to the right scrolls the origin left.
            velocity: -current.gesture.releaseVelocity(at: event.timestamp),
            at: event.timestamp
        )
        // The card's press already ended when the drag began.
        return nil
    }

    private func endSession() {
        session = nil
        setGrabCursor(false)
    }

    /// The registered rail under the pointer, if the innermost scroll view
    /// there is one. A sheet or popover over a rail hit-tests to itself.
    private func rail(at event: NSEvent) -> NSScrollView? {
        guard let contentView = event.window?.contentView else { return nil }
        let point = contentView.superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        var view = contentView.hitTest(point)
        while let current = view {
            if let scrollView = current as? NSScrollView {
                return rails.contains(scrollView) ? scrollView : nil
            }
            view = current.superview
        }
        return nil
    }

    /// Scrolls `rail` horizontally, kept within its content. Returns whether
    /// the rail moved the whole way (false at either end).
    @discardableResult
    private func setOriginX(_ x: CGFloat, of rail: NSScrollView) -> Bool {
        let clipView = rail.contentView
        var bounds = clipView.bounds
        bounds.origin.x = x
        let origin = clipView.constrainBoundsRect(bounds).origin
        if origin != clipView.bounds.origin {
            clipView.scroll(to: origin)
            rail.reflectScrolledClipView(clipView)
        }
        return abs(origin.x - x) < 0.5
    }

    private func startGlide(on rail: NSScrollView?, velocity: CGFloat, at time: TimeInterval) {
        let momentum = MouseDragScrollMomentum(velocity: velocity)
        guard let rail, !momentum.isFinished else { return }
        glide = Glide(rail: rail, momentum: momentum, lastTime: time)
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepGlide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        glideTimer = timer
    }

    private func stepGlide() {
        guard var current = glide, let rail = current.rail else {
            stopGlide()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let distance = current.momentum.step(by: now - current.lastTime)
        current.lastTime = now
        glide = current
        let reachedTarget = setOriginX(rail.contentView.bounds.origin.x + distance, of: rail)
        if current.momentum.isFinished || !reachedTarget { stopGlide() }
    }

    private func stopGlide() {
        glideTimer?.invalidate()
        glideTimer = nil
        glide = nil
    }

    private func setGrabCursor(_ grabbing: Bool) {
        guard grabbing != showsGrabCursor else { return }
        showsGrabCursor = grabbing
        if grabbing { NSCursor.closedHand.push() } else { NSCursor.pop() }
    }

    /// A left-button release far outside the window, in place of `event`. It
    /// goes to the view that took the press, which ends the press as a
    /// release outside the card.
    private static func cancellingMouseUp(for event: NSEvent) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: -100_000, y: -100_000),
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: 1,
            pressure: 0
        )
    }
}
#endif

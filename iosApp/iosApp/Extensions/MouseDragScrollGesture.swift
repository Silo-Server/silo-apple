import CoreGraphics
import Foundation

/// Tells a click from a sideways drag on a horizontal rail, and measures the
/// drag so the rail can follow the pointer and glide on after release.
///
/// Only the Mac app drives a rail this way (`mouseDragScrolling()`); touch
/// platforms scroll natively. Kept free of AppKit so it can be unit-tested.
struct MouseDragScrollGesture {
    enum Phase: Equatable {
        /// Pressed, but not yet far enough from the press to be a drag.
        case pending
        /// A sideways drag: the rail follows the pointer and the press must
        /// not end as a click.
        case dragging
        /// Moved mostly vertically: left alone, so it stays an ordinary press.
        case ignored
    }

    /// How far the pointer travels before a press becomes a drag. Below this,
    /// a slightly shaky click still opens the card.
    static let threshold: CGFloat = 6
    /// Samples older than this at release don't count toward the fling.
    static let velocityWindow: TimeInterval = 0.1
    /// A pointer held still this long before release ends without a glide.
    static let restInterval: TimeInterval = 0.08
    static let maxVelocity: CGFloat = 6_000

    private(set) var phase: Phase = .pending
    private let start: CGPoint
    private var samples: [(time: TimeInterval, x: CGFloat)]

    init(start: CGPoint, time: TimeInterval) {
        self.start = start
        samples = [(time, start.x)]
    }

    /// Horizontal travel since the press: how far the content should follow
    /// the pointer. Positive when the pointer moved right.
    var translation: CGFloat { (samples.last?.x ?? start.x) - start.x }

    /// Records a pointer move. Returns true once the press is a drag.
    @discardableResult
    mutating func move(to point: CGPoint, time: TimeInterval) -> Bool {
        switch phase {
        case .ignored:
            return false
        case .pending:
            let dx = point.x - start.x
            let dy = point.y - start.y
            guard hypot(dx, dy) >= Self.threshold else { return false }
            guard abs(dx) >= abs(dy) else {
                phase = .ignored
                return false
            }
            phase = .dragging
        case .dragging:
            break
        }
        samples.append((time, point.x))
        samples.removeAll { time - $0.time > Self.velocityWindow }
        return true
    }

    /// Pointer velocity at release in points per second, positive to the
    /// right. Zero when the pointer had come to rest before the button lifted.
    func releaseVelocity(at time: TimeInterval) -> CGFloat {
        guard phase == .dragging,
              let first = samples.first, let last = samples.last,
              time - last.time < Self.restInterval else { return 0 }
        let elapsed = last.time - first.time
        guard elapsed > 0 else { return 0 }
        let velocity = (last.x - first.x) / CGFloat(elapsed)
        return min(max(velocity, -Self.maxVelocity), Self.maxVelocity)
    }
}

/// The glide after a fling, decaying like a native scroll view's momentum.
struct MouseDragScrollMomentum {
    /// Fraction of velocity kept per millisecond (UIScrollView's normal rate).
    static let decelerationPerMillisecond: CGFloat = 0.998
    /// Below this speed, in points per second, the glide stops.
    static let stopVelocity: CGFloat = 15

    private(set) var velocity: CGFloat

    init(velocity: CGFloat) {
        self.velocity = velocity
    }

    var isFinished: Bool { abs(velocity) < Self.stopVelocity }

    /// Advances the glide by `interval` seconds and returns how far it moved.
    mutating func step(by interval: TimeInterval) -> CGFloat {
        guard !isFinished, interval > 0 else { return 0 }
        let decay = pow(Self.decelerationPerMillisecond, CGFloat(interval * 1_000))
        // Integral of v·rᵗ over the step, so frame rate doesn't change distance.
        let distance = velocity * (decay - 1) / log(Self.decelerationPerMillisecond) / 1_000
        velocity *= decay
        return distance
    }
}

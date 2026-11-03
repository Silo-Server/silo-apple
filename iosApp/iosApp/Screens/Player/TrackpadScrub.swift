#if os(iOS) || os(macOS)
import CoreGraphics

/// Decides whether one swipe over the player scrubs: a two-finger trackpad
/// swipe, or a Magic Mouse scroll. `PlayerViewModel` turns the horizontal
/// travel it reports into playhead movement.
///
/// The swipe commits to an axis once it has travelled `axisLockDistance`, and
/// only a horizontal swipe scrubs. Travel follows the system's scroll
/// direction, so with natural scrolling, the default, the playhead moves with
/// the fingers.
struct TrackpadScrub {
    /// Horizontal travel, in points, that covers a whole timeline, so the rate
    /// scales with the video's length: about 1.8 seconds per point of a
    /// two-hour film and 0.33 of a 22-minute episode. It doesn't depend on the
    /// window, because trackpad travel has nothing to do with the window's size.
    static let pointsPerTimeline: CGFloat = 4_000
    static let axisLockDistance: CGFloat = 6

    enum Step: Equatable {
        /// The swipe went horizontal, after `points` of horizontal travel.
        case begin(points: CGFloat)
        case move(points: CGFloat)
    }

    private enum State {
        case idle
        case deciding(travel: CGSize)
        case owning
        /// Vertical, refused, or abandoned: the rest of the swipe does nothing.
        case ignoring
    }

    private var state = State.idle

    var ownsScrub: Bool {
        if case .owning = state { return true }
        return false
    }

    /// A player that can't seek ignores the whole swipe.
    mutating func start(canSeek: Bool) {
        state = canSeek ? .deciding(travel: .zero) : .ignoring
    }

    mutating func move(by delta: CGSize) -> Step? {
        switch state {
        case .idle, .ignoring:
            return nil
        case .deciding(var travel):
            travel.width += delta.width
            travel.height += delta.height
            guard max(abs(travel.width), abs(travel.height)) >= Self.axisLockDistance else {
                state = .deciding(travel: travel)
                return nil
            }
            guard abs(travel.width) > abs(travel.height) else {
                state = .ignoring
                return nil
            }
            state = .owning
            return .begin(points: travel.width)
        case .owning:
            return .move(points: delta.width)
        }
    }

    mutating func abandon() {
        if ownsScrub { state = .ignoring }
    }

    /// Ends the swipe. Returns whether it owned the scrub.
    mutating func finish() -> Bool {
        defer { state = .idle }
        return ownsScrub
    }
}
#endif

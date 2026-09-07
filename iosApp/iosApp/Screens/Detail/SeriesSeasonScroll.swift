import Foundation

/// One continuous episode-rail scroll, including changes to the loaded row's origin.
struct SeriesSeasonScroll {
    private(set) var startOffset: CGFloat
    private(set) var targetOffset: CGFloat
    let startedAt: TimeInterval
    enum Timing {
        case season
        case episode

        var duration: TimeInterval { self == .season ? 0.45 : 0.30 }
    }

    var timing: Timing = .season

    func offset(at time: TimeInterval) -> CGFloat {
        let progress = min(1, max(0, (time - startedAt) / timing.duration))
        let eased = timing == .season
            ? progress * progress * (3 - 2 * progress)
            : 1 - pow(1 - progress, 3)
        return startOffset + (targetOffset - startOffset) * eased
    }

    func isComplete(at time: TimeInterval) -> Bool {
        time >= startedAt + timing.duration
    }

    /// Clamp rendered frames, not the animation endpoints, so paging keeps
    /// the same easing and deadline even when a boundary clips the motion.
    static func clampedOffset(_ offset: CGFloat, maximumOffset: CGFloat) -> CGFloat {
        min(max(0, offset), max(0, maximumOffset))
    }

    mutating func rebase(by shift: CGFloat) {
        startOffset += shift
        targetOffset += shift
    }
}

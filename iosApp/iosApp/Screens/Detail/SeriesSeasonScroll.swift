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
        startOffset + (targetOffset - startOffset) * easedProgress(at: time)
    }

    private func easedProgress(at time: TimeInterval) -> CGFloat {
        let progress = min(1, max(0, (time - startedAt) / timing.duration))
        return timing == .season
            ? progress * progress * (3 - 2 * progress)
            : 1 - pow(1 - progress, 3)
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

    /// Changes the destination mid-flight, for example when a page load lets
    /// a clamped move reach its card. The frame at `time` and the deadline stay
    /// the same, so the remaining motion eases into the new target.
    mutating func retarget(to target: CGFloat, at time: TimeInterval) {
        let eased = easedProgress(at: time)
        guard eased < 1 else {
            startOffset = target
            targetOffset = target
            return
        }
        let current = offset(at: time)
        startOffset = (current - target * eased) / (1 - eased)
        targetOffset = target
    }
}

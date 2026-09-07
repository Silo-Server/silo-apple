import Foundation

/// One continuous season-pill scroll, including changes to the loaded row's origin.
struct SeriesSeasonScroll {
    private(set) var startOffset: CGFloat
    private(set) var targetOffset: CGFloat
    let startedAt: TimeInterval
    static let duration: TimeInterval = 0.45

    func offset(at time: TimeInterval) -> CGFloat {
        let progress = min(1, max(0, (time - startedAt) / Self.duration))
        let eased = progress * progress * (3 - 2 * progress)
        return startOffset + (targetOffset - startOffset) * eased
    }

    func isComplete(at time: TimeInterval) -> Bool {
        time >= startedAt + Self.duration
    }

    mutating func rebase(by shift: CGFloat) {
        startOffset += shift
        targetOffset += shift
    }
}

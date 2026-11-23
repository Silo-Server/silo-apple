import CoreGraphics
import Foundation

/// The viewer's own rating on the server's scale: 1 to 10, stars times two,
/// so 7 is 3.5 stars. 0 is a draft with no stars, which saves as no rating;
/// the server never receives it.
struct RatingScore: Hashable, Comparable, Sendable {
    static let maxValue = 10
    static let starCount = 5
    /// No stars.
    static let none = RatingScore(0)
    /// Where a draft starts when the title is unrated (3 stars).
    static let unratedDraft = RatingScore(6)

    /// 0 to 10.
    let value: Int

    /// Clamps `value` into 0...10.
    init(_ value: Int) {
        self.value = min(max(value, 0), Self.maxValue)
    }

    /// A server rating; nil (unrated) is `.none`.
    init(server value: Int?) {
        self.init(value ?? 0)
    }

    static func < (lhs: RatingScore, rhs: RatingScore) -> Bool { lhs.value < rhs.value }

    var isRated: Bool { value > 0 }
    /// What `ItemDetailViewModel.setRating` takes: nil removes the rating.
    var serverValue: Int? { isRated ? value : nil }
    var stars: Double { Double(value) / 2 }
    var isMax: Bool { value == Self.maxValue }

    /// Half a star more, at most five.
    var steppedUp: RatingScore { RatingScore(value + 1) }
    /// Half a star less, at least none.
    var steppedDown: RatingScore { RatingScore(value - 1) }

    /// The stars as text, "4" or "4.5", with the locale's decimal separator
    /// ("4,5" in German). "0" for no stars; callers show their own blank.
    func display(locale: Locale = .current) -> String {
        stars.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }

    /// How much of star `index` (0 is the leading star) is filled.
    func fill(ofStar index: Int) -> RatingStarFill {
        let halves = value - index * 2
        if halves >= 2 { return .full }
        return halves == 1 ? .half : .empty
    }

    // MARK: Track input

    /// The score under a drag at `x` points from the leading edge of the
    /// first star, on a track of `cellWidth`-wide stars: under 4 points is
    /// no stars, otherwise the next half star up, at most five. Past either
    /// end it clamps.
    static func fromTrack(x: CGFloat, cellWidth: CGFloat) -> RatingScore {
        guard cellWidth > 0, x >= 4 else { return .none }
        let halves = (x / cellWidth * 2).rounded(.up)
        return RatingScore(halves >= CGFloat(maxValue) ? maxValue : Int(halves))
    }

    /// The star (0 to 4) under `x` points from the first star's leading
    /// edge; positions before or past the track pick the end stars.
    static func starIndex(x: CGFloat, cellWidth: CGFloat) -> Int {
        guard cellWidth > 0, x > 0 else { return 0 }
        let index = (x / cellWidth).rounded(.down)
        return index >= CGFloat(starCount - 1) ? starCount - 1 : Int(index)
    }

    /// A tap fills the whole star under it. Tapping the star that is already
    /// the exact current value steps it down to its half (5 to 4.5), so half
    /// stars need no drag.
    static func tapped(starIndex index: Int, current: RatingScore) -> RatingScore {
        let whole = RatingScore((min(max(index, 0), starCount - 1) + 1) * 2)
        return whole == current ? whole.steppedDown : whole
    }

    /// `tapped(starIndex:current:)` for a tap at `x`, measured as in
    /// `fromTrack(x:cellWidth:)`.
    static func tapped(x: CGFloat, cellWidth: CGFloat, current: RatingScore) -> RatingScore {
        tapped(starIndex: starIndex(x: x, cellWidth: cellWidth), current: current)
    }

    /// Converts a gesture's x, measured from the track's left edge, to the
    /// distance from its leading edge: the same value left to right, and
    /// mirrored across `width` right to left, where the first star is on the
    /// right. `width` spans from the first star's leading edge to the last
    /// star's trailing edge.
    static func leadingOffset(x: CGFloat, width: CGFloat, isRightToLeft: Bool) -> CGFloat {
        isRightToLeft ? width - x : x
    }
}

/// How much of one star is filled.
enum RatingStarFill: Sendable {
    case empty
    case half
    case full

    /// The share of the star's width the accent covers, from its leading edge.
    var fraction: CGFloat {
        switch self {
        case .empty: 0
        case .half: 0.5
        case .full: 1
        }
    }
}

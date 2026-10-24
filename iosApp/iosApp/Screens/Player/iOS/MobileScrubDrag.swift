#if os(iOS)
import CoreGraphics

/// How fast the playhead follows the finger along the scrub bar. Like the
/// native player, sliding up off the bar slows the scrub one step per
/// `tierHeight` points, down to fine scrubbing.
enum MobileScrubSpeed: CaseIterable {
    case full, half, quarter, fine

    static let tierHeight: CGFloat = 50

    init(heightAboveBar height: CGFloat) {
        let tiers = Self.allCases
        let index = Int(max(height, 0) / Self.tierHeight)
        self = tiers[min(index, tiers.count - 1)]
    }

    /// Bar fraction moved per bar width the finger travels.
    var rate: Double {
        switch self {
        case .full: 1
        case .half: 0.5
        case .quarter: 0.25
        case .fine: 0.1
        }
    }

    /// Shown in the scrub bubble; nil at full speed, which needs no label.
    var label: String? {
        switch self {
        case .full: nil
        case .half: "Half-Speed Scrubbing"
        case .quarter: "Quarter-Speed Scrubbing"
        case .fine: "Fine Scrubbing"
        }
    }
}

/// One finger drag on the scrub bar. The touch-down point sets the playhead,
/// then horizontal travel moves it at the current speed. Each speed change
/// re-anchors where the playhead already is, so it never jumps; until the
/// finger leaves the bar, the playhead stays under it.
struct MobileScrubDrag: Equatable {
    private(set) var speed: MobileScrubSpeed = .full
    private(set) var fraction: Double
    private var anchorX: CGFloat
    private var anchorFraction: Double

    init(startX: CGFloat, width: CGFloat) {
        fraction = Self.clamped(Double(startX / width))
        anchorX = startX
        anchorFraction = fraction
    }

    /// `x` is the finger's position along the bar; `heightAboveBar` is how
    /// far it has risen since touch-down.
    mutating func move(toX x: CGFloat, heightAboveBar: CGFloat, width: CGFloat) {
        let newSpeed = MobileScrubSpeed(heightAboveBar: heightAboveBar)
        if newSpeed != speed {
            speed = newSpeed
            anchorX = x
            anchorFraction = fraction
        }
        let proposed = anchorFraction + Double((x - anchorX) / width) * speed.rate
        fraction = Self.clamped(proposed)
        // Below full speed the playhead is no longer under the finger, so
        // drop any travel past an end; turning back then moves it at once.
        if speed != .full && fraction != proposed {
            anchorX = x
            anchorFraction = fraction
        }
    }

    private static func clamped(_ fraction: Double) -> Double {
        min(max(fraction, 0), 1)
    }
}
#endif

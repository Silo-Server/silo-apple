import SwiftUI

extension View {
    /// Media transport controls and timelines read left to right in every
    /// language, as on web and in the system players: rewind on the left,
    /// time running rightward. The rest of the player mirrors.
    func mediaLayoutDirection() -> some View {
        environment(\.layoutDirection, .leftToRight)
    }
}

#if os(tvOS)
extension MoveCommandDirection {
    /// The direction as the layout reads it. Siri Remote presses are
    /// physical, so in a right-to-left layout a press to the right moves
    /// toward the leading side: `.left` and `.right` swap. Handlers that map
    /// left/right to previous/next in a mirrored row read it through this.
    func inLayout(_ layoutDirection: LayoutDirection) -> MoveCommandDirection {
        guard layoutDirection == .rightToLeft else { return self }
        switch self {
        case .left: return .right
        case .right: return .left
        default: return self
        }
    }
}
#endif

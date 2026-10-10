#if os(iOS)
import SwiftUI

/// Tabletop playback on iPhone Duo: the open display half-folded with its
/// fold running across the screen and the lower half resting on a surface.
/// The video takes the upper pane and the controls the lower one, each kept
/// clear of the crease. Matches the Android player's tabletop posture.
///
/// Both edges are global y coordinates; each consumer converts them into its
/// own space, since the video surface ignores the safe area and the controls
/// don't.
struct PlayerTabletopLayout: Equatable {
    /// Where the upper pane, holding the video, ends.
    let videoMaxY: CGFloat
    /// Where the lower pane, holding the controls, begins.
    let controlsMinY: CGFloat

    /// Kept between each pane and the fold's reported frame, which can have
    /// no height on a flexible display.
    static let foldClearance: CGFloat = 12
    /// Below these, a pane is too small to be useful and the player keeps its
    /// full-screen layout.
    static let minimumVideoHeight: CGFloat = 160
    static let minimumControlsHeight: CGFloat = 220

    /// Nil unless `fold` is an active fold running across `bounds` with room
    /// on both sides. A fold running down the screen (the book posture) keeps
    /// the full-screen layout.
    init?(bounds: CGRect, fold: CGRect, isActive: Bool) {
        guard isActive, fold.width > fold.height,
              fold.minX <= bounds.minX + 1, fold.maxX >= bounds.maxX - 1 else { return nil }
        let videoMaxY = fold.minY - Self.foldClearance
        let controlsMinY = fold.maxY + Self.foldClearance
        guard videoMaxY - bounds.minY >= Self.minimumVideoHeight,
              bounds.maxY - controlsMinY >= Self.minimumControlsHeight else { return nil }
        self.videoMaxY = videoMaxY
        self.controlsMinY = controlsMinY
    }
}

extension EnvironmentValues {
    /// Set by the player while the device is in its tabletop posture.
    @Entry var playerTabletopLayout: PlayerTabletopLayout? = nil
}

extension View {
    /// Reports the tabletop layout whenever an active fold crosses this view,
    /// and nil otherwise. Folds exist only on iPhone Duo with iOS 27.1, so
    /// builds with an older SDK report nothing.
    func onPlayerTabletopLayoutChange(_ action: @escaping (PlayerTabletopLayout?) -> Void) -> some View {
        modifier(PlayerTabletopLayoutReader(action: action))
    }
}

private struct PlayerTabletopLayoutReader: ViewModifier {
    let action: (PlayerTabletopLayout?) -> Void

    func body(content: Content) -> some View {
        #if canImport(SwiftUICore, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content.onGeometryChange(for: PlayerTabletopLayout?.self) { proxy in
                let bounds = proxy.frame(in: .global)
                return proxy.reservedRegions(kind: .division).lazy.compactMap { region in
                    PlayerTabletopLayout(
                        bounds: bounds,
                        fold: region.frame.offsetBy(dx: bounds.minX, dy: bounds.minY),
                        isActive: region.isActive
                    )
                }.first
            } action: { layout in
                action(layout)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
#endif

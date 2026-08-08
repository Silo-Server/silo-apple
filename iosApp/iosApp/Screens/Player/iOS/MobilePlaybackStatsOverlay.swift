#if os(iOS)
import SwiftUI

/// Infuse-style stats annotation: `PlaybackStats.compactRows` drawn over the
/// picture on a low-contrast dark plate, with no header, close button or
/// scroll affordance.
///
/// Two properties matter and are easy to break:
///
/// - It is inert. `allowsHitTesting(false)` means a tap in its footprint
///   still reaches the transport and the gesture layer underneath — the
///   overlay must never cost the user a play/pause. That rules out
///   scrolling, which is why it renders the compact row set and not the
///   full one the tvOS pane pages through.
/// - It outlives the controls. It sits outside the `showControls` gate in
///   `MobilePlayerControls`, so the 3 s auto-hide takes the transport away
///   and leaves the stats up. Toggled off from where it was toggled on
///   (settings sheet → Stats), which is why there is no dismiss control.
struct MobilePlaybackStatsOverlay: View {
    let stats: PlaybackStats

    /// Clears the control overlay's top strip so the two never collide.
    private static let topInset: CGFloat = 60

    var body: some View {
        plate
            .padding(.leading, 16)
            .padding(.top, Self.topInset)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .allowsHitTesting(false)
    }

    private var plate: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            // Flat translucent black rather than a material: a blur reads as
            // a window, which is exactly what this shouldn't look like. Just
            // enough to hold white text over a bright scene.
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.38))
            )
            // Hug the rows so the plate never spans the player.
            .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        // Gated on the compact set, not `hasRows`: early snapshots can carry
        // only rows this overlay filters out, which would draw a blank plate.
        if !stats.compactRows.isEmpty {
            PlaybackStatsPanel(stats: stats, layout: .plain)
        } else {
            Text("Stats appear once playback starts.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}
#endif

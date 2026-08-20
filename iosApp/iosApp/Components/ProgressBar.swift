import SwiftUI

/// A thin progress bar (0-1) for showing watch progress.
///
/// Defaults are the card style: white fill on a translucent track (Plezy
/// style — no accent color). The episode stills overlay their bar on the
/// artwork itself and pass the squared, higher-contrast variant.
struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 3
    var cornerRadius: CGFloat = 2
    var trackColor: Color = .white.opacity(0.2)
    var fillColor: Color = .siloOnSurface

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(trackColor)
                    .frame(height: height)

                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(fillColor)
                    .frame(width: geo.size.width * min(max(value, 0), 1), height: height)
            }
        }
        .frame(height: height)
    }

    /// The watch-progress bar the episode stills draw over their artwork:
    /// squared corners inside the card's own clip, and a solid white fill on
    /// a dark track so it reads over a bright still.
    static func episodeStill(fraction: Double, height: CGFloat) -> ProgressBar {
        ProgressBar(
            value: fraction,
            height: height,
            cornerRadius: 0,
            trackColor: .black.opacity(0.6),
            fillColor: .white
        )
    }
}

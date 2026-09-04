import SwiftUI

/// A thin progress bar (0-1) for showing watch progress.
/// Uses white fill on translucent track (Plezy style — no accent color).
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 3)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.siloOnSurface)
                    .frame(width: geo.size.width * min(max(value, 0), 1), height: 3)
            }
        }
        .frame(height: 3)
    }
}

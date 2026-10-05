import SwiftUI

/// PlexAmp-style ambient backdrop: a full-bleed 3×3 mesh gradient built
/// from cover-sampled colors whose interior control points drift slowly,
/// under a scrim that keeps controls legible. The drift runs only while
/// audio plays, stops for Reduce Motion, and the corner points stay pinned
/// so the mesh always covers the safe area.
struct AudioPlayerBackground: View {
    let palette: AudioCoverPalette
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Time spent paused, left out of the drift clock so a resumed drift
    /// continues from the frame it stopped on instead of jumping ahead.
    @State private var pausedDuration: TimeInterval = 0
    @State private var pausedSince: Date?

    var body: some View {
        ZStack {
            Color.siloBackground
                .ignoresSafeArea()

            if reduceMotion {
                mesh(phase: 0)
                    .ignoresSafeArea()
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { timeline in
                    mesh(phase: driftPhase(at: timeline.date))
                        .ignoresSafeArea()
                }
            }

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.20), location: 0),
                    .init(color: .black.opacity(0.05), location: 0.35),
                    .init(color: .black.opacity(0.55), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 1.2), value: palette)
        .onAppear {
            pausedSince = isPlaying ? nil : Date.now
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                if let pausedSince {
                    pausedDuration += Date.now.timeIntervalSince(pausedSince)
                }
                pausedSince = nil
            } else {
                pausedSince = Date.now
            }
        }
    }

    /// Drift clock: wall time minus paused time, held at the pause moment
    /// while paused.
    private func driftPhase(at date: Date) -> TimeInterval {
        (pausedSince ?? date).timeIntervalSinceReferenceDate - pausedDuration
    }

    private func mesh(phase: TimeInterval) -> some View {
        // Two incommensurate periods so the drift never visibly loops.
        let a = Float(sin(phase / 11.0))
        let b = Float(cos(phase / 17.0))

        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5 + 0.10 * a, 0], [1, 0],
                [0, 0.5 + 0.08 * b], [0.5 + 0.12 * b, 0.5 - 0.12 * a], [1, 0.5 - 0.08 * a],
                [0, 1], [0.5 - 0.10 * b, 1], [1, 1],
            ],
            colors: [
                palette.corners[0], blend(0, 1), palette.corners[1],
                blend(0, 2), palette.center, blend(1, 3),
                palette.corners[2], blend(2, 3), palette.corners[3],
            ]
        )
    }

    private func blend(_ first: Int, _ second: Int) -> Color {
        palette.corners[first].mix(with: palette.corners[second], by: 0.5)
    }
}

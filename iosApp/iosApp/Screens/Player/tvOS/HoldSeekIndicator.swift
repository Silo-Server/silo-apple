#if os(tvOS)
import CoreGraphics
import SwiftUI

/// Floating chip shown during a seek session. The transport overlay is
/// deliberately suppressed while a session is active (it would shift
/// focus off the press-capture view and lose the remote's input), so
/// this is the only visual feedback between hold-enter and commit/cancel.
/// Shows the signed rate (direction + magnitude), the running preview
/// time, and a small hint line for the available controls.
struct HoldSeekIndicator: View {
    /// Signed multiplier: negative = backward, positive = forward.
    let rate: Int
    let previewTime: Double
    let duration: Double
    let previewImage: CGImage?

    var body: some View {
        VStack(spacing: 16) {
            if let previewImage {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 480, height: 270)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.55), radius: 18, y: 7)
            }
            chip
            if duration > 0 {
                miniProgress
                    .frame(width: 520)
            }
            hint
        }
        .padding(.top, 120)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .shadow(color: .black.opacity(0.6), radius: 16, y: 6)
    }

    private var chip: some View {
        HStack(spacing: 18) {
            Image(systemName: directionIcon)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Text("\(abs(rate))×")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(PlayerTimeFormatter.formatHMS(previewTime))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .monospacedDigit()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .siloPlayerGlass(
            in: Capsule(style: .continuous),
            tint: Color.black.opacity(0.35)
        )
        .overlay(
            Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    /// Thin progress bar so the user has spatial context for where the
    /// preview is landing. Read-only — the scrubber is suppressed while
    /// this is on-screen, so there's no control to fight with.
    private var miniProgress: some View {
        GeometryReader { geo in
            let fraction = min(max(previewTime / duration, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(Color.white).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }

    /// Small one-liner reminding the user which buttons do what. First-
    /// time discoverability matters here since the seek-session model
    /// doesn't match the Apple TV app's momentary hold-to-FF.
    private var hint: some View {
        HStack(spacing: 18) {
            Label("Speed", systemImage: "arrow.left.arrow.right")
            Label("Play", systemImage: "circle.fill")
            Label("Cancel", systemImage: "arrow.uturn.backward")
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .labelStyle(.titleAndIcon)
    }

    private var directionIcon: String {
        rate >= 0 ? "forward.fill" : "backward.fill"
    }
}
#endif

import SwiftUI

/// The watch-progress bar drawn over a media card's artwork (0-1).
///
/// Matches the web client's keyline bar: an inset capsule with a dark track,
/// a dark keyline and drop shadow, and a near-white fill with a hairline
/// edge, so it stays visible on bright artwork. The view fills its container
/// and places itself at the bottom, so call sites overlay it on the card at
/// the card's size and add no padding of their own. Nothing is drawn when
/// `value` is zero or less.
struct ProgressBar: View {
    let value: Double
    /// Box-set cards lower the bar so it clears their film-count chip, as on
    /// web and Android.
    var belowCornerLabel = false

    /// How far above the card's bottom edge a corner badge sits to clear the
    /// bar on any platform: the bottom inset, the tvOS bar's height, and a
    /// small gap for the keyline.
    static let badgeClearance: CGFloat = 14

    #if os(tvOS)
    private static let height: CGFloat = 4
    #else
    private static let height: CGFloat = 3
    #endif
    private static let horizontalInset: CGFloat = 10
    private var bottomInset: CGFloat { belowCornerLabel ? 4 : 8 }

    private var fraction: CGFloat { CGFloat(min(max(value, 0), 1)) }

    var body: some View {
        if fraction > 0 {
            GeometryReader { geo in
                Capsule()
                    .fill(Color.siloOnSurface)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.4), lineWidth: 0.5))
                    .frame(width: geo.size.width * fraction)
            }
            .frame(height: Self.height)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    // Keyline just outside the track's edge.
                    .overlay(
                        Capsule()
                            .stroke(Color.black.opacity(0.35), lineWidth: 1)
                            .padding(-0.5)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 1)
            )
            .padding(.horizontal, Self.horizontalInset)
            .padding(.bottom, bottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
    }
}

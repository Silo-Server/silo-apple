#if os(tvOS)
import SwiftUI

/// One backdrop footprint shared by Skyline landings and item details.
/// tvOS content is rendered in a 16:9 logical viewport, so deriving the
/// height from the available width keeps the artwork request, crop, and mask
/// identical even when the detail hero itself is shorter than the viewport.
enum TVBackdropArtworkLayout {
    static let widthFraction: CGFloat = 0.64
    static let heightFraction: CGFloat = 0.70

    static func artworkSize(forViewportWidth viewportWidth: CGFloat) -> CGSize {
        let viewportHeight = viewportWidth * 9 / 16
        return CGSize(
            width: viewportWidth * widthFraction,
            height: viewportHeight * heightFraction
        )
    }
}

/// Shared corner falloff for the root marquee and movie/series details.
/// Keeping one mask prevents the artwork edge from visibly changing while
/// the already-focused card opens its seeded detail route.
struct TVBackdropArtworkFadeMask: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: 0.32),
                .init(color: .clear, location: 1.0),
            ],
            startPoint: .trailing,
            endPoint: .leading
        )
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.38),
                    .init(color: .black.opacity(0.88), location: 0.52),
                    .init(color: .black.opacity(0.58), location: 0.68),
                    .init(color: .black.opacity(0.24), location: 0.81),
                    // Reach zero before the detail hero's lower boundary so
                    // its clip can never reveal a straight artwork edge.
                    .init(color: .clear, location: 0.90),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

/// Page-level ambient hero backdrop for root tvOS screens.
///
/// Keeping this behind the whole page instead of inside the hero/marquee
/// gives the custom top menu, marquee, and rows one shared visual plane.
/// On Home and the library Browse landings the artwork tracks the
/// marquee's focused item (Skyline §5.4): a crisp image is anchored in the
/// top-right corner and fades out toward the leading edge and the bottom
/// into a color sampled from the art itself, which is carried (dimmed)
/// across the rest of the page so the metadata and rows below sit on the
/// same tint. Calendar and Recommendations keep passing static (nil)
/// artwork with `tintColor: .continuumBackground`, so they render as the
/// flat app background.
struct TVRootHeroBackdrop: View {
    let tintColor: Color
    let artworkURL: String?
    let artworkThumbhash: String?
    var isVisible: Bool = true
    /// Artwork/tint crossfade duration, shared with rested marquee swaps.
    var crossfadeDuration: Double = 0.55

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// False until the first artwork has painted. The very first backdrop
    /// (cold entry, seeded before focus settles) should be there on frame
    /// one — only artwork→artwork swaps get the ambient crossfade.
    @State private var hasDisplayedArtwork = false

    /// Near-crisp by request (§ user direction). Bump a little only if the
    /// server's backdrop is low-res enough to show compression artifacts.
    private let artBlur: CGFloat = 0
    /// Full-width top scrim height so the menu bar stays legible over the
    /// bright art now sitting directly behind the tabs and profile avatar.
    private let topScrimHeight: CGFloat = 190

    var body: some View {
        ZStack(alignment: .top) {
            Color.continuumBackground

            tintBackground

            if isVisible {
                backdropImage
                topChromeScrim
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            if artworkURL?.isEmpty == false { hasDisplayedArtwork = true }
        }
        .onChange(of: artworkURL) { _, url in
            if url?.isEmpty == false { hasDisplayedArtwork = true }
        }
    }

    /// Sampled-color wash: richest in the top-right behind the art, carried
    /// dimmed down to the bottom-left so the page keeps the art's color
    /// without washing out the metadata or row captions. When the caller
    /// passes `.continuumBackground` (Calendar/Recommendations) every stop
    /// collapses to the app background, so the wash renders flat.
    private var tintBackground: some View {
        LinearGradient(
            stops: [
                .init(color: tintColor, location: 0.0),
                .init(color: tintColor.opacity(isVisible ? 0.5 : 0.0), location: 0.45),
                .init(color: tintColor.opacity(isVisible ? 0.18 : 0.0), location: 1.0),
            ],
            startPoint: .topTrailing,
            endPoint: .bottomLeading
        )
        // The first tint (cold-entry seed with a prefetch-warmed sample)
        // snaps in with the artwork; only tint→tint changes crossfade.
        .animation(
            reduceMotion || !hasDisplayedArtwork
                ? nil
                : .easeInOut(duration: crossfadeDuration),
            value: tintColor
        )
        .animation(
            reduceMotion || !hasDisplayedArtwork ? nil : .easeInOut(duration: 0.24),
            value: isVisible
        )
    }

    @ViewBuilder
    private var backdropImage: some View {
        GeometryReader { geometry in
            let artworkSize = TVBackdropArtworkLayout.artworkSize(
                forViewportWidth: geometry.size.width
            )

            if let artworkURL, !artworkURL.isEmpty {
                AsyncImageView(
                    url: artworkURL,
                    thumbhash: artworkThumbhash,
                    targetSize: artworkSize,
                    contentMode: .fill
                )
                .id(artworkURL)
                .frame(width: artworkSize.width, height: artworkSize.height)
                .clipped()
                .blur(radius: artBlur)
                .mask { TVBackdropArtworkFadeMask() }
                // Anchor the art block to the screen's top-right corner; the
                // mask keeps only that corner opaque, so the corner reads as
                // fully painted with no gap and the art dissolves inward.
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .topTrailing
                )
                .transition(
                    reduceMotion || !hasDisplayedArtwork
                        ? .identity
                        : .opacity.animation(.easeInOut(duration: crossfadeDuration))
                )
            }
        }
        .ignoresSafeArea()
    }

    /// Full-width black ramp pinned to the top so the wordmark, tabs, and
    /// profile avatar stay legible now that bright art sits behind them.
    private var topChromeScrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.5), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(maxWidth: .infinity, maxHeight: topScrimHeight, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}
#endif

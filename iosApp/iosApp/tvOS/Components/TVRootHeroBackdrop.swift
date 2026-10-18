#if os(tvOS)
import SwiftUI

/// One backdrop footprint shared by Skyline landings and item details.
/// tvOS content is rendered in a 16:9 logical viewport, so deriving the
/// height from the available width keeps the artwork request, crop, and mask
/// identical even when the detail hero itself is shorter than the viewport.
enum TVBackdropArtworkLayout {
    /// tvOS renders every screen into a 1920 pt wide logical canvas, so the
    /// hero artwork size is fixed and can be computed off the main thread.
    static let viewportWidth: CGFloat = 1920
    /// Equal fractions keep the box 16:9, so a backdrop fills it uncropped.
    static let widthFraction: CGFloat = 0.77
    static let heightFraction: CGFloat = 0.77
    /// Where the art reaches zero below the top edge, as a fraction of the
    /// viewport height. It must stay inside the detail hero's clip (690 pt
    /// on a 1080 pt canvas) so that clip never reveals a straight edge.
    static let fadeEndFraction: CGFloat = 0.63

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
///
/// One elliptical falloff from the top-trailing corner, eased over many
/// stops, so bright art dissolves without the diagonal seam two crossed
/// linear ramps leave behind.
struct TVBackdropArtworkFadeMask: View {
    var body: some View {
        EllipticalGradient(
            stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: 0.34),
                .init(color: .black.opacity(0.93), location: 0.44),
                .init(color: .black.opacity(0.78), location: 0.54),
                .init(color: .black.opacity(0.56), location: 0.64),
                .init(color: .black.opacity(0.32), location: 0.74),
                .init(color: .black.opacity(0.14), location: 0.84),
                .init(color: .black.opacity(0.04), location: 0.92),
                .init(color: .clear, location: 1.0),
            ],
            center: .topTrailing,
            startRadiusFraction: 0,
            endRadiusFraction: 1
        )
        // Squash the ellipse vertically so it ends at `fadeEndFraction`
        // rather than the bottom of the artwork box.
        .scaleEffect(
            x: 1,
            y: TVBackdropArtworkLayout.fadeEndFraction / TVBackdropArtworkLayout.heightFraction,
            anchor: .top
        )
    }
}

/// Page wash sampled from the backdrop, shared by the root landings and
/// item details so both pages carry the same colors. The base tint is
/// richest in the top-right behind the art and carried dimmed down to the
/// bottom-left; the art's accent glows under the right half of the rows and
/// its shadow tone pools in the bottom-left corner. The page keeps the art's
/// colors without washing out the metadata or row captions.
struct TVBackdropTintWash: View {
    let tints: HeroBackdropPalette.Tints
    var isVisible: Bool = true

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: tints.base, location: 0.0),
                    .init(color: tints.base.opacity(isVisible ? 0.5 : 0.0), location: 0.45),
                    .init(color: tints.base.opacity(isVisible ? 0.18 : 0.0), location: 1.0),
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )

            EllipticalGradient(
                colors: [tints.accent.opacity(isVisible ? 0.3 : 0.0), tints.accent.opacity(0)],
                center: UnitPoint(x: 0.66, y: 0.78),
                endRadiusFraction: 0.33
            )

            EllipticalGradient(
                colors: [tints.shadow.opacity(isVisible ? 0.55 : 0.0), tints.shadow.opacity(0)],
                center: .bottomLeading,
                endRadiusFraction: 0.42
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
/// into colors sampled from the art itself, which are carried (dimmed)
/// across the rest of the page so the metadata and rows below sit on the
/// same tint. Calendar passes nil artwork with flat `.siloBackground` tints
/// and renders flat.
struct TVRootHeroBackdrop: View {
    let tints: HeroBackdropPalette.Tints
    let artworkURL: String?
    let artworkThumbhash: String?
    var isVisible: Bool = true
    /// Artwork/tint crossfade duration. Focus-marquee hosts pass the §4.2
    /// 240 ms swap; other surfaces keep the slower ambient default.
    var crossfadeDuration: Double = 0.55

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// False until the first artwork has painted. The very first backdrop
    /// (cold entry, seeded before focus settles) should be there on frame
    /// one — only artwork→artwork swaps get the ambient crossfade.
    @State private var hasDisplayedArtwork = false

    /// Height of the full-width top scrim that keeps the menu bar legible over
    /// bright artwork.
    private let topScrimHeight: CGFloat = 190

    var body: some View {
        ZStack(alignment: .top) {
            Color.siloBackground

            tintBackground

            if isVisible {
                backdropImage
                // Dithers the large dark ramps, which band on TVs.
                MarqueeGrain()
                topChromeScrim
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: artworkURL, initial: true) { _, url in
            if url?.isEmpty == false { hasDisplayedArtwork = true }
        }
    }

    /// Sampled-color wash; when the caller passes flat `.siloBackground`
    /// tints (Calendar) every stop collapses to the app background, so the
    /// wash renders flat.
    private var tintBackground: some View {
        TVBackdropTintWash(tints: tints, isVisible: isVisible)
            // The first tint (cold-entry seed with a prefetch-warmed sample)
            // snaps in with the artwork; only tint→tint changes crossfade.
            .animation(
                reduceMotion || !hasDisplayedArtwork
                    ? nil
                    : .easeInOut(duration: crossfadeDuration),
                value: tints
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

            // The mask wraps the crossfading pair rather than each image, so
            // a swap renders one masked offscreen pass instead of two
            // full-resolution ones while both artworks are on screen.
            ZStack {
                if let artworkURL, !artworkURL.isEmpty {
                    AsyncImageView(
                        url: artworkURL,
                        thumbhash: artworkThumbhash,
                        targetSize: artworkSize,
                        contentMode: .fill
                    )
                    .id(artworkURL)
                    .transition(
                        reduceMotion || !hasDisplayedArtwork
                            ? .identity
                            : .opacity.animation(.easeInOut(duration: crossfadeDuration))
                    )
                }
            }
            .frame(width: artworkSize.width, height: artworkSize.height)
            .clipped()
            .mask { TVBackdropArtworkFadeMask() }
            // Anchor the art block to the screen's top-right corner; the
            // mask keeps only that corner opaque, so the corner reads as
            // fully painted with no gap and the art dissolves inward.
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .topTrailing
            )
        }
        .ignoresSafeArea()
    }

    /// Black ramp pinned to the top so the wordmark, tabs, and avatar stay
    /// legible over bright artwork.
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

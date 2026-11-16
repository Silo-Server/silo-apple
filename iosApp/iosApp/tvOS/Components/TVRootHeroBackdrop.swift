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

/// Page wash sampled from the backdrop, shared by the root landings and
/// item details so both pages carry the same colors. The base tint is
/// richest in the top-right behind the art and carried dimmed down to the
/// bottom-left; the art's accent glows up from the bottom edge under the
/// right half of the rows, stopping below where the art ends so it never
/// tints the artwork, and its shadow tone pools in the bottom-left corner.
/// The page keeps the art's colors without washing out the metadata or row
/// captions.
struct TVBackdropTintWash: View {
    let tints: HeroBackdropPalette.Tints
    var isVisible: Bool = true
    /// The base gradient sits behind the art and shows through its fade.
    /// Item details turn it off to keep their own dimmer tint behind the art.
    var includesBase: Bool = true

    var body: some View {
        ZStack {
            if includesBase {
                LinearGradient(
                    stops: [
                        .init(color: tints.base, location: 0.0),
                        .init(color: tints.base.opacity(isVisible ? 0.5 : 0.0), location: 0.45),
                        .init(color: tints.base.opacity(isVisible ? 0.18 : 0.0), location: 1.0),
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
            }

            EllipticalGradient(
                colors: [tints.accent.opacity(isVisible ? 0.3 : 0.0), tints.accent.opacity(0)],
                center: UnitPoint(x: 0.7, y: 1.0),
                endRadiusFraction: 0.3
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
    /// Set when the artwork is a cover standing in for a missing backdrop:
    /// the hero draws it framed at this shape over a glow of itself instead
    /// of stretching it across the backdrop area.
    var artworkCoverAspect: MediaCardAspect? = nil
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

    /// A framed cover's height. It sits in the top-right corner between the
    /// top menu and the row band, so it never reaches the rows.
    private static let coverHeight: CGFloat = 380
    private static let coverTopInset: CGFloat = 170
    private static let coverTrailingInset: CGFloat = 150
    static let coverCornerRadius: CGFloat = 14

    /// Where a framed cover sits on a `canvas`-sized screen. The ambient wash
    /// draws its glow and shadow around this frame.
    static func coverFrame(for aspect: MediaCardAspect, canvas: CGSize) -> CGRect {
        let size = coverSize(for: aspect)
        return CGRect(
            x: canvas.width - coverTrailingInset - size.width,
            y: coverTopInset,
            width: size.width,
            height: size.height
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.siloBackground

            tintBackground

            if isVisible {
                backdropImage
                coverImage
                topChromeScrim
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: artworkURL, initial: true) { _, url in
            if url?.isEmpty == false { hasDisplayedArtwork = true }
        }
    }

    /// Sampled-color wash, with a framed cover's glow and shadow, dithered
    /// so its dark ramps don't band. When the caller passes flat
    /// `.siloBackground` tints (Calendar) every stop collapses to the app
    /// background, so the wash renders flat.
    private var tintBackground: some View {
        TVHeroAmbientWash(
            tints: tints,
            isVisible: isVisible,
            cover: displayedCover,
            // The first tint (cold-entry seed with a prefetch-warmed sample)
            // snaps in with the artwork; only tint→tint changes crossfade.
            animatesChanges: !reduceMotion && hasDisplayedArtwork,
            crossfadeDuration: crossfadeDuration
        )
    }

    private var displayedCover: TVHeroAmbientWash.Cover? {
        guard isVisible, let artworkURL, !artworkURL.isEmpty, let artworkCoverAspect else { return nil }
        return TVHeroAmbientWash.Cover(url: artworkURL, aspect: artworkCoverAspect)
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
                if let artworkURL, !artworkURL.isEmpty, artworkCoverAspect == nil {
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

    /// A cover standing in for a missing backdrop, drawn whole and sharp at
    /// a size its artwork can carry. Its glow and shadow are part of the
    /// ambient wash. Its own layer, so a backdrop-to-cover swap still
    /// crossfades.
    private var coverImage: some View {
        ZStack {
            if let artworkURL, !artworkURL.isEmpty, let aspect = artworkCoverAspect {
                framedCover(url: artworkURL, size: Self.coverSize(for: aspect))
                    .id(artworkURL)
                    .transition(
                        reduceMotion || !hasDisplayedArtwork
                            ? .identity
                            : .opacity.animation(.easeInOut(duration: crossfadeDuration))
                    )
            }
        }
        .padding(.top, Self.coverTopInset)
        .padding(.trailing, Self.coverTrailingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .ignoresSafeArea()
    }

    private func framedCover(url: String, size: CGSize) -> some View {
        AsyncImageView(url: url, thumbhash: artworkThumbhash, targetSize: size, contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Self.coverCornerRadius, style: .continuous))
    }

    private static func coverSize(for aspect: MediaCardAspect) -> CGSize {
        switch aspect {
        case .square: CGSize(width: coverHeight, height: coverHeight)
        case .poster: CGSize(width: coverHeight * 2 / 3, height: coverHeight)
        }
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

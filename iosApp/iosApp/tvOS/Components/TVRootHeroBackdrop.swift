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

/// Item details' wash around the art: the accent glows up from the bottom
/// edge under the right half of the rows, stopping below where the art ends
/// so it never tints the artwork, and the shadow tone pools in the
/// bottom-left corner.
struct TVBackdropTintWash: View {
    let tints: HeroBackdropPalette.Tints

    var body: some View {
        ZStack {
            EllipticalGradient(
                colors: [tints.accent.opacity(0.3), tints.accent.opacity(0)],
                center: UnitPoint(x: 0.7, y: 1.0),
                endRadiusFraction: 0.3
            )

            EllipticalGradient(
                colors: [tints.shadow.opacity(0.55), tints.shadow.opacity(0)],
                center: .bottomLeading,
                endRadiusFraction: 0.42
            )
        }
    }
}

/// Home and library page wash: each screen corner glows with the color
/// sampled from the same quarter of the art, fading over black, and the
/// four overlap so the colors blend into each other across the page.
/// Corners are drawn bottom-trailing, bottom-leading, top-trailing, then
/// top-leading, which is the darkest and sits behind the marquee's title.
struct TVBackdropCornerWash: View {
    let corners: HeroBackdropPalette.Corners
    let includesTopTrailing: Bool
    var isVisible: Bool = true

    /// How far each corner's color reaches before it is fully faded, as a
    /// fraction of the screen's width and height.
    nonisolated static let reach: CGFloat = 4.0 / 3.0

    /// Bottom to top, with each corner's position on the screen.
    nonisolated static func layers(
        _ corners: HeroBackdropPalette.Corners,
        includesTopTrailing: Bool
    ) -> [(color: Color, center: UnitPoint)] {
        var layers: [(color: Color, center: UnitPoint)] = [
            (corners.bottomTrailing, .bottomTrailing),
            (corners.bottomLeading, .bottomLeading),
        ]
        if includesTopTrailing {
            layers.append((corners.topTrailing, .topTrailing))
        }
        layers.append((corners.topLeading, .topLeading))
        return layers
    }

    var body: some View {
        ZStack {
            ForEach(Self.layers(corners, includesTopTrailing: includesTopTrailing), id: \.center) { layer in
                EllipticalGradient(
                    colors: [layer.color.opacity(isVisible ? 1 : 0), layer.color.opacity(0)],
                    center: layer.center,
                    endRadiusFraction: Self.reach
                )
            }
        }
    }
}

/// Page-level ambient hero backdrop for root tvOS screens.
///
/// Keeping this behind the whole page instead of inside the hero/marquee
/// gives the custom top menu, marquee, and rows one shared visual plane.
/// On Home and the library Browse landings the artwork tracks the
/// marquee's focused item (Skyline §5.4): a crisp image is anchored in the
/// top-right corner and fades into the sampled wash from the other three
/// corners. Framed covers use all four corner colors and a glow.
struct TVRootHeroBackdrop: View {
    let tints: HeroBackdropPalette.Tints
    let artworkURL: String?
    let artworkThumbhash: String?
    /// Set when the artwork is a cover standing in for a missing backdrop:
    /// the hero draws it framed at this shape over a glow of itself instead
    /// of stretching it across the backdrop area.
    var artworkCoverAspect: MediaCardAspect? = nil
    var isVisible: Bool = true
    /// Artwork crossfade duration. Focus-marquee hosts pass the §4.2
    /// 240 ms swap; other surfaces keep the slower ambient default.
    var crossfadeDuration: Double = 0.55
    /// Crossfade of the sampled-color wash and a framed cover's glow.
    var washCrossfadeDuration: Double = 0.55

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

    /// The wash skips the top-right color beneath wide artwork. A framed
    /// cover keeps the full wash, glow, and shadow.
    private var tintBackground: some View {
        let cover = displayedCover
        return TVHeroAmbientWash(
            tints: tints,
            isVisible: isVisible,
            includesTopTrailing: cover != nil,
            cover: cover,
            // The first tint (cold-entry seed with a prefetch-warmed sample)
            // snaps in with the artwork; only tint→tint changes crossfade.
            animatesChanges: !reduceMotion && hasDisplayedArtwork,
            crossfadeDuration: washCrossfadeDuration
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
                    .transition(artworkTransition)
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

    /// The first artwork paints without a fade; every later swap
    /// crossfades. The removal fade is set for the first artwork too: a view
    /// inserted with `.identity` kept it when it was removed, so the first
    /// swap on a page blinked the old art out before the new one faded in.
    private var artworkTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        let fade = AnyTransition.opacity.animation(.easeInOut(duration: crossfadeDuration))
        return .asymmetric(insertion: hasDisplayedArtwork ? fade : .identity, removal: fade)
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
                    .transition(artworkTransition)
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

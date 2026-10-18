import Foundation

/// The screen an image-bearing read is drawn on, which decides the width it
/// asks the server for each artwork slot (see ``ArtworkSlotWidths``). Widths
/// are the points each screen draws a slot at, before the Poster Size
/// setting; `ImageSizeCapability` multiplies them by the display scale.
///
/// A hero that fills its frame with a 16:9 image needs the frame's height ×
/// 16/9 when that is wider than the frame ("fill width").
enum ArtworkSurface: Sendable {
    /// Home rows, and the tvOS and macOS heroes above them.
    case home
    /// Library sections, For You and the Watch Party picker's shelves: rows
    /// beneath the hero on tvOS.
    case shelves
    /// Item detail: its hero, logo, poster and cast.
    case detail
    /// A season's episode rail.
    case episodes
    /// The More Like This rail.
    case similar
    /// Catalog grids: browse, search, history, person credits and collections.
    case cards
    /// Favorites and watchlist.
    case lists
    /// A series' seasons.
    case seasons
    /// Watch detail, read when playback starts; it draws no artwork.
    case watch
    /// Shuffle picks, shown only as Now Playing and the blurred Up Next
    /// background.
    case shuffle

    func slots(on display: ArtworkDisplay) -> ArtworkSlotWidths {
        #if os(tvOS)
        tvSlots
        #elseif os(macOS)
        macSlots(screen: display.screenSize)
        #else
        iosSlots(on: display)
        #endif
    }

    /// The width a 16:9 image needs to fill `frame`.
    static func fillWidth(_ frame: CGSize) -> CGFloat {
        max(frame.width, frame.height * 16 / 9).rounded(.up)
    }

    #if os(tvOS)
    /// The hero backdrop's fill width: 1344 pt for the 1229 × 756 pt hero box
    /// (`TVBackdropArtworkLayout`). Home, For You and detail ask for the same
    /// hero widths so opening an item reuses the hero image already cached.
    static let tvHeroBackdropWidth = fillWidth(
        TVBackdropArtworkLayout.artworkSize(forViewportWidth: TVBackdropArtworkLayout.viewportWidth)
    )

    /// Every title logo decodes into the Home marquee's logo box
    /// (`PosterImageCache.titleLogoPointBox`), so every surface asks for its width.
    static let tvTitleLogoWidth: CGFloat = SiloTheme.Skyline.marqueeLogoMaxWidth

    private var tvSlots: ArtworkSlotWidths {
        switch self {
        case .home, .shelves:
            // Row posters (176 pt) get `medium`; landscape cards draw the
            // hero backdrop.
            ArtworkSlotWidths(imageSize: "medium", backdrop: Self.tvHeroBackdropWidth, logo: Self.tvTitleLogoWidth)
        case .detail:
            // The poster is drawn only as an audiobook's 460 pt cover.
            ArtworkSlotWidths(
                poster: 460, backdrop: Self.tvHeroBackdropWidth, logo: Self.tvTitleLogoWidth,
                photo: TVDetailCastRail.photoSize.width
            )
        case .episodes:
            ArtworkSlotWidths(still: SiloTheme.thumbnailCardWidth)
        // Card rails and grids also ask for the hero backdrop: a card's
        // backdrop seeds the detail hero while it loads, and the player's
        // backdrop hint, so it must be the URL detail asks for.
        case .similar:
            ArtworkSlotWidths(poster: 220, backdrop: Self.tvHeroBackdropWidth)
        case .cards:
            // The Browse grid's card.
            ArtworkSlotWidths(poster: 260, backdrop: Self.tvHeroBackdropWidth)
        case .lists:
            ArtworkSlotWidths(poster: SiloTheme.Skyline.densePosterCardWidth, backdrop: Self.tvHeroBackdropWidth)
        case .seasons:
            // tvOS season lists draw no artwork; the Watch Party room shows a
            // season poster at the Browse card's size.
            ArtworkSlotWidths(poster: 260)
        case .watch:
            ArtworkSlotWidths()
        case .shuffle:
            ArtworkSlotWidths(imageSize: "medium")
        }
    }
    #endif

    #if os(macOS)
    /// The narrowest sidebar; the content column is the rest of the window.
    private static let sidebarWidth: CGFloat = 240

    private func macSlots(screen: CGSize) -> ArtworkSlotWidths {
        let column = max(screen.width - Self.sidebarWidth, 0)
        switch self {
        case .home:
            // `MacFeaturedHero` fills the column at 0.8 × the window height,
            // clamped to 660...1200 pt; landscape cards are 340 pt.
            let heroHeight = min(max(screen.height * 0.8, 660), 1200)
            return ArtworkSlotWidths(
                poster: 185, backdrop: Self.fillWidth(CGSize(width: column, height: heroHeight)), logo: 320
            )
        case .shelves:
            return ArtworkSlotWidths(poster: 185, backdrop: 340)
        case .detail:
            // The hero fills the detail column 520 pt high, beside a 230 pt poster.
            return ArtworkSlotWidths(
                poster: 230, backdrop: Self.fillWidth(CGSize(width: column, height: 520)), logo: 320, photo: 76
            )
        case .episodes:
            return ArtworkSlotWidths(still: 240)
        case .similar, .cards, .lists:
            return ArtworkSlotWidths(poster: 185)
        case .seasons:
            return ArtworkSlotWidths(poster: 130)
        case .watch:
            return ArtworkSlotWidths()
        case .shuffle:
            return ArtworkSlotWidths(imageSize: "medium")
        }
    }
    #endif

    #if os(iOS)
    /// iPhone and iPad share their screens; only the detail hero and the
    /// catalog grid lay out wider on iPad.
    private func iosSlots(on display: ArtworkDisplay) -> ArtworkSlotWidths {
        let screen = display.screenSize
        switch self {
        case .home:
            return ArtworkSlotWidths(poster: 132, backdrop: 240)
        case .shelves:
            return ArtworkSlotWidths(poster: 120, backdrop: 240)
        case .detail where display.isPad:
            // Landscape split layout: the hero is half the window wide and
            // the full window high.
            return ArtworkSlotWidths(
                backdrop: Self.fillWidth(CGSize(width: screen.width / 2, height: screen.height)), logo: 430, photo: 76
            )
        case .detail:
            // Portrait hero: the screen's width (`screenSize` puts the long
            // edge first), 1.18 × as high within 430...540 pt.
            let width = screen.height
            let heroHeight = min(max(width * 1.18, 430), 540)
            return ArtworkSlotWidths(
                backdrop: Self.fillWidth(CGSize(width: width, height: heroHeight)), logo: width - 56, photo: 76
            )
        case .episodes:
            return ArtworkSlotWidths(still: 240)
        case .cards where display.isPad:
            // Width-fitted grid cards reach about 216 pt.
            return ArtworkSlotWidths(poster: 216)
        case .similar, .cards, .lists, .seasons:
            return ArtworkSlotWidths(poster: 120)
        case .watch:
            return ArtworkSlotWidths()
        case .shuffle:
            return ArtworkSlotWidths(imageSize: "medium")
        }
    }
    #endif
}

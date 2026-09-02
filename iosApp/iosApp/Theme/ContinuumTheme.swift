import SwiftUI

/// Central design token repository matching Plezy's mono theme.
/// On tvOS, spacing/radius tokens are scaled up to match 10-foot viewing distance.
struct ContinuumTheme {

    // MARK: - Platform scale

    #if os(tvOS)
    /// Uniform scale applied to tvOS — everything is ~2x bigger than iOS.
    static let scale: CGFloat = 2.0
    #else
    static let scale: CGFloat = 1.0
    #endif

    // MARK: - Corner Radii

    #if os(tvOS)
    /// Standard card/poster corner radius (12pt on tvOS, larger so focus rings read well)
    static let cornerRadius: CGFloat = 12
    /// Smaller elements like episode thumbnail corners
    static let smallCornerRadius: CGFloat = 8
    /// Card container radius
    static let cardCornerRadius: CGFloat = 18
    #else
    /// Standard card/poster corner radius (8pt — Plezy radiusSm)
    static let cornerRadius: CGFloat = 8
    /// Smaller elements like episode thumbnail corners (6pt)
    static let smallCornerRadius: CGFloat = 6
    /// Card container radius (14pt — Plezy CardTheme)
    static let cardCornerRadius: CGFloat = 14
    #endif

    /// Pill-shaped elements — use Capsule() instead of a fixed radius
    static let pillCornerRadius: CGFloat = 100

    // MARK: - Top Bar

    /// Tap-target frame for chrome-free top-bar icon buttons (Search / Cast).
    /// The glyph stays small; the frame keeps a comfortable 44pt hit area and
    /// sets the rhythm for the evenly spaced top-right cluster.
    static let topBarIconHitSize: CGFloat = 44
    /// Gap between top-bar action items (cast / search / profile). Tuned so the
    /// visible spacing between glyphs reads like Plex's top-right cluster.
    static let topBarIconSpacing: CGFloat = 2

    // MARK: - Spacing

    #if os(tvOS)
    /// Base spacing unit — scaled up for TV
    static let spacing: CGFloat = 24
    /// Standard content padding
    static let padding: CGFloat = 48
    /// Compact padding
    static let smallPadding: CGFloat = 16
    /// Large section spacing
    static let largePadding: CGFloat = 60
    /// Screen safe-area padding — tvOS always wants overscan
    static let safePadding: CGFloat = 80
    #else
    /// Base spacing unit (12pt — Plezy space token)
    static let spacing: CGFloat = 12
    /// Standard content padding (16pt)
    static let padding: CGFloat = 16
    /// Compact padding (8pt)
    static let smallPadding: CGFloat = 8
    /// Large section spacing (24pt)
    static let largePadding: CGFloat = 24
    /// No extra overscan padding on iOS
    static let safePadding: CGFloat = 16
    #endif

    // MARK: - Elevation

    /// Card elevation — zero for Plezy-style flat cards
    static let cardElevation: CGFloat = 0

    // MARK: - Media Aspect Ratios

    /// Movie/show poster (2:3.3 — Plezy uses slightly taller posters)
    static let posterAspectRatio: CGFloat = 2.0 / 3.3

    /// Backdrop/banner image (16:9)
    static let backdropAspectRatio: CGFloat = 16.0 / 9.0

    /// Episode thumbnail (16:9)
    static let thumbnailAspectRatio: CGFloat = 16.0 / 9.0

    // MARK: - Media Card Dimensions

    #if os(tvOS)
    /// Poster card width in a media row
    static let posterCardWidth: CGFloat = 260
    /// Poster card height matching aspect ratio
    static let posterCardHeight: CGFloat = 390
    /// Episode/thumbnail card width
    static let thumbnailCardWidth: CGFloat = 360
    /// Episode/thumbnail card height
    static let thumbnailCardHeight: CGFloat = 200
    #else
    static let posterCardWidth: CGFloat = 120
    static let posterCardHeight: CGFloat = 198
    static let thumbnailCardWidth: CGFloat = 160
    static let thumbnailCardHeight: CGFloat = 90
    #endif

    /// Profile avatar size
    #if os(tvOS)
    static let profileAvatarSize: CGFloat = 160
    #else
    static let profileAvatarSize: CGFloat = 80
    #endif

    // MARK: - Animation Durations (Plezy mono_tokens)

    /// Fast — focus state changes, hover effects (120ms)
    static let fastDuration: Double = 0.12

    /// Normal — tab transitions, chip selection (200ms)
    static let normalDuration: Double = 0.20

    /// Slow — image crossfades, content reveals (300ms)
    static let slowDuration: Double = 0.30

    /// Standard transition duration
    static let animationDuration: Double = 0.20

    /// Standard spring animation
    static let springAnimation = Animation.spring(response: 0.35, dampingFraction: 0.85)

    #if os(tvOS)
    // MARK: - Skyline chrome metrics (tvOS)

    /// Skyline navigation chrome tokens (design guide §4–§5). Values are
    /// mockup pixels at 1920×1080, which render 1:1 as points on tvOS.
    enum Skyline {
        /// Root horizontal inset for chrome and content — `safeArea.x`.
        static let safeAreaX: CGFloat = 88
        /// Top bar offset from the screen's top edge — `safeArea.top`.
        static let barTopInset: CGFloat = 56
        /// Top bar row height.
        static let barHeight: CGFloat = 64
        /// Gap between tab capsules in the bar's center cluster.
        static let tabSpacing: CGFloat = 8
        static let tabLabelSize: CGFloat = 26
        static let tabPaddingHorizontal: CGFloat = 29
        static let tabPaddingVertical: CGFloat = 12
        /// Square hit target of the search button and the profile avatar.
        static let barIconSize: CGFloat = 58
        /// Gap between the search button and the avatar.
        static let barTrailingSpacing: CGFloat = 22
        static let wordmarkSize: CGFloat = 26
        /// Wordmark letter tracking — +0.34 em.
        static let wordmarkTracking: CGFloat = 26 * 0.34
        /// Bar opacity while focus is down in the content zone (§5.1).
        static let barDimmedOpacity: Double = 0.7

        /// Pill row offset from the screen top — 30 below the bar (§5.2).
        static let pillRowTopInset: CGFloat = 150
        static let pillSpacing: CGFloat = 12
        static let pillLabelSize: CGFloat = 19
        static let pillPaddingHorizontal: CGFloat = 22
        static let pillPaddingVertical: CGFloat = 9
        /// Right-aligned scope caption in the pill row.
        static let pillCaptionSize: CGFloat = 18
        /// Upward drift of incoming sub-pill content on a pill switch
        /// (§4.2: "200 ms crossfade + 12 px upward drift of incoming
        /// content"). Paired with the shared 200 ms `normalDuration`.
        static let pillDriftY: CGFloat = 12

        /// A–Z alphabet rail letter size when expanded (§6.4: "mono 15").
        /// Rendered monospaced; the collapsed edge peek uses a smaller frame.
        static let alphabetRailLetterSize: CGFloat = 15

        /// Top inset for library-tab content that has no hero of its own
        /// (grids, chip clouds): clears the bar and the pill row.
        static let libraryContentTopInset: CGFloat = 216
        /// Extra top inset the featured hero needs on library tabs so its
        /// card deck starts below the pill row instead of under it.
        static let libraryHeroExtraTopInset: CGFloat = 88

        /// Anchored dropdown panel (§5.3/§5.8).
        static let dropdownWidth: CGFloat = 460
        static let dropdownCornerRadius: CGFloat = 22
        static let dropdownPadding: CGFloat = 14
        static let dropdownRowTextSize: CGFloat = 22
        static let dropdownHeaderSize: CGFloat = 14
        /// Panel top offset — anchored just under the bar.
        static let dropdownTopInset: CGFloat = 132

        // MARK: Cascading library selector (§5.3)

        /// Focus-dwell before a library tab (or the profile avatar) opens
        /// its anchored panel. Sweeping across the bar never opens it;
        /// resting this long does. Tuned per Open-Q5/Q7 on device.
        static let cascadeDwellMilliseconds: UInt64 = 250
        /// Cascade open scale-up start (§4.2: 0.96 → 1.0).
        static let cascadeOpenScale: CGFloat = 0.96
        /// Cascade panel scale/fade duration (§4.2, 180 ms).
        static let cascadeOpenDuration: Double = 0.18
        /// Scrim fade duration behind the cascade (§4.2, 150 ms).
        static let cascadeScrimDuration: Double = 0.15
        /// Width of the notch tab pointing from a panel to its anchor.
        static let cascadeNotchWidth: CGFloat = 20
        /// Height the notch protrudes toward its anchor.
        static let cascadeNotchHeight: CGFloat = 10

        /// Level-1 library row metrics (§5.3).
        static let cascadeRowTextSize: CGFloat = 22
        static let cascadeRowPaddingHorizontal: CGFloat = 18
        static let cascadeRowPaddingVertical: CGFloat = 16
        static let cascadeRowCornerRadius: CGFloat = 14
        static let cascadeRowIconSize: CGFloat = 30
        /// Library rows visible before the level-1 list scrolls internally.
        static let cascadeMaxVisibleRows = 6

        /// Sections flyout (§5.3, level 2).
        static let flyoutWidth: CGFloat = 300
        static let flyoutCornerRadius: CGFloat = 18
        static let flyoutPadding: CGFloat = 10
        /// Gap between the level-1 panel's right edge and the flyout.
        static let flyoutGap: CGFloat = 18
        static let flyoutRowTextSize: CGFloat = 20
        static let flyoutRowPaddingHorizontal: CGFloat = 16
        static let flyoutRowPaddingVertical: CGFloat = 13
        static let flyoutRowCornerRadius: CGFloat = 12
        static let flyoutHeaderSize: CGFloat = 13
        /// Open scale-up for the flyout (§4.2, 0.97 → 1.0).
        static let flyoutOpenScale: CGFloat = 0.97
        static let flyoutOpenDuration: Double = 0.16
        /// Rest debounce before the flyout follows focus to a new library
        /// row (§5.3) — rolling the list never thrashes the flyout.
        static let flyoutFollowDebounceMilliseconds: UInt64 = 150

        // MARK: Focus marquee (§5.4/§5.5)

        /// Shared vertical placement for the foreground marquee and row band
        /// on every Skyline landing. Keeping this in the shared feed prevents
        /// title logos from rising into the app-level top menu while Home and
        /// every library Recommended landing retain identical geometry.
        static let landingContentVerticalOffset: CGFloat = 56

        /// Marquee block bottom inset — Home scale. On a 1080p tvOS canvas,
        /// this lands the marquee's bottom edge at the midpoint so the lower
        /// half can hold the focused row plus a peek of the next row.
        static let marqueeBottomInsetHome: CGFloat = 540
        /// Marquee block bottom inset — library (compact) scale. Matched to
        /// Home so the Skyline feed keeps a consistent 50/50 marquee-to-row
        /// split across Home and library landings.
        static let marqueeBottomInsetLibrary: CGFloat = 540
        /// Marquee content block width.
        static let marqueeContentWidth: CGFloat = 880
        static let marqueeTitleSizeHome: CGFloat = 84
        static let marqueeTitleSizeLibrary: CGFloat = 66
        static let marqueeMetaSizeHome: CGFloat = 20
        static let marqueeMetaSizeLibrary: CGFloat = 19
        /// Fixed leading slot for the age/content-rating pill. For You often
        /// backfills this value from item detail; reserving the slot prevents
        /// the remaining metadata from sliding sideways when it arrives.
        static let marqueeRatingSlotWidth: CGFloat = 104
        static let marqueeSynopsisSize: CGFloat = 22
        /// Synopsis column cap (§4.1) — narrower than the content block.
        static let marqueeSynopsisMaxWidth: CGFloat = 780
        /// Cached server logo art caps in the marquee title slot. With
        /// the row stack owning the lower half of the screen, Home affords
        /// the full §5.4 cap; the library scale stays tighter because the
        /// pill row eats into its band. While a logo is shown the synopsis
        /// drops a line, like a wrapped title.
        static let marqueeLogoMaxWidth: CGFloat = 880
        static let marqueeLogoMaxHeightHome: CGFloat = 200
        static let marqueeLogoMaxHeightLibrary: CGFloat = 150
        /// Codec/HDR badge chip label size (§4.1).
        static let marqueeBadgeSize: CGFloat = 15
        /// Focus must rest this long before the marquee swaps (§4.2) —
        /// rolling through cards never thrashes backdrops.
        static let marqueeRestDebounceMilliseconds = 150
        /// Marquee text + backdrop crossfade duration (§4.2).
        static let marqueeCrossfadeDuration: Double = 0.24

        // MARK: Row band under the marquee (§5.7, revised)

        /// Portion of the screen reserved for the row stack. The focused row
        /// sits at the top of this lower-half band and the following row peeks
        /// below it.
        static let rowBandHeightFraction: CGFloat = 0.50

        /// Bottom inset for the row band, measured from the physical bottom
        /// edge. The row layers ignore the bottom safe area (the ~86pt tvOS
        /// overscan was leaving a dead band under the rail), so this is the
        /// small margin kept below the focused row's captions.
        static let rowBandBottomInset: CGFloat = 20
        /// Vertical gap between the focused row and the passive preview of
        /// the next row.
        static let rowBandPreviewSpacing: CGFloat = 10
        /// Tighter vertical breathing room for the focused Skyline card strip.
        /// Regular rows keep the wider tvOS padding so focus lift has more
        /// space in standard scroll layouts.
        static let rowBandCardVerticalPadding: CGFloat = 14
        /// Duration for the vertical row-stack scroll when paging up/down.
        static let rowBandScrollDuration: Double = 0.18
        /// Distance the outgoing focused row travels as it fades behind the
        /// marquee/title area during row paging.
        static let rowBandExitOffset: CGFloat = 140
        /// Passive row preview tint so it reads as available content without
        /// competing with the focused row.
        static let rowPreviewOpacity: Double = 0.74
        /// Number of preview cards to paint. Enough to fill the visible width
        /// without doing unnecessary image work for off-screen cards.
        static let rowPreviewItemLimit = 8
        /// Dense poster card (§5.6) for Home + Browse poster rows. Sized so
        /// a full poster row (header + 2:3 poster + title/year) fits in the
        /// top of the lower-half row band while leaving a preview of the next
        /// row below it.
        static let densePosterCardWidth: CGFloat = 176

        // MARK: Collections poster grid (§6.3)

        /// Collections render as standard 2:3 poster tiles (the canonical
        /// `posterCardWidth` poster) in a grid that mirrors the library Browse
        /// grid, so a collection reads as a first-class browseable card.
        /// 6 flexible columns within the safe area.
        static let collectionGridColumnCount = 6
        static let collectionGridColumnSpacing: CGFloat = 40
        static let collectionGridRowSpacing: CGFloat = 60
        /// Mono group-header size for the collections grid (§6.3, mono
        /// header style — the dropdown mono grammar at grid scale).
        static let collectionGridGroupHeaderSize: CGFloat = 22
    }
    #endif
}

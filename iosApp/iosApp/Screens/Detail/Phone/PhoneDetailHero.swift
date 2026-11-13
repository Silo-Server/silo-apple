#if !os(tvOS)
import SwiftUI

/// Shared reference state for the pinned chrome. Artwork parallax is driven by
/// a render-time `visualEffect`, so the native scroll view never has to publish
/// its high-frequency movement through SwiftUI state just to move the image.
@Observable
@MainActor
final class PhoneDetailScrollState {
    private(set) var offset: CGFloat = 0

    /// Takes an offset already folded by `phoneDetailScrollTracking`.
    func update(_ offset: CGFloat) {
        guard abs(offset - self.offset) >= 0.5 else { return }
        self.offset = offset
    }

    func reset() {
        offset = 0
    }
}

extension View {
    /// Feeds the native scroll offset into `state`. Nothing in the chrome
    /// changes below 150 points or above 480, so those plateaus fold onto
    /// their endpoints and the small chrome views stay untouched while their
    /// rendered output is static.
    func phoneDetailScrollTracking(_ state: PhoneDetailScrollState) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            let offset = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            return offset <= 150 ? 0 : min(offset, 480)
        } action: { _, offset in
            state.update(offset)
        }
    }
}

/// The named native scroll coordinate space used by render-time parallax.
/// A name resolves to the nearest ancestor, so separately presented detail
/// cards cannot interfere with one another.
enum PhoneDetailScrollCoordinateSpace {
    static let name = "phone-detail-scroll"
}

/// Artwork-matched surface shared by mobile video-detail pages. Compact iPhone
/// movie/series cards keep a saturated, heavily softened copy of the hero fixed
/// behind the ScrollView. It supplies the colour field that remains visible as
/// the sharp artwork drifts away more slowly than the foreground content.
struct PhoneDetailPageSurface<Content: View>: View {
    let backdropURL: String?
    let backdropThumbhash: String?
    let enablesArtworkGlass: Bool
    /// Leaves the side safe-area insets to the content, which
    /// `PhoneDetailPageLayout` needs to keep a split page clear of the iPhone
    /// Duo's status-bar column. The backdrop always fills the window.
    var keepsSideSafeArea = false
    @ViewBuilder let content: () -> Content

    @State private var sampledTint = Color(red: 0.04, green: 0.12, blue: 0.14)
    @State private var topSafeArea: CGFloat = 0
    #if os(macOS)
    @State private var pageHeight: CGFloat = 0
    #endif
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        #if os(macOS)
        // The page keeps the leading inset so it is not laid out underneath
        // the Mac sidebar, while its backdrop still fills the window: a
        // backdrop that stopped at the inset would show a hard edge beside
        // the sidebar's rounded panel.
        content()
            .ignoresSafeArea(edges: .vertical)
            // The hero places its details column by the window's height.
            .environment(\.detailPageVisibleHeight, pageHeight)
            .background { backdrop.ignoresSafeArea() }
            // The page runs under the title bar, so its height includes it.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            } action: { pageHeight = $0 }
            .task(id: backdropURL) { await sampleTint() }
        #else
        ZStack {
            backdrop
                .ignoresSafeArea()
            content()
                .ignoresSafeArea(.all, edges: keepsSideSafeArea ? .vertical : .all)
                .environment(\.detailPageTopSafeArea, topSafeArea)
        }
        // Content reaches under the status bar, so it can't read this itself.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topSafeArea = $0 }
        .task(id: backdropURL) { await sampleTint() }
        #endif
    }

    private var backdrop: some View {
        ZStack {
            Color.black

            if usesArtworkGlass, let backdropURL, !backdropURL.isEmpty {
                GeometryReader { geometry in
                    AsyncImageView(
                        url: backdropURL,
                        thumbhash: backdropThumbhash,
                        contentMode: .fill
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(1.18)
                    .saturation(1.28)
                    .brightness(-0.10)
                    .blur(radius: 46, opaque: true)
                    .clipped()
                }
                .allowsHitTesting(false)

                Color.black.opacity(0.28)
                sampledTint.opacity(0.10)
                PhoneDetailGrainOverlay()
            } else {
                sampledTint.opacity(0.42)
            }
        }
    }

    private func sampleTint() async {
        guard let rawURL = backdropURL,
              let url = URL(string: rawURL) else {
            sampledTint = Color(red: 0.04, green: 0.12, blue: 0.14)
            return
        }

        if let cached = HeroBackdropPalette.cachedTint(for: url) {
            sampledTint = cached
        }
        if let tint = await HeroBackdropPalette.tintColor(for: url),
           !Task.isCancelled {
            sampledTint = tint
        }
    }

    private var usesArtworkGlass: Bool {
        guard enablesArtworkGlass, !reduceTransparency else { return false }
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
            && horizontalSizeClass != .regular
        #else
        return false
        #endif
    }
}

/// A fixed one-device-pixel monochrome dither. At 1.4% opacity it is not meant
/// to read as a texture; it only breaks up 8-bit colour steps in large, slowly
/// changing gradients. The tiny tile is generated once and never animates.
private struct PhoneDetailGrainOverlay: View {
    var body: some View {
        if let texture = PhoneDetailGrainTexture.image {
            Image(decorative: texture, scale: 3)
                .resizable(resizingMode: .tile)
                .interpolation(.none)
                .blendMode(.overlay)
                .opacity(0.012)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private enum PhoneDetailGrainTexture {
    static let image: CGImage? = {
        let width = 96
        let height = 96
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var pixels = [UInt8](repeating: 0, count: width * height)

        for index in pixels.indices {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 24)
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }()
}

/// What fills the hero's artwork slot. Video titles use their wide backdrop.
/// Books have only cover art, so `.cover` keeps the same slot but fills it
/// with a blurred wash of the cover and floats the sharp cover on top.
/// `aspectRatio` is the cover's width ÷ height.
enum PhoneDetailArtworkStyle: Equatable {
    case backdrop
    case cover(aspectRatio: CGFloat, placeholderSymbol: String)

    /// The mark a missing poster or cover shows.
    var placeholderSymbol: String {
        switch self {
        case .backdrop: ArtworkPlaceholderSymbol.fallback
        case .cover(_, let placeholderSymbol): placeholderSymbol
        }
    }
}

/// Artwork moves at roughly half foreground speed. Its translation and
/// scroll-linked dimming are render-time effects derived directly from the
/// native scroll geometry, avoiding an observable-state update and image-view
/// rebuild on every frame.
private struct PhoneDetailParallaxArtwork: View {
    let url: String?
    let thumbhash: String?
    let height: CGFloat
    let isEnabled: Bool
    var style: PhoneDetailArtworkStyle = .backdrop

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let parallaxEnabled = usesParallax
        ZStack {
            artwork
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipped()
                .visualEffect { content, proxy in
                    let minY = proxy.frame(in: .named(PhoneDetailScrollCoordinateSpace.name)).minY
                    let offset = min(max(0, -minY), 540)
                    return content.offset(
                        y: parallaxEnabled ? offset * 0.52 : 0
                    )
                }

            Color.black
                .visualEffect { content, proxy in
                    let minY = proxy.frame(in: .named(PhoneDetailScrollCoordinateSpace.name)).minY
                    let offset = min(max(0, -minY), 540)
                    return content.opacity(
                        parallaxEnabled
                            ? 0.30 * min(max(offset / 360, 0), 1)
                            : 0
                    )
                }
                .allowsHitTesting(false)
        }
        .frame(height: height)
        .clipped()
        .mask(artworkMask)
    }

    @ViewBuilder
    private var artwork: some View {
        switch style {
        case .backdrop:
            if let url, !url.isEmpty {
                AsyncImageView(url: url, thumbhash: thumbhash, contentMode: .fill)
            } else {
                Color.siloSurface
            }
        case .cover(let aspectRatio, let placeholderSymbol):
            // The cover clears the floating top controls and leaves the lower
            // part of the slot to the title, which overlays it as usual.
            PhoneDetailCoverArtwork(
                url: url,
                thumbhash: thumbhash,
                aspectRatio: aspectRatio,
                placeholderSymbol: placeholderSymbol,
                coverHeight: min(max(height * 0.48, 190), 250),
                coverTopInset: 100
            )
        }
    }

    private var usesParallax: Bool {
        guard isEnabled, !reduceMotion else { return false }
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
            && horizontalSizeClass != .regular
        #else
        return false
        #endif
    }

    private var artworkMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.72),
                .init(color: .black.opacity(0.76), location: 0.84),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// The parts of `PhoneDetailHero` a split page lays out separately.
enum PhoneDetailHeroPane {
    /// The artwork, spread behind the whole page.
    case artwork
    /// Title, facts, and actions, for the glass sidebar.
    case sidebar
    /// Overview and credits, at the top of the content pane.
    case overview
}

/// Chooses between `PhoneDetailHero`'s compact and expanded compositions.
/// Shared with the floating top chrome, which times its backing strip to the
/// hero it sits over.
enum PhoneDetailHeroLayout {
    static let expandedBreakpoint: CGFloat = 700

    static func usesExpandedLayout(
        availableWidth: CGFloat,
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        if horizontalSizeClass == .compact, verticalSizeClass == .regular {
            return false
        }
        if availableWidth > 0 {
            return availableWidth >= expandedBreakpoint
        }
        return horizontalSizeClass == .regular
    }

    /// How far a split page's sidebar floats in from the window's edges.
    static let splitSidebarMargin: CGFloat = 14

    /// Where the Close button sits in a split page's sidebar: 10pt inside
    /// both edges, so the 44pt button is concentric with the sidebar's 32pt
    /// corner (22 + 10).
    static let splitCloseButtonInset: CGFloat = splitSidebarMargin + 10

    /// Narrowest page that splits into a hero pane and a content pane.
    static let splitMinimumWidth: CGFloat = 760

    /// A wide, short page — the iPhone Duo's open inner display held in
    /// landscape — leaves a single hero-first column showing little more
    /// than artwork. It splits instead: the artwork spans the window, the
    /// title and actions hold still in a sidebar, and the rest of the page
    /// scrolls beside it (see `PhoneDetailPageLayout`). An iPad window in
    /// landscape splits the same way.
    /// Taller pages (portrait, including iPad page sheets) keep one column,
    /// and so do compact-height ones: an iPhone turned to landscape for the
    /// player also rotates the pages beneath it, which must not re-lay out.
    static func usesSplitLayout(pageSize: CGSize, verticalSizeClass: UserInterfaceSizeClass?) -> Bool {
        #if os(macOS)
        // Mac detail pages have their own header beside the sidebar.
        return false
        #else
        return verticalSizeClass == .regular
            && pageSize.width >= splitMinimumWidth
            && pageSize.width >= pageSize.height * 1.2
        #endif
    }
}

/// Artwork-led mobile detail header used inside the bottom-presented detail
/// card. Compact widths use the approved portrait composition: sharp artwork,
/// title art at its lower edge, then metadata and actions. Wide iPad panes use
/// the same ingredients in a touch-first editorial split rather than stretching
/// the phone stack or reusing television geometry.
struct PhoneDetailHero<Actions: View, BelowOverview: View>: View {
    let title: String
    let logoUrl: String?
    let posterUrl: String?
    let posterThumbhash: String?
    let backdropUrl: String?
    let backdropThumbhash: String?
    let eyebrow: String?
    let sourceTokens: [String]
    let ratingChip: String?
    let overview: String?
    let factsLine: [PhoneHeroFactToken]
    /// External ratings in server order, shown as a row under the facts: the
    /// first `DisplayRating.phoneLimit` on one line in the compact layout,
    /// all of them in the expanded one.
    var ratings: [DisplayRating] = []
    var creditText: String? = nil
    /// Overlay metadata used to add the advisory-age badge when the active
    /// profile has enabled it.
    let overlayData: OverlayData?
    var enablesArtworkParallax = false
    var artworkStyle: PhoneDetailArtworkStyle = .backdrop
    /// Set when the hero supplies one part of a split page (see
    /// `PhoneDetailHeroLayout.usesSplitLayout`). `belowOverview` is not drawn
    /// in any part; the page places it in the content pane.
    var pane: PhoneDetailHeroPane? = nil
    /// Scales the compact (iPhone) artwork's height. A page whose content
    /// matters more than its art, such as a box set's movies, passes less
    /// than 1 so that content starts in the first screen.
    var compactArtworkHeightFactor: CGFloat = 1
    /// Sizes the regular-width (iPad and Mac) hero to its text and actions
    /// rather than the fixed backdrop height, with the backdrop filling
    /// whatever height that is. For the same pages as
    /// `compactArtworkHeightFactor`.
    var fitsRegularHeroToContent = false
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let belowOverview: () -> BelowOverview

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    #if os(iOS)
    @Environment(\.statusColumn) private var statusColumn
    #endif
    /// Rating scores follow Dynamic Type from their 15pt default.
    @ScaledMetric(relativeTo: .subheadline) private var ratingSize: CGFloat = 15
    @State private var availableWidth: CGFloat = 0
    @State private var showFullOverview = false
    #if os(macOS)
    @Environment(\.detailPageVisibleHeight) private var macPageHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The Mac header's details column, measured without its offset.
    @State private var macDetailsHeight: CGFloat = 0
    #endif
    @ObservedObject private var advisoryAgePreference = AdvisoryAgePreferenceStore.shared

    var body: some View {
        Group {
            #if os(macOS)
            macHeader
            #else
            if let pane {
                switch pane {
                case .artwork: paneArtwork
                case .sidebar: paneSidebar
                case .overview: paneOverview
                }
            } else if usesExpandedLayout {
                expandedHeader
            } else {
                compactHeader
            }
            #endif
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard abs(width - availableWidth) > 1 else { return }
            availableWidth = width
        }
        .task(id: overlayData?.advisoryAge) {
            guard (overlayData?.advisoryAge ?? 0) > 0 else { return }
            await advisoryAgePreference.hydrateIfNeeded()
        }
    }

    private var usesExpandedLayout: Bool {
        PhoneDetailHeroLayout.usesExpandedLayout(
            availableWidth: availableWidth,
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
    }

    // MARK: - Compact iPhone layout

    private var compactHeader: some View {
        VStack(spacing: 0) {
            compactArtwork

            VStack(spacing: 16) {
                metadataBlock(alignment: .center, textAlignment: .center, isCompact: true)

                actions()
                    .padding(.top, 2)

                overviewBlock
                creditBlock(alignment: .leading)
                belowOverview()
            }
            .padding(.horizontal, SiloTheme.safePadding)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    private var compactArtwork: some View {
        ZStack(alignment: .bottom) {
            PhoneDetailParallaxArtwork(
                url: resolvedArtworkURL,
                thumbhash: resolvedArtworkThumbhash,
                height: compactArtworkHeight,
                isEnabled: enablesArtworkParallax,
                style: artworkStyle
            )

            LinearGradient(
                colors: [Color.black.opacity(0.34), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .allowsHitTesting(false)

            titleBlock(textAlignment: .center, logoHeight: compactLogoHeight)
                .padding(.horizontal, 28)
                .padding(statusColumnEdge, statusColumnWidth)
                .padding(.bottom, 6)
        }
        .frame(height: compactArtworkHeight)
        .clipped()
        // The artwork runs under the iPhone Duo's status column; the title
        // stays centred on the page beside it.
        .padding(statusColumnEdge, -statusColumnWidth)
        .accessibilityElement(children: .contain)
    }

    private var statusColumnEdge: Edge.Set {
        #if os(iOS)
        statusColumn?.edgeSet ?? .trailing
        #else
        .trailing
        #endif
    }

    private var statusColumnWidth: CGFloat {
        #if os(iOS)
        statusColumn?.width ?? 0
        #else
        0
        #endif
    }

    private var compactArtworkHeight: CGFloat {
        let width = availableWidth > 0 ? availableWidth : 390
        return min(max(width * 1.18, 430), 540) * compactArtworkHeightFactor
    }

    private var compactLogoHeight: CGFloat {
        min(max(compactArtworkHeight * 0.24, 104), 138)
    }

    // MARK: - Split page parts

    /// The sidebar of a split page: title, facts, and actions, aligned to
    /// the leading edge of the glass panel the page draws around them.
    private var paneSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Smaller than the compact logo: the sidebar is narrow and shares
            // the display's height with the facts, actions, and selectors.
            titleBlock(textAlignment: .leading, logoHeight: 84)
            metadataBlock(alignment: .leading, textAlignment: .leading, isCompact: true)
            actions()
                .padding(.top, 2)
        }
    }

    /// The overview and credits, which open the content pane.
    private var paneOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            overviewBlock
            creditBlock(alignment: .leading)
        }
    }

    /// The artwork the page spreads across the whole window, from edge to
    /// edge under the sidebar and the content pane.
    private var paneArtwork: some View {
        artwork
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Expanded iPad layout

    @ViewBuilder
    private var expandedHeader: some View {
        if fitsRegularHeroToContent {
            expandedText
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(alignment: .topLeading) { expandedArtwork(fillsHeight: true) }
                .clipped()
        } else {
            ZStack(alignment: .topLeading) {
                expandedArtwork(fillsHeight: false)
                expandedText
            }
            .frame(maxWidth: .infinity, minHeight: 550, alignment: .topLeading)
            .clipped()
        }
    }

    private var expandedText: some View {
        VStack(alignment: .leading, spacing: 15) {
            if let eyebrow, !eyebrow.isEmpty {
                Text(eyebrow.uppercased(with: locale))
                    .siloScaledFont(size: 11, weight: .bold, relativeTo: .caption2)
                    .tracking(1.2)
                    .foregroundStyle(Color.siloOnSurface.opacity(0.7))
            }

            titleBlock(textAlignment: .leading, logoHeight: 122)
                .frame(maxWidth: 430, alignment: .leading)

            metadataBlock(alignment: .leading, textAlignment: .leading, isCompact: false)
            overviewBlock
            creditBlock(alignment: .leading)
            belowOverview()

            actions()
                .padding(.top, 2)
        }
        .frame(maxWidth: expandedEditorialWidth, alignment: .leading)
        .padding(.leading, expandedHorizontalPadding)
        .padding(.top, 88)
        .padding(.bottom, 38)
    }

    /// `fillsHeight` stretches the artwork to the hero's full height; otherwise
    /// it keeps a 16:9 frame inside the fixed 550pt hero.
    private func expandedArtwork(fillsHeight: Bool) -> some View {
        GeometryReader { geometry in
            artwork
                .frame(
                    width: geometry.size.width * 0.66,
                    height: fillsHeight
                        ? geometry.size.height
                        : min(550, geometry.size.width * 0.66 * 9 / 16)
                )
                .clipped()
                .mask(expandedArtworkMask)
                .frame(
                    width: geometry.size.width,
                    height: fillsHeight ? geometry.size.height : 550,
                    alignment: .topTrailing
                )
        }
        .allowsHitTesting(false)
    }

    private var expandedArtworkMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.52),
                .init(color: .clear, location: 1),
            ],
            startPoint: .trailing,
            endPoint: .leading
        )
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.74),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var expandedEditorialWidth: CGFloat {
        min(max(availableWidth * 0.47, 410), 560)
    }

    private var expandedHorizontalPadding: CGFloat {
        availableWidth >= 1_000 ? 56 : 40
    }

    #if os(macOS)
    // MARK: - Mac layout

    /// Desktop composition: the backdrop runs the full width behind the
    /// header, with the poster on the leading side and the title, facts,
    /// synopsis, and actions in a column beside it. With a backdrop, the
    /// column starts lower than the poster (see `macDetailsOffset`) so more
    /// of the art shows above it. The header ends below whichever of the two
    /// ends lower.
    private var macHeader: some View {
        let offset = macDetailsOffset
        return macContent(detailsOffset: offset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(alignment: .top) {
                macBackdrop(detailsTop: SiloTheme.macDetailTopInset + offset)
            }
    }

    /// How much lower than the poster the details column starts. With a
    /// backdrop, enough to put the column's top about a fifth of the way down
    /// the page (capped for very tall windows), but never so much that the
    /// column and `macDetailBelowHeaderReserve` below it (a series' seasons
    /// and the top of its episode row) stop fitting on the first screen.
    /// Box sets, which want their movies on the first screen, and titles
    /// without a backdrop keep the column level with the poster.
    private var macDetailsOffset: CGFloat {
        guard !fitsRegularHeroToContent,
              case .backdrop = artworkStyle,
              nonEmpty(backdropUrl) != nil,
              macPageHeight > 0 else { return 0 }
        let inset = SiloTheme.macDetailTopInset
        let preferredTop = min(
            macPageHeight * SiloTheme.macDetailColumnTopFraction,
            SiloTheme.macDetailColumnMaxTop
        )
        let roomBelow = macPageHeight - inset - macDetailsHeight
            - SiloTheme.padding - SiloTheme.macDetailBelowHeaderReserve
        return max(0, min(preferredTop - inset, roomBelow))
    }

    private func macContent(detailsOffset: CGFloat) -> some View {
        HStack(alignment: .top, spacing: SiloTheme.largePadding) {
            macPoster

            VStack(alignment: .leading, spacing: 12) {
                if let eyebrow, !eyebrow.isEmpty {
                    Text(eyebrow.uppercased(with: locale))
                        .font(.siloCaption.weight(.bold))
                        .tracking(SiloTheme.macSidebarHeadingTracking)
                        .foregroundStyle(Color.siloOnSurface.opacity(0.7))
                }

                macTitle
                metadataBlock(alignment: .leading, textAlignment: .leading, isCompact: false)
                overviewBlock
                creditBlock(alignment: .leading)
                belowOverview()
                actions()
            }
            .frame(maxWidth: SiloTheme.macDetailTextWidth, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                guard abs(height - macDetailsHeight) > 1 else { return }
                macDetailsHeight = height
            }
            .padding(.top, detailsOffset)
        }
        // Same gutter as the rows below, so the poster lines up with them.
        .padding(.horizontal, SiloTheme.padding)
        .padding(.top, SiloTheme.macDetailTopInset)
        .padding(.bottom, SiloTheme.padding)
    }

    /// The backdrop behind the whole header, open above the details column.
    /// From there down it darkens toward the bottom and a little on the
    /// leading side so the text reads, then fades into the page surface.
    /// It scrolls with the page, drifting a little slower than the text.
    /// Cover-style titles (audiobooks) have no backdrop and show the page
    /// surface.
    @ViewBuilder
    private func macBackdrop(detailsTop: CGFloat) -> some View {
        if case .backdrop = artworkStyle, let url = nonEmpty(backdropUrl) {
            let parallax = reduceMotion ? 0 : SiloTheme.macDetailBackdropParallax
            GeometryReader { proxy in
                // Where the details column starts, as a fraction of the backdrop.
                let detailsStart = min(max(detailsTop / max(proxy.size.height, 1), 0), 0.8)
                // Where the details column ends across, as a fraction of the width.
                let detailsEnd = min(macDetailsTrailingEdge / max(proxy.size.width, 1), 1)
                AsyncImageView(url: url, thumbhash: backdropThumbhash, contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .visualEffect { content, proxy in
                        let minY = proxy.frame(in: .named(PhoneDetailScrollCoordinateSpace.name)).minY
                        return content.offset(y: max(0, -minY) * parallax)
                    }
                    .clipped()
                    .overlay { macBackdropShade(detailsStart: detailsStart, detailsEnd: detailsEnd) }
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.55),
                                .init(color: .black.opacity(0.6), location: 0.8),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The details column's trailing edge, measured from the header's
    /// leading edge, when the column is at its widest.
    private var macDetailsTrailingEdge: CGFloat {
        SiloTheme.padding + SiloTheme.macDetailPosterWidth + SiloTheme.largePadding
            + SiloTheme.macDetailTextWidth
    }

    /// A light shade at the very top for the toolbar's back button, nothing
    /// over the art above the details, then a leading-side shade behind them
    /// from just above the column down, and a bottom-up shade over the
    /// header's lower half, where the selectors and Play sit. The leading
    /// shade ends a little past `detailsEnd`, the column's trailing edge, so
    /// the art beyond the text stays clear.
    private func macBackdropShade(detailsStart: CGFloat, detailsEnd: CGFloat) -> some View {
        let shadeStart = max(detailsStart - 0.08, 0.06)
        return ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.3), location: 0),
                    .init(color: .clear, location: min(0.1, shadeStart)),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.35), location: 0.75),
                    .init(color: .black.opacity(0.55), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.65), location: 0),
                    .init(color: .black.opacity(0.5), location: detailsEnd * 0.55),
                    .init(color: .black.opacity(0.35), location: detailsEnd),
                    .init(color: .clear, location: min(detailsEnd + 0.18, 1)),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .mask {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: UnitPoint(x: 0.5, y: shadeStart),
                    endPoint: UnitPoint(x: 0.5, y: min(detailsStart + 0.08, 1))
                )
            }
        }
    }

    @ViewBuilder
    private var macPoster: some View {
        if let url = nonEmpty(posterUrl) {
            let size = macPosterSize
            AsyncImageView(
                url: url,
                thumbhash: posterThumbhash,
                targetSize: size,
                contentMode: .fill,
                placeholderStyle: .artwork,
                placeholderSymbol: artworkStyle.placeholderSymbol
            )
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cardCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            .accessibilityHidden(true)
        }
    }

    private var macPosterSize: CGSize {
        let width = SiloTheme.macDetailPosterWidth
        if case .cover(let aspectRatio, _) = artworkStyle, aspectRatio > 0 {
            return CGSize(width: width, height: width / aspectRatio)
        }
        return CGSize(width: width, height: width * 1.5)
    }

    @ViewBuilder
    private var macTitle: some View {
        if let logoUrl = displayedLogoUrl {
            MacTitleLogo(
                url: logoUrl,
                size: CGSize(width: SiloTheme.macHeroLogoWidth, height: SiloTheme.macHeroLogoHeight)
            )
            .accessibilityLabel(title)
        } else {
            PhoneHeroTitle(title: title, textAlignment: .leading)
        }
    }
    #endif

    // MARK: - Artwork and title

    @ViewBuilder
    private var artwork: some View {
        switch artworkStyle {
        case .backdrop:
            if let url = resolvedArtworkURL {
                AsyncImageView(
                    url: url,
                    thumbhash: resolvedArtworkThumbhash,
                    contentMode: .fill
                )
            } else {
                Color.siloSurface
            }
        case .cover(let aspectRatio, let placeholderSymbol):
            GeometryReader { geometry in
                PhoneDetailCoverArtwork(
                    url: resolvedArtworkURL,
                    thumbhash: resolvedArtworkThumbhash,
                    aspectRatio: aspectRatio,
                    placeholderSymbol: placeholderSymbol,
                    coverHeight: geometry.size.height * 0.68,
                    coverTopInset: nil
                )
            }
        }
    }

    /// Cover art always shows the cover; backdrop art falls back to the
    /// poster only when the title has no backdrop.
    private var resolvedArtworkURL: String? {
        if case .cover = artworkStyle { return nonEmpty(posterUrl) }
        return nonEmpty(backdropUrl) ?? nonEmpty(posterUrl)
    }

    private var resolvedArtworkThumbhash: String? {
        if case .cover = artworkStyle { return posterThumbhash }
        return nonEmpty(backdropUrl) != nil ? backdropThumbhash : posterThumbhash
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    /// Logo art only while the profile shows title art on this device;
    /// otherwise the text title, exactly as for a title without a logo.
    private var displayedLogoUrl: String? {
        guard TitleArtPreferences.shared.showsTitleArt,
              let logoUrl, !logoUrl.isEmpty else { return nil }
        return logoUrl
    }

    @ViewBuilder
    private func titleBlock(textAlignment: TextAlignment, logoHeight: CGFloat) -> some View {
        if let logoUrl = displayedLogoUrl {
            AsyncImageView(url: logoUrl, contentMode: .fit, placeholderStyle: .clear)
                .frame(maxWidth: textAlignment == .leading ? 430 : .infinity)
                .frame(height: logoHeight, alignment: textAlignment == .leading ? .leading : .center)
                .accessibilityLabel(title)
        } else {
            PhoneHeroTitle(title: title, textAlignment: textAlignment)
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private func metadataBlock(
        alignment: Alignment,
        textAlignment: TextAlignment,
        isCompact: Bool
    ) -> some View {
        let stackAlignment: HorizontalAlignment = textAlignment == .leading ? .leading : .center
        let hasFacts = !metadataTokens.isEmpty || !ratingChips.isEmpty
        if hasFacts || !ratings.isEmpty {
            VStack(alignment: stackAlignment, spacing: 10) {
                if hasFacts {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            metadataText(textAlignment: textAlignment)
                            ratingView
                        }
                        .frame(maxWidth: .infinity, alignment: alignment)

                        VStack(alignment: stackAlignment, spacing: 8) {
                            metadataText(textAlignment: textAlignment)
                            ratingView
                        }
                        .frame(maxWidth: .infinity, alignment: alignment)
                    }
                }
                if !ratings.isEmpty {
                    Group {
                        if isCompact {
                            PhoneRatingsRow(ratings: ratings, size: ratingSize)
                        } else {
                            RatingsRow(ratings: ratings, size: ratingSize, alignment: stackAlignment)
                        }
                    }
                    .foregroundStyle(Color.siloOnSurface)
                    .frame(maxWidth: .infinity, alignment: alignment)
                }
            }
        }
    }

    private func metadataText(textAlignment: TextAlignment) -> some View {
        Text(metadataTokens.joined(separator: "  ·  "))
            .siloScaledFont(size: 14, weight: .medium, relativeTo: .subheadline)
            .foregroundStyle(Color.siloOnSurface.opacity(0.84))
            .multilineTextAlignment(textAlignment)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var ratingView: some View {
        // No view at all without chips: an empty stack would still take the
        // parent's spacing and push the metadata off centre.
        if !ratingChips.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(ratingChips.enumerated()), id: \.offset) { _, chip in
                    Text(chip)
                        .siloScaledFont(size: 11, weight: .heavy, relativeTo: .caption2)
                        .tracking(0.7)
                        .foregroundStyle(Color.siloOnSurface)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.siloOnSurface.opacity(0.55), lineWidth: 1)
                        )
                }
            }
        }
    }

    private var ratingChips: [String] {
        var chips = [ratingChip].compactMap { value in
            value.flatMap { $0.isEmpty ? nil : $0 }
        }
        if advisoryAgePreference.showsAdvisoryAge,
           let advisory = overlayData?.advisoryAgeBadgeLabel {
            chips.append(advisory)
        }
        return chips
    }

    private var metadataTokens: [String] {
        var values = factsLine.compactMap { token -> String? in
            guard case .text(let value) = token else { return nil }
            return value
        }
        values.append(contentsOf: sourceTokens.filter { !values.contains($0) })
        return values
    }

    // MARK: - Editorial copy

    @ViewBuilder
    private var overviewBlock: some View {
        if let overview, !overview.isEmpty {
            PhoneDetailOverview(text: overview, isExpanded: $showFullOverview)
        }
    }

    @ViewBuilder
    private func creditBlock(alignment: Alignment) -> some View {
        if let creditText, !creditText.isEmpty {
            Text(creditText)
                .siloScaledFont(size: 13, weight: .medium, relativeTo: .footnote)
                .foregroundStyle(Color.siloOnSurface.opacity(0.58))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
    }
}

// MARK: - Overview

/// The overview, cut to three lines until tapped. When the text runs past
/// three lines, the end of the last visible line fades out before a MORE pill,
/// as the App Store does, so the pill never sits on top of words. Truncation
/// is measured against an unclipped copy at the same width, so the pill shows
/// only when text is actually hidden, at any Dynamic Type size.
private struct PhoneDetailOverview: View {
    let text: String
    @Binding var isExpanded: Bool

    private static let collapsedLineLimit = 3
    private static let lineSpacing: CGFloat = 3
    private static let pillGap: CGFloat = 4

    @ScaledMetric(relativeTo: .subheadline) private var fadeWidth: CGFloat = 32
    @State private var collapsedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    @State private var pillWidth: CGFloat = 0

    var body: some View {
        styledText
            .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                collapsedHeight = height
            }
            .background {
                styledText
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        fullHeight = height
                    }
                    .hidden()
            }
            .mask { visibleTextMask }
            .overlay(alignment: .bottomTrailing) {
                if isTruncated {
                    morePill
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.width
                        } action: { width in
                            pillWidth = width
                        }
                        .frame(height: lastLineHeight)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: SiloTheme.normalDuration)) {
                    isExpanded.toggle()
                }
            }
    }

    private var styledText: some View {
        Text(text)
            .siloScaledFont(size: 15, relativeTo: .subheadline)
            .foregroundStyle(Color.siloOnSurface.opacity(0.80))
            .lineSpacing(Self.lineSpacing)
            .multilineTextAlignment(.leading)
    }

    private var isTruncated: Bool {
        !isExpanded && fullHeight > collapsedHeight + 1
    }

    /// Height of one line of the collapsed text, without the spacing between lines.
    private var lastLineHeight: CGFloat {
        let lines = CGFloat(Self.collapsedLineLimit)
        return max((collapsedHeight - Self.lineSpacing * (lines - 1)) / lines, 0)
    }

    /// Opaque over the text, except for the end of the last line, which fades
    /// out and leaves clear space for the pill.
    @ViewBuilder
    private var visibleTextMask: some View {
        if isTruncated {
            VStack(spacing: 0) {
                Color.black
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fadeWidth)
                    Color.clear
                        .frame(width: pillWidth + Self.pillGap)
                }
                .frame(height: lastLineHeight + Self.lineSpacing / 2)
            }
        } else {
            Color.black
        }
    }

    private var morePill: some View {
        Button {
            withAnimation(.easeInOut(duration: SiloTheme.normalDuration)) {
                isExpanded = true
            }
        } label: {
            Text(.detailOverviewMore)
                .siloScaledFont(size: 10, weight: .heavy, relativeTo: .caption2)
                .tracking(0.6)
                .foregroundStyle(Color.siloOnSurface)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.54)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cover artwork

/// Fills the artwork slot with a soft, saturated wash of the cover, then
/// floats the sharp cover on it. `coverTopInset` pins the cover below the
/// top controls; nil centres it in the slot.
private struct PhoneDetailCoverArtwork: View {
    let url: String?
    let thumbhash: String?
    let aspectRatio: CGFloat
    let placeholderSymbol: String
    let coverHeight: CGFloat
    let coverTopInset: CGFloat?

    var body: some View {
        ZStack(alignment: coverTopInset == nil ? .center : .top) {
            wash
            cover
                .padding(.top, coverTopInset ?? 0)
        }
    }

    @ViewBuilder
    private var wash: some View {
        if let url, !url.isEmpty {
            Color.clear
                .overlay {
                    AsyncImageView(
                        url: url,
                        thumbhash: thumbhash,
                        targetSize: CGSize(width: 420, height: 420),
                        contentMode: .fill
                    )
                    .scaleEffect(1.25)
                    .saturation(1.2)
                    .blur(radius: 44, opaque: true)
                }
                .overlay(Color.black.opacity(0.26))
                .clipped()
        } else {
            Color.siloSurface
        }
    }

    private var cover: some View {
        let width = coverHeight * aspectRatio
        return AsyncImageView(
            url: url ?? "",
            thumbhash: thumbhash,
            targetSize: CGSize(width: width, height: coverHeight),
            contentMode: .fill,
            placeholderStyle: .artwork,
            placeholderSymbol: placeholderSymbol
        )
        .frame(width: width, height: coverHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 26, x: 0, y: 16)
        .accessibilityHidden(true)
    }
}

// MARK: - Titles

private struct PhoneHeroTitle: View {
    let title: String
    let textAlignment: TextAlignment

    var body: some View {
        let parts = PhoneHeroMetadata.splitTitle(title)
        VStack(spacing: 4) {
            Text(parts.primary)
                .siloScaledFont(size: 32, weight: .heavy, relativeTo: .largeTitle)
                .foregroundStyle(Color.siloOnSurface)
                .lineLimit(2)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = parts.subtitle {
                Text(subtitle.uppercased())
                    .siloScaledFont(size: 13, weight: .heavy, relativeTo: .footnote)
                    .tracking(1.2)
                    .foregroundStyle(Color.siloOnSurface.opacity(0.80))
                    .lineLimit(2)
                    .multilineTextAlignment(textAlignment)
            }
        }
        .frame(maxWidth: .infinity, alignment: textAlignment == .leading ? .leading : .center)
        // The title sits over fixed-height artwork with a two-line limit;
        // past AX1 a long title would truncate rather than read better.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

#endif

#if !os(tvOS)
import SwiftUI

/// Shared reference state for the pinned chrome. Artwork parallax is driven by
/// a render-time `visualEffect`, so the native scroll view never has to publish
/// its high-frequency movement through SwiftUI state just to move the image.
@Observable
@MainActor
final class PhoneDetailScrollState {
    private(set) var offset: CGFloat = 0

    func update(_ rawOffset: CGFloat) {
        // Nothing in the chrome changes below 150 points or above 480. Folding
        // those plateaus onto their endpoints avoids invalidating even the
        // small chrome views while their rendered output is completely static.
        let clamped = min(max(0, rawOffset), 480)
        let normalized = clamped <= 150 ? 0 : clamped
        guard abs(normalized - offset) >= 0.5 else { return }
        offset = normalized
    }

    func reset() {
        offset = 0
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
    @ViewBuilder let content: () -> Content

    @State private var sampledTint = Color(red: 0.04, green: 0.12, blue: 0.14)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
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

            content()
        }
        .ignoresSafeArea()
        .task(id: backdropURL) {
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

/// Artwork moves at roughly half foreground speed. Its translation and
/// scroll-linked dimming are render-time effects derived directly from the
/// native scroll geometry, avoiding an observable-state update and image-view
/// rebuild on every frame.
private struct PhoneDetailParallaxArtwork: View {
    let url: String?
    let thumbhash: String?
    let height: CGFloat
    let isEnabled: Bool

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
        if let url, !url.isEmpty {
            AsyncImageView(url: url, thumbhash: thumbhash, contentMode: .fill)
        } else {
            Color.siloSurface
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

/// Artwork-led mobile detail header used inside the bottom-presented detail
/// card. Compact widths use the approved portrait composition: sharp artwork,
/// title art at its lower edge, then metadata and actions. Wide iPad panes use
/// the same ingredients in a touch-first editorial split rather than stretching
/// the phone stack or reusing television geometry.
struct PhoneDetailHero<Actions: View, BelowOverview: View>: View {
    let title: String
    let seriesTitle: String?
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
    var creditText: String? = nil
    /// Retained at the call boundary for source compatibility. Detail artwork
    /// intentionally renders no card-overlay badges in this redesigned surface.
    var overlayData: OverlayData? = nil
    var enablesArtworkParallax = false
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let belowOverview: () -> BelowOverview

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var availableWidth: CGFloat = 0
    @State private var showFullOverview = false

    private let expandedLayoutBreakpoint: CGFloat = 700

    var body: some View {
        Group {
            if usesExpandedLayout {
                expandedHeader
            } else {
                compactHeader
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard abs(width - availableWidth) > 1 else { return }
            availableWidth = width
        }
    }

    private var usesExpandedLayout: Bool {
        if horizontalSizeClass == .compact, verticalSizeClass == .regular {
            return false
        }
        if availableWidth > 0 {
            return availableWidth >= expandedLayoutBreakpoint
        }
        return horizontalSizeClass == .regular
    }

    // MARK: - Compact iPhone layout

    private var compactHeader: some View {
        VStack(spacing: 0) {
            compactArtwork

            VStack(spacing: 16) {
                metadataBlock(alignment: .center, textAlignment: .center)

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
                isEnabled: enablesArtworkParallax
            )

            LinearGradient(
                colors: [Color.black.opacity(0.34), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .allowsHitTesting(false)

            titleBlock(textAlignment: .center, logoHeight: compactLogoHeight)
                .padding(.horizontal, 28)
                .padding(.bottom, 6)
        }
        .frame(height: compactArtworkHeight)
        .clipped()
        .accessibilityElement(children: .contain)
    }

    private var compactArtworkHeight: CGFloat {
        let width = availableWidth > 0 ? availableWidth : 390
        return min(max(width * 1.18, 430), 540)
    }

    private var compactLogoHeight: CGFloat {
        min(max(compactArtworkHeight * 0.24, 104), 138)
    }

    // MARK: - Expanded iPad layout

    private var expandedHeader: some View {
        ZStack(alignment: .topLeading) {
            expandedArtwork

            VStack(alignment: .leading, spacing: 15) {
                if let eyebrow, !eyebrow.isEmpty {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.siloOnSurface.opacity(0.7))
                }

                titleBlock(textAlignment: .leading, logoHeight: 122)
                    .frame(maxWidth: 430, alignment: .leading)

                metadataBlock(alignment: .leading, textAlignment: .leading)
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
        .frame(maxWidth: .infinity, minHeight: 550, alignment: .topLeading)
        .clipped()
    }

    private var expandedArtwork: some View {
        GeometryReader { geometry in
            artwork
                .frame(
                    width: geometry.size.width * 0.66,
                    height: min(550, geometry.size.width * 0.66 * 9 / 16)
                )
                .clipped()
                .mask(expandedArtworkMask)
                .frame(
                    width: geometry.size.width,
                    height: 550,
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

    // MARK: - Artwork and title

    @ViewBuilder
    private var artwork: some View {
        if let url = resolvedArtworkURL {
            AsyncImageView(
                url: url,
                thumbhash: resolvedArtworkThumbhash,
                contentMode: .fill
            )
        } else {
            Color.siloSurface
        }
    }

    private var resolvedArtworkURL: String? {
        nonEmpty(backdropUrl) ?? nonEmpty(posterUrl)
    }

    private var resolvedArtworkThumbhash: String? {
        nonEmpty(backdropUrl) != nil ? backdropThumbhash : posterThumbhash
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    @ViewBuilder
    private func titleBlock(textAlignment: TextAlignment, logoHeight: CGFloat) -> some View {
        if let episodeSeriesTitle {
            if let logoUrl, !logoUrl.isEmpty {
                PhoneEpisodeLogoTitle(
                    logoUrl: logoUrl,
                    seriesTitle: episodeSeriesTitle,
                    episodeTitle: title,
                    textAlignment: textAlignment,
                    logoHeight: logoHeight
                )
            } else {
                PhoneEpisodeHierarchyTitle(
                    seriesTitle: episodeSeriesTitle,
                    episodeTitle: title,
                    textAlignment: textAlignment
                )
            }
        } else if let logoUrl, !logoUrl.isEmpty {
            AsyncImageView(url: logoUrl, contentMode: .fit, placeholderStyle: .clear)
                .frame(maxWidth: textAlignment == .leading ? 430 : .infinity)
                .frame(height: logoHeight, alignment: textAlignment == .leading ? .leading : .center)
                .accessibilityLabel(title)
        } else {
            PhoneHeroTitle(title: title, textAlignment: textAlignment)
        }
    }

    private var episodeSeriesTitle: String? {
        guard let trimmed = seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Metadata

    @ViewBuilder
    private func metadataBlock(
        alignment: Alignment,
        textAlignment: TextAlignment
    ) -> some View {
        if !metadataTokens.isEmpty || ratingChip != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    metadataText(textAlignment: textAlignment)
                    ratingView
                }
                .frame(maxWidth: .infinity, alignment: alignment)

                VStack(alignment: textAlignment == .leading ? .leading : .center, spacing: 8) {
                    metadataText(textAlignment: textAlignment)
                    ratingView
                }
                .frame(maxWidth: .infinity, alignment: alignment)
            }
        }
    }

    private func metadataText(textAlignment: TextAlignment) -> some View {
        Text(metadataTokens.joined(separator: "  ·  "))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.siloOnSurface.opacity(0.84))
            .multilineTextAlignment(textAlignment)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var ratingView: some View {
        if let ratingChip, !ratingChip.isEmpty {
            Text(ratingChip)
                .font(.system(size: 11, weight: .heavy))
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
            Text(overview)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.siloOnSurface.opacity(0.80))
                .lineSpacing(3)
                .lineLimit(showFullOverview ? nil : 3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottomTrailing) {
                    if !showFullOverview, isOverviewClipped {
                        morePill
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: SiloTheme.normalDuration)) {
                        showFullOverview.toggle()
                    }
                }
        }
    }

    @ViewBuilder
    private func creditBlock(alignment: Alignment) -> some View {
        if let creditText, !creditText.isEmpty {
            Text(creditText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.siloOnSurface.opacity(0.58))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    private var morePill: some View {
        Button {
            withAnimation(.easeInOut(duration: SiloTheme.normalDuration)) {
                showFullOverview = true
            }
        } label: {
            Text("MORE")
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Color.siloOnSurface)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.54)))
        }
        .buttonStyle(.plain)
    }

    private var isOverviewClipped: Bool {
        (overview?.count ?? 0) > 140
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
                .font(.system(size: 32, weight: .heavy))
                .foregroundStyle(Color.siloOnSurface)
                .lineLimit(2)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = parts.subtitle {
                Text(subtitle.uppercased())
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(Color.siloOnSurface.opacity(0.80))
                    .lineLimit(2)
                    .multilineTextAlignment(textAlignment)
            }
        }
        .frame(maxWidth: .infinity, alignment: textAlignment == .leading ? .leading : .center)
    }
}

private struct PhoneEpisodeHierarchyTitle: View {
    let seriesTitle: String
    let episodeTitle: String
    let textAlignment: TextAlignment

    var body: some View {
        VStack(spacing: 6) {
            Text(seriesTitle)
                .font(.system(size: 32, weight: .heavy))
                .foregroundStyle(Color.siloOnSurface)
                .lineLimit(2)
                .multilineTextAlignment(textAlignment)
            Text(episodeTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.siloOnSurface.opacity(0.90))
                .lineLimit(2)
                .multilineTextAlignment(textAlignment)
        }
        .frame(maxWidth: .infinity, alignment: textAlignment == .leading ? .leading : .center)
    }
}

/// Episode hierarchy using the parent show's supplied clear logo, with the
/// episode title beneath it. This is the touch-sized counterpart of tvOS's
/// episode hero and falls back to `PhoneEpisodeHierarchyTitle` only when the
/// backend has no logo artwork.
private struct PhoneEpisodeLogoTitle: View {
    let logoUrl: String
    let seriesTitle: String
    let episodeTitle: String
    let textAlignment: TextAlignment
    let logoHeight: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            AsyncImageView(url: logoUrl, contentMode: .fit, placeholderStyle: .clear)
                .frame(maxWidth: textAlignment == .leading ? 430 : .infinity)
                .frame(
                    height: logoHeight,
                    alignment: textAlignment == .leading ? .leading : .center
                )
                .accessibilityLabel(seriesTitle)

            Text(episodeTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.siloOnSurface.opacity(0.90))
                .lineLimit(2)
                .multilineTextAlignment(textAlignment)
        }
        .frame(
            maxWidth: .infinity,
            alignment: textAlignment == .leading ? .leading : .center
        )
    }
}
#endif

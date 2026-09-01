#if !os(tvOS)
import SwiftUI

/// Fully opaque, artwork-matched surface shared by every mobile video-detail
/// page. The sampled tint is composited over black, so scrolling never exposes
/// a live material or blur after the artwork itself has left the screen.
struct PhoneDetailPageSurface<Content: View>: View {
    let backdropURL: String?
    @ViewBuilder let content: () -> Content

    @State private var sampledTint = Color(red: 0.04, green: 0.12, blue: 0.14)

    var body: some View {
        ZStack {
            Color.black
            sampledTint.opacity(0.42)
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
            .padding(.horizontal, ContinuumTheme.safePadding)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    private var compactArtwork: some View {
        ZStack(alignment: .bottom) {
            artwork
                .frame(height: compactArtworkHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .mask(compactArtworkMask)

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
        .accessibilityElement(children: .contain)
    }

    private var compactArtworkHeight: CGFloat {
        let width = availableWidth > 0 ? availableWidth : 390
        return min(max(width * 1.18, 430), 540)
    }

    private var compactLogoHeight: CGFloat {
        min(max(compactArtworkHeight * 0.24, 104), 138)
    }

    private var compactArtworkMask: some View {
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

    // MARK: - Expanded iPad layout

    private var expandedHeader: some View {
        ZStack(alignment: .topLeading) {
            expandedArtwork

            VStack(alignment: .leading, spacing: 15) {
                if let eyebrow, !eyebrow.isEmpty {
                    Text(eyebrow.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.continuumOnSurface.opacity(0.7))
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
            Color.continuumSurface
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
            .foregroundStyle(Color.continuumOnSurface.opacity(0.84))
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
                .foregroundStyle(Color.continuumOnSurface)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.continuumOnSurface.opacity(0.55), lineWidth: 1)
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
                .foregroundStyle(Color.continuumOnSurface.opacity(0.80))
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
                    withAnimation(.easeInOut(duration: ContinuumTheme.normalDuration)) {
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
                .foregroundStyle(Color.continuumOnSurface.opacity(0.58))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    private var morePill: some View {
        Button {
            withAnimation(.easeInOut(duration: ContinuumTheme.normalDuration)) {
                showFullOverview = true
            }
        } label: {
            Text("MORE")
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Color.continuumOnSurface)
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
                .foregroundStyle(Color.continuumOnSurface)
                .lineLimit(2)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = parts.subtitle {
                Text(subtitle.uppercased())
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(Color.continuumOnSurface.opacity(0.80))
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
                .foregroundStyle(Color.continuumOnSurface)
                .lineLimit(2)
                .multilineTextAlignment(textAlignment)
            Text(episodeTitle)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.continuumOnSurface.opacity(0.90))
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
                .foregroundStyle(Color.continuumOnSurface.opacity(0.90))
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

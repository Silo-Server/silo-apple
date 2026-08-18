#if !os(tvOS)
import SwiftUI

/// Horizontal poster rail of "More Like This" items shown at the bottom
/// of Movie / Series detail pages. Mirrors the web frontend's
/// `RecommendationGrid` flow:
///   1. Hit `/recommendations/similar/{contentId}` for scored IDs
///   2. Resolve each ID to an `ItemDetail` in parallel
///   3. Render a poster card per resolved item; tap opens detail
///
/// The rail self-loads its data when the parent provides a
/// `contentId`. Hidden when the request fails or returns nothing —
/// recommendations are non-essential, so a missing rail is preferable
/// to an error placeholder. The section header lives in here (not the
/// parent) for the same reason: when recommendations are disabled or
/// empty, an orphaned "More Like This" title must vanish with the cards.
struct PhoneSimilarRail: View {
    let contentId: String
    let onSelect: (String) -> Void

    @State private var items: [SimilarPosterItem] = []
    @State private var isLoading = true
    @State private var loadedFor: String? = nil
    @State private var uiCustomization = UICustomizationPreferences.shared

    var body: some View {
        Group {
            if isLoading {
                section { loadingPlaceholder }
            } else if !items.isEmpty {
                section { rail }
            }
        }
        .task(id: contentId) { await load() }
    }

    private func section(@ViewBuilder content: () -> some View) -> some View {
        // Header-to-content gap matches the parents' former
        // `VStack(spacing: 14)` so the page rhythm is unchanged.
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: "More Like This")
                .padding(.horizontal, SiloTheme.safePadding)
            content()
        }
    }

    // MARK: - Rail

    private var rail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(items) { item in
                    Button {
                        onSelect(item.contentId)
                    } label: {
                        PhoneSimilarCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityDescription)
                }
            }
            .padding(.horizontal, SiloTheme.safePadding)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Loading placeholder

    private var loadingPlaceholder: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                        .fill(Color.siloSurfaceElevated)
                        .frame(
                            width: SiloTheme.posterCardWidth
                                * uiCustomization.cardPresentation.posterSize.scale,
                            height: SiloTheme.posterCardHeight
                                * uiCustomization.cardPresentation.posterSize.scale
                        )
                }
            }
            .padding(.horizontal, SiloTheme.safePadding)
            .padding(.vertical, 4)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Data loading

    private func load() async {
        // Bail if we already populated for this id.
        guard loadedFor != contentId else { return }
        loadedFor = contentId
        isLoading = true
        items = []

        do {
            items = try await SimilarRecommendationsLoader.load(contentId: contentId)
        } catch {
            items = []
        }
        isLoading = false
    }
}

// MARK: - Card

private struct PhoneSimilarCard: View {
    let item: SimilarPosterItem
    @State private var uiCustomization = UICustomizationPreferences.shared

    private var cardWidth: CGFloat {
        SiloTheme.posterCardWidth * uiCustomization.cardPresentation.posterSize.scale
    }
    private var cardHeight: CGFloat {
        cardWidth * (SiloTheme.posterCardHeight / SiloTheme.posterCardWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            poster
            if uiCustomization.cardPresentation.caption.showsTitle {
                Text(item.title)
                    .font(.siloSubheadline)
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            if uiCustomization.cardPresentation.caption.showsMetadata, let year = item.year {
                Text(String(year))
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var poster: some View {
        if let url = item.posterUrl, !url.isEmpty {
            AsyncImageView(url: url, thumbhash: item.posterThumbhash, contentMode: .fill)
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cornerRadius))
        } else {
            RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                .fill(Color.siloSurfaceElevated)
                .frame(width: cardWidth, height: cardHeight)
                .overlay(
                    Image(systemName: "film")
                        .foregroundColor(.siloOnSurface.opacity(0.3))
                )
        }
    }
}
#endif

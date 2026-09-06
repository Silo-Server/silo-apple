#if !os(tvOS)
import SwiftUI

/// Horizontal poster rail of "More Like This" items shown at the bottom
/// of Movie / Series detail pages. Mirrors the web frontend's
/// `RecommendationGrid` flow: fetch ordered v2 cards and render their
/// posters directly; tapping a card opens its detail.
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
            LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: 12) {
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
            .phoneMediaRailBounds()
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
        guard loadedFor != contentId else { return }
        let requested = contentId
        loadedFor = requested
        isLoading = true
        items = []
        defer { if loadedFor == requested { isLoading = false } }
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              !Task.isCancelled, loadedFor == requested else { return }
        do {
            let cards = try await SiloAPI.shared.recommendationsSimilar(contentId: requested, limit: 12, auth: auth)
            let current = await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
            guard current, !Task.isCancelled, loadedFor == requested else { return }
            items = cards.map(SimilarPosterItem.init(card:))
        } catch {
            guard !Task.isCancelled, loadedFor == requested else { return }
            items = []
        }
    }

}

// MARK: - Card model

/// View-side projection of a catalog card containing only what the
/// poster card needs. Decoupled so the card never re-renders when
/// unrelated detail fields change.
struct SimilarPosterItem: Identifiable, Hashable {
    let contentId: String
    let title: String
    let posterUrl: String?
    let posterThumbhash: String?
    let year: Int?
    var id: String { contentId }

    var accessibilityDescription: String {
        [title, year.map(String.init)].compactMap { $0 }.joined(separator: ", ")
    }

    init(card: BrowseItem) {
        contentId = card.contentId
        title = card.title
        posterUrl = card.posterUrl
        posterThumbhash = card.posterThumbhash
        year = card.year
    }

    init(detail: ItemDetail) {
        self.contentId = detail.contentId
        self.title = detail.title
        self.posterUrl = detail.posterUrl
        self.posterThumbhash = detail.posterThumbhash
        self.year = detail.year
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

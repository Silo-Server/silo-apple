#if !os(tvOS)
import SwiftUI

/// Horizontal poster rail of "More Like This" items shown at the bottom
/// of Movie / Series detail pages. One request returns the ranked cards;
/// tapping a card opens its detail page.
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
        PhonePosterRailCards(items: items, onSelect: onSelect)
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
            let cards = try await SiloAPI.shared.recommendationsSimilar(
                contentId: contentId,
                limit: 12
            )
            items = cards.map(SimilarPosterItem.init(card:))
        } catch {
            items = []
        }
        isLoading = false
    }
}

// MARK: - Poster rail

/// Titled horizontal rail of poster cards, shared by the detail pages'
/// "More Like This" rail and the book rails (series, more by author).
/// `aspectRatio` is width ÷ height: 2:3 video posters by default, square
/// for audiobook covers.
struct PhonePosterRail: View {
    let title: String
    var trailingText: String? = nil
    let items: [SimilarPosterItem]
    var aspectRatio: CGFloat = SiloTheme.posterCardWidth / SiloTheme.posterCardHeight
    var placeholderSymbol: String = "film"
    let onSelect: (String) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                PhoneSectionHeader(title: title, trailingText: trailingText)
                    .padding(.horizontal, SiloTheme.safePadding)
                PhonePosterRailCards(
                    items: items,
                    aspectRatio: aspectRatio,
                    placeholderSymbol: placeholderSymbol,
                    onSelect: onSelect
                )
            }
        }
    }
}

/// The untitled card strip inside `PhonePosterRail`.
struct PhonePosterRailCards: View {
    let items: [SimilarPosterItem]
    var aspectRatio: CGFloat = SiloTheme.posterCardWidth / SiloTheme.posterCardHeight
    var placeholderSymbol: String = "film"
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: 12) {
                ForEach(items) { item in
                    Button {
                        onSelect(item.contentId)
                    } label: {
                        PhonePosterCard(
                            item: item,
                            aspectRatio: aspectRatio,
                            placeholderSymbol: placeholderSymbol
                        )
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
}

// MARK: - Card model

/// View-side projection of a recommendation card containing only what
/// the poster card needs. Decoupled so the card never re-renders when
/// unrelated card fields change.
struct SimilarPosterItem: Identifiable, Hashable {
    let contentId: String
    let title: String
    let posterUrl: String?
    let posterThumbhash: String?
    let year: Int?
    /// Replaces the year caption when set, e.g. "Book 2" in a series rail.
    let subtitle: String?
    let accessibilityDescription: String
    var id: String { contentId }

    init(card: BrowseItem) {
        self.contentId = card.contentId
        self.title = card.title
        self.posterUrl = card.posterUrl
        self.posterThumbhash = card.posterThumbhash
        self.year = card.year
        self.subtitle = nil
        self.accessibilityDescription = [card.title, card.year.map(String.init)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    init(audiobook item: AudiobookRelatedItem) {
        self.contentId = item.contentId
        self.title = item.title
        self.posterUrl = item.posterUrl
        self.posterThumbhash = nil
        self.year = item.year
        self.subtitle = item.seriesIndex.map { "Book \($0)" }
        self.accessibilityDescription = audiobookRelatedItemAccessibilityLabel(item)
    }
}

// MARK: - Card

private struct PhonePosterCard: View {
    let item: SimilarPosterItem
    let aspectRatio: CGFloat
    let placeholderSymbol: String
    @State private var uiCustomization = UICustomizationPreferences.shared

    private var cardWidth: CGFloat {
        SiloTheme.posterCardWidth * uiCustomization.cardPresentation.posterSize.scale
    }
    private var cardHeight: CGFloat {
        cardWidth / aspectRatio
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
            if uiCustomization.cardPresentation.caption.showsMetadata,
               let caption = item.subtitle ?? item.year.map(String.init) {
                Text(caption)
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
                    Image(systemName: placeholderSymbol)
                        .foregroundColor(.siloOnSurface.opacity(0.3))
                )
        }
    }
}
#endif

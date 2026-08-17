#if os(tvOS)
import SwiftUI

/// Horizontal poster rail of "More Like This" items used at the bottom
/// of the tvOS Movie / Series detail pages. Mirrors `PhoneSimilarRail`
/// — same `/recommendations/similar/{id}` flow, same parallel detail
/// resolution — but renders `TVMediaCard` posters at the 10-foot scale
/// so cards focus-lift consistently with the rest of the detail body.
///
/// The rail self-loads on appear and silently hides if the request
/// fails or returns nothing — recommendations are non-essential, so a
/// missing rail is preferable to an error placeholder. The section
/// header lives in here (not the parent) for the same reason: when
/// recommendations are disabled or empty, an orphaned "More Like This"
/// title must vanish along with the cards.
struct TVSimilarRail: View {
    let contentId: String
    let onSelect: (String) -> Void

    @State private var items: [SimilarPosterItem] = []
    @State private var isLoading = true
    @State private var loadedFor: String? = nil
    @FocusState private var focusedItemId: String?

    private let cardSpacing: CGFloat = 32
    private let railVerticalPadding: CGFloat = 24
    /// Header-to-content gap, matching the other detail sections'
    /// `VStack(spacing: 28)` so the page rhythm stays uniform.
    private let headerSpacing: CGFloat = 28

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
        VStack(alignment: .leading, spacing: headerSpacing) {
            TVSectionHeader(title: "More Like This")
            content()
        }
    }

    // MARK: - Rail

    private var rail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: cardSpacing) {
                ForEach(items) { item in
                    TVMediaCard(
                        title: item.title,
                        posterUrl: item.posterUrl ?? "",
                        year: item.year,
                        action: { onSelect(item.contentId) },
                        focusTreatment: .ring,
                        focusBinding: $focusedItemId,
                        focusContentId: item.contentId
                    )
                }
            }
            .padding(.vertical, railVerticalPadding)
        }
        .focusSection()
        // Land d-pad entry on the first card (like the cast/episode rails)
        // instead of letting tvOS pick the geometrically-nearest middle card.
        .applyDefaultFocusIfPresent($focusedItemId, id: items.first?.contentId)
        .scrollClipDisabled()
    }

    // MARK: - Loading placeholder

    private var loadingPlaceholder: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: cardSpacing) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius)
                        .fill(Color.continuumSurfaceElevated)
                        .frame(
                            width: ContinuumTheme.posterCardWidth,
                            height: ContinuumTheme.posterCardHeight
                        )
                }
            }
            .padding(.vertical, railVerticalPadding)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Data loading

    private func load() async {
        guard loadedFor != contentId else { return }
        loadedFor = contentId
        isLoading = true
        items = []

        do {
            let scored = try await ContinuumAPI.shared.recommendationsSimilar(
                contentId: contentId,
                limit: 12
            )
            // Resolve detail pages in parallel — preserve the engine's
            // ranking by zipping the resolved details back to their
            // original index. Failed resolutions are dropped silently.
            let resolved = await withTaskGroup(of: (Int, ItemDetail?).self) { group in
                for (index, ref) in scored.enumerated() {
                    group.addTask {
                        let detail = try? await ContinuumAPI.shared.itemDetail(
                            contentId: ref.mediaItemId
                        )
                        return (index, detail)
                    }
                }
                var pairs: [(Int, ItemDetail)] = []
                for await (index, detail) in group {
                    if let detail { pairs.append((index, detail)) }
                }
                return pairs.sorted(by: { $0.0 < $1.0 }).map(\.1)
            }
            items = resolved.map(SimilarPosterItem.init(detail:))
        } catch {
            items = []
        }
        isLoading = false
    }
}

// MARK: - Card model

/// View-side projection of an `ItemDetail` containing only what the
/// poster card needs. Decoupled so the card never re-renders when
/// unrelated detail fields change.
struct SimilarPosterItem: Identifiable, Hashable {
    let contentId: String
    let title: String
    let posterUrl: String?
    let posterThumbhash: String?
    let year: Int?
    var id: String { contentId }

    init(detail: ItemDetail) {
        self.contentId = detail.contentId
        self.title = detail.title
        self.posterUrl = detail.posterUrl
        self.posterThumbhash = detail.posterThumbhash
        self.year = detail.year
    }
}
#endif

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
    let title: String
    let onSelect: (String) -> Void

    @State private var items: [SimilarPosterItem] = []
    @State private var isLoading = true
    @State private var loadedFor: String? = nil
    @FocusState private var focusedItemId: String?

    private let cardWidth: CGFloat = 220
    private let cardSpacing: CGFloat = 44
    private let railVerticalPadding: CGFloat = 12
    /// Header-to-content gap, matching the other detail sections'
    /// `VStack(spacing: 28)` so the page rhythm stays uniform.
    private let headerSpacing: CGFloat = TVDetailLayout.sectionHeaderSpacing

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
            TVSectionHeader(title: title)
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
                        cardWidth: cardWidth,
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
        .applySimilarRailDefaultFocus(items.first?.contentId, binding: $focusedItemId)
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
                            width: cardWidth,
                            height: cardWidth * 1.5
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

private extension View {
    /// When focus enters the Recommended rail, land on the first card rather
    /// than the geometrically-nearest one. `.userInitiated` priority is what
    /// makes `defaultFocus` win over geometric proximity on d-pad entry — the
    /// same helper shape as `TVDetailCastRail.applyCastRailDefaultFocus`.
    /// No-op while loading / empty (first id is nil).
    @ViewBuilder
    func applySimilarRailDefaultFocus(
        _ firstContentId: String?,
        binding: FocusState<String?>.Binding
    ) -> some View {
        if let firstContentId {
            self.defaultFocus(binding, firstContentId, priority: .userInitiated)
        } else {
            self
        }
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

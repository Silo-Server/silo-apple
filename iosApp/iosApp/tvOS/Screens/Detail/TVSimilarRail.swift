#if os(tvOS)
import SwiftUI
import CryptoKit

/// Horizontal poster rail of "More Like This" items used at the bottom
/// of the tvOS Movie / Series detail pages. Mirrors `PhoneSimilarRail`
/// — same ordered v2 recommendation cards — but renders `TVMediaCard` posters at the 10-foot scale
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
    var focusRequest = 0

    @State private var items: [SimilarPosterItem] = []
    @State private var isLoading = true
    @State private var loadedFor: String? = nil
    @State private var lastAppliedFocusRequest = 0
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
        .task(id: contentId, priority: .background) { await load() }
        .onChange(of: focusRequest, initial: true) { _, _ in
            applyFocusRequestIfPossible()
        }
        .onChange(of: items) { _, _ in
            applyFocusRequestIfPossible()
        }
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
                        posterThumbhash: item.posterThumbhash,
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
                    RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                        .fill(Color.siloSurfaceElevated)
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

    private func applyFocusRequestIfPossible() {
        guard focusRequest > 0,
              focusRequest != lastAppliedFocusRequest,
              let firstContentId = items.first?.contentId else { return }
        lastAppliedFocusRequest = focusRequest
        focusedItemId = firstContentId
    }

    // MARK: - Data loading

    private func load() async {
        guard loadedFor != contentId else { return }
        let requestedContentId = contentId
        loadedFor = requestedContentId
        var completed = false
        defer {
            if !completed, loadedFor == requestedContentId {
                loadedFor = nil
            }
        }
        lastAppliedFocusRequest = 0
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              !Task.isCancelled, loadedFor == requestedContentId else { return }
        // Never read a legacy unscoped rail cache under a new viewer.
        let owner = "\(auth.account.serverId)|\(auth.account.serverURL)|\(auth.account.credentialGenerationID)|\(auth.profileId ?? "")|\(auth.profileToken ?? "")"
        let cacheKey = CacheKey.similar(requestedContentId) + ":v2:" + SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
        let mayUseCache = await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
        guard !Task.isCancelled, loadedFor == requestedContentId else { return }
        guard mayUseCache else { items = []; isLoading = false; return }
        let cached: [SimilarPosterItem]? = ResponseCache.shared.get(cacheKey)
        if let cached {
            items = cached
            isLoading = false
        } else {
            items = []
            isLoading = true
        }

        // This rail sits below the primary detail content. Give the hero,
        // selected season, and their artwork a head start before spending
        // bandwidth on recommendations that may never enter the viewport.
        do {
            try await Task.sleep(for: .milliseconds(cached == nil ? 900 : 1_500))
        } catch {
            return
        }

        do {
            let cards = try await SiloAPI.shared.recommendationsSimilar(
                contentId: requestedContentId, limit: 12, auth: auth)
            let current = await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
            guard !Task.isCancelled, loadedFor == requestedContentId else { return }
            guard current else { items = []; isLoading = false; return }
            let refreshed = cards.map(SimilarPosterItem.init(card:))
            items = refreshed
            ResponseCache.shared.set(refreshed, for: cacheKey)
        } catch {
            let current = await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
            guard !Task.isCancelled, loadedFor == requestedContentId else { return }
            if !current || cached == nil { items = [] }
        }
        isLoading = false
        completed = true
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
#endif

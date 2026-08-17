import SwiftUI

func libraryCollectionAccessibilityLabel(_ collection: LibraryCollection) -> String {
    let type = collection.kind == .userCollections
        ? "User collection"
        : collection.collectionType?.capitalized ?? "Collection"
    let count = if let itemCount = collection.itemCount {
        "\(itemCount) item\(itemCount == 1 ? "" : "s")"
    } else {
        "Smart"
    }
    return [collection.name, type, count].joined(separator: ", ")
}

@Observable
@MainActor
private class LibraryCollectionsViewModel {
    /// Ordered render sections — either named groups from the server or
    /// a single anonymous section synthesized from a flat response.
    var sections: [LibraryCollectionSection] = []
    var isLoading = false
    var isRefreshing = false
    var error: ErrorState?

    var isEmpty: Bool { sections.allSatisfy { $0.collections.isEmpty } }

    func loadCollections(libraryId: Int) async {
        let key = "library:\(libraryId):collections"
        if sections.isEmpty,
           let cached: [LibraryCollectionSection] = ResponseCache.shared.get(key) {
            sections = cached
        }
        if sections.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        error = nil

        do {
            let response = try await SiloAPI.shared.libraryCollections(libraryId: libraryId)
            let resolved = response.resolvedSections
            ResponseCache.shared.set(resolved, for: key)
            sections = resolved
        } catch let err {
            if sections.isEmpty {
                error = ErrorState(err)
            }
        }

        isLoading = false
        isRefreshing = false
    }
}

struct LibraryCollectionsView: View {
    let libraryId: Int

    @State private var viewModel = LibraryCollectionsViewModel()
    @State private var uiCustomization = UICustomizationPreferences.shared
    @Environment(\.horizontalSizeClass) private var hSize

    private var columns: [GridItem] {
        AdaptiveColumns.posters(
            for: hSize,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
    }

    var body: some View {
        Group {
            if !viewModel.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: SiloTheme.padding) {
                        ForEach(viewModel.sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(SiloTheme.padding)
                    .padding(.bottom, SiloTheme.largePadding)
                }
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.loadCollections(libraryId: libraryId) } })
            } else if viewModel.isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up.fill",
                    title: "No collections yet",
                    subtitle: "Create library collections in the web app to feature curated shelves here."
                )
            }
        }
        .siloBackground()
        .task(id: libraryId) {
            await viewModel.loadCollections(libraryId: libraryId)
        }
        .refreshable {
            await viewModel.loadCollections(libraryId: libraryId)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: LibraryCollectionSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !section.name.isEmpty {
                Text(section.name)
                    .font(.siloTitle)
                    .foregroundColor(.siloOnSurface)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(section.collections) { collection in
                    NavigationLink(
                        value: Route.libraryCollection(
                            libraryId: libraryId,
                            collectionId: collection.id,
                            title: collection.name,
                            kind: collection.kind
                        )
                    ) {
                        LibraryCollectionCard(collection: collection)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(libraryCollectionAccessibilityLabel(collection))
                }
            }
        }
    }
}

private struct LibraryCollectionCard: View {
    let collection: LibraryCollection
    @State private var uiCustomization = UICustomizationPreferences.shared

    private var cardWidth: CGFloat {
        SiloTheme.posterCardWidth * uiCustomization.cardPresentation.posterSize.scale
    }
    private var cardHeight: CGFloat {
        cardWidth * (SiloTheme.posterCardHeight / SiloTheme.posterCardWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                poster

                Text(countLabel)
                    .font(.siloSmall)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Capsule())
                    .padding(8)
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius))

            if uiCustomization.cardPresentation.caption.showsTitle {
                Text(collection.name)
                    .font(.siloCaption)
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(2, reservesSpace: true)
            }

            if uiCustomization.cardPresentation.caption.showsMetadata {
                Text(typeLabel)
                    .font(.siloSmall)
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    @ViewBuilder
    private var poster: some View {
        if let posterUrl = collection.posterUrl, !posterUrl.isEmpty {
            AsyncImageView(
                url: posterUrl,
                thumbhash: collection.posterThumbhash,
                targetSize: CGSize(width: cardWidth, height: cardHeight),
                contentMode: .fill
            )
            .frame(width: cardWidth, height: cardHeight)
            .clipped()
        } else {
            ZStack {
                Color.siloSurfaceVariant
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.siloSecondaryText)
            }
            .frame(width: cardWidth, height: cardHeight)
        }
    }

    private var countLabel: String {
        if let itemCount = collection.itemCount {
            return "\(itemCount)"
        }
        return "Smart"
    }

    private var typeLabel: String {
        if collection.kind == .userCollections {
            return "User collection"
        }
        return collection.collectionType?.capitalized ?? "Collection"
    }
}

struct LibraryCollectionDetailView: View {
    let libraryId: Int
    let collectionId: String
    let title: String?
    let kind: LibraryCollectionKind?

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    @State private var hasMore = true
    @State private var totalItems: Int?
    @State private var nextOffset = 0
    @State private var snapshot: String?

    @Environment(AppRouter.self) private var router

    private let pageSize = 60

    var body: some View {
        Group {
            if !items.isEmpty {
                content
            } else if let error {
                ErrorView(state: error, onRetry: { Task { await loadItems(reset: true) } })
            } else if isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up.fill",
                    title: "Collection is empty",
                    subtitle: "This collection does not have any items yet."
                )
            }
        }
        .siloBackground()
        .navigationTitle(title ?? "Collection")
        .siloNavigationTitleDisplayMode(.large)
        .task(id: "\(libraryId)-\(collectionId)") {
            await loadItems(reset: true)
        }
        .refreshable {
            await loadItems(reset: true)
        }
    }

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SiloTheme.padding) {
                Text(countLabel)
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)

                CatalogGrid(
                    items: items,
                    isLoading: isLoading,
                    hasMore: hasMore,
                    onItemTap: { contentId in
                        router.navigate(to: .itemDetail(contentId: contentId))
                    },
                    onLoadMore: {
                        Task { await loadMoreIfNeeded() }
                    }
                )
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.smallPadding)
            .padding(.bottom, SiloTheme.largePadding)
        }
    }

    private var countLabel: String {
        if let totalItems, !hasMore {
            return "\(totalItems) item\(totalItems == 1 ? "" : "s")"
        }
        let suffix = hasMore ? "+" : ""
        return "\(items.count)\(suffix) item\(items.count == 1 && !hasMore ? "" : "s")"
    }

    private func loadMoreIfNeeded() async {
        guard hasMore, !isLoading else { return }
        await loadItems(reset: false)
    }

    private func loadItems(reset: Bool) async {
        guard !isLoading else { return }
        if reset {
            // Surface the cached page-1 snapshot instantly so the grid
            // doesn't blank out while the network call runs.
            if items.isEmpty,
               let cached: CatalogResponse = ResponseCache.shared.get(
                   CacheKey.collectionItems(collectionId)
               ) {
                items = cached.items
                hasMore = cached.hasMore ?? false
                totalItems = cached.totalExact == false ? nil : cached.total
                nextOffset = cached.items.count
                snapshot = cached.snapshot
            } else {
                items = []
                hasMore = true
                totalItems = nil
                nextOffset = 0
                snapshot = nil
            }
        }
        guard hasMore else { return }

        isLoading = true
        error = nil

        do {
            let response: CatalogResponse
            if kind == .userCollections {
                response = try await SiloAPI.shared.userCollectionItems(
                    collectionId: collectionId,
                    offset: nextOffset,
                    limit: pageSize,
                    snapshot: snapshot
                )
            } else {
                response = try await SiloAPI.shared.libraryCollectionItems(
                    libraryId: libraryId,
                    collectionId: collectionId,
                    offset: nextOffset,
                    limit: pageSize,
                    snapshot: snapshot
                )
            }
            if reset {
                items = response.items
                ResponseCache.shared.set(response, for: CacheKey.collectionItems(collectionId))
            } else {
                items.append(contentsOf: response.items)
            }
            totalItems = response.totalExact == false ? nil : response.total
            hasMore = response.hasMore ?? false
            nextOffset += response.items.count
            if snapshot == nil {
                snapshot = response.snapshot
            }
        } catch let err {
            if items.isEmpty {
                error = ErrorState(err)
            }
        }

        isLoading = false
    }
}

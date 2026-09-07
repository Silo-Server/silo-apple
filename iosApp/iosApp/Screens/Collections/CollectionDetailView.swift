import SwiftUI

/// Shows the items within a specific collection.
struct CollectionDetailView: View {
    let collectionId: String

    @State private var viewModel = CollectionDetailViewModel()
    private var items: [BrowseItem] { viewModel.items }
    private var isLoading: Bool { viewModel.isLoading }
    private var error: ErrorState? { viewModel.membership.error ?? viewModel.error }
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var gridWidth: CGFloat = 0
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSize

    private var columns: [GridItem] {
        if usesThreeColumnPhoneLayout {
            return Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: 3
            )
        }
        return AdaptiveColumns.posters(
            for: hSize,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
    }

    var body: some View {
        Group {
            if !items.isEmpty {
                gridContent
            } else if let error {
                ErrorView(state: error, onRetry: { Task { await loadItems() } })
            } else if isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack",
                    title: "Collection is empty",
                    subtitle: "Add items from their detail pages"
                )
            }
        }
        .environment(\.catalogMembershipModel, viewModel.membership)
        .siloPageBackground()
        .navigationTitle("Collection")
        .siloNavigationTitleDisplayMode(.large)
        .task(id: collectionId) {
            await loadItems()
        }
        .refreshable {
            await loadItems()
        }
    }

    private var gridContent: some View {
        ScrollView {
            if let error {
                ErrorView(state: error, onRetry: { Task { await loadItems() } })
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { item in
                    MediaCard(
                        title: item.title,
                        posterUrl: item.posterUrl ?? "",
                        thumbhash: item.posterThumbhash,
                        year: item.year,
                        userState: viewModel.membership.userState(for: item.contentId),
                        overlayData: OverlayData.from(item),
                        action: {
                            router.navigate(to: .itemDetail(browseItem: item))
                        },
                        playAction: playAction(for: item),
                        contentId: item.contentId,
                        cardWidthOverride: phoneCardWidthOverride
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            #if os(iOS)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                guard abs(width - gridWidth) >= 0.5 else { return }
                gridWidth = width
            }
            #endif
            .padding(SiloTheme.padding)
        }
    }

    private func playAction(for item: BrowseItem) -> (() -> Void)? {
        #if os(tvOS)
        guard SiloMediaType.isDirectlyPlayable(item.type) else { return nil }
        return {
            router.presentPlayer(
                contentId: item.contentId,
                posterURL: item.posterUrl,
                backdropURL: item.backdropUrl
            )
        }
        #else
        return nil
        #endif
    }

    private var usesThreeColumnPhoneLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var phoneCardWidthOverride: CGFloat? {
        guard usesThreeColumnPhoneLayout else { return nil }
        let fittedWidth = AdaptiveColumns.fittedPosterWidth(
            containerWidth: gridWidth,
            columnCount: 3,
            spacing: 12
        )
        return fittedWidth / uiCustomization.cardPresentation.posterSize.scale
    }

    private func loadItems() async {
        await viewModel.load(collectionId: collectionId)
    }
}

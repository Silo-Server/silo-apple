import SwiftUI

/// List of recently watched items from the user's history.
struct HistoryView: View {
    @State private var viewModel = HistoryViewModel()
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if !viewModel.items.isEmpty {
                gridContent
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.load(reset: true) } })
            } else if viewModel.isLoading {
                // tvOS: this is a pushed destination, so the top menu bar
                // isn't there to hold focus — without a focusable element
                // the remote goes dead until the grid renders.
                Color.clear
                #if os(tvOS)
                    .focusable()
                #endif
            } else {
                EmptyStateView(
                    icon: "clock",
                    title: "No watch history",
                    subtitle: "Items you watch will appear here"
                )
            }
        }
        .continuumBackground()
        .navigationTitle("History")
        .continuumNavigationTitleDisplayMode(.large)
        .task {
            await viewModel.load(reset: true)
        }
        .refreshable {
            await viewModel.load(reset: true)
        }
    }

    private var gridContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: ContinuumTheme.padding) {
                Text(viewModel.countLabel)
                    .font(.continuumCaption)
                    .foregroundColor(.continuumSecondaryText)

                CatalogGrid(
                    items: viewModel.items,
                    isLoading: viewModel.isLoading,
                    hasMore: viewModel.hasMore,
                    onItemTap: { item in
                        router.navigate(to: .itemDetail(browseItem: item))
                    },
                    onLoadMore: {
                        Task { await viewModel.load(reset: false) }
                    }
                )
            }
            .padding(.horizontal, ContinuumTheme.padding)
            .padding(.top, ContinuumTheme.smallPadding)
            .padding(.bottom, ContinuumTheme.largePadding)
        }
    }
}

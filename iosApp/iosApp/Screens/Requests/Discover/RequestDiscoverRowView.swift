import SwiftUI

/// A Discover row's See all page on iOS and macOS. The tvOS hub has no See
/// all link for these rows.
struct RequestDiscoverRowView: View {
    let rowKey: String
    let title: String

    var body: some View {
        #if os(tvOS)
        EmptyView()
        #else
        PhoneRequestDiscoverRowView(rowKey: rowKey, title: title)
        #endif
    }
}

#if !os(tvOS)
private struct PhoneRequestDiscoverRowView: View {
    @State private var viewModel: RequestDiscoverRowViewModel

    init(rowKey: String, title: String) {
        _viewModel = State(initialValue: RequestDiscoverRowViewModel(key: rowKey, title: title))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiloTheme.largePadding) {
                content
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.smallPadding)
            .padding(.bottom, SiloTheme.largePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .siloPageBackground()
        .navigationTitle(viewModel.title)
        .siloNavigationTitleDisplayMode(.large)
        .siloToolbarColorSchemeDark()
        .task {
            if viewModel.results.isEmpty { await viewModel.loadMore() }
        }
        .onChange(of: RequestsEventBus.shared.lastUpdate) { _, update in
            if let update { viewModel.applyRequestUpdate(update) }
        }
        .onChange(of: RequestsEventBus.shared.lastTitleState) { _, update in
            if let update { viewModel.applyTitleState(update) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.notFound {
            EmptyStateView(
                icon: "rectangle.stack.badge.minus",
                title: "This row is gone",
                subtitle: "The server's Discover page no longer shows it"
            )
            .padding(.top, 80)
        } else if let error = viewModel.error, viewModel.results.isEmpty {
            ErrorView(state: error, onRetry: { Task { await viewModel.loadMore() } })
                .padding(.top, 60)
        } else if viewModel.isLoading && viewModel.results.isEmpty {
            RequestPosterGrid(results: [], placeholderCount: 9)
        } else if viewModel.results.isEmpty {
            EmptyStateView(
                icon: "sparkles",
                title: "Nothing here yet",
                subtitle: "This row has no titles right now"
            )
            .padding(.top, 80)
        } else {
            RequestPosterGrid(results: viewModel.results) {
                Task { await viewModel.loadMore() }
            }
            if viewModel.isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if viewModel.moreFailed {
                Button("Couldn't load more. Try again") {
                    Task { await viewModel.loadMore() }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
#endif

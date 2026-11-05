import SwiftUI

/// Every card of one Home or library row, opened from the row's title or its
/// trailing Explore all card. Rows show at most `SectionRowLimit.cards`.
struct SectionCatalogView: View {
    let target: SectionCatalogTarget
    /// Set when the page is the root of the iOS detail card.
    var onClose: (() -> Void)? = nil

    @State private var viewModel = SectionCatalogViewModel()
    @Environment(AppRouter.self) private var router

    private var libraryId: Int? {
        if case .library(let id) = target.scope { return id }
        return nil
    }

    var body: some View {
        Group {
            if !viewModel.items.isEmpty {
                content
            } else if viewModel.isUnavailable {
                placeholder(
                    icon: "rectangle.stack.badge.minus",
                    title: "Row unavailable",
                    subtitle: "This row is no longer available."
                )
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await load(reset: true) } })
            } else if viewModel.isLoading {
                Color.clear
                #if os(tvOS)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tvPageFocusOwner(focusRequest: 1, isTopMenuFocused: false,
                                      accessibilityLabel: "Loading \(target.title)", onMoveUp: nil)
                #endif
            } else {
                placeholder(
                    icon: "square.stack.3d.up.fill",
                    title: "Nothing here yet",
                    subtitle: "This row does not have any items right now."
                )
            }
        }
        .siloPageBackground()
        .environment(\.browseLibraryId, libraryId)
        .navigationTitle(target.title)
        .siloNavigationTitleDisplayMode(.large)
        #if os(iOS)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        #endif
        .task(id: target) {
            // Coming back from a card's detail page keeps the pages read.
            await viewModel.open(target)
        }
        .refreshable {
            await load(reset: true)
        }
    }

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SiloTheme.padding) {
                if let countLabel {
                    Text(countLabel)
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                }

                CatalogGrid(
                    items: viewModel.items,
                    isLoading: viewModel.isLoading,
                    hasMore: viewModel.hasMore,
                    forcesThreeColumnsOnPhone: true,
                    onItemTap: { item in
                        router.navigate(to: .itemDetail(browseItem: item, libraryId: libraryId))
                    },
                    onLoadMore: {
                        Task { await load(reset: false) }
                    }
                )
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.smallPadding)
            .padding(.bottom, SiloTheme.largePadding)
        }
    }

    /// Shown once the whole row is loaded or the server knows its size.
    private var countLabel: String? {
        let count = viewModel.totalItems ?? (viewModel.hasMore ? nil : viewModel.items.count)
        return count.map { "\($0.formatted()) item\($0 == 1 ? "" : "s")" }
    }

    @ViewBuilder
    private func placeholder(icon: String, title: String, subtitle: String) -> some View {
        let state = EmptyStateView(icon: icon, title: title, subtitle: subtitle)
        #if os(tvOS)
        // A pushed page with nothing focusable would leave Menu/Back dead.
        state.tvPageFocusOwner(focusRequest: 1, isTopMenuFocused: false, accessibilityLabel: title, onMoveUp: nil)
        #else
        state
        #endif
    }

    private func load(reset: Bool) async {
        await viewModel.load(target, reset: reset)
    }
}

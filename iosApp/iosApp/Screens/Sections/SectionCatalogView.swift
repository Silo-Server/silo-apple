import SwiftUI

/// Every card of one Home or library row, opened from the row's title or its
/// trailing Explore all card. Rows show at most `SectionRowLimit.cards`.
struct SectionCatalogView: View {
    let target: SectionCatalogTarget
    /// Set when the page is the root of the iOS detail card.
    var onClose: (() -> Void)? = nil

    @State private var viewModel = SectionCatalogViewModel()
    @Environment(AppRouter.self) private var router
    /// The app language, so a switch re-renders the title.
    @Environment(\.locale) private var locale

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
                    title: .rowPageUnavailable,
                    subtitle: .rowPageUnavailableBody
                )
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await load(reset: true) } })
            } else if viewModel.isLoading {
                Color.clear
                #if os(tvOS)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tvPageFocusOwner(focusRequest: 1, isTopMenuFocused: false,
                                      accessibilityLabel: AppLanguage.string(.rowPageLoading(target.displayTitle(in: locale)), locale: locale),
                                      onMoveUp: nil)
                #endif
            } else {
                placeholder(
                    icon: "square.stack.3d.up.fill",
                    title: .rowPageEmpty,
                    subtitle: .rowPageEmptyBody
                )
            }
        }
        .siloPageBackground()
        .environment(\.browseLibraryId, libraryId)
        .navigationTitle(target.displayTitle(in: locale))
        .siloNavigationTitleDisplayMode(.large)
        #if os(iOS)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text(.rowPageClose))
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
    private var countLabel: LocalizedStringResource? {
        let count = viewModel.totalItems ?? (viewModel.hasMore ? nil : viewModel.items.count)
        return count.map { LocalizedStringResource.rowPageItemCount(count: $0, $0.formatted(.number.locale(locale))) }
    }

    @ViewBuilder
    private func placeholder(icon: String, title: LocalizedStringResource, subtitle: LocalizedStringResource) -> some View {
        let titleText = AppLanguage.string(title, locale: locale)
        let state = EmptyStateView(icon: icon, title: titleText, subtitle: AppLanguage.string(subtitle, locale: locale))
        #if os(tvOS)
        // A pushed page with nothing focusable would leave Menu/Back dead.
        state.tvPageFocusOwner(focusRequest: 1, isTopMenuFocused: false, accessibilityLabel: titleText, onMoveUp: nil)
        #else
        state
        #endif
    }

    private func load(reset: Bool) async {
        await viewModel.load(target, reset: reset)
    }
}

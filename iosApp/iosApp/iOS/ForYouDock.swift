#if os(iOS)
import SwiftUI

/// The pages of the iPhone For You tab, in the dock's order.
enum ForYouPage: String, CaseIterable, Identifiable, PageDockSegment {
    case forYou
    case watchlist
    case favorites

    var id: String { rawValue }

    var dockIcon: String {
        switch self {
        case .forYou: return "sparkles"
        case .watchlist: return "bookmark"
        case .favorites: return "heart"
        }
    }

    var dockTitle: LocalizedStringResource {
        switch self {
        case .forYou: return .topBarForYou
        case .watchlist: return .personalWatchlistTitle
        case .favorites: return .personalFavoritesTitle
        }
    }

    /// The header's title for the page.
    var headerTitle: LocalizedStringResource {
        self == .forYou ? .forYouRecommendations : dockTitle
    }
}

/// The iPhone For You tab's dock: which page is on screen, and the type
/// (All, Movies, TV Shows) every page is narrowed to. The tab owns it.
/// The type opens on All, then on the one used last.
@Observable
@MainActor
final class ForYouDockModel: PageDockModel {
    private(set) var selectedTab: ForYouPage = .forYou
    var mediaFilter: PersonalMediaFilter {
        didSet { defaults.set(mediaFilter.rawValue, forKey: Self.mediaFilterKey) }
    }
    private(set) var feedbackCount = 0

    @ObservationIgnored private let defaults: UserDefaults
    private static let mediaFilterKey = "forYou.mediaFilter"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mediaFilter = defaults.string(forKey: Self.mediaFilterKey)
            .flatMap(PersonalMediaFilter.init(rawValue:)) ?? .all
    }

    @ObservationIgnored var onScrollToTop: (ForYouPage) -> Void = { _ in }

    var visibleTabs: [ForYouPage] { ForYouPage.allCases }
    var allTabs: [ForYouPage] { ForYouPage.allCases }
    var leadingButtonIsInteractive: Bool { true }

    func select(_ tab: ForYouPage) {
        feedbackCount += 1
        if tab == selectedTab {
            onScrollToTop(tab)
        } else {
            selectedTab = tab
        }
    }

    func commitDrag(to tab: ForYouPage) {
        guard tab != selectedTab else { return }
        selectedTab = tab
    }

    func leadingButton(style: PageDockStyle) -> ForYouDockTypeButton {
        ForYouDockTypeButton(model: self, style: style)
    }
}

/// The dock's leading button: a system menu of All, Movies and TV Shows,
/// with a checkmark on the type showing. Its glyph is that type's.
struct ForYouDockTypeButton: View {
    @Bindable var model: ForYouDockModel
    let style: PageDockStyle

    var body: some View {
        Menu {
            Picker(selection: $model.mediaFilter) {
                ForEach(PersonalMediaFilter.allCases) { filter in
                    Label {
                        Text(filter.label)
                    } icon: {
                        Image(systemName: filter.systemImage)
                    }
                    .tag(filter)
                }
            } label: {
                Text(.personalMediaType)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            PageDockGlyph(systemName: model.mediaFilter.systemImage, style: style)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityLabel(Text(.personalMediaType))
        .accessibilityValue(Text(model.mediaFilter.label))
        .accessibilityShowsLargeContentViewer {
            Label {
                Text(model.mediaFilter.label)
            } icon: {
                Image(systemName: model.mediaFilter.systemImage)
            }
        }
    }
}

/// The iPhone For You tab: recommendations, the watchlist and favorites as
/// three pages under a plain header, switched from the dock, as the
/// Libraries tab switches a library's pages. Every page shown so far stays
/// alive, so each keeps its scroll position.
struct ForYouDockedView: View {
    let viewModel: RecommendationsViewModel

    @State private var dock = ForYouDockModel()
    @State private var mountedPages: Set<ForYouPage> = [.forYou]
    @State private var pageChromeStates: [ForYouPage: PageChromeScrollState] = Dictionary(
        uniqueKeysWithValues: ForYouPage.allCases.map { ($0, PageChromeScrollState()) }
    )
    @State private var scrollClaimLinks: [ForYouPage: LibraryPageScrollClaimLink] = Dictionary(
        uniqueKeysWithValues: ForYouPage.allCases.map { ($0, LibraryPageScrollClaimLink()) }
    )
    @State private var scrollToTopRequests: [ForYouPage: Int] = [:]
    /// Bumped when a saved list is switched to, so it reads again.
    @State private var reloadRequests: [ForYouPage: Int] = [:]
    /// How many titles each saved list is showing, for the header.
    @State private var listCounts: [ForYouPage: Int] = [:]
    @State private var isDockVisible = false

    @Environment(AppRouter.self) private var router
    @Environment(PageDockHost.self) private var dockHost: PageDockHost?
    @Environment(SiloControlClient.self) private var siloControl
    @Environment(AudioPlaybackStore.self) private var audioStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    private var selectedPage: ForYouPage { dock.selectedTab }

    var body: some View {
        let chrome = pageChromeStates[selectedPage] ?? PageChromeScrollState()
        pages
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedPage)
            .safeAreaInset(edge: .top, spacing: 0) {
                header
                    .pageChromeBacking(
                        scrollState: chrome,
                        outset: EdgeInsets(top: 0, leading: -8, bottom: -8, trailing: -8)
                    )
                    .background {
                        PageChromeGlass(scrollState: chrome)
                    }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Exactly one dock shows: here, or in the tab bar's slot.
                if !dockIsInSlot {
                    PageDock(model: dock)
                }
            }
            .onAppear {
                dock.onScrollToTop = { page in
                    scrollToTopRequests[page, default: 0] += 1
                }
                isDockVisible = true
                dockHost?.present(dock)
            }
            .onDisappear {
                isDockVisible = false
                dockHost?.withdraw(dock)
            }
            .onChange(of: selectedPage) {
                // A list already built reads again when it is switched to;
                // one not yet built reads as it appears.
                if selectedPage != .forYou, mountedPages.contains(selectedPage) {
                    reloadRequests[selectedPage, default: 0] += 1
                }
                mountedPages.insert(selectedPage)
            }
    }

    /// The tab bar shows the dock in its accessory slot (iOS 26.1 and
    /// later) unless a now-playing bar holds the slot.
    private var dockIsInSlot: Bool {
        guard PageDockHost.slotIsAvailable, isDockVisible,
              let dockHost, dockHost.dock === dock else { return false }
        return !NowPlayingShelf.hasActiveAccessory(control: siloControl, audio: audioStore)
    }

    // MARK: Pages

    /// Only the selected page is visible and reachable. It comes first:
    /// the tab bar minimises with the first scroll view it finds in the tab.
    private var pages: some View {
        let ordered = [selectedPage] + ForYouPage.allCases.filter { $0 != selectedPage }
        return ZStack {
            ForEach(ordered) { page in
                if page == selectedPage || mountedPages.contains(page) {
                    let isSelected = page == selectedPage
                    let claimLink = scrollClaimLinks[page, default: LibraryPageScrollClaimLink()]
                    content(for: page)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.libraryPageScrollClaimLink, claimLink)
                        .background(LibraryPageScrollClaim(isActive: isSelected, link: claimLink))
                        .environment(pageChromeStates[page] ?? PageChromeScrollState())
                        .environment(\.libraryPageScrollToTopRequest, scrollToTopRequests[page, default: 0])
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                        .accessibilityHidden(!isSelected)
                        .zIndex(isSelected ? 1 : 0)
                }
            }
        }
    }

    @ViewBuilder
    private func content(for page: ForYouPage) -> some View {
        switch page {
        case .forYou:
            recommendations
        case .watchlist:
            WatchlistView(showsNavigationTitle: false, dockPage: dockPage(for: page))
        case .favorites:
            FavoritesView(showsNavigationTitle: false, dockPage: dockPage(for: page))
        }
    }

    private func dockPage(for page: ForYouPage) -> PersonalListDockPage {
        PersonalListDockPage(
            filter: dock.mediaFilter,
            reloadRequest: reloadRequests[page, default: 0],
            onCount: { count in
                if listCounts[page] != count { listCounts[page] = count }
            }
        )
    }

    // MARK: Recommendations

    /// The recommendation rows narrowed to the dock's type; a row left
    /// with nothing is dropped.
    private var visibleSections: [ResolvedSection] {
        let filter = dock.mediaFilter
        guard filter != .all else { return viewModel.sections }
        return viewModel.sections.compactMap { section in
            let kept = section.items.filter { filter.includes(type: $0.type) }
            return kept.isEmpty ? nil : section.replacingItems(kept)
        }
    }

    @ViewBuilder
    private var recommendations: some View {
        let sections = visibleSections
        if !sections.isEmpty {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: SiloTheme.largePadding) {
                    ForEach(sections) { section in
                        SectionRow(
                            section: section,
                            onItemTap: { destinationContentId, item in
                                router.navigate(
                                    to: .itemDetail(
                                        destinationContentId: destinationContentId,
                                        sectionItem: item
                                    )
                                )
                            }
                        )
                    }
                }
                .padding(.top, SiloTheme.smallPadding)
                .padding(.bottom, SiloTheme.largePadding)
            }
            .reportsPageChromeScroll()
            .scrollsToTopOnLibraryDockRequest()
        } else if !viewModel.sections.isEmpty {
            // Recommendations exist, none of the dock's type.
            EmptyStateView(
                icon: dock.mediaFilter.systemImage,
                title: AppLanguage.string(.forYouEmpty, locale: locale)
            )
        } else if let error = viewModel.error {
            ErrorView(state: error, onRetry: { Task { await viewModel.loadRecommendations() } })
        } else if viewModel.isLoading {
            Color.clear
        } else {
            EmptyStateView(
                icon: "sparkles",
                title: AppLanguage.string(.forYouEmpty, locale: locale),
                subtitle: AppLanguage.string(.forYouEmptyBody, locale: locale)
            )
        }
    }

    // MARK: Header

    /// The page's name, the count of a saved list under it, and the shared
    /// actions.
    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(selectedPage.headerTitle)
                    .font(.siloTitle)
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(.siloCaption)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            TabTopBarActions(
                onSearch: { router.navigate(to: .search) },
                onOpenSettings: { router.navigate(to: .settings) },
                onOpenRequests: { router.navigate(to: .requestsHub) },
                onSwitchProfile: { router.switchProfile() },
                onSignOut: { router.signOutAndReset() }
            )
        }
        .padding(.horizontal, SiloTheme.padding)
        .padding(.top, SiloTheme.smallPadding)
        .padding(.bottom, SiloTheme.smallPadding)
    }

    /// "9 movies": what a saved list is showing, once it has loaded.
    private var caption: LocalizedStringResource? {
        guard selectedPage != .forYou, let count = listCounts[selectedPage] else { return nil }
        return dock.mediaFilter.countLabel(count)
    }
}
#endif

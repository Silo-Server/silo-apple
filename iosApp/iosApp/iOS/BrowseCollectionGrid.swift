#if os(iOS)
import SwiftUI
import UIKit

/// The library grid on iPhone and iPad: the page's controls, then a poster
/// for every title, in a `UICollectionView`.
///
/// In title order with a letter index the grid is as long as the whole list
/// from the start, so a jump to a letter is one scroll and the titles on
/// either side of it are already in place to scroll through. Rows have one
/// fixed height, so nothing moves when titles arrive, and titles are read by
/// list position ahead of the scroll (`CatalogPositionPager`). In other
/// orders, and with a server that has no letter index, it shows the loaded
/// titles and asks for more near the end, as `CatalogGrid` does.
struct BrowseCollectionGrid: View {
    /// Titles loaded from the top of the list.
    let items: [BrowseItem]
    /// Reads the rest of a title-ordered list by position; nil when the
    /// grid only shows `items`.
    let pager: CatalogPositionPager?
    let isLoading: Bool
    let hasMore: Bool
    /// Changes when the grid shows a different list, which starts at its top.
    let listIdentity: String
    var forcesThreeColumnsOnPhone = false
    var usesSquareArtwork = false
    var trailingPadding: CGFloat = SiloTheme.padding
    let commands: BrowseGridCommands
    /// The controls that scroll with the grid, above its first row.
    let header: () -> AnyView
    let onItemTap: (BrowseItem) -> Void
    let onLoadMore: () -> Void
    let onRefresh: () async -> Void
    /// Called when a finger starts scrolling the grid; jumps don't call it.
    var onUserScroll: () -> Void = {}

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(PageChromeScrollState.self) private var chromeState: PageChromeScrollState?
    @State private var uiCustomization = UICustomizationPreferences.shared

    var body: some View {
        // The grid runs under the page's top chrome and the tab bar, like a
        // SwiftUI scroll view's content. SwiftUI's own insets, such as the
        // Library tab's chrome, don't reach a UIKit view, so the grid is
        // given them here.
        GeometryReader { proxy in
            Representable(model: BrowseGridModel(
                grid: self,
                layout: BrowseGridLayoutInputs(
                    horizontalSizeClass: horizontalSizeClass,
                    verticalSizeClass: verticalSizeClass,
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                    posterSize: uiCustomization.cardPresentation.posterSize,
                    forcesThreeColumnsOnPhone: forcesThreeColumnsOnPhone,
                    usesSquareArtwork: usesSquareArtwork,
                    trailingPadding: trailingPadding
                ),
                topInset: proxy.safeAreaInsets.top,
                bottomInset: proxy.safeAreaInsets.bottom,
                chromeState: chromeState
            ))
            .ignoresSafeArea(.container, edges: .vertical)
        }
    }

    private struct Representable: UIViewControllerRepresentable {
        let model: BrowseGridModel

        func makeUIViewController(context: Context) -> BrowseGridController {
            BrowseGridController(model: model, environment: context.environment)
        }

        func updateUIViewController(_ controller: BrowseGridController, context: Context) {
            controller.update(model, environment: context.environment)
        }
    }
}

/// Moves the grid from outside it.
@MainActor
final class BrowseGridCommands {
    fileprivate var scrollHandler: ((Int) -> Void)?
    fileprivate var topHandler: (() -> Void)?

    /// Put the title at list `position` in the grid's top row, at once.
    func scroll(toPosition position: Int) {
        scrollHandler?(position)
    }

    /// Scroll back to the top of the page, controls and all.
    func scrollToTop() {
        topHandler?()
    }
}

/// What decides the grid's columns and row height.
struct BrowseGridLayoutInputs: Equatable {
    var horizontalSizeClass: UserInterfaceSizeClass?
    var verticalSizeClass: UserInterfaceSizeClass?
    var isAccessibilitySize = false
    var posterSize: CardPosterSize = .standard
    var forcesThreeColumnsOnPhone = false
    var usesSquareArtwork = false
    var trailingPadding: CGFloat = SiloTheme.padding
}

/// The grid's columns for a width, by `CatalogGrid`'s rules on iPhone and
/// iPad: two or three columns at accessibility text sizes, as many as fit on
/// iPad and on a wide phone window, otherwise the phone's fixed count.
struct BrowseGridMetrics: Equatable {
    var columnCount: Int
    var spacing: CGFloat
    /// Width a card draws its artwork at.
    var cardWidth: CGFloat

    static func resolve(containerWidth: CGFloat, isPhone: Bool, inputs: BrowseGridLayoutInputs) -> BrowseGridMetrics {
        let scale = inputs.posterSize.scale
        if inputs.isAccessibilitySize {
            let count = inputs.horizontalSizeClass == .regular ? 3 : 2
            return BrowseGridMetrics(
                columnCount: count,
                spacing: 8,
                cardWidth: AdaptiveColumns.fittedPosterWidth(
                    containerWidth: containerWidth, columnCount: count, spacing: 8, maximumWidth: 240
                )
            )
        }
        let fit = isPhone
            ? AdaptiveColumns.widePhonePosterFit(
                containerWidth: containerWidth,
                posterSize: inputs.posterSize,
                verticalSizeClass: inputs.verticalSizeClass
            )
            : AdaptiveColumns.widthFittedPosters(
                containerWidth: containerWidth,
                minimumCardWidth: AdaptiveColumns.tabletMinimumPosterWidth * scale,
                spacing: AdaptiveColumns.tabletPosterSpacing
            )
        if let fit {
            return BrowseGridMetrics(
                columnCount: fit.columnCount, spacing: AdaptiveColumns.tabletPosterSpacing, cardWidth: fit.cardWidth
            )
        }
        let threeUp = inputs.forcesThreeColumnsOnPhone && isPhone
        let count = threeUp ? 3 : AdaptiveColumns.posters(
            for: inputs.horizontalSizeClass, posterSize: inputs.posterSize, spacing: 8
        ).count
        guard isPhone else {
            return BrowseGridMetrics(columnCount: count, spacing: 8, cardWidth: SiloTheme.posterCardWidth * scale)
        }
        return BrowseGridMetrics(
            columnCount: count,
            spacing: 8,
            cardWidth: AdaptiveColumns.fittedPosterWidth(
                containerWidth: containerWidth,
                columnCount: count,
                spacing: 8,
                maximumWidth: threeUp ? SiloTheme.posterCardWidth : SiloTheme.posterCardWidth * scale
            )
        )
    }
}

@MainActor
struct BrowseGridModel {
    let grid: BrowseCollectionGrid
    let layout: BrowseGridLayoutInputs
    /// Height of the bars the grid scrolls under at each end.
    let topInset: CGFloat
    let bottomInset: CGFloat
    let chromeState: PageChromeScrollState?

    /// Titles the grid has a place for.
    var titleCount: Int {
        grid.pager.map { max($0.total, grid.items.count) } ?? grid.items.count
    }

    func item(at position: Int) -> BrowseItem? {
        grid.pager?.item(at: position) ?? (position < grid.items.count ? grid.items[position] : nil)
    }

    var isLoadingFirstTitles: Bool { grid.items.isEmpty && grid.isLoading && grid.pager == nil }

    var isLoadingMore: Bool { grid.isLoading && !grid.items.isEmpty && grid.pager == nil }
}

final class BrowseGridController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    private enum Section: Int {
        case header, cards, footer
    }

    private enum Entry: Hashable {
        case header
        case card(Int)
        case footer
    }

    /// Environment values a card draws from. A change redraws the cards on
    /// screen; anything else reaches them the next time they are set up.
    private struct Appearance: Equatable {
        let dynamicTypeSize: DynamicTypeSize
        let locale: Locale
        let colorScheme: ColorScheme
        let layoutDirection: LayoutDirection
        let legibilityWeight: LegibilityWeight?

        init(_ environment: EnvironmentValues) {
            dynamicTypeSize = environment.dynamicTypeSize
            locale = environment.locale
            colorScheme = environment.colorScheme
            layoutDirection = environment.layoutDirection
            legibilityWeight = environment.legibilityWeight
        }
    }

    private struct RowHeightKey: Equatable {
        let cardWidth: CGFloat
        let usesSquareArtwork: Bool
        let appearance: Appearance
    }

    private static let rowSpacing: CGFloat = 12
    private static let footerHeight: CGFloat = 56

    private var model: BrowseGridModel
    private var environment: EnvironmentValues
    private var appearance: Appearance
    private var metrics = BrowseGridMetrics(columnCount: 3, spacing: 8, cardWidth: SiloTheme.posterCardWidth)
    private var rowHeight: CGFloat = SiloTheme.posterCardHeight
    private var rowHeightKey: RowHeightKey?
    private var cardCount = -1
    private var showsFooter = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Entry>!

    init(model: BrowseGridModel, environment: EnvironmentValues) {
        self.model = model
        self.environment = environment
        appearance = Appearance(environment)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - View

    override func loadView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, layoutEnvironment in
            self?.layoutSection(at: index, width: layoutEnvironment.container.effectiveContentSize.width)
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.allowsSelection = false
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        let refresh = UIRefreshControl()
        refresh.tintColor = UIColor(Color.siloOnSurface)
        refresh.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        collectionView.refreshControl = refresh
        view = collectionView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let card = UICollectionView.CellRegistration<BrowseCardCell, Int> { [weak self] cell, _, position in
            self?.configure(cell, at: position, force: false)
        }
        let header = UICollectionView.CellRegistration<UICollectionViewCell, Int> { [weak self] cell, _, _ in
            self?.configureHeader(cell)
        }
        let footer = UICollectionView.CellRegistration<UICollectionViewCell, Int> { cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration {
                ProgressView()
                    .tint(.siloOnSurface)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .margins(.all, 0)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, entry -> UICollectionViewCell? in
            switch entry {
            case .header:
                return collectionView.dequeueConfiguredReusableCell(using: header, for: indexPath, item: 0)
            case .card(let position):
                return collectionView.dequeueConfiguredReusableCell(using: card, for: indexPath, item: position)
            case .footer:
                return collectionView.dequeueConfiguredReusableCell(using: footer, for: indexPath, item: 0)
            }
        }
        bind(replacing: nil)
        applyInsets()
        applyStructure(reload: true)
    }

    /// Inset the grid by the bars it scrolls under. A grid resting at its
    /// top stays there when the bar above it changes height.
    private func applyInsets() {
        let old = collectionView.contentInset
        guard abs(old.top - model.topInset) >= 0.5 || abs(old.bottom - model.bottomInset) >= 0.5 else { return }
        let wasAtTop = collectionView.contentOffset.y <= -old.top + 0.5
        var insets = old
        insets.top = model.topInset
        insets.bottom = model.bottomInset
        collectionView.contentInset = insets
        collectionView.verticalScrollIndicatorInsets = UIEdgeInsets(
            top: model.topInset, left: 0, bottom: model.bottomInset, right: 0
        )
        if wasAtTop {
            collectionView.contentOffset.y = -model.topInset
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reportScroll()
    }

    // MARK: - Updates

    func update(_ new: BrowseGridModel, environment: EnvironmentValues) {
        let old = model
        model = new
        self.environment = environment
        let newAppearance = Appearance(environment)
        let appearanceChanged = newAppearance != appearance
        appearance = newAppearance
        guard isViewLoaded else { return }
        bind(replacing: old)
        applyInsets()
        if appearanceChanged || old.layout != new.layout {
            collectionView.collectionViewLayout.invalidateLayout()
        }
        let isNewList = old.grid.listIdentity != new.grid.listIdentity
        applyStructure(reload: isNewList)
        if isNewList {
            collectionView.setContentOffset(
                CGPoint(x: collectionView.contentOffset.x, y: -collectionView.adjustedContentInset.top),
                animated: false
            )
        }
        refreshVisibleCells(force: appearanceChanged)
        reportScroll()
    }

    private func bind(replacing old: BrowseGridModel?) {
        model.grid.commands.scrollHandler = { [weak self] in self?.scroll(toPosition: $0) }
        model.grid.commands.topHandler = { [weak self] in self?.scrollToTop() }
        model.grid.pager?.onChange = { [weak self] in self?.refreshVisibleCells(force: false) }
        if let old, old.grid.commands !== model.grid.commands {
            old.grid.commands.scrollHandler = nil
            old.grid.commands.topHandler = nil
        }
    }

    /// Match the grid's sections to the model: a place for each title, the
    /// placeholders of a first load, and the spinner of a load at the end.
    private func applyStructure(reload: Bool) {
        let count = model.isLoadingFirstTitles ? metrics.columnCount * 4 : model.titleCount
        let footer = model.isLoadingMore
        guard reload || count != cardCount || footer != showsFooter else { return }
        cardCount = count
        showsFooter = footer
        var snapshot = NSDiffableDataSourceSnapshot<Section, Entry>()
        snapshot.appendSections([.header, .cards, .footer])
        snapshot.appendItems([.header], toSection: .header)
        snapshot.appendItems((0..<count).map(Entry.card), toSection: .cards)
        if footer { snapshot.appendItems([.footer], toSection: .footer) }
        if reload {
            dataSource.applySnapshotUsingReloadData(snapshot)
        } else {
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    /// Redraw the cells on screen whose title has changed, or all of them.
    private func refreshVisibleCells(force: Bool) {
        for cell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            if let cell = cell as? BrowseCardCell {
                configure(cell, at: indexPath.item, force: force)
            } else if force, indexPath.section == Section.header.rawValue {
                configureHeader(cell)
            }
        }
    }

    // MARK: - Cells

    private func configure(_ cell: BrowseCardCell, at position: Int, force: Bool) {
        let width = metrics.cardWidth
        let aspect: MediaCardAspect = model.layout.usesSquareArtwork ? .square : .poster
        let content: BrowseCardCell.Content = model.item(at: position).map {
            .card($0, width: width, rowTitles: rowTitles(at: position))
        } ?? .placeholder(width: width, aspect: aspect)
        guard force || cell.content != content else { return }
        cell.content = content
        let widthOverride = width / model.layout.posterSize.scale
        let environment = environment
        switch content {
        case .card(let item, _, let rowTitles):
            cell.contentConfiguration = UIHostingConfiguration {
                CatalogGridCard(
                    item: item,
                    widthOverride: widthOverride,
                    rowTitles: rowTitles,
                    onItemTap: { [weak self] in self?.model.grid.onItemTap($0) }
                )
                // A reused cell must not carry one title's menu state to the next.
                .id(item.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // A cell under the page chrome draws where every other one does.
                .ignoresSafeArea()
                .environment(\.self, environment)
            }
            .margins(.all, 0)
        case .placeholder:
            let size = MediaCard.artworkSize(cardWidthOverride: widthOverride, aspect: aspect)
            cell.contentConfiguration = UIHostingConfiguration {
                RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.09))
                    .frame(width: size.width, height: size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            .margins(.all, 0)
        }
    }

    /// Titles of the cards in `position`'s row that have been read, so the
    /// row's cards line their years up under its tallest title. The row
    /// itself keeps one height for any titles.
    private func rowTitles(at position: Int) -> [String] {
        let columns = max(metrics.columnCount, 1)
        let rowStart = position - position % columns
        return (rowStart..<min(rowStart + columns, cardCount)).compactMap {
            model.item(at: $0).map(EpisodeCardCaption.cardTitle(for:))
        }
    }

    /// Artwork of the cards at `indexPaths`, at the size they draw it.
    private func artwork(at indexPaths: [IndexPath]) -> [CardArtwork] {
        let widthOverride = metrics.cardWidth / model.layout.posterSize.scale
        return indexPaths.compactMap { indexPath in
            guard indexPath.section == Section.cards.rawValue,
                  let item = model.item(at: indexPath.item),
                  let url = item.posterUrl ?? item.boxSet?.posterUrl, !url.isEmpty else { return nil }
            return CardArtwork(
                url: url,
                pointSize: MediaCard.artworkSize(
                    cardWidthOverride: widthOverride, aspect: item.isAudiobook ? .square : .poster
                )
            )
        }
    }

    private func configureHeader(_ cell: UICollectionViewCell) {
        let environment = environment
        cell.contentConfiguration = UIHostingConfiguration {
            BrowseGridHeader { [weak self] in self?.model.grid.header() ?? AnyView(EmptyView()) }
                .ignoresSafeArea()
                .environment(\.self, environment)
        }
        .margins(.all, 0)
    }

    // MARK: - Layout

    private func layoutSection(at index: Int, width: CGFloat) -> NSCollectionLayoutSection? {
        switch Section(rawValue: index) {
        case .header:
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(60))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets.bottom = SiloTheme.padding
            return section
        case .cards:
            resolveMetrics(gridWidth: max(0, width - SiloTheme.padding - model.layout.trailingPadding))
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1 / CGFloat(metrics.columnCount)),
                heightDimension: .fractionalHeight(1)
            ))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(rowHeight)),
                repeatingSubitem: item,
                count: metrics.columnCount
            )
            group.interItemSpacing = .fixed(metrics.spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = Self.rowSpacing
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: SiloTheme.padding, bottom: 0, trailing: model.layout.trailingPadding
            )
            return section
        case .footer:
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(Self.footerHeight))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            return NSCollectionLayoutSection(group: group)
        case nil:
            return nil
        }
    }

    /// Work out the columns and row height for the width being laid out.
    /// When they change, the cells on screen are redrawn at the new width
    /// once this layout pass is over.
    private func resolveMetrics(gridWidth: CGFloat) {
        let resolved = BrowseGridMetrics.resolve(
            containerWidth: gridWidth,
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            inputs: model.layout
        )
        let key = RowHeightKey(
            cardWidth: resolved.cardWidth, usesSquareArtwork: model.layout.usesSquareArtwork, appearance: appearance
        )
        guard resolved != metrics || key != rowHeightKey else { return }
        metrics = resolved
        if key != rowHeightKey {
            rowHeightKey = key
            rowHeight = measuredRowHeight()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyStructure(reload: false)
            self.refreshVisibleCells(force: true)
        }
    }

    /// Height of a card with a year under a two-line title, the tallest a
    /// card in this grid gets.
    private func measuredRowHeight() -> CGFloat {
        let aspect: MediaCardAspect = model.layout.usesSquareArtwork ? .square : .poster
        let widthOverride = metrics.cardWidth / model.layout.posterSize.scale
        let artwork = MediaCard.artworkSize(cardWidthOverride: widthOverride, aspect: aspect)
        let sample = MediaCard(
            title: "Ag", // i18n-ignore: off-screen sample that measures a card's height
            posterUrl: "",
            mediaType: "movie",
            year: 2000,
            action: {},
            aspect: aspect,
            cardWidthOverride: widthOverride
        )
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.self, environment)
        let height = UIHostingController(rootView: sample)
            .sizeThatFits(in: CGSize(width: artwork.width, height: 10_000)).height
        guard height.isFinite, height > artwork.height, height < 10_000 else { return artwork.height + 64 }
        return height.rounded(.up)
    }

    // MARK: - Scrolling

    private func scrollToTop() {
        guard isViewLoaded else { return }
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: -collectionView.adjustedContentInset.top),
            animated: !UIAccessibility.isReduceMotionEnabled
        )
    }

    private func scroll(toPosition position: Int) {
        guard isViewLoaded, (0..<cardCount).contains(position) else { return }
        collectionView.layoutIfNeeded()
        let indexPath = IndexPath(item: position, section: Section.cards.rawValue)
        guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let insets = collectionView.adjustedContentInset
        let top = -insets.top
        let bottom = max(top, collectionView.contentSize.height + insets.bottom - collectionView.bounds.height)
        let target = min(max(frame.minY - SiloTheme.smallPadding - insets.top, top), bottom)
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
        reportScroll()
    }

    /// Tell the page chrome how far the grid has scrolled, and the pager
    /// which titles are on screen.
    private func reportScroll() {
        model.chromeState?.update(collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
        guard let pager = model.grid.pager else { return }
        var first = Int.max, last = Int.min
        for indexPath in collectionView.indexPathsForVisibleItems where indexPath.section == Section.cards.rawValue {
            first = min(first, indexPath.item)
            last = max(last, indexPath.item)
        }
        guard first <= last else { return }
        pager.show(first..<last + 1)
    }

    private func refresh() {
        Task { [weak self] in
            await self?.model.grid.onRefresh()
            self?.collectionView.refreshControl?.endRefreshing()
        }
    }

    // MARK: - UICollectionViewDataSourcePrefetching

    /// Warm the posters of the rows about to scroll in, so they draw with
    /// their cards.
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        PosterImageCache.prefetchArtwork(artwork(at: indexPaths))
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        PosterImageCache.stopPrefetchingArtwork(artwork(at: indexPaths))
    }

    // MARK: - UICollectionViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        model.grid.onUserScroll()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportScroll()
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? BrowseCardCell else { return }
        // A cell prepared ahead of the scroll may have been set up before
        // its title arrived.
        configure(cell, at: indexPath.item, force: false)
        let grid = model.grid
        if grid.pager == nil, grid.hasMore, !grid.items.isEmpty,
           indexPath.item >= grid.items.count - CatalogGrid.loadMoreLead {
            grid.onLoadMore()
        }
    }
}

private final class BrowseCardCell: UICollectionViewCell {
    enum Content: Equatable {
        case card(BrowseItem, width: CGFloat, rowTitles: [String])
        case placeholder(width: CGFloat, aspect: MediaCardAspect)
    }

    /// What the cell last drew, so it is set up again only for a change.
    var content: Content?
}

/// Draws the screen's controls inside the grid. A view of its own, so the
/// controls redraw when the state they read changes.
private struct BrowseGridHeader: View {
    let content: () -> AnyView

    var body: some View {
        content()
    }
}
#endif

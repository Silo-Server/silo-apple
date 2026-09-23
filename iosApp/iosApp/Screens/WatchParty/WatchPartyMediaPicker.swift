#if os(iOS) || os(tvOS)
import SwiftUI

enum WatchPartyPickerPurpose {
    case select, suggest
}

private enum WatchPartyPickerSource: String, CaseIterable, Identifiable {
    case together = "Continue Together", watchlist = "Watchlists", search = "Search"
    var id: Self { self }
}

private struct WatchPartyMediaChoice: Hashable {
    let contentId: String
    let type: String
    let title: String
    var subtitle: String?
    var posterURL: String?
    var posterThumbhash: String?
    var backdropURL: String?
    var backdropThumbhash: String?
    var overview: String?
    var facts: [String] = []

    init(item: BrowseItem) {
        contentId = item.contentId
        type = item.type
        title = item.title
        subtitle = nil
        posterURL = item.posterUrl
        posterThumbhash = item.posterThumbhash
        backdropURL = item.backdropUrl
        backdropThumbhash = item.backdropThumbhash
        overview = item.overview
        facts = item.watchPartyFacts
    }

    init(series: BrowseItem, episode: EpisodeListItem) {
        contentId = episode.contentId
        type = "episode"
        title = series.title
        subtitle = "S\(episode.seasonNumber) · E\(episode.episodeNumber)" + (episode.title.map { " · \($0)" } ?? "")
        posterURL = series.posterUrl
        posterThumbhash = series.posterThumbhash
        backdropURL = episode.stillUrl ?? series.backdropUrl
        backdropThumbhash = episode.stillUrl != nil ? episode.stillThumbhash : series.backdropThumbhash
        overview = episode.overview
        if let runtime = episode.runtime, runtime > 0 { facts = [WatchPartyFacts.runtime(runtime)] }
    }

    init(series: BrowseItem, nextUp: WatchPartyPickerNextUp) {
        contentId = nextUp.contentId
        type = "episode"
        title = series.title
        subtitle = "S\(nextUp.seasonNumber) · E\(nextUp.episodeNumber)" + (nextUp.title.map { " · \($0)" } ?? "")
        posterURL = series.posterUrl
        posterThumbhash = series.posterThumbhash
        backdropURL = series.backdropUrl
        backdropThumbhash = series.backdropThumbhash
    }
}

private enum WatchPartyPickerDestination: Hashable {
    case series(BrowseItem)
    case choice(WatchPartyMediaChoice)
    case search
}

enum WatchPartyFacts {
    static func runtime(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

private extension BrowseItem {
    /// "2021 · 2h 35m · PG-13" for the picker hero.
    var watchPartyFacts: [String] {
        var facts: [String] = []
        if let year, year > 0 { facts.append(String(year)) }
        if let runtime, runtime > 0 { facts.append(WatchPartyFacts.runtime(runtime)) }
        if let contentRating, !contentRating.isEmpty { facts.append(contentRating) }
        if let genres, let first = genres.first { facts.append(first) }
        return facts
    }
}

struct WatchPartyMediaPicker: View {
    let session: WatchPartySession
    var purpose: WatchPartyPickerPurpose = .select
    @Environment(\.dismiss) private var dismiss
    @State private var source: WatchPartyPickerSource = .search
    @State private var query = ""
    @State private var items: [BrowseItem] = []
    @State private var continuation: APIv2CatalogContinuation?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didChooseInitialSource = false
    @State private var didFallBackFromEmptySource = false
    @State private var loadID = UUID()
    @State private var destination: WatchPartyPickerDestination?
    #if os(tvOS)
    private enum ChromeFocus: Hashable { case search, close }
    /// Chrome-icon geometry copied from the top bar so the strip reads as
    /// the same bar Home sits under.
    private static let chromeIconSize: CGFloat = 27
    @FocusState private var chromeFocus: ChromeFocus?
    @State private var feedFocusRequest = 0
    /// Watchlist fallback for servers without the picker capability.
    @State private var watchlistItems: [BrowseItem] = []
    /// Discovery rows borrowed from Home (trending, curated…), personal rows removed.
    @State private var homeSections: [ResolvedSection] = []
    @State private var recentSeries: [BrowseItem] = []
    #endif

    private var sources: [WatchPartyPickerSource] {
        session.capabilities?.picker == true ? WatchPartyPickerSource.allCases : [.watchlist, .search]
    }

    private var shownItems: [BrowseItem] {
        switch source {
        case .together: return session.picker?.continueTogether.map(\.item) ?? []
        case .watchlist where session.capabilities?.picker == true:
            return session.picker?.watchlistUnion.map(\.item) ?? []
        default: return items
        }
    }

    private var playableItems: [BrowseItem] {
        shownItems.filter { SiloMediaType.isMovieLibrary($0.type) || SiloMediaType.isSeries($0.type) || $0.type == "episode" }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var loading: Bool { isLoading || (source != .search && session.isLoadingPicker) }
    private var requestKey: String {
        #if os(tvOS)
        // One stable key: the shelves load once per open. A changing key
        // would cancel the in-flight picker read and the session's
        // single-flight guard then drops the retry.
        "shelves"
        #else
        source.rawValue + ":" + query + (didChooseInitialSource ? ":ready" : ":initial")
        #endif
    }
    private var title: String { purpose == .suggest ? "Suggest a title" : "Choose a title" }
    private var subtitle: String { purpose == .suggest ? "Bring an idea to the party." : "Find something everyone will enjoy." }

    var body: some View {
        content
            .navigationDestination(item: $destination) { destination in
                switch destination {
                case .series(let item):
                    WatchPartyEpisodePicker(session: session, purpose: purpose, series: item, onComplete: { dismiss() })
                case .choice(let choice):
                    WatchPartyMediaChoiceView(session: session, purpose: purpose, choice: choice, onComplete: { dismiss() })
                case .search:
                    #if os(tvOS)
                    WatchPartySearchPage(purpose: purpose) { open($0) }
                    #else
                    EmptyView()
                    #endif
                }
            }
            .task {
                guard !didChooseInitialSource else { return }
                didChooseInitialSource = true
                if session.capabilities?.picker == true { source = .together }
            }
            .task(id: requestKey) {
                #if os(iOS)
                guard didChooseInitialSource else { return }
                #endif
                if !query.isEmpty {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                }
                await load(reset: true)
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        tvBody
        #else
        phoneBody
        #endif
    }

    // MARK: - tvOS

    #if os(tvOS)
    private static let togetherSectionID = "watchParty.together"
    private static let watchlistSectionID = "watchParty.watchlist"
    private static let recentMoviesSectionID = "watchParty.recentMovies"
    private static let recentSeriesSectionID = "watchParty.recentSeries"
    /// Home rows the shelf skips, mirroring the web picker: personal rows are
    /// covered by the together rows or would leak one member's history, and
    /// per-library recently-added rows are replaced by the shelf's own.
    private static let skippedHomeSectionTypes: Set<String> = [
        "recently_added", "recently_released", "new_to_library", "continue_watching", "next_up",
        "next_in_series", "watchlist", "favorites", "profile_activity_feed", "because_you_watched",
        "recommended_for_you", "similar_users_liked", "taste_match", "forgotten_favorites",
    ]
    private static let maxHomeSections = 4

    /// Home-style shelves: group picks first, then everyone's watchlists,
    /// then the newest library additions. A search with results replaces the
    /// recent shelf. Empty shelves are omitted, as on Home.
    private var tvSections: [ResolvedSection] {
        var sections: [ResolvedSection] = []
        if session.capabilities?.picker == true, let picker = session.picker {
            let together = picker.continueTogether.filter { isPlayable($0.item) }.map { entry in
                SectionItem(browseItem: entry.item,
                            positionSeconds: entry.members.compactMap(\.positionSeconds).max(),
                            durationSeconds: entry.members.compactMap(\.durationSeconds).max())
            }
            if !together.isEmpty {
                sections.append(section(Self.togetherSectionID, type: "watch_party_together", title: "Continue Together", items: together))
            }
            let watchlist = picker.watchlistUnion.filter { isPlayable($0.item) }.map { SectionItem(browseItem: $0.item) }
            if !watchlist.isEmpty {
                sections.append(section(Self.watchlistSectionID, type: "watch_party_watchlist", title: "On Your Watchlists", items: watchlist))
            }
        } else if !watchlistItems.isEmpty {
            sections.append(section(Self.watchlistSectionID, type: "watch_party_watchlist", title: "On Your Watchlists",
                                    items: watchlistItems.filter(isPlayable).map { SectionItem(browseItem: $0) }))
        }
        sections.append(contentsOf: homeSections)
        let movies = items.filter(isPlayable).map { SectionItem(browseItem: $0) }
        if !movies.isEmpty {
            sections.append(section(Self.recentMoviesSectionID, type: "watch_party_recent_movies", title: "Recently Added Movies", items: movies))
        }
        let series = recentSeries.filter(isPlayable).map { SectionItem(browseItem: $0) }
        if !series.isEmpty {
            sections.append(section(Self.recentSeriesSectionID, type: "watch_party_recent_series", title: "Recently Added Series", items: series))
        }
        return sections
    }

    private func section(_ id: String, type: String, title: String, items: [SectionItem]) -> ResolvedSection {
        ResolvedSection(id: id, sectionType: type, title: title, featured: false, itemLimit: nil,
                        totalCount: items.count, isCustom: nil, customized: nil, items: items)
    }

    private func isPlayable(_ item: BrowseItem) -> Bool {
        SiloMediaType.isMovieLibrary(item.type) || SiloMediaType.isSeries(item.type) || item.type == "episode"
    }

    /// The Skyline feed owns the hero and the rows. A slim chrome strip on top
    /// carries the purpose, search, and Close; Up from the first row hands
    /// focus to it, exactly as Home hands focus to the top bar.
    private var tvBody: some View {
        ZStack(alignment: .top) {
            Color.siloBackground.ignoresSafeArea()
            if tvSections.isEmpty {
                tvEmptyState
            } else {
                TVSkylineSectionFeed(
                    sections: tvSections,
                    focusRequest: feedFocusRequest,
                    isTopMenuFocused: chromeHasFocus,
                    onTopMenuFocusRequest: { chromeFocus = .search },
                    onItemTap: { _, item in openSection(item) }
                )
            }
            tvChrome
        }
        // Mirror the tab shell: it ignores the safe area on both the outer
        // stack and the root inside the navigation stack, so Skyline rows see
        // no horizontal inset. With an inset the row's rest offset includes it
        // while focus-scrolls do not, so the strip drifts as focus leaves.
        .ignoresSafeArea(edges: [.top, .horizontal])
        .toolbar(.hidden, for: .navigationBar)
        .onExitCommand { dismiss() }
        // First row, first card owns focus on open, as on Home. The token is
        // bumped whenever the section set changes identity so a late shelf
        // (picker rows arrive after the catalog) re-claims the first card
        // instead of leaving focus on whichever row mounted first.
        .onAppear { if chromeFocus == nil { feedFocusRequest += 1 } }
        .onChange(of: chromeFocus) { _, focus in
            if focus == nil { feedFocusRequest += 1 }
        }
        .onChange(of: tvSections.map(\.id)) { _, ids in
            if !ids.isEmpty, chromeFocus == nil { feedFocusRequest += 1 }
        }
    }

    private var chromeHasFocus: Bool { chromeFocus != nil }

    /// The strip mirrors the app's top bar: same inset, same height, same
    /// capsule icons. Left is the page name; right is Search and Close.
    private var tvChrome: some View {
        HStack(spacing: SiloTheme.Skyline.tabSpacing) {
            Text(title)
                .font(.system(size: SiloTheme.Skyline.tabLabelSize, weight: .semibold))
                .foregroundStyle(Color.white)
            Spacer()
            chromeIcon("magnifyingglass", label: "Search", id: .search) { destination = .search }
            chromeIcon("xmark", label: "Close", id: .close) { dismiss() }
        }
        .frame(height: SiloTheme.Skyline.barHeight)
        .padding(.horizontal, SiloTheme.Skyline.safeAreaX)
        .padding(.top, SiloTheme.Skyline.barTopInset)
        .focusSection()
    }

    private func chromeIcon(_ systemName: String, label: String, id: ChromeFocus, action: @escaping () -> Void) -> some View {
        let isFocused = chromeFocus == id
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Self.chromeIconSize, weight: .semibold))
                .foregroundStyle(isFocused ? Color.siloBackground : .white.opacity(0.62))
                .frame(width: SiloTheme.Skyline.barIconSize, height: SiloTheme.Skyline.barIconSize)
                .background(Capsule().fill(isFocused ? Color.white : .clear))
                .focusEffectDisabled()
                .animation(SiloTheme.springAnimation, value: isFocused)
        }
        .buttonStyle(.siloFlat)
        .focused($chromeFocus, equals: id)
        .accessibilityLabel(label)
    }

    private var tvEmptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loading {
                ProgressView().tint(Color.siloSecondaryText)
            } else {
                EmptyStateView(icon: "film.stack", title: "Nothing to pick from yet",
                               subtitle: "Search for a title, or add something to a watchlist.")
                if let message = errorMessage ?? session.errorMessage {
                    WatchPartyBanner(message: message, tone: .warning)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, WatchPartyMetrics.pageInset)
        .onAppear { if chromeFocus == nil { chromeFocus = .search } }
    }

    private func browseItem(for contentId: String) -> BrowseItem? {
        if let hit = items.first(where: { $0.contentId == contentId }) { return hit }
        if let hit = recentSeries.first(where: { $0.contentId == contentId }) { return hit }
        if let hit = watchlistItems.first(where: { $0.contentId == contentId }) { return hit }
        return session.picker?.continueTogether.first { $0.item.contentId == contentId }?.item
            ?? session.picker?.watchlistUnion.first { $0.item.contentId == contentId }?.item
    }

    /// Home rows come as `SectionItem`; lift one back to a `BrowseItem` shape
    /// through the shared decoder so the confirmation page has facts and art.
    private func openSection(_ item: SectionItem) {
        if let browse = browseItem(for: item.contentId) {
            open(browse)
        } else if let browse = BrowseItem(sectionItem: item) {
            open(browse)
        }
    }
    #endif

    // MARK: - iOS

    #if os(iOS)
    private var phoneBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                controls
                if loading && shownItems.isEmpty {
                    ProgressView("Loading titles…").frame(maxWidth: .infinity)
                } else if shownItems.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: source == .search ? "magnifyingglass" : "film",
                        description: Text(emptyDescription))
                } else {
                    mediaGrid
                }
                if let message = errorMessage ?? session.errorMessage {
                    Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    Button { Task { await load(reset: true) } } label: {
                        Text("Try Again").watchPartyButtonLabel()
                    }
                }
                if continuation != nil, source == .search || session.capabilities?.picker != true {
                    Button { Task { await load(reset: false) } } label: {
                        Text("Load More").watchPartyButtonLabel()
                    }
                        .disabled(isLoading)
                }
            }
            .padding(spacing)
        }
        .navigationTitle(title)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(subtitle).foregroundStyle(.secondary)
                Spacer()
                Button { dismiss() } label: { Text("Close").watchPartyButtonLabel() }
            }
            Picker("Browse", selection: $source) {
                ForEach(sources) { source in Text(source.rawValue).tag(source) }
            }
            .pickerStyle(.segmented)
            if source == .search {
                TextField("Search movies and series", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("watchParty.search")
            }
        }
    }

    private var mediaGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
            ForEach(playableItems) { item in
                VStack(alignment: .leading, spacing: 12) {
                    MediaCard(title: item.title, posterUrl: item.posterUrl ?? "", thumbhash: item.posterThumbhash,
                        year: item.year, action: { open(item) }, cardWidthOverride: cardWidth)
                        .frame(maxWidth: .infinity)
                    if let entry = entry(for: item.contentId) {
                        Text(memberNames(entry.members)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let nextUp = entry.nextUp {
                            Button {
                                destination = .choice(WatchPartyMediaChoice(series: item, nextUp: nextUp))
                            } label: {
                                Text("Next: S\(nextUp.seasonNumber) · E\(nextUp.episodeNumber)").watchPartyButtonLabel()
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cardWidth + 10), spacing: spacing, alignment: .top)]
    }
    #endif

    // MARK: - Shared

    /// Select on a "continue together" series goes straight to the group's
    /// next episode; other series open the season browser.
    private func open(_ item: BrowseItem) {
        if SiloMediaType.isSeries(item.type) {
            if let nextUp = entry(for: item.contentId)?.nextUp {
                destination = .choice(WatchPartyMediaChoice(series: item, nextUp: nextUp))
            } else {
                destination = .series(item)
            }
        } else {
            destination = .choice(WatchPartyMediaChoice(item: item))
        }
    }

    private func entry(for contentId: String) -> WatchPartyPickerEntry? {
        #if os(tvOS)
        let entries = (session.picker?.continueTogether ?? []) + (session.picker?.watchlistUnion ?? [])
        #else
        let entries = (source == .together ? session.picker?.continueTogether : source == .watchlist ? session.picker?.watchlistUnion : nil) ?? []
        #endif
        return entries.first { $0.item.contentId == contentId }
    }

    private func memberNames(_ members: [WatchPartyPickerMember]) -> String {
        members.map(\.displayName).joined(separator: ", ")
    }

    private func load(reset: Bool) async {
        #if os(tvOS)
        await loadShelves(reset: reset)
        #else
        await loadSource(reset: reset)
        #endif
    }

    #if os(tvOS)
    /// One pass fills every shelf: the server picker (group picks and
    /// watchlists), and the catalog for recent additions or search results.
    private func loadShelves(reset: Bool) async {
        let roomId = session.room?.roomId
        let requestedKey = requestKey
        if !reset, isLoading { return }
        let requestID = UUID()
        loadID = requestID
        isLoading = true
        errorMessage = nil
        if reset { continuation = nil; items = [] }
        defer { if loadID == requestID { isLoading = false } }
        if reset {
            async let picker: Void = session.capabilities?.picker == true ? session.refreshPicker() : ()
            async let watchlist: Void = session.capabilities?.picker != true && watchlistItems.isEmpty
                ? loadWatchlistFallback(roomId: roomId) : ()
            async let home: Void = loadHomeShelves(roomId: roomId)
            async let series: Void = loadRecentSeries(roomId: roomId)
            _ = await (picker, watchlist, home, series)
            guard !Task.isCancelled, roomId == session.room?.roomId, requestedKey == requestKey, loadID == requestID else { return }
        }
        do {
            let auth = try await session.catalogAuth()
            let result: APIv2CatalogResult
            if !reset, let continuation {
                result = try await SiloAPI.shared.apiV2Client.nextCatalogPage(continuation)
            } else {
                result = try await SiloAPI.shared.apiV2Client.catalogPage(query: Self.recentQuery(type: "movie"), auth: auth)
            }
            guard !Task.isCancelled, roomId == session.room?.roomId, requestedKey == requestKey, loadID == requestID else { return }
            if reset { items = result.value.items }
            else {
                let existing = Set(items.map(\.contentId))
                items.append(contentsOf: result.value.items.filter { !existing.contains($0.contentId) })
            }
            continuation = result.continuation
        } catch {
            guard !Task.isCancelled, roomId == session.room?.roomId, requestedKey == requestKey, loadID == requestID else { return }
            errorMessage = error.localizedDescription
        }
    }

    private static func recentQuery(type: String) -> APIv2CatalogQuery {
        var query = APIv2CatalogQuery()
        query.type = type
        query.limit = 24
        query.sort = CatalogSortKey.addedAt.field
        query.order = "desc"
        return query
    }

    private func loadRecentSeries(roomId: String?) async {
        do {
            let auth = try await session.catalogAuth()
            let result = try await SiloAPI.shared.apiV2Client.catalogPage(query: Self.recentQuery(type: "series"), auth: auth)
            guard !Task.isCancelled, roomId == session.room?.roomId else { return }
            recentSeries = result.value.items
        } catch {
            // The movies shelf still renders on its own.
        }
    }

    /// The first few discovery rows from Home, sharing Home's response cache
    /// so a picker opened from Home costs nothing extra.
    private func loadHomeShelves(roomId: String?) async {
        let response: SectionsResponse?
        if let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.homeSections) {
            response = cached
        } else {
            response = try? await StartupContentPrefetcher.fetchHomeSections()
        }
        guard let response, !Task.isCancelled, roomId == session.room?.roomId else { return }
        homeSections = response.sections
            .filter { !Self.skippedHomeSectionTypes.contains($0.sectionType.lowercased()) }
            .compactMap { section in
                let items = section.items.filter { SiloMediaType.isMovieLibrary($0.type) || SiloMediaType.isSeries($0.type) }
                guard !items.isEmpty else { return nil }
                return ResolvedSection(id: "watchParty.home." + section.id, sectionType: section.sectionType, title: section.title,
                                       featured: false, itemLimit: nil, totalCount: items.count, isCustom: section.isCustom,
                                       customized: section.customized, items: items)
            }
            .prefix(Self.maxHomeSections)
            .map { $0 }
    }

    private func loadWatchlistFallback(roomId: String?) async {
        do {
            let auth = try await session.catalogAuth()
            var catalogQuery = APIv2CatalogQuery()
            catalogQuery.type = "video"
            catalogQuery.limit = 40
            catalogQuery.source = "watchlist"
            let result = try await SiloAPI.shared.apiV2Client.catalogPage(query: catalogQuery, auth: auth)
            guard !Task.isCancelled, roomId == session.room?.roomId else { return }
            watchlistItems = result.value.items
        } catch {
            // The recent shelf still renders; the watchlist shelf is simply absent.
        }
    }
    #endif

    #if os(iOS)
    private func loadSource(reset: Bool) async {
        let roomId = session.room?.roomId
        let requestedKey = requestKey
        if !reset, isLoading { return }
        let requestID = UUID()
        loadID = requestID
        if source == .together || (source == .watchlist && session.capabilities?.picker == true) {
            continuation = nil
            isLoading = false
            await session.refreshPicker()
            fallBackIfEmpty()
            return
        }
        isLoading = true
        errorMessage = nil
        if reset { continuation = nil; items = [] }
        defer { if loadID == requestID { isLoading = false } }
        do {
            let auth = try await session.catalogAuth()
            let result: APIv2CatalogResult
            if !reset, let continuation {
                result = try await SiloAPI.shared.apiV2Client.nextCatalogPage(continuation)
            } else {
                var catalogQuery = APIv2CatalogQuery()
                catalogQuery.type = "video"
                catalogQuery.limit = 60
                if source == .watchlist { catalogQuery.source = "watchlist" }
                if source == .search {
                    if trimmedQuery.isEmpty {
                        // No query: newest additions read better than an alphabetical dump.
                        catalogQuery.sort = CatalogSortKey.addedAt.field
                        catalogQuery.order = "desc"
                    } else {
                        catalogQuery.q = trimmedQuery
                    }
                }
                result = try await SiloAPI.shared.apiV2Client.catalogPage(query: catalogQuery, auth: auth)
            }
            guard !Task.isCancelled, roomId == session.room?.roomId, requestedKey == requestKey, loadID == requestID else { return }
            if reset { items = result.value.items }
            else {
                let existing = Set(items.map(\.contentId))
                items.append(contentsOf: result.value.items.filter { !existing.contains($0.contentId) })
            }
            continuation = result.continuation
        } catch {
            guard !Task.isCancelled, roomId == session.room?.roomId, requestedKey == requestKey, loadID == requestID else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// The first open lands on whichever group source has titles, so a new
    /// party is not greeted by an empty "Continue Together" shelf.
    private func fallBackIfEmpty() {
        guard !didFallBackFromEmptySource, source == .together, let picker = session.picker,
              picker.continueTogether.isEmpty else { return }
        didFallBackFromEmptySource = true
        source = picker.watchlistUnion.isEmpty ? .search : .watchlist
    }
    #endif

    #if os(iOS)
    private var emptyTitle: String {
        switch source {
        case .together: return "Nothing to continue together"
        case .watchlist: return "No watchlist titles"
        case .search: return "No matching titles"
        }
    }
    private var emptyDescription: String {
        switch source {
        case .together: return "Titles the group has started show up here. Try Watchlists or Search."
        case .watchlist: return "Nothing on anyone's watchlist yet. Try Search."
        case .search: return "Try a different title."
        }
    }
    #endif
    private var spacing: CGFloat {
        #if os(tvOS)
        40
        #else
        20
        #endif
    }
    private var cardWidth: CGFloat {
        #if os(tvOS)
        200
        #else
        140
        #endif
    }
}

#if os(tvOS)
/// The app's own search: `SearchViewModel` behind the system search field
/// and `TVCatalogGrid`, as on the Search tab. Selecting a result hands the
/// item back to the picker instead of opening detail.
private struct WatchPartySearchPage: View {
    let purpose: WatchPartyPickerPurpose
    let onPick: (BrowseItem) -> Void
    @State private var viewModel = SearchViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiloTheme.padding) {
                if viewModel.isSearching && viewModel.results.isEmpty {
                    Color.clear
                } else if let error = viewModel.error {
                    ErrorView(state: error, onRetry: { Task { await viewModel.performSearch() } })
                } else if viewModel.hasSearched && viewModel.results.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "No results", subtitle: "Try a different search term")
                        .padding(.top, 80)
                } else if viewModel.results.isEmpty {
                    EmptyStateView(icon: "magnifyingglass",
                                   title: purpose == .suggest ? "Suggest a title" : "Choose a title",
                                   subtitle: "Find movies and series")
                        .padding(.top, 80)
                } else {
                    Text("\(viewModel.total) result\(viewModel.total == 1 ? "" : "s")")
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                    TVCatalogGrid(
                        items: viewModel.results.filter { !$0.isAudiobook },
                        isLoading: viewModel.isSearching,
                        hasMore: viewModel.hasMore,
                        onItemTap: onPick,
                        onNearEnd: { _ in Task { await viewModel.loadMore() } },
                        columnCount: 6,
                        cardWidth: 220,
                        prefersDefaultFocusOnFirstItem: true
                    )
                }
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.padding)
            .siloFormWidth(1600)
        }
        .siloPageBackground()
        .safeAreaPadding(.horizontal, 110)
        .navigationTitle("Search")
        .siloNavigationTitleDisplayMode(.inline)
        .siloSearchable(text: $viewModel.query, prompt: "Search movies and series...")
        .onAppear { viewModel.audiobooksEnabled = false }
        .onChange(of: viewModel.query) { _, _ in viewModel.onQueryChanged() }
    }
}
#endif

private struct WatchPartyEpisodePicker: View {
    let session: WatchPartySession
    let purpose: WatchPartyPickerPurpose
    let series: BrowseItem
    let onComplete: () -> Void
    @State private var seasons: [Season] = []
    @State private var episodes: [EpisodeListItem] = []
    @State private var seasonNumber: Int?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var chosen: WatchPartyMediaChoice?
    #if os(tvOS)
    @State private var focusedEpisodeId: String?
    @FocusState private var focusedSeasonNumber: Int?
    #endif

    var body: some View {
        content
            .navigationDestination(item: $chosen) { choice in
                WatchPartyMediaChoiceView(session: session, purpose: purpose, choice: choice, onComplete: onComplete)
            }
            .task { await loadSeasons() }
            .task(id: seasonNumber) { await loadEpisodes() }
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        tvBody
        #else
        phoneBody
        #endif
    }

    #if os(tvOS)
    private var focusedEpisode: EpisodeListItem? {
        episodes.first { $0.contentId == focusedEpisodeId }
    }

    private var tvBody: some View {
        ZStack {
            WatchPartyBackdrop(url: series.backdropUrl ?? series.posterUrl,
                               thumbhash: series.backdropUrl != nil ? series.backdropThumbhash : series.posterThumbhash,
                               isPoster: series.backdropUrl == nil)
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                WatchPartyEyebrow(text: "Watch Party · \(purpose == .suggest ? "Suggest an episode" : "Choose an episode")")
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 10) {
                    Text(series.title)
                        .font(.system(size: 64, weight: .bold))
                        .tracking(-1)
                        .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(focusedEpisode.map(episodeLine) ?? (series.year.map(String.init) ?? ""))
                        .font(.system(size: WatchPartyMetrics.body, weight: .medium))
                        .foregroundStyle(Color.siloSecondaryText)
                    Text(focusedEpisode?.overview ?? series.overview ?? "")
                        .font(.system(size: WatchPartyMetrics.body))
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(3)
                        .frame(height: WatchPartyMetrics.body * 1.3 * 3, alignment: .top)
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .animation(.easeOut(duration: SiloTheme.fastDuration), value: focusedEpisodeId)
                .padding(.bottom, 36)
                if !seasons.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 16) {
                            ForEach(seasons) { season in
                                TVSeriesModeTab(
                                    title: season.downloadDisplayName,
                                    isSelected: seasonNumber == season.seasonNumber,
                                    rendersFocusedAppearance: focusedSeasonNumber == season.seasonNumber
                                ) {
                                    seasonNumber = season.seasonNumber
                                }
                                .focused($focusedSeasonNumber, equals: season.seasonNumber)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .scrollClipDisabled()
                    .padding(.horizontal, -8)
                    .focusSection()
                    .padding(.bottom, 24)
                }
                Group {
                    if isLoading && episodes.isEmpty && seasons.isEmpty {
                        // Nothing else on the page can hold focus until the
                        // seasons arrive; without an owner Menu cannot leave.
                        ProgressView().tint(Color.siloSecondaryText).frame(maxWidth: .infinity)
                            .tvPageFocusOwner(focusRequest: 0, isTopMenuFocused: false,
                                              accessibilityLabel: "Loading episodes", onMoveUp: nil)
                    } else if isLoading && episodes.isEmpty {
                        ProgressView().tint(Color.siloSecondaryText).frame(maxWidth: .infinity)
                    } else if episodes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No episodes in this season").font(.system(size: 28, weight: .semibold)).foregroundStyle(Color.siloOnSurface)
                            if let errorMessage { WatchPartyBanner(message: errorMessage, tone: .warning) }
                            Button { Task { await loadSeasons() } } label: { Text("Reload episodes") }
                                .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                        }
                    } else {
                        TVEpisodeRail(
                            episodes: episodes,
                            onSelect: { id in
                                guard let episode = episodes.first(where: { $0.contentId == id }) else { return }
                                chosen = WatchPartyMediaChoice(series: series, episode: episode)
                            },
                            onFocusedEpisodeChange: { id in if let id { focusedEpisodeId = id } },
                            baseCardWidth: 400,
                            cardSpacing: 36
                        )
                        .padding(.horizontal, -WatchPartyMetrics.pageInset)
                    }
                }
                .frame(height: 400 * 9 / 16 + 120, alignment: .top)
                .focusSection()
            }
            .padding(.horizontal, WatchPartyMetrics.pageInset)
            .padding(.top, 48)
            .padding(.bottom, 40)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func episodeLine(_ episode: EpisodeListItem) -> String {
        var parts = ["S\(episode.seasonNumber) · E\(episode.episodeNumber)"]
        if let title = episode.title, !title.isEmpty { parts.append(title) }
        if let runtime = episode.runtime, runtime > 0 { parts.append(WatchPartyFacts.runtime(runtime)) }
        return parts.joined(separator: " · ")
    }
    #endif

    #if os(iOS)
    private var phoneBody: some View {
        List {
            if !seasons.isEmpty {
                Picker("Season", selection: $seasonNumber) {
                    ForEach(seasons) { season in
                        Text(season.downloadDisplayName).tag(Optional(season.seasonNumber))
                    }
                }
            }
            if isLoading { ProgressView("Loading episodes…") }
            ForEach(episodes) { episode in
                Button {
                    chosen = WatchPartyMediaChoice(series: series, episode: episode)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(episode.episodeNumber). \(episode.title ?? "Episode \(episode.episodeNumber)")").font(.headline)
                        if let overview = episode.overview, !overview.isEmpty {
                            Text(overview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .watchPartyButtonLabel()
                }
            }
            if !isLoading && episodes.isEmpty && errorMessage == nil {
                Text("No episodes are available in this season.").foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
            }
            Button { Task { await loadSeasons() } } label: {
                Text("Reload Episodes").watchPartyButtonLabel()
            }
        }
        .navigationTitle(series.title)
    }
    #endif

    private func loadSeasons() async {
        let roomId = session.room?.roomId
        isLoading = true
        errorMessage = nil
        do {
            let auth = try await session.catalogAuth()
            let values = try await SiloAPI.shared.apiV2Client.catalogSeasons(seriesId: series.contentId, imageSize: nil, auth: auth)
            guard !Task.isCancelled, roomId == session.room?.roomId else { return }
            seasons = try values.map { try Season(catalog: $0) }.sortedForDisplay()
            let target = seasons.first(where: { $0.seasonNumber > 0 }) ?? seasons.first
            if seasonNumber == target?.seasonNumber { await loadEpisodes() }
            else { seasonNumber = target?.seasonNumber }
            if seasons.isEmpty { isLoading = false }
        } catch {
            guard !Task.isCancelled, roomId == session.room?.roomId else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func loadEpisodes() async {
        guard let seasonNumber else { return }
        let roomId = session.room?.roomId
        isLoading = true
        errorMessage = nil
        episodes = []
        do {
            let auth = try await session.catalogAuth()
            let values = try await SiloAPI.shared.apiV2Client.catalogEpisodes(seriesId: series.contentId,
                seasonNumber: seasonNumber, imageSize: nil, auth: auth)
            guard !Task.isCancelled, roomId == session.room?.roomId, self.seasonNumber == seasonNumber else { return }
            episodes = try values.map { try EpisodeListItem(catalog: $0) }
        } catch {
            guard !Task.isCancelled, roomId == session.room?.roomId, self.seasonNumber == seasonNumber else { return }
            errorMessage = error.localizedDescription
        }
        if self.seasonNumber == seasonNumber { isLoading = false }
    }
}

private struct WatchPartyMediaChoiceView: View {
    let session: WatchPartySession
    let purpose: WatchPartyPickerPurpose
    let choice: WatchPartyMediaChoice
    let onComplete: () -> Void
    #if os(tvOS)
    @FocusState private var confirmFocused: Bool
    #endif

    private var posterWidth: CGFloat {
        #if os(tvOS)
        260
        #else
        120
        #endif
    }

    var body: some View {
        ZStack {
            #if os(tvOS)
            WatchPartyBackdrop(url: choice.backdropURL ?? choice.posterURL,
                               thumbhash: choice.backdropURL != nil ? choice.backdropThumbhash : choice.posterThumbhash,
                               isPoster: choice.backdropURL == nil)
            #else
            Color.siloBackground.ignoresSafeArea()
            #endif
            ScrollView {
                VStack(alignment: .leading, spacing: WatchPartyMetrics.body * 1.4) {
                    HStack(alignment: .bottom, spacing: WatchPartyMetrics.body) {
                        WatchPartyPoster(url: choice.posterURL, thumbhash: choice.posterThumbhash, width: posterWidth)
                            .shadow(color: .black.opacity(0.6), radius: 16, y: 10)
                        VStack(alignment: .leading, spacing: 8) {
                            WatchPartyEyebrow(text: purpose == .suggest ? "Suggest to the party" : "Watch together")
                            Text(choice.title)
                                .font(.system(size: WatchPartyMetrics.heroTitle * 0.9, weight: .bold))
                                .tracking(-1)
                                .foregroundStyle(Color.siloOnSurface)
                                .lineLimit(3)
                                .minimumScaleFactor(0.7)
                            let facts = (choice.subtitle.map { [$0] } ?? []) + choice.facts
                            if !facts.isEmpty {
                                Text(facts.joined(separator: " · "))
                                    .font(.system(size: WatchPartyMetrics.body))
                                    .foregroundStyle(Color.siloSecondaryText)
                            }
                        }
                    }
                    if let overview = choice.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: WatchPartyMetrics.body))
                            .foregroundStyle(Color.siloSecondaryText)
                            .lineLimit(6)
                    }
                    Button { Task { await submit() } } label: {
                        Label(actionTitle, systemImage: purpose == .suggest ? "plus" : "checkmark")
                    }
                    .buttonStyle(WatchPartyButtonStyle(kind: .primary))
                    .disabled(session.locksControls || !session.isEngaged)
                    .accessibilityIdentifier("watchParty.confirmSelection")
                    #if os(tvOS)
                    .focused($confirmFocused)
                    #endif
                    if session.capabilities?.memberState == true {
                        VStack(alignment: .leading, spacing: 10) {
                            WatchPartyEyebrow(text: "Who's seen it")
                            if session.isLoadingMemberState {
                                Text("Checking viewing history…")
                                    .font(.system(size: WatchPartyMetrics.caption))
                                    .foregroundStyle(Color.siloSecondaryText)
                            } else if let item = session.memberState?.items.first(where: { $0.contentId == choice.contentId }) {
                                ForEach(session.room?.members ?? []) { member in
                                    let state = item.members.first { $0.userId == member.userId && $0.profileId == member.profileId }
                                    HStack {
                                        Text(member.displayName).foregroundStyle(Color.siloOnSurface)
                                        Spacer()
                                        Text(historyLabel(state)).foregroundStyle(Color.siloSecondaryText)
                                    }
                                    .font(.system(size: WatchPartyMetrics.body))
                                }
                            }
                        }
                    }
                    if let message = session.errorMessage {
                        WatchPartyBanner(message: message, tone: .warning)
                    }
                }
                .padding(WatchPartyMetrics.pageInset)
                .padding(.top, 8)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(tvOS)
        .toolbar(.hidden, for: .navigationBar)
        .defaultFocus($confirmFocused, true, priority: .userInitiated)
        #endif
        .task(id: choice.contentId) {
            if session.capabilities?.memberState == true {
                await session.refreshMemberState(contentIds: [choice.contentId])
            }
        }
    }

    private var actionTitle: String {
        if purpose == .suggest { return "Add suggestion" }
        return session.room?.phase == .lobby && session.capabilities?.stagedSelection == true ? "Choose for the party" : "Play for everyone"
    }

    private func submit() async {
        let succeeded: Bool
        if purpose == .suggest {
            succeeded = await session.addSuggestion(WatchPartyNewSuggestion(contentId: choice.contentId,
                contentType: choice.type, title: choice.title, subtitle: choice.subtitle,
                posterUrl: choice.posterURL, note: nil))
        } else {
            succeeded = await session.select(WatchPartySelection(contentId: choice.contentId))
        }
        if succeeded { onComplete() }
    }

    private func historyLabel(_ state: WatchPartyMemberWatchState?) -> String {
        guard let state else { return "No viewing history" }
        let label: String
        switch state.state {
        case "watched", "completed", "played": label = "Watched"
        case "in_progress", "inprogress": label = "In progress"
        default: label = "Not watched"
        }
        return state.onWatchlist ? label + " · Watchlist" : label
    }
}
#endif

#if os(iOS) || os(tvOS)
import SwiftUI

enum WatchPartyPickerPurpose {
    case select, suggest
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
    /// The lobby hero's wording differs from this page's: an episode leads
    /// with its own title and puts the series and code underneath.
    private var lobbyTitle: String?
    private var lobbySubtitle: String?
    private var year: Int?
    private var runtimeMinutes: Int?
    /// The series to browse from here. Nil when the choice came from the
    /// series' own episode list, where Back already returns to it.
    private(set) var seriesLink: BrowseItem?
    /// Opens the series page on this episode's season.
    private(set) var seasonNumber: Int?

    /// Handed to the session so the lobby lays out before the room confirms.
    var lobbyPreview: WatchPartySelectedItem {
        WatchPartySelectedItem(previewContentId: contentId, type: type, title: lobbyTitle ?? title,
                               subtitle: lobbySubtitle, posterUrl: posterURL, posterThumbhash: posterThumbhash,
                               backdropUrl: backdropURL, backdropThumbhash: backdropThumbhash,
                               year: year, runtimeMinutes: runtimeMinutes, overview: overview)
    }

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
        year = item.year
        runtimeMinutes = item.runtime
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
        if let runtime = MediaTextFormatting.runtime(minutes: episode.runtime) { facts = [runtime] }
        lobbyTitle = episode.title ?? "Episode \(episode.episodeNumber)"
        lobbySubtitle = "\(series.title) · S\(episode.seasonNumber):E\(episode.episodeNumber)"
        runtimeMinutes = episode.runtime
    }

    /// A resume-row episode. Home rows carry the series poster and the
    /// episode's backdrop, so the confirmation keeps portrait art.
    init(episode item: SectionItem) {
        contentId = item.contentId
        type = "episode"
        title = item.seriesTitle ?? item.title
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            subtitle = "S\(season) · E\(episode)" + (item.seriesTitle != nil ? " · \(item.title)" : "")
        } else {
            subtitle = item.seriesTitle != nil ? item.title : nil
        }
        posterURL = item.posterUrl
        posterThumbhash = item.posterThumbhash
        backdropURL = item.backdropUrl
        backdropThumbhash = item.backdropThumbhash
        overview = item.overview
        if let runtime = MediaTextFormatting.runtime(minutes: item.runtime) { facts = [runtime] }
        lobbyTitle = item.title
        seasonNumber = item.seasonNumber
        if let seriesId = item.seriesId, !seriesId.isEmpty {
            seriesLink = BrowseItem(seriesId: seriesId, title: item.seriesTitle ?? item.title,
                                    posterUrl: item.posterUrl, posterThumbhash: item.posterThumbhash,
                                    backdropUrl: item.backdropUrl, backdropThumbhash: item.backdropThumbhash)
        }
        if let seriesTitle = item.seriesTitle, let season = item.seasonNumber, let episode = item.episodeNumber {
            lobbySubtitle = "\(seriesTitle) · S\(season):E\(episode)"
        } else {
            lobbySubtitle = item.seriesTitle
        }
        runtimeMinutes = item.runtime
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
        lobbyTitle = nextUp.title ?? "Episode \(nextUp.episodeNumber)"
        lobbySubtitle = "\(series.title) · S\(nextUp.seasonNumber):E\(nextUp.episodeNumber)"
        seriesLink = series
        seasonNumber = nextUp.seasonNumber
    }
}

private extension BrowseItem {
    /// A series row built from what an episode card already carries, enough
    /// for the episode picker, which loads the seasons itself.
    init?(seriesId: String, title: String, posterUrl: String?, posterThumbhash: String?,
          backdropUrl: String?, backdropThumbhash: String?) {
        var fields = ["contentId": seriesId, "type": "series", "title": title]
        fields["posterUrl"] = posterUrl
        fields["posterThumbhash"] = posterThumbhash
        fields["backdropUrl"] = backdropUrl
        fields["backdropThumbhash"] = backdropThumbhash
        guard let data = try? JSONEncoder().encode(fields),
              let item = try? JSONDecoder().decode(BrowseItem.self, from: data) else { return nil }
        self = item
    }
}

private enum WatchPartyPickerDestination: Hashable {
    case series(BrowseItem)
    case choice(WatchPartyMediaChoice)
    case search
}

private extension BrowseItem {
    /// "2021 · 2h 35m · PG-13" for the picker hero.
    var watchPartyFacts: [String] {
        var facts: [String] = []
        if let year, year > 0 { facts.append(String(year)) }
        if let runtimeText = MediaTextFormatting.runtime(minutes: runtime) { facts.append(runtimeText) }
        if let contentRating, !contentRating.isEmpty { facts.append(contentRating) }
        if let genres, let first = genres.first { facts.append(first) }
        return facts
    }
}

struct WatchPartyMediaPicker: View {
    let session: WatchPartySession
    var purpose: WatchPartyPickerPurpose = .select
    @Environment(\.dismiss) private var dismiss
    /// Recently added movies.
    @State private var items: [BrowseItem] = []
    @State private var continuation: APIv2CatalogContinuation?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadID = UUID()
    @State private var destination: WatchPartyPickerDestination?
    /// Watchlist fallback for servers without the picker capability.
    @State private var watchlistItems: [BrowseItem] = []
    /// Discovery rows borrowed from Home (trending, curated…), personal rows removed.
    @State private var homeSections: [ResolvedSection] = []
    @State private var recentSeries: [BrowseItem] = []
    #if os(tvOS)
    private enum ChromeFocus: Hashable { case search, close }
    /// Chrome-icon geometry copied from the top bar so the strip reads as
    /// the same bar Home sits under.
    private static let chromeIconSize: CGFloat = 27
    @FocusState private var chromeFocus: ChromeFocus?
    @State private var feedFocusRequest = 0
    #else
    /// The chooser's own Continue Watching row. The server's "together" row
    /// needs two members with progress, so a party of one would otherwise
    /// have nothing to resume.
    @State private var resumeItems: [SectionItem] = []
    @State private var search = SearchViewModel()
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var searchGridWidth: CGFloat = 0
    #endif

    private var loading: Bool { isLoading || session.isLoadingPicker }
    private var title: String { purpose == .suggest ? "Suggest a title" : "Choose a title" }

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
            // The shelves load once per open. A re-keyed task would cancel the
            // in-flight picker read and the session's single-flight guard
            // would then drop the retry.
            .task { await loadShelves(reset: true) }
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        tvBody
        #else
        phoneBody
        #endif
    }

    // MARK: - Shelves

    private static let togetherSectionID = "watchParty.together"
    private static let resumeSectionID = "watchParty.resume"
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
    /// then discovery rows and the newest library additions. Empty shelves
    /// are omitted, as on Home.
    private var sections: [ResolvedSection] {
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
        }
        #if !os(tvOS)
        if !resumeItems.isEmpty {
            sections.append(section(Self.resumeSectionID, type: "continue_watching", title: "Continue Watching", items: resumeItems))
        }
        #endif
        if session.capabilities?.picker == true, let picker = session.picker {
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

    private func browseItem(for contentId: String) -> BrowseItem? {
        if let hit = items.first(where: { $0.contentId == contentId }) { return hit }
        if let hit = recentSeries.first(where: { $0.contentId == contentId }) { return hit }
        if let hit = watchlistItems.first(where: { $0.contentId == contentId }) { return hit }
        return session.picker?.continueTogether.first { $0.item.contentId == contentId }?.item
            ?? session.picker?.watchlistUnion.first { $0.item.contentId == contentId }?.item
    }

    /// Home rows come as `SectionItem`; lift one back to a `BrowseItem` shape
    /// through the shared decoder so the confirmation page has facts and art.
    /// A resume episode goes straight to its confirmation.
    private func openSection(_ item: SectionItem) {
        if item.type == "episode" {
            destination = .choice(WatchPartyMediaChoice(episode: item))
        } else if let browse = browseItem(for: item.contentId) {
            open(browse)
        } else if let browse = BrowseItem(sectionItem: item) {
            open(browse)
        }
    }

    // MARK: - tvOS

    #if os(tvOS)
    /// The Skyline feed owns the hero and the rows. A slim chrome strip on top
    /// carries the purpose, search, and Close; Up from the first row hands
    /// focus to it, exactly as Home hands focus to the top bar.
    private var tvBody: some View {
        ZStack(alignment: .top) {
            Color.siloBackground.ignoresSafeArea()
            if sections.isEmpty {
                tvEmptyState
            } else {
                TVSkylineSectionFeed(
                    sections: sections,
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
        .onChange(of: sections.map(\.id)) { _, ids in
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
    #endif

    // MARK: - iOS

    #if os(iOS)
    private var isSearching: Bool {
        !search.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var phoneBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HomeFeedMetrics.sectionSpacing) {
                if isSearching {
                    searchResults
                } else if sections.isEmpty {
                    phoneEmptyState
                } else {
                    ForEach(sections) { section in
                        phoneRow(section)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .siloPageBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .siloSearchable(text: $search.query, prompt: "Search movies and series")
        .onChange(of: search.query) { _, _ in search.onQueryChanged() }
        .onAppear { search.audiobooksEnabled = false }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
            }
        }
    }

    private func phoneRow(_ section: ResolvedSection) -> some View {
        let isResume = section.id == Self.resumeSectionID
        let scale = uiCustomization.cardPresentation.posterSize.scale
        return VStack(alignment: .leading, spacing: HomeFeedMetrics.headerGap) {
            HomeSectionHeader(title: section.title, icon: isResume ? "play.circle.fill" : nil)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: HomeFeedMetrics.cardSpacing) {
                    ForEach(section.items) { item in
                        // Home's own cards, so art, overlays and captions match it.
                        if isResume {
                            HomeStillCard(item: item, width: HomeFeedMetrics.stillWidth * scale,
                                          showsCaption: uiCustomization.cardPresentation.caption.showsTitle,
                                          showsMetadata: uiCustomization.cardPresentation.caption.showsMetadata,
                                          onTap: { openSection(item) })
                        } else {
                            HomePosterCard(item: item, width: HomeFeedMetrics.posterWidth * scale,
                                           showsCaption: uiCustomization.cardPresentation.caption.showsTitle,
                                           showsMetadata: uiCustomization.cardPresentation.caption.showsMetadata,
                                           showsProgress: section.id == Self.togetherSectionID,
                                           onTap: { openSection(item) },
                                           secondLineOverride: caption(for: item, in: section))
                        }
                    }
                }
                .padding(.horizontal, HomeFeedMetrics.gutter)
            }
            .scrollClipDisabled()
        }
    }

    /// Group rows say who the title belongs to; other rows keep the year.
    private func caption(for item: SectionItem, in section: ResolvedSection) -> String? {
        guard section.id == Self.togetherSectionID || section.id == Self.watchlistSectionID,
              let entry = entry(for: item.contentId), !entry.members.isEmpty else { return nil }
        if section.id == Self.togetherSectionID, let nextUp = entry.nextUp {
            return "Next: S\(nextUp.seasonNumber) · E\(nextUp.episodeNumber)"
        }
        return memberNames(entry.members)
    }

    @ViewBuilder
    private var phoneEmptyState: some View {
        if loading {
            ProgressView().tint(Color.siloSecondaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, 120)
        } else {
            VStack(spacing: 16) {
                EmptyStateView(icon: "film.stack", title: "Nothing to pick from yet",
                               subtitle: "Search for a title, or add something to a watchlist.")
                if let message = errorMessage ?? session.errorMessage {
                    WatchPartyBanner(message: message, tone: .warning)
                    Button { Task { await loadShelves(reset: true) } } label: { Text("Try Again") }
                        .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, HomeFeedMetrics.gutter)
            .padding(.top, 80)
        }
    }

    private static let searchColumnCount = 3

    private var searchColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: HomeFeedMetrics.cardSpacing, alignment: .top),
              count: Self.searchColumnCount)
    }

    private var searchCardWidth: CGFloat {
        let gaps = HomeFeedMetrics.cardSpacing * CGFloat(Self.searchColumnCount - 1)
        return max(0, (searchGridWidth - gaps) / CGFloat(Self.searchColumnCount)).rounded(.down)
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = search.results.filter(isPlayable)
        if let error = search.error {
            ErrorView(state: error, onRetry: { Task { await search.performSearch() } })
        } else if results.isEmpty {
            if search.isSearching || !search.hasSearched {
                ProgressView().tint(Color.siloSecondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
            } else {
                EmptyStateView(icon: "magnifyingglass", title: "No results", subtitle: "Try a different search term.")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            }
        } else {
            LazyVGrid(columns: searchColumns, alignment: .leading, spacing: 18) {
                ForEach(results) { item in
                    HomePosterCard(item: SectionItem(browseItem: item), width: searchCardWidth,
                                   showsCaption: uiCustomization.cardPresentation.caption.showsTitle,
                                   showsMetadata: uiCustomization.cardPresentation.caption.showsMetadata,
                                   onTap: { open(item) })
                        .onAppear {
                            if item.contentId == results.last?.contentId { Task { await search.loadMore() } }
                        }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { searchGridWidth = $0 }
            .padding(.horizontal, HomeFeedMetrics.gutter)
        }
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
        let entries = (session.picker?.continueTogether ?? []) + (session.picker?.watchlistUnion ?? [])
        return entries.first { $0.item.contentId == contentId }
    }

    private func memberNames(_ members: [WatchPartyPickerMember]) -> String {
        members.map(\.displayName).joined(separator: ", ")
    }

    /// One pass fills every shelf: the server picker (group picks and
    /// watchlists), and the catalog for recent additions or search results.
    private func loadShelves(reset: Bool) async {
        let roomId = session.room?.roomId
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
            guard !Task.isCancelled, roomId == session.room?.roomId, loadID == requestID else { return }
        }
        do {
            let auth = try await session.catalogAuth()
            let result: APIv2CatalogResult
            if !reset, let continuation {
                result = try await SiloAPI.shared.apiV2Client.nextCatalogPage(continuation)
            } else {
                result = try await SiloAPI.shared.apiV2Client.catalogPage(query: Self.recentQuery(type: "movie"), auth: auth)
            }
            guard !Task.isCancelled, roomId == session.room?.roomId, loadID == requestID else { return }
            if reset { items = result.value.items }
            else {
                let existing = Set(items.map(\.contentId))
                items.append(contentsOf: result.value.items.filter { !existing.contains($0.contentId) })
            }
            continuation = result.continuation
        } catch {
            guard !Task.isCancelled, roomId == session.room?.roomId, loadID == requestID else { return }
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
        #if !os(tvOS)
        resumeItems = response.sections
            .first(where: HomeFeed.isResume)?
            .items.filter { SiloMediaType.isMovieLibrary($0.type) || $0.type == "episode" } ?? []
        #endif
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
    var initialSeasonNumber: Int? = nil
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
        if let runtime = MediaTextFormatting.runtime(minutes: episode.runtime) { parts.append(runtime) }
        return parts.joined(separator: " · ")
    }
    #endif

    #if os(iOS)
    private var phoneBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !seasons.isEmpty {
                    PhoneSeasonChips(seasons: seasons,
                                     selected: seasons.first { $0.seasonNumber == seasonNumber },
                                     onSelect: { seasonNumber = $0.seasonNumber })
                }
                Group {
                    if isLoading && episodes.isEmpty {
                        ProgressView().tint(Color.siloSecondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                    } else if episodes.isEmpty {
                        VStack(spacing: 16) {
                            EmptyStateView(icon: "tv", title: "No episodes",
                                           subtitle: errorMessage ?? "Nothing in this season is available to play.")
                            Button { Task { await loadSeasons() } } label: { Text("Try Again") }
                                .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(episodes) { episode in
                                Button {
                                    chosen = WatchPartyMediaChoice(series: series, episode: episode)
                                } label: {
                                    episodeRow(episode)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, SiloTheme.safePadding)
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .siloPageBackground()
        .navigationTitle(series.title)
        .navigationBarTitleDisplayMode(.large)
    }

    private static let stillWidth: CGFloat = 136

    private func episodeRow(_ episode: EpisodeListItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let still = episode.stillUrl, !still.isEmpty {
                    AsyncImageView(url: still, thumbhash: episode.stillThumbhash,
                                   targetSize: CGSize(width: Self.stillWidth * 2, height: Self.stillWidth * 9 / 8))
                } else {
                    Rectangle().fill(Color.siloSurfaceElevated)
                        .overlay { Image(systemName: "tv").foregroundStyle(Color.siloSecondaryText) }
                }
            }
            .frame(width: Self.stillWidth, height: Self.stillWidth * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.episodeNumber). \(episode.title ?? "Episode \(episode.episodeNumber)")")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(2)
                if let runtime = MediaTextFormatting.runtime(minutes: episode.runtime) {
                    Text(runtime)
                        .font(.caption)
                        .foregroundStyle(Color.siloSecondaryText)
                }
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
            // A retry keeps the season being viewed; the first load opens on
            // the initial season.
            let target = seasons.first(where: { $0.seasonNumber == seasonNumber })
                ?? seasons.first(where: { $0.seasonNumber == initialSeasonNumber })
                ?? seasons.first(where: { $0.seasonNumber > 0 }) ?? seasons.first
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
    @State private var browsedSeries: BrowseItem?
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
            WatchPartyBackdrop(url: choice.backdropURL ?? choice.posterURL,
                               thumbhash: choice.backdropURL != nil ? choice.backdropThumbhash : choice.posterThumbhash,
                               isPoster: choice.backdropURL == nil)
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
                    if let series = choice.seriesLink {
                        Button { browsedSeries = series } label: {
                            Label("See all episodes", systemImage: "list.bullet")
                        }
                        .buttonStyle(WatchPartyButtonStyle(kind: .secondary))
                        .accessibilityIdentifier("watchParty.browseSeries")
                    }
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
                #if os(iOS)
                // Let the backdrop show above the poster, as in the lobby.
                .padding(.top, 150)
                #else
                .padding(.top, 8)
                #endif
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(tvOS)
        .toolbar(.hidden, for: .navigationBar)
        .defaultFocus($confirmFocused, true, priority: .userInitiated)
        #endif
        .navigationDestination(item: $browsedSeries) { series in
            WatchPartyEpisodePicker(session: session, purpose: purpose, series: series,
                                    initialSeasonNumber: choice.seasonNumber, onComplete: onComplete)
        }
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
            succeeded = await session.select(WatchPartySelection(contentId: choice.contentId), preview: choice.lobbyPreview)
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

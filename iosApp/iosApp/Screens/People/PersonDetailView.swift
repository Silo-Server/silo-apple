import SwiftUI
import os

enum PersonMediaFilter: String, CaseIterable, Identifiable {
    case all
    case movies
    case series

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .series: "Series"
        }
    }

    var catalogType: String? {
        switch self {
        case .all: nil
        case .movies: "movie"
        case .series: "series"
        }
    }
}

@Observable
@MainActor
final class PersonDetailViewModel: CatalogMembershipModel {
    let personId: Int
    var person: Person?
    var items: [BrowseItem] = []
    var isLoadingPerson = false
    var isLoadingItems = false
    var error: ErrorState?
    var hasMore = true
    var selectedFilter: PersonMediaFilter = .all
    var availableFilters = PersonMediaFilter.allCases
    var totalItems: Int?
    var isRefreshingMetadata = false

    private static let metadataRefreshWindowSeconds: TimeInterval = 120
    private static let metadataRefreshPollInterval: Duration = .seconds(3)
    /// Consecutive unchanged polls after which the person is treated as
    /// unchanged enough to stop observing. This does not prove job completion.
    private static let metadataRefreshSettledPollCount = 5
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "PersonDetail"
    )
    private let pageSize = 60
    private var continuation: APIv2CatalogContinuation?
    private var generation = 0
    private var metadataRefreshTask: Task<Void, Never>?
    private var autoRefreshRequestedPersonId: Int?
    private var metadataRefreshExhaustedPersonId: Int?

    #if os(tvOS)
    private var prefetchedPosterURLs: Set<URL> = []
    #endif

    private let api: SiloAPI
    private let tokens: TokenStore
    private let pollDelay: () async throws -> Void
    private let authorityCheck: (CapturedOrdinaryRequestAuth) async -> Bool
    private var refreshAuth: CapturedOrdinaryRequestAuth?
    private var didCaptureRefreshAuth = false
    private var metadataRunID = UUID()
    var metadataRefreshTaskForTesting: Task<Void, Never>? { metadataRefreshTask }

    init(personId: Int, api: SiloAPI = .shared, tokens: TokenStore = .shared,
         pollDelay: @escaping () async throws -> Void = { try await Task.sleep(for: PersonDetailViewModel.metadataRefreshPollInterval) },
         authorityCheck: ((CapturedOrdinaryRequestAuth) async -> Bool)? = nil) {
        self.personId = personId
        self.api = api
        self.tokens = tokens
        self.pollDelay = pollDelay
        self.authorityCheck = authorityCheck ?? { await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: $0) != nil }
    }


    private(set) var displayedRead: CatalogCardOwner?
    private(set) var cardGeneration = 0
    private var pendingCardActions: [String: UUID] = [:]

    private func matchesCardScope(_ owner: CatalogCardOwner) -> Bool {
        owner.scope == "person:\(personId)" && owner.filterKey == selectedFilter.rawValue
    }

    func prepareCardAction(contentId: String, target: APIv2PersonalListKind, included: Bool) -> CatalogMembershipAction? {
        guard let owner = displayedRead, matchesCardScope(owner), pendingCardActions[contentId] == nil,
              items.contains(where: { $0.contentId == contentId && $0.userState != nil }) else { return nil }
        let action = CatalogMembershipAction(id: UUID(), contentId: contentId, owner: owner,
            generation: cardGeneration, target: target, included: included)
        pendingCardActions[contentId] = action.id
        return action
    }

    private func isCurrent(_ action: CatalogMembershipAction) -> Bool {
        action.owner == displayedRead && matchesCardScope(action.owner) && action.generation == cardGeneration
            && pendingCardActions[action.contentId] == action.id && !Task.isCancelled
            && items.contains(where: { $0.contentId == action.contentId })
    }

    func performCardAction(_ action: CatalogMembershipAction) async -> Bool? {
        defer { if pendingCardActions[action.contentId] == action.id { pendingCardActions[action.contentId] = nil } }
        let current = await authorityCheck(action.owner.auth)
        guard current, isCurrent(action) else { return nil }
        do {
            switch action.target {
            case .favorites: try await api.v2.setFavoriteMembership(id: action.contentId, included: action.included, auth: action.owner.auth)
            case .watchlist: try await api.v2.setWatchlistMembership(id: action.contentId, included: action.included, auth: action.owner.auth)
            }
            let current = await authorityCheck(action.owner.auth)
            guard current, isCurrent(action) else { return nil }
            generation += 1
            isLoadingItems = false
            if let index = items.firstIndex(where: { $0.contentId == action.contentId }) {
                let old = items[index].userState
                items[index].userState = MediaItemUserState(played: old?.played ?? false,
                    isFavorite: action.target == .favorites ? action.included : old?.isFavorite ?? false,
                    inWatchlist: action.target == .watchlist ? action.included : old?.inWatchlist ?? false)
            }
            ResponseCache.shared.remove(CacheKey.itemUserState(action.contentId))
            ResponseCache.shared.remove(action.target == .favorites ? CacheKey.favorites : CacheKey.watchlist)
            ResponseCache.shared.remove(CacheKey.homeSections)
            return true
        } catch {
            let current = await authorityCheck(action.owner.auth)
            guard current, isCurrent(action) else { return nil }
            return false
        }
    }
    func cancelFilmography() {
        generation += 1
        resetFilmography()
        isLoadingItems = false
        isLoadingPerson = false
    }

    func captureMetadataRefreshAuthority() async {
        guard !didCaptureRefreshAuth else { return }
        didCaptureRefreshAuth = true
        refreshAuth = await tokens.captureOrdinaryRequestAuth()
    }

    private func isCurrentMetadataRun(_ id: UUID) -> Bool {
        id == metadataRunID && !Task.isCancelled
    }

    /// Cancel the manually-spawned refresh poll when this page leaves the
    /// nav stack. SwiftUI only auto-cancels `.task`; this task otherwise
    /// retains the view model and keeps mutating state after the route pops.
    func stopMetadataRefresh() {
        guard metadataRefreshTask != nil || isRefreshingMetadata else { return }
        Self.logger.debug("stopMetadataRefresh personId=\(self.personId, privacy: .public)")
        metadataRunID = UUID()
        metadataRefreshTask?.cancel()
        metadataRefreshTask = nil
        isRefreshingMetadata = false
    }

    func resumeMetadataRefreshIfNeeded() {
        scheduleMetadataRefreshIfNeeded(for: person)
    }

    var isInitialLoading: Bool {
        person == nil && (isLoadingPerson || isLoadingItems)
    }

    func loadInitial() async {
        guard displayedRead == nil, !isLoadingPerson, !isLoadingItems else { return }
        await reload()
    }

    func reload() async {
        generation += 1
        let currentGeneration = generation
        resetFilmography()
        error = nil

        isLoadingPerson = person == nil
        defer { if currentGeneration == generation { isLoadingPerson = false } }

        do {
            await captureMetadataRefreshAuthority()
            guard currentGeneration == generation, !Task.isCancelled else { return }
            guard let auth = refreshAuth else { throw HTTPError.requestIdentityChanged }
            if person == nil {
                let loaded = try await api.person(id: personId, auth: auth)
                let mayPublish = await authorityCheck(auth)
                guard currentGeneration == generation, !Task.isCancelled else { return }
                guard mayPublish else { throw HTTPError.requestIdentityChanged }
                person = loaded
            }
            scheduleMetadataRefreshIfNeeded(for: person)
            async let availability: Void = refreshAvailableFilters(generation: currentGeneration)
            await fetchPage(reset: true, generation: currentGeneration)
            await availability
        } catch {
            guard currentGeneration == generation else { return }
            self.error = ErrorState(error)
            isLoadingItems = false
        }
    }

    func applyFilter(_ filter: PersonMediaFilter) async {
        guard filter != selectedFilter else { return }
        selectedFilter = filter
        generation += 1
        let currentGeneration = generation
        resetFilmography()
        error = nil
        await fetchPage(reset: true, generation: currentGeneration)
    }

    func loadMoreIfNeeded() async {
        guard hasMore, !isLoadingItems else { return }
        await fetchPage(reset: false, generation: generation)
    }

    #if os(tvOS)
    func prefetchPosters(in range: Range<Int>) {
        let urls = items[safe: range]
            .compactMap(\.posterUrl)
            .compactMap(URL.init(string:))
        let newURLs = urls.filter { prefetchedPosterURLs.insert($0).inserted }
        guard !newURLs.isEmpty else { return }
        PosterImageCache.prefetchCardArtwork(newURLs)
    }
    #endif

    private func scheduleMetadataRefreshIfNeeded(for person: Person?) {
        guard let person, person.id == personId, let auth = refreshAuth else { return }
        guard person.isMetadataIncomplete else {
            stopMetadataRefresh()
            return
        }
        guard metadataRefreshTask == nil else { return }
        guard metadataRefreshExhaustedPersonId != person.id else { return }

        let shouldQueueRefresh = autoRefreshRequestedPersonId != person.id
        if shouldQueueRefresh {
            autoRefreshRequestedPersonId = person.id
        }
        isRefreshingMetadata = true
        Self.logger.debug("startMetadataRefresh personId=\(person.id, privacy: .public) queue=\(shouldQueueRefresh, privacy: .public)")
        let runID = UUID()
        metadataRunID = runID
        metadataRefreshTask = Task { [weak self] in
            await self?.runMetadataAutoRefresh(for: person.id, shouldQueueRefresh: shouldQueueRefresh,
                                               auth: auth, runID: runID)
        }
    }

    private func runMetadataAutoRefresh(for personId: Int, shouldQueueRefresh: Bool,
                                        auth: CapturedOrdinaryRequestAuth, runID: UUID) async {
        defer {
            // An old suspended run must not clear a replacement task/phase.
            if metadataRunID == runID {
                metadataRefreshTask = nil
                isRefreshingMetadata = false
                if !Task.isCancelled, person?.isMetadataIncomplete == true {
                    metadataRefreshExhaustedPersonId = personId
                }
            }
        }
        let mayStart = await authorityCheck(auth)
        guard isCurrentMetadataRun(runID), mayStart else { return }
        if shouldQueueRefresh {
            // The per-view latch was claimed before scheduling. A failed or
            // ambiguous POST is never resubmitted by polling or resuming.
            _ = try? await api.refreshPerson(id: personId, auth: auth)
            guard isCurrentMetadataRun(runID) else { return }
        }
        let deadline = Date.now.addingTimeInterval(Self.metadataRefreshWindowSeconds)
        var unchangedPolls = 0
        while isCurrentMetadataRun(runID) && Date.now < deadline {
            do { try await pollDelay() } catch { return }
            guard isCurrentMetadataRun(runID) else { return }
            let mayRead = await authorityCheck(auth)
            guard isCurrentMetadataRun(runID), mayRead else { return }
            do {
                let updatedPerson = try await api.person(id: personId, auth: auth)
                guard isCurrentMetadataRun(runID) else { return }
                let mayPublish = await authorityCheck(auth)
                guard isCurrentMetadataRun(runID), mayPublish, personId == self.personId else { return }
                if updatedPerson == person {
                    unchangedPolls += 1
                    if unchangedPolls >= Self.metadataRefreshSettledPollCount { return }
                    continue
                }
                unchangedPolls = 0
                person = updatedPerson
                if !updatedPerson.isMetadataIncomplete { return }
            } catch {
                guard isCurrentMetadataRun(runID) else { return }
                let mayContinue = await authorityCheck(auth)
                guard isCurrentMetadataRun(runID), mayContinue else { return }
            }
        }
    }

    private func fetchPage(reset: Bool, generation currentGeneration: Int) async {
        guard hasMore, reset || !isLoadingItems else { return }
        isLoadingItems = true
        defer { if currentGeneration == generation { isLoadingItems = false } }
        let filter = selectedFilter
        // Filmography belongs to the person view's original authority, including nil PIN.
        await captureMetadataRefreshAuthority()
        guard currentGeneration == generation, !Task.isCancelled else { return }
        guard let auth = refreshAuth, let profile = auth.profileId, !profile.isEmpty else {
            resetFilmography()
            hasMore = false
            error = ErrorState(HTTPError.requestIdentityChanged)
            return
        }
        let owner = CatalogCardOwner(auth: auth, scope: "person:\(personId)", filterKey: filter.rawValue)
        do {
            let page: APIv2CatalogResult
            if !reset {
                guard displayedRead == owner, let continuation, continuation.auth == auth else {
                    throw HTTPError.requestIdentityChanged
                }
                page = try await api.v2.nextCatalogPage(continuation)
            } else {
                var query = APIv2CatalogQuery()
                query.source = "person"
                query.personId = String(personId)
                query.type = filter.catalogType
                query.limit = pageSize
                query.sort = "year"
                query.order = "desc"
                page = try await api.catalogPage(query: query, auth: auth)
            }
            let current = await authorityCheck(auth)
            guard currentGeneration == generation, !Task.isCancelled, matchesCardScope(owner) else { return }
            guard current, page.auth == auth else { throw HTTPError.requestIdentityChanged }
            let response = page.value
            if reset { items = response.items } else {
                let existing = Set(items.map(\.contentId))
                items.append(contentsOf: response.items.filter { !existing.contains($0.contentId) })
            }
            displayedRead = owner
            totalItems = response.totalExact ? response.total : nil
            hasMore = page.continuation != nil
            continuation = page.continuation
        } catch {
            let current = await authorityCheck(auth)
            guard currentGeneration == generation, !Task.isCancelled, matchesCardScope(owner) else { return }
            if !current { resetFilmography() }
            self.error = ErrorState(current ? error : HTTPError.requestIdentityChanged)
            hasMore = false
            continuation = nil
        }
    }

    private func refreshAvailableFilters(generation currentGeneration: Int) async {
        guard let auth = refreshAuth else { return }
        async let movies = catalogHasItems(type: "movie", auth: auth)
        async let series = catalogHasItems(type: "series", auth: auth)
        let results = await (movies, series)
        let current = await authorityCheck(auth)
        guard currentGeneration == generation, !Task.isCancelled, current else { return }

        var filters: [PersonMediaFilter] = [.all]
        if results.0 != false { filters.append(.movies) }
        if results.1 != false { filters.append(.series) }
        availableFilters = filters
    }

    /// `nil` means the availability check failed. In that case the filter
    /// remains visible rather than hiding content based on a network error.
    private func catalogHasItems(type: String, auth: CapturedOrdinaryRequestAuth) async -> Bool? {
        do {
            var query = APIv2CatalogQuery()
            query.source = "person"
            query.personId = String(personId)
            query.type = type
            query.limit = 1
            let response = try await api.catalogPage(query: query, auth: auth)
            return !response.value.items.isEmpty
        } catch {
            return nil
        }
    }

    private func resetFilmography() {
        displayedRead = nil
        cardGeneration += 1
        #if os(tvOS)
        if !prefetchedPosterURLs.isEmpty {
            PosterImageCache.stopPrefetchingCardArtwork(Array(prefetchedPosterURLs))
            prefetchedPosterURLs.removeAll()
        }
        #endif
        items = []
        totalItems = nil
        continuation = nil
        hasMore = true
    }
}

struct PersonDetailView: View {
    @State private var viewModel: PersonDetailViewModel
    #if os(iOS)
    @Environment(\.detailPullBackAction) private var goBack
    @Environment(\.dismiss) private var dismiss
    #endif

    init(personId: Int) {
        _viewModel = State(initialValue: PersonDetailViewModel(personId: personId))
    }

    var body: some View {
        rootContent
            #if os(iOS)
            .environment(\.detailPullBackAction, {
                if let goBack { goBack() } else { dismiss() }
            })
            #endif
            .onAppear {
                viewModel.resumeMetadataRefreshIfNeeded()
            }
            .task {
                await viewModel.loadInitial()
            }
            .onDisappear {
                viewModel.stopMetadataRefresh()
                viewModel.cancelFilmography()
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if let person = viewModel.person {
            personContent(person: person)
        } else if let error = viewModel.error {
            ErrorView(state: error, onRetry: { Task { await viewModel.reload() } })
        } else if viewModel.isInitialLoading {
            Color.clear
        } else {
            EmptyStateView(icon: "person", title: "Person not found")
                .siloPageBackground()
        }
    }

    @ViewBuilder
    private func personContent(person: Person) -> some View {
        #if os(tvOS)
        TVPersonDetailContent(person: person, viewModel: viewModel)
        #else
        #if os(iOS)
        // On iOS this pull means Back, including actor pages opened from
        // outside a title's detail sheet. Do not start a metadata refresh too.
        PhonePersonDetailContent(person: person, viewModel: viewModel)
        #else
        refreshablePersonContent(person: person)
        #endif
        #endif
    }

    #if !os(tvOS)
    private func refreshablePersonContent(person: Person) -> some View {
        PhonePersonDetailContent(person: person, viewModel: viewModel)
            .refreshable {
                async let overlayRefresh: Void = OverlayPrefsStore.shared.refresh()
                await viewModel.reload()
                await overlayRefresh
            }
    }
    #endif
}

#if os(tvOS)
private struct TVPersonDetailContent: View {
    let person: Person
    var viewModel: PersonDetailViewModel

    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                header
                    .padding(.horizontal, SiloTheme.safePadding)
                    .padding(.top, 48)

                VStack(alignment: .leading, spacing: 28) {
                    filmographyHeader

                    if viewModel.items.isEmpty && viewModel.isLoadingItems {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 420)
                    } else if let error = viewModel.error, viewModel.items.isEmpty {
                        ErrorView(state: error, onRetry: { Task { await viewModel.reload() } })
                            .frame(maxWidth: .infinity, minHeight: 420)
                    } else if viewModel.items.isEmpty {
                        EmptyStateView(
                            icon: "film.stack",
                            title: "No titles found",
                            subtitle: "There are no movies or series linked to this person yet."
                        )
                        .frame(maxWidth: .infinity, minHeight: 420)
                    } else {
                        TVCatalogGrid(
                            items: viewModel.items,
                            isLoading: viewModel.isLoadingItems,
                            hasMore: viewModel.hasMore,
                            onItemTap: { item in
                                router.navigate(to: .itemDetail(browseItem: item))
                            },
                            onNearEnd: { index in
                                Task { await viewModel.loadMoreIfNeeded() }
                                let end = min(index + 48, viewModel.items.count)
                                viewModel.prefetchPosters(in: index..<end)
                            }
                        )
                        .environment(\.catalogMembershipModel, viewModel)
                    }
                }
                .padding(.horizontal, SiloTheme.safePadding)
            }
            .padding(.bottom, 72)
        }
        .siloPageBackground()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 48) {
            PersonPortrait(person: person, width: 300)

            VStack(alignment: .leading, spacing: 22) {
                Text(person.name)
                    .font(.system(size: 72, weight: .bold))
                    .foregroundColor(.siloOnSurface)
                    .lineLimit(2)

                metadataRow

                if let bio = clean(person.bio) {
                    Text(bio)
                        .font(.siloBody)
                        .foregroundColor(.siloSecondaryText)
                        .lineLimit(7)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 920, alignment: .leading)
                }
            }
            .padding(.top, 10)
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 12) {
            ForEach(metadataBadges, id: \.self) { badge in
                Text(badge)
                    .font(.siloSmall)
                    .foregroundColor(.siloOnSurface)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.siloSurfaceVariant)
                    )
            }

            if viewModel.isRefreshingMetadata {
                PersonMetadataRefreshIndicator()
            }
        }
    }

    private var filmographyHeader: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Filmography")
                    .font(.siloHeadline)
                    .foregroundColor(.siloOnSurface)

                if let label = totalLabel {
                    Text(label)
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                }

                Spacer()
            }

            PersonFilterBar(filters: viewModel.availableFilters, selected: viewModel.selectedFilter) { filter in
                Task { await viewModel.applyFilter(filter) }
            }
        }
    }

    private var metadataBadges: [String] {
        person.personMetadataBadges
    }

    private var totalLabel: String? {
        personFilmographyCountLabel(total: viewModel.totalItems, loaded: viewModel.items.count, hasMore: viewModel.hasMore)
    }
}
#else
private struct PhonePersonDetailContent: View {
    let person: Person
    var viewModel: PersonDetailViewModel

    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                    .padding(.horizontal, SiloTheme.padding)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 16) {
                    filmographyHeader

                    if viewModel.items.isEmpty && viewModel.isLoadingItems {
                        ProgressView()
                            .tint(.siloOnSurface)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if let error = viewModel.error, viewModel.items.isEmpty {
                        ErrorView(state: error, onRetry: { Task { await viewModel.reload() } })
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else if viewModel.items.isEmpty {
                        EmptyStateView(
                            icon: "film",
                            title: "No titles found",
                            subtitle: "There are no movies or series linked to this person yet."
                        )
                        .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        CatalogGrid(
                            items: viewModel.items,
                            isLoading: viewModel.isLoadingItems,
                            hasMore: viewModel.hasMore,
                            onItemTap: { item in
                                router.navigate(to: .itemDetail(browseItem: item))
                            },
                            onLoadMore: {
                                Task { await viewModel.loadMoreIfNeeded() }
                            }
                        )
                        .environment(\.catalogMembershipModel, viewModel)
                        .padding(.horizontal, SiloTheme.padding)
                    }
                }
            }
            .padding(.bottom, SiloTheme.largePadding)
        }
        .detailScrollDismissal()
        .siloPageBackground()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            PersonPortrait(person: person, width: 132)

            VStack(alignment: .leading, spacing: 10) {
                Text(person.name)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.siloOnSurface)
                    .lineLimit(3)

                metadataWrap

                if let bio = clean(person.bio) {
                    Text(bio)
                        .font(.siloBody)
                        .foregroundColor(.siloSecondaryText)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var metadataWrap: some View {
        FlowLayout(spacing: 6) {
            ForEach(person.personMetadataBadges, id: \.self) { badge in
                Text(badge)
                    .font(.siloSmall)
                    .foregroundColor(.siloOnSurface)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.siloSurfaceVariant)
                    )
            }

            if viewModel.isRefreshingMetadata {
                PersonMetadataRefreshIndicator()
            }
        }
    }

    private var filmographyHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Filmography")
                    .font(.siloHeadline)
                    .foregroundColor(.siloOnSurface)

                if let label = personFilmographyCountLabel(
                    total: viewModel.totalItems,
                    loaded: viewModel.items.count,
                    hasMore: viewModel.hasMore
                ) {
                    Text(label)
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                }

                Spacer()
            }
            .padding(.horizontal, SiloTheme.padding)

            PersonFilterBar(filters: viewModel.availableFilters, selected: viewModel.selectedFilter) { filter in
                Task { await viewModel.applyFilter(filter) }
            }
            .padding(.horizontal, SiloTheme.padding)
        }
    }
}
#endif

private struct PersonPortrait: View {
    let person: Person
    let width: CGFloat

    private var height: CGFloat { width * 1.5 }

    var body: some View {
        ZStack {
            Color.siloSurfaceElevated

            if let photoUrl = clean(person.photoUrl) {
                AsyncImageView(
                    url: photoUrl,
                    thumbhash: person.photoThumbhash,
                    targetSize: CGSize(width: width, height: height),
                    contentMode: .fill
                )
            } else {
                Text(person.initials)
                    .font(.system(size: width * 0.28, weight: .semibold))
                    .foregroundColor(.siloSecondaryText)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: SiloTheme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct PersonMetadataRefreshIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(controlSize)
                .tint(.siloOnSurface)

            Text("Loading metadata")
                .font(.siloSmall)
                .foregroundColor(.siloSecondaryText)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(
            Capsule()
                .fill(Color.siloSurfaceVariant.opacity(0.72))
        )
        .accessibilityElement(children: .combine)
    }

    private var controlSize: ControlSize {
        #if os(tvOS)
        .regular
        #else
        .small
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        16
        #else
        9
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
        8
        #else
        5
        #endif
    }
}

private struct PersonFilterBar: View {
    let filters: [PersonMediaFilter]
    let selected: PersonMediaFilter
    let onSelect: (PersonMediaFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters) { filter in
                    PersonFilterButton(
                        title: filter.title,
                        isSelected: filter == selected,
                        action: { onSelect(filter) }
                    )
                }
            }
            #if os(tvOS)
            .padding(.vertical, 8)
            #endif
        }
        .scrollClipDisabled()
    }
}

private struct PersonFilterButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(buttonFont)
                .foregroundColor(foregroundColor)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(
                    Capsule()
                        .fill(backgroundColor)
                )
                .overlay(
                    Capsule()
                        .stroke(strokeColor, lineWidth: isFocused ? 2 : 1)
                )
        }
        .buttonStyle(.siloFlat)
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: isSelected)
    }

    private var foregroundColor: Color {
        isSelected || isFocused ? .siloOnSurface : .siloSecondaryText
    }

    private var backgroundColor: Color {
        if isSelected { return .siloSurfaceVariant }
        if isFocused { return Color.siloSurfaceVariant.opacity(0.8) }
        return Color.siloSurfaceElevated.opacity(0.55)
    }

    private var strokeColor: Color {
        isFocused ? .siloOnSurface.opacity(0.85) : Color.white.opacity(isSelected ? 0.16 : 0.08)
    }

    private var buttonFont: Font {
        #if os(tvOS)
        .siloCaption
        #else
        .siloCaption
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        22
        #else
        12
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
        10
        #else
        7
        #endif
    }
}

private extension Person {
    var isMetadataIncomplete: Bool {
        clean(bio) == nil || clean(photoUrl) == nil || clean(birthDate) == nil
    }

    var initials: String {
        let parts = name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
        let value = String(parts).uppercased()
        return value.isEmpty ? "?" : value
    }

    var personMetadataBadges: [String] {
        var badges: [String] = []
        if let birthDate = formattedPersonDate(birthDate) {
            badges.append("Born \(birthDate)")
        }
        if let deathDate = formattedPersonDate(deathDate) {
            badges.append("Died \(deathDate)")
        } else if let age = personAge(from: birthDate, to: nil) {
            badges.append("\(age) years old")
        }
        if let birthplace = clean(birthplace) {
            badges.append(birthplace)
        }
        return badges
    }
}

private func personFilmographyCountLabel(total: Int?, loaded: Int, hasMore: Bool) -> String? {
    if let total {
        return total == 1 ? "1 title" : "\(total) titles"
    }
    guard loaded > 0 else { return nil }
    return hasMore ? "\(loaded)+ titles" : (loaded == 1 ? "1 title" : "\(loaded) titles")
}

private func clean(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func formattedPersonDate(_ value: String?) -> String? {
    guard let date = parsePersonDate(value) else { return clean(value) }
    return SelfDateFormatter.personDisplay.string(from: date)
}

private func personAge(from birthValue: String?, to deathValue: String?) -> Int? {
    guard let birthDate = parsePersonDate(birthValue) else { return nil }
    let endDate = parsePersonDate(deathValue) ?? Date()
    let years = Calendar.current.dateComponents([.year], from: birthDate, to: endDate).year
    guard let years, years >= 0 else { return nil }
    return years
}

private func parsePersonDate(_ value: String?) -> Date? {
    guard let value = clean(value) else { return nil }
    return SelfDateFormatter.personISO.date(from: value)
}

private enum SelfDateFormatter {
    static let personISO: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let personDisplay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

#if os(tvOS)
private extension Array {
    subscript(safe range: Range<Int>) -> ArraySlice<Element> {
        let lower = Swift.max(0, range.lowerBound)
        let upper = Swift.min(count, range.upperBound)
        guard lower < upper else { return [] }
        return self[lower..<upper]
    }
}
#endif

import Foundation

enum SearchMediaType: String, CaseIterable, Identifiable {
    case all
    case movie
    case series
    case audiobook

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .movie: "Movies"
        case .series: "Series"
        case .audiobook: "Audiobooks"
        }
    }

    /// The `type` query value for this filter. `.all` is context-dependent:
    /// when audiobooks aren't part of this search it means video-only (the old
    /// "Movies & Series" filter), so hidden audiobooks never leak into
    /// unfiltered results; when they are, it sends no filter (true everything).
    func queryValue(audiobooksEnabled: Bool) -> String? {
        switch self {
        case .all: audiobooksEnabled ? nil : "video"
        case .movie: "movie"
        case .series: "series"
        case .audiobook: "audiobook"
        }
    }
}

@Observable
@MainActor
class SearchViewModel {
    var query = ""
    var selectedMediaType: SearchMediaType = .all
    var results: [BrowseItem] = []

    /// Whether audiobooks participate in this search session. Drives both the
    /// offered filters (`availableMediaTypes`) and what `.all` means. On tvOS
    /// this mirrors the Audiobooks tab — an audiobook library exists and the
    /// user has opted to show it. On iOS it mirrors the local Settings toggle.
    /// macOS has no hide setting, so it stays `true`. Clamp the selection if
    /// audiobooks become unavailable.
    var audiobooksEnabled = true {
        didSet {
            if !audiobooksEnabled, selectedMediaType == .audiobook {
                selectedMediaType = .all
            }
        }
    }

    /// Filters offered in the picker — Audiobooks only when enabled.
    var availableMediaTypes: [SearchMediaType] {
        audiobooksEnabled ? [.all, .movie, .series, .audiobook] : [.all, .movie, .series]
    }
    var isSearching = false
    var error: ErrorState?
    var hasSearched = false
    var hasMore = false
    var total = 0

    private let api: APIv2Client

    init(api: APIv2Client = APIv2Client()) { self.api = api }

    private var searchTask: Task<Void, Never>?
    private let pageSize = 60
    private var continuation: APIv2CatalogContinuation?
    private var generation = 0
    var totalExact = true
    var resultWindowLimit: Int?
    var sessionExpiresAt: Date?

    var countLabel: String {
        "\(totalExact ? "" : "About ")\(total) result\(total == 1 ? "" : "s")"
    }

    /// Debounced search triggered on query change.
    func onQueryChanged() {
        searchTask?.cancel()

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            resetState()
            return
        }

        searchTask = Task {
            // 300ms debounce
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(reset: true)
        }
    }

    func applyMediaType() async {
        searchTask?.cancel()

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }

        await performSearch(reset: true)
    }

    func loadMore() async {
        guard hasMore, !isSearching else { return }
        await performSearch(reset: false)
    }

    func performSearch(reset: Bool = true) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            resetState()
            return
        }

        if !reset, !hasMore {
            return
        }

        if reset { generation += 1; continuation = nil }
        let requestGeneration = generation

        isSearching = true
        error = nil

        do {
            let page: APIv2CatalogResult
            if !reset, let continuation {
                page = try await api.nextCatalogPage(continuation)
            } else {
                let capabilities = try await api.catalogSearchCapabilities()
                guard capabilities.allowed != false else { throw CatalogSearchUnavailable() }
                var searchQuery = APIv2CatalogQuery()
                searchQuery.q = trimmed
                searchQuery.limit = pageSize
                searchQuery.imageSize = ImageSizeCapability.shared.requestQuery["image_size"]
                searchQuery.type = selectedMediaType.queryValue(audiobooksEnabled: audiobooksEnabled)
                page = try await api.catalogPage(query: searchQuery)
            }
            guard !Task.isCancelled, requestGeneration == generation else { return }
            let response = page.value
            if reset {
                results = response.items
            } else {
                let existingIds = Set(results.map(\.contentId))
                results.append(contentsOf: response.items.filter { !existingIds.contains($0.contentId) })
            }

            continuation = page.continuation
            total = response.total
            totalExact = response.totalExact
            resultWindowLimit = response.searchDiagnostics?.resultWindowLimit
            sessionExpiresAt = response.searchDiagnostics?.sessionExpiresAt
            hasMore = page.continuation != nil
            hasSearched = true
        } catch let err {
            guard !Task.isCancelled, requestGeneration == generation else { return }
            hasMore = false
            self.error = ErrorState(err)
            if reset {
                results = []
                total = 0
                hasMore = false
                hasSearched = true
            }
        }
        isSearching = false
    }

    private func resetState() {
        results = []
        isSearching = false
        error = nil
        hasSearched = false
        hasMore = false
        total = 0
        generation += 1
        continuation = nil
        totalExact = true
        resultWindowLimit = nil
        sessionExpiresAt = nil
    }
}

private struct CatalogSearchUnavailable: LocalizedError {
    var errorDescription: String? { "Search is currently unavailable. Please try again later." }
}

import Foundation
import SwiftUI

@Observable
@MainActor
final class PersonalListViewModel {
    var items: [BrowseItem] = []
    private(set) var isLoading = false
    private(set) var error: ErrorState?
    private(set) var hasMore = false

    private let kind: APIv2PersonalListKind
    private let api: APIv2Client
    private let tokenStore: TokenStore
    private let captureBarrier: (@MainActor () async -> Void)?
    private var continuation: APIv2PersonalListContinuation?
    private var generation = 0
    private var task: Task<APIv2PersonalListResult, Error>?
    private var owner: RefreshAccountIdentity?
    private var profile: String?

    private struct CachedCards {
        let items: [BrowseItem]
        let owner: RefreshAccountIdentity
        let profile: String
    }

    init(kind: APIv2PersonalListKind, api: APIv2Client = APIv2Client(), tokenStore: TokenStore = .shared,
         captureBarrier: (@MainActor () async -> Void)? = nil) {
        self.kind = kind
        self.api = api
        self.tokenStore = tokenStore
        self.captureBarrier = captureBarrier
    }

    private var cacheKey: String { kind == .favorites ? CacheKey.favorites : CacheKey.watchlist }

    func reload() async { await load(reset: true) }

    func loadMore() async {
        guard hasMore, !isLoading, error == nil else { return }
        await load(reset: false)
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isLoading = false
    }

    func remove(id: String) {
        items.removeAll { $0.contentId == id }
        cacheCards()
    }

    private func cacheCards() {
        guard let owner, let profile else { return }
        ResponseCache.shared.set(CachedCards(items: Array(items.prefix(50)), owner: owner, profile: profile), for: cacheKey)
    }

    private func load(reset: Bool) async {
        if reset { cancel(); continuation = nil; hasMore = false }
        let requestGeneration = generation
        // Reserve this generation before suspending so a second Load More cannot
        // dispatch the same continuation or later reopen an exhausted page.
        isLoading = true
        defer {
            if requestGeneration == generation { isLoading = false; task = nil }
        }
        if let captureBarrier { await captureBarrier() }
        let captured = await tokenStore.captureOrdinaryRequestAuth()
        guard requestGeneration == generation else { return }
        guard let auth = captured, let requestedProfile = auth.profileId else {
            items = []; continuation = nil; hasMore = false
            error = ErrorState(HTTPError.requestIdentityChanged)
            return
        }
        guard requestGeneration == generation else { return }
        if owner != auth.account || profile != requestedProfile {
            items = []
            if !reset {
                continuation = nil; hasMore = false
                error = ErrorState(HTTPError.requestIdentityChanged)
                return
            }
        }
        owner = auth.account
        profile = requestedProfile
        if reset, items.isEmpty,
           let cached: CachedCards = ResponseCache.shared.get(cacheKey),
           cached.owner == owner, cached.profile == profile {
            items = cached.items
        }
        error = nil
        let cursor = reset ? nil : continuation
        let api = self.api
        let kind = self.kind
        let request = Task {
            if let cursor { return try await api.nextPersonalListPage(cursor) }
            await ImageSizeCapability.shared.refresh()
            return try await api.personalList(kind: kind, imageSize: ImageSizeCapability.shared.requestQuery["image_size"])
        }
        task = request
        do {
            let result = try await request.value
            guard requestGeneration == generation, !Task.isCancelled else { return }
            guard let current = await tokenStore.captureOrdinaryRequestAuth(), requestGeneration == generation,
                  !Task.isCancelled, current.account == auth.account,
                  current.profileId == requestedProfile else { throw HTTPError.requestIdentityChanged }
            var seen = Set(reset ? [] : items.map(\.contentId))
            let incoming = result.value.items.filter { seen.insert($0.contentId).inserted }
            if reset { items = incoming } else { items.append(contentsOf: incoming) }
            continuation = result.continuation
            hasMore = result.continuation != nil
            if reset { cacheCards() }
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            let current = await tokenStore.captureOrdinaryRequestAuth()
            guard requestGeneration == generation, !Task.isCancelled else { return }
            if let current, current.account == auth.account,
               current.profileId == requestedProfile {
                self.error = ErrorState(error)
            } else {
                items = []
                self.error = ErrorState(HTTPError.requestIdentityChanged)
            }
            continuation = nil
            hasMore = false
        }
    }
}

/// Always available outside the grid, including an empty page or media category.
struct PersonalListPagingControls: View {
    @Bindable var model: PersonalListViewModel
    var onMoveUp: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.error, !model.items.isEmpty {
                Text(error.message).foregroundStyle(Color.siloError)
                Button("Reload list") { Task { await model.reload() } }
            } else if model.isLoading {
                ProgressView()
            } else if model.hasMore {
                Button("Load More") { Task { await model.loadMore() } }
            }
        }
        .padding(12)
        #if os(tvOS)
        .onMoveCommand { direction in
            if direction == .up, model.items.isEmpty { onMoveUp?() }
        }
        #endif
    }
}

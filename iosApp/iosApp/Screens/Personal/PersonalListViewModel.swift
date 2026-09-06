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
    private(set) var displayedAuth: CapturedOrdinaryRequestAuth?
    private(set) var cardGeneration = 0
    private var pendingCardActions: [String: UUID] = [:]

    struct CardAction {
        let id: UUID
        let contentId: String
        let target: APIv2PersonalListKind
        let included: Bool
        let auth: CapturedOrdinaryRequestAuth
        let generation: Int
    }

    /// Reserve the displayed owner synchronously, before the UI creates a Task.
    func prepareCardAction(contentId: String, target: APIv2PersonalListKind, included: Bool) -> CardAction? {
        guard let auth = displayedAuth, pendingCardActions[contentId] == nil,
              items.contains(where: { $0.contentId == contentId }) else { return nil }
        let action = CardAction(id: UUID(), contentId: contentId, target: target,
            included: included, auth: auth, generation: cardGeneration)
        pendingCardActions[contentId] = action.id
        return action
    }

    private func cardActionIsCurrent(_ action: CardAction) -> Bool {
        action.generation == cardGeneration && displayedAuth == action.auth
            && pendingCardActions[action.contentId] == action.id
            && items.contains(where: { $0.contentId == action.contentId }) && !Task.isCancelled
    }

    /// nil is a stale action; false is a current failure eligible for UI revert.
    func performCardAction(_ action: CardAction) async -> Bool? {
        defer {
            if pendingCardActions[action.contentId] == action.id {
                pendingCardActions[action.contentId] = nil
            }
        }
        let current = await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: action.auth) != nil
        guard current, cardActionIsCurrent(action) else { return nil }
        do {
            switch action.target {
            case .favorites:
                try await api.setFavoriteMembership(id: action.contentId, included: action.included, auth: action.auth)
            case .watchlist:
                try await api.setWatchlistMembership(id: action.contentId, included: action.included, auth: action.auth)
            }
            let current = await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: action.auth) != nil
            guard current, cardActionIsCurrent(action) else { return nil }
            // Cancel older reads without invalidating other item actions from
            // this same displayed list. Keep the accepted opaque continuation.
            generation += 1
            task?.cancel(); task = nil; isLoading = false
            if action.target == kind && !action.included {
                items.removeAll { $0.contentId == action.contentId }
            } else if let index = items.firstIndex(where: { $0.contentId == action.contentId }) {
                let old = items[index].userState
                items[index].userState = MediaItemUserState(played: old?.played ?? false,
                    isFavorite: action.target == .favorites ? action.included : old?.isFavorite ?? false,
                    inWatchlist: action.target == .watchlist ? action.included : old?.inWatchlist ?? false)
            }
            ResponseCache.shared.remove(CacheKey.itemUserState(action.contentId))
            ResponseCache.shared.remove(action.target == .favorites ? CacheKey.favorites : CacheKey.watchlist)
            cacheCards()
            return true
        } catch {
            let current = await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: action.auth) != nil
            guard current, cardActionIsCurrent(action) else { return nil }
            return false
        }
    }


    private struct CachedCards {
        let items: [BrowseItem]
        let auth: CapturedOrdinaryRequestAuth
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
        cardGeneration += 1
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
        guard let auth = displayedAuth else { return }
        ResponseCache.shared.set(CachedCards(items: Array(items.prefix(50)), auth: auth), for: cacheKey)
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
        guard let auth = captured, let requestedProfile = auth.profileId, !requestedProfile.isEmpty else {
            items = []; displayedAuth = nil; continuation = nil; hasMore = false
            error = ErrorState(HTTPError.requestIdentityChanged)
            return
        }
        guard requestGeneration == generation else { return }
        if displayedAuth != auth {
            items = []
            if !reset {
                continuation = nil; hasMore = false
                error = ErrorState(HTTPError.requestIdentityChanged)
                return
            }
        }
        displayedAuth = auth
        if reset, items.isEmpty,
           let cached: CachedCards = ResponseCache.shared.get(cacheKey),
           cached.auth == auth {
            items = cached.items
        }
        error = nil
        let cursor = reset ? nil : continuation
        let api = self.api
        let kind = self.kind
        let request = Task {
            if let cursor { return try await api.nextPersonalListPage(cursor) }
            await ImageSizeCapability.shared.refresh()
            return try await api.personalList(kind: kind, imageSize: ImageSizeCapability.shared.requestQuery["image_size"], auth: auth)
        }
        task = request
        do {
            let result = try await request.value
            guard requestGeneration == generation, !Task.isCancelled else { return }
            let current = await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
            guard current, result.auth == auth, requestGeneration == generation,
                  !Task.isCancelled else { throw HTTPError.requestIdentityChanged }
            var seen = Set(reset ? [] : items.map(\.contentId))
            let incoming = result.value.items.filter { seen.insert($0.contentId).inserted }
            if reset { items = incoming } else { items.append(contentsOf: incoming) }
            continuation = result.continuation
            hasMore = result.continuation != nil
            if reset { cacheCards() }
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            let current = await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
            guard requestGeneration == generation, !Task.isCancelled else { return }
            if current {
                self.error = ErrorState(error)
            } else {
                items = []
                displayedAuth = nil
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

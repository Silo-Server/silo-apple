import Foundation

/// Membership actions for complete collection and recommendation reads. Commands
/// are consumed once; an unknown outcome remains held for this displayed owner.
@Observable
@MainActor
final class ReadOwnedMembershipModel: CatalogMembershipModel {
    private(set) var displayedRead: CatalogCardOwner?
    private(set) var cardGeneration = 0
    private(set) var mutationRevision = 0
    private(set) var error: ErrorState?
    private var states: [String: MediaItemUserState] = [:]
    private var prepared: [UUID: CatalogMembershipAction] = [:]
    private var unresolved: [UUID: CatalogMembershipAction] = [:]
    private let api: APIv2Client
    private let tokens: TokenStore
    private var cacheKeys: [String] = []

    init(api: APIv2Client = SiloAPI.shared.v2, tokens: TokenStore = .shared) {
        self.api = api
        self.tokens = tokens
    }

    func publish(owner: CatalogCardOwner?, rows: [(String, MediaItemUserState?)], cacheKeys: [String] = []) {
        cardGeneration += 1
        displayedRead = owner
        states = [:]
        for (id, state) in rows { states[id] = state }
        self.cacheKeys = cacheKeys
        prepared = [:]
        // A new read is not proof of an earlier mutation's terminal outcome.
        if unresolved.isEmpty { error = nil }
    }

    func userState(for id: String) -> MediaItemUserState? { states[id] }

    func prepareCardAction(contentId: String, target: APIv2PersonalListKind, included: Bool) -> CatalogMembershipAction? {
        guard let owner = displayedRead, states[contentId] != nil else { return nil }
        let held = Array(prepared.values) + Array(unresolved.values)
        guard !held.contains(where: {
            $0.contentId == contentId && $0.target == target && Self.sameOwner($0.owner, owner)
        }) else { return nil }
        let action = CatalogMembershipAction(id: UUID(), contentId: contentId, owner: owner,
            generation: cardGeneration, target: target, included: included)
        prepared[action.id] = action
        return action
    }

    private static func sameOwner(_ a: CatalogCardOwner, _ b: CatalogCardOwner) -> Bool {
        a.auth.account == b.auth.account && a.auth.credentialOwner == b.auth.credentialOwner
            && a.auth.profileId == b.auth.profileId && a.auth.profileToken == b.auth.profileToken
    }

    private func isDisplayed(_ action: CatalogMembershipAction) -> Bool {
        displayedRead == action.owner && cardGeneration == action.generation && states[action.contentId] != nil
    }

    func performCardAction(_ action: CatalogMembershipAction) async -> Bool? {
        // Consume synchronously before the first suspension, including duplicate invocations.
        guard let command = prepared.removeValue(forKey: action.id) else { return nil }
        unresolved[command.id] = command
        let mayDispatch = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: command.owner.auth) != nil
        guard mayDispatch, isDisplayed(command), !Task.isCancelled else {
            unresolved[command.id] = nil
            return nil
        }
        do {
            switch command.target {
            case .favorites:
                try await api.setFavoriteMembership(id: command.contentId, included: command.included, auth: command.owner.auth)
            case .watchlist:
                try await api.setWatchlistMembership(id: command.contentId, included: command.included, auth: command.owner.auth)
            }
            unresolved[command.id] = nil
            let mayPublish = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: command.owner.auth) != nil
            guard mayPublish, isDisplayed(command), !Task.isCancelled else { return nil }
            mutationRevision += 1
            if let old = states[command.contentId] {
                states[command.contentId] = MediaItemUserState(played: old.played,
                    isFavorite: command.target == .favorites ? command.included : old.isFavorite,
                    inWatchlist: command.target == .watchlist ? command.included : old.inWatchlist)
            }
            for key in cacheKeys + [CacheKey.itemUserState(command.contentId), CacheKey.homeSections,
                command.target == .favorites ? CacheKey.favorites : CacheKey.watchlist] {
                ResponseCache.shared.remove(key)
            }
            return true
        } catch {
            let mayPublish = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: command.owner.auth) != nil
            guard mayPublish, isDisplayed(command), !Task.isCancelled else { return nil }
            // No automatic retry, compensation or rebasing after an uncertain dispatch.
            self.error = ErrorState(ReadOwnedMembershipError.outcomeUnknown)
            return false
        }
    }
}

private enum ReadOwnedMembershipError: LocalizedError {
    case outcomeUnknown
    var errorDescription: String? {
        "The membership change could not be confirmed. It has not been sent again."
    }
}

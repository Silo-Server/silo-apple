import SwiftUI

struct SectionReadOwner: Equatable {
    let auth: CapturedOrdinaryRequestAuth
    let cacheKey: String
}

private struct SectionReadOwnerKey: EnvironmentKey {
    static let defaultValue: SectionReadOwner? = nil
}

extension EnvironmentValues {
    var sectionReadOwner: SectionReadOwner? {
        get { self[SectionReadOwnerKey.self] }
        set { self[SectionReadOwnerKey.self] = newValue }
    }
}

/// Single-dispatch watched actions captured from an existing section response.
@Observable
@MainActor
final class SectionWatchedActions {
    private(set) var owner: SectionReadOwner?
    private(set) var generation = 0
    private(set) var errorMessage: String?
    private var pending: [(String, SectionReadOwner)] = []
    private let api: APIv2Client
    private let tokens: TokenStore

    init(api: APIv2Client = SiloAPI.shared.v2, tokens: TokenStore = .shared) {
        self.api = api
        self.tokens = tokens
    }

    func display(_ owner: SectionReadOwner?) {
        guard self.owner != owner else { return }
        self.owner = owner
        generation += 1
        errorMessage = nil
    }

    func setWatched(contentId: String, played: Bool, owner captured: SectionReadOwner) async -> Bool {
        guard owner == captured, !pending.contains(where: {
            $0.0 == contentId && $0.1.auth.account == captured.auth.account
                && $0.1.auth.credentialOwner == captured.auth.credentialOwner
                && $0.1.auth.profileId == captured.auth.profileId
                && $0.1.auth.profileToken == captured.auth.profileToken
        }) else { return false }
        let run = generation
        // Install the barrier before any suspension. A later explicit tap is not a retry.
        pending.append((contentId, captured))
        let current = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: captured.auth) != nil
        guard current, owner == captured, run == generation, !Task.isCancelled else {
            pending.removeAll { $0.0 == contentId && $0.1 == captured }
            return false
        }
        do {
            try await api.setWatchedState(id: contentId, included: played, auth: captured.auth)
            pending.removeAll { $0.0 == contentId && $0.1 == captured }
            let current = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: captured.auth) != nil
            guard current, owner == captured, run == generation, !Task.isCancelled else { return false }
            ResponseCache.shared.remove(captured.cacheKey)
            ResponseCache.shared.remove(CacheKey.itemUserState(contentId))
            NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
            return true
        } catch {
            let current = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: captured.auth) != nil
            guard current, owner == captured, run == generation, !Task.isCancelled else { return false }
            errorMessage = "The watched change could not be confirmed. It has not been sent again."
            return false
        }
    }
}

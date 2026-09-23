import Foundation
import os

/// The three per-item personal flags a viewer can change from a card or a
/// detail page. Each maps to one v2 mutation pair.
enum PersonalStateTarget: String, Sendable {
    case favorite
    case watchlist
    case watched
}

/// A mutation that was sent but never answered. Every v2 favorite, watchlist
/// and watched write is `non_retryable`, so Silo cannot tell whether the
/// server applied it and must not send it again on its own. The change stays
/// held for its owner, item and flag until the viewer discards it.
struct PersonalStateHeldChange: Identifiable, Equatable, Sendable {
    let id: UUID
    let owner: CapturedOrdinaryRequestAuth
    let target: PersonalStateTarget
    let contentId: String
    let included: Bool
}

/// How one dispatched personal-state mutation ended (plan §9 failure model).
enum PersonalStateOutcome: Equatable {
    /// The server answered 204 under the captured owner.
    case applied
    /// Never sent, or the server answered with a non-2xx status. Nothing was
    /// applied; revert and tell the viewer once. The requirement is set when
    /// the server or this app needs an update, so retrying cannot succeed.
    case failed(UpdateRequirement?)
    /// Sent with no answer, or an earlier change to the same flag is still
    /// held. Nothing is re-sent; the viewer can discard the held change.
    case held(PersonalStateHeldChange)
    /// The owner changed, or another change to the same flag is in flight.
    /// Nothing was applied locally and there is nothing to report.
    case skipped
}

enum PersonalStateMutationError: LocalizedError {
    case held(PersonalStateHeldChange)
    /// A change to the same item and flag is already in flight.
    case inFlight

    var errorDescription: String? {
        switch self {
        case .held: return PersonalStateNotice.heldMessage
        case .inFlight: return "Another change to this item is still being saved."
        }
    }
}

/// Unconfirmed personal-state mutations for the current session, keyed by
/// owner, flag and item. In memory only: a relaunch re-reads the item from
/// the server, which is the authority on what actually landed.
@MainActor
final class PersonalStateHolds {
    static let shared = PersonalStateHolds()

    private var changes: [PersonalStateHeldChange] = []
    private var inFlight: Set<String> = []

    func change(for target: PersonalStateTarget, contentId: String,
                owner: CapturedOrdinaryRequestAuth) -> PersonalStateHeldChange? {
        changes.first {
            $0.target == target && $0.contentId == contentId && $0.owner.sameCredentialIdentity(as: owner)
        }
    }

    func hold(_ change: PersonalStateHeldChange) {
        changes.removeAll {
            $0.target == change.target && $0.contentId == change.contentId
                && $0.owner.sameCredentialIdentity(as: change.owner)
        }
        changes.append(change)
    }

    /// Releases the hold and drops every cache that could still show the
    /// guessed state, so the next read comes from the server.
    func discard(_ change: PersonalStateHeldChange) {
        changes.removeAll { $0.id == change.id }
        PersonalStateSync.invalidateItemState(contentId: change.contentId)
    }

    /// Sign-out and profile or server switches drop every hold.
    func reset() {
        changes.removeAll()
    }

    fileprivate func begin(_ key: String) -> Bool {
        inFlight.insert(key).inserted
    }

    fileprivate func end(_ key: String) {
        inFlight.remove(key)
    }
}

/// The one dispatcher for favorite, watchlist and watched writes. It sends
/// each change once through `APIv2Client` under a captured owner, holds an
/// unanswered change instead of replaying it, and returns only after the
/// owner has been checked again, so callers can apply the result locally.
@MainActor
enum PersonalStateSync {
    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "personal-state")

    /// Throws `PersonalStateMutationError.held` for an unanswered or already
    /// held change, `HTTPError.requestIdentityChanged`/`.authorityChanged`
    /// when the owner is no longer current, and the transport or server error
    /// for a definite failure. Returning normally means the server applied it.
    static func set(
        _ target: PersonalStateTarget,
        contentId: String,
        to included: Bool,
        owner suppliedOwner: CapturedOrdinaryRequestAuth? = nil,
        api: APIv2Client = SiloAPI.shared.apiV2Client,
        tokens: TokenStore = .shared,
        holds suppliedHolds: PersonalStateHolds? = nil
    ) async throws {
        let holds = suppliedHolds ?? .shared
        let captured: CapturedOrdinaryRequestAuth?
        if let suppliedOwner {
            captured = suppliedOwner
        } else {
            captured = await tokens.captureOrdinaryRequestAuth()
        }
        guard let owner = captured else { throw HTTPError.requestIdentityChanged }
        if let held = holds.change(for: target, contentId: contentId, owner: owner) {
            throw PersonalStateMutationError.held(held)
        }
        let key = "\(target.rawValue)\u{1F}\(contentId)"
        guard holds.begin(key) else { throw PersonalStateMutationError.inFlight }
        defer { holds.end(key) }

        do {
            switch target {
            case .favorite:
                try await api.setFavoriteMembership(id: contentId, included: included, auth: owner)
            case .watchlist:
                try await api.setWatchlistMembership(id: contentId, included: included, auth: owner)
            case .watched:
                try await api.setWatchedState(id: contentId, included: included, auth: owner)
            }
        } catch {
            let delivery = classify(error)
            logger.error("""
                \(target.rawValue, privacy: .public) \(included ? "set" : "clear", privacy: .public) \
                \(delivery.rawValue, privacy: .public): \(String(describing: error), privacy: .private)
                """)
            guard delivery == .unconfirmed else { throw error }
            let change = PersonalStateHeldChange(
                id: UUID(), owner: owner, target: target, contentId: contentId, included: included
            )
            holds.hold(change)
            throw PersonalStateMutationError.held(change)
        }
        // The client's fence checked the owner when the response arrived; check
        // again after the hop back here, before any caller writes local state.
        guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: owner) != nil else {
            throw HTTPError.authorityChanged
        }
    }

    static func outcome(for error: Error) -> PersonalStateOutcome {
        if let mutation = error as? PersonalStateMutationError {
            switch mutation {
            case .held(let change): return .held(change)
            case .inFlight: return .skipped
            }
        }
        return classify(error) == .ownerChanged ? .skipped : .failed(UpdateRequirement(error))
    }

    static func outcome(_ operation: () async throws -> Void) async -> PersonalStateOutcome {
        do {
            try await operation()
            return .applied
        } catch {
            return outcome(for: error)
        }
    }

    enum Delivery: String {
        /// A response arrived, or the request never left the device.
        case definite
        /// The owner changed; nothing is applied under the new one.
        case ownerChanged = "owner_changed"
        /// The request may have reached the server without an answer.
        case unconfirmed
    }

    static func classify(_ error: Error) -> Delivery {
        if let http = error as? HTTPError {
            switch http {
            case .requestIdentityChanged, .authorityChanged:
                return .ownerChanged
            case .serverUrlNotConfigured, .invalidURL, .encodingFailed, .http, .decodingFailed:
                return .definite
            case .network(let underlying):
                return wasNeverSent(underlying) ? .definite : .unconfirmed
            case .invalidResponse:
                return .unconfirmed
            }
        }
        // Every APIv2Error is either a refusal before dispatch (`gate()`) or a
        // decoded server answer.
        if error is APIv2Error { return .definite }
        // Cancellation and anything unrecognized may have left the device.
        return .unconfirmed
    }

    /// Transport failures that happen before any request byte reaches the
    /// server: no route, no name, no connection, or a failed TLS handshake.
    private static func wasNeverSent(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .callIsActive, .badURL, .unsupportedURL,
             .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            return true
        default:
            return false
        }
    }

    /// Drops every cached read that can show an item's personal flags.
    static func invalidateItemState(contentId: String, seriesId: String? = nil) {
        ResponseCache.shared.removeItemMetadata(contentId: contentId)
        if let seriesId {
            ResponseCache.shared.removeItemMetadata(contentId: seriesId)
        }
        StartupContentPrefetcher.invalidateHomeSectionsInFlight()
        for key in [CacheKey.homeSections, CacheKey.recommendations, CacheKey.favorites,
                    CacheKey.watchlist, CacheKey.history] {
            ResponseCache.shared.remove(key)
        }
        for prefix in ["browse:", "tvlibrary:", "library:", "collection:"] {
            ResponseCache.shared.removeAll(withPrefix: prefix)
        }
        #if os(tvOS)
        ItemDetailCache.shared.markStaleFamily(contentId: contentId)
        #endif
    }
}

import Foundation

/// Whether two saved addresses reach one backend. A `server_id` is
/// self-asserted, so it only picks the addresses to ask. A login session ID
/// is a random UUID that only the backend that issued it knows: when the
/// holder's backend lists the other address's own session, both reach one
/// deployment. Each address is asked only about its own account's sessions,
/// with its own credentials, so no token ever goes to the other address. An
/// address that is not that backend, or a proxy for it, cannot list the
/// session unless it signs in to the holder with the person's own
/// credentials, which already give it the account.
///
/// Used by the push registrar to share one installation record, and by
/// `ServerRegistry.mergeDuplicateServers` to fold one server saved under two
/// addresses into one.
enum LoginSessionProof {
    enum Outcome: String, Codable, Sendable {
        /// The holder's backend lists the other address's session.
        case proven
        /// Both answered, and the holder's backend does not know the session.
        case disproven
        /// A read failed, or there was no session to compare.
        case unavailable
    }

    /// One page of an account's login sessions (`listSessions`), read at
    /// that account's own address with its own session.
    typealias Sessions = @Sendable (_ cursor: String?) async throws -> APIv2LoginSessionPage

    /// Pages of the holder's sessions read at most.
    static let maximumSessionPages = 10

    static func check(own: Sessions, holder: Sessions) async -> Outcome {
        guard let id = try? await own(nil).currentSession?.id, !id.isEmpty else { return .unavailable }
        var cursor: String?
        for _ in 0..<maximumSessionPages {
            guard let page = try? await holder(cursor) else { return .unavailable }
            // The holder's own session is never the other address's.
            if page.items.contains(where: { $0.id == id && !$0.current }) { return .proven }
            guard let next = page.page?.nextCursor, page.page?.hasMore == true else { return .disproven }
            cursor = next
        }
        return .unavailable
    }
}

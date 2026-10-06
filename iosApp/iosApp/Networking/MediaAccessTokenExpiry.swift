import Foundation
import Synchronization

/// An unverified JWT payload is only a refresh scheduling hint. The server
/// remains the authority; opaque tokens continue to use bounded 401 recovery.
enum MediaAccessTokenExpiry {
    static func shouldRefresh(_ token: String, now: Date) -> Bool {
        guard let claims = claims(token) else { return false }
        let lifetime = claims.issuedAt.map { claims.expiry - $0 }
        let margin = lifetime.map { min(60, max(1, $0 * 0.1)) } ?? 5
        return now.timeIntervalSince1970 >= claims.expiry - margin
    }

    static func isExpired(_ token: String, now: Date) -> Bool {
        guard let expiry = claims(token)?.expiry else { return false }
        return now.timeIntervalSince1970 >= expiry
    }

    private struct Claims {
        let expiry: Double
        /// Present only when finite and before `expiry`.
        let issuedAt: Double?
    }

    /// The last token parsed and its claims. Every request checks the same
    /// token until it rotates, so this skips re-parsing the payload.
    private static let lastParsed = Mutex<(token: String, claims: Claims?)?>(nil)

    private static func claims(_ token: String) -> Claims? {
        if let cached = lastParsed.withLock({ $0 }), cached.token == token { return cached.claims }
        let parsed = parseClaims(token)
        lastParsed.withLock { $0 = (token, parsed) }
        return parsed
    }

    private static func parseClaims(_ token: String) -> Claims? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = claims["exp"] as? Double, expiry.isFinite else { return nil }
        let issuedAt = (claims["iat"] as? Double).flatMap { $0.isFinite && $0 < expiry ? $0 : nil }
        return Claims(expiry: expiry, issuedAt: issuedAt)
    }
}

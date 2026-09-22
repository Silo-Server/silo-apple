import Foundation

/// An unverified JWT payload is only a refresh scheduling hint. The server
/// remains the authority; opaque tokens continue to use bounded 401 recovery.
enum MediaAccessTokenExpiry {
    static func shouldRefresh(_ token: String, now: Date) -> Bool {
        guard let claims = claims(token), let expiry = claims["exp"] else { return false }
        let lifetime = claims["iat"].map { expiry - $0 }
        let margin = lifetime.map { min(60, max(1, $0 * 0.1)) } ?? 5
        return now.timeIntervalSince1970 >= expiry - margin
    }

    static func isExpired(_ token: String, now: Date) -> Bool {
        guard let expiry = claims(token)?["exp"] else { return false }
        return now.timeIntervalSince1970 >= expiry
    }

    private static func claims(_ token: String) -> [String: Double]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = claims["exp"] as? Double, expiry.isFinite else { return nil }
        var result = ["exp": expiry]
        if let issuedAt = claims["iat"] as? Double, issuedAt.isFinite, issuedAt < expiry {
            result["iat"] = issuedAt
        }
        return result
    }
}

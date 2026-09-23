import Foundation

/// Body for POST /api/v2/auth/login (`LoginInputBody`). A nil `provider`
/// is omitted, which selects the server's default provider.
struct LoginRequest: Codable {
    let username: String
    let password: String
    let provider: String?

    init(username: String, password: String, provider: String? = nil) {
        self.username = username
        self.password = password
        self.provider = provider
    }
}

/// Body for POST /api/v2/auth/refresh (`RefreshSessionInputBody`).
struct RefreshRequest: Codable {
    let refreshToken: String

    init(refreshToken value: String) {
        refreshToken = value
    }

    init(_ value: String) {
        refreshToken = value
    }
}

/// Response from POST /api/v2/auth/refresh (`RefreshedTokens`).
struct RefreshResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int64
}

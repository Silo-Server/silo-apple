import Foundation

/// Body for POST /api/v2/auth/login (`LoginInputBody`). No `provider` is
/// sent, which selects the server's default provider.
struct LoginRequest: Encodable {
    let username: String
    let password: String
}

/// Body for POST /api/v2/auth/refresh (`RefreshSessionInputBody`).
struct RefreshRequest: Encodable {
    let refreshToken: String
}

/// Response from POST /api/v2/auth/refresh (`RefreshedTokens`).
struct RefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String
}

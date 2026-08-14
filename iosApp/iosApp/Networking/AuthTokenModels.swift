import Foundation

/// Body for POST /api/v1/auth/login.
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

/// Response from POST /api/v1/auth/login.
struct LoginResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int64
    let user: AuthUser
}

/// Wire-format user object returned inside auth responses.
///
/// Distinct from ``UserInfo`` (used by the rest of the app) because the
/// server wire shape has more fields than the reduced `UserInfo` the UI
/// needs. `ContinuumAPI` maps between the two at the API boundary.
struct AuthUser: Codable {
    let id: Int
    let username: String
    let email: String
    let role: String
    let downloadAllowed: Bool?
    let impersonation: ImpersonationInfo?
}

struct ImpersonationInfo: Codable {
    let active: Bool
    let impersonatorUserId: Int
    let impersonatorUsername: String
}

/// Body for POST /api/v1/auth/refresh.
struct RefreshRequest: Codable {
    let refreshToken: String

    init(refreshToken value: String) {
        refreshToken = value
    }

    init(_ value: String) {
        refreshToken = value
    }
}

/// Response from POST /api/v1/auth/refresh.
struct RefreshResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int64
}

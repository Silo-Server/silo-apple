import Foundation

/// `GET /api/v2/capabilities/password-reset`: whether the sign-in screen may
/// offer "Forgot password?". `available` only when an admin turned
/// self-service reset on and the server can email a link; `disabled` or
/// `not_configured` otherwise.
struct APIv2PasswordResetCapability: Decodable, Sendable {
    let state: String
}

/// Self-service password reset on the v2 wire. The server emails the account a
/// link to its web `/reset-password/{token}` screen, so the new password is
/// chosen in the browser, never in the app. See silo-server
/// `docs/auth-api.md`, "Self-service password reset".
///
/// The sign-in name or email travels only in the request body, which the
/// transport never logs.
extension APIv2Client {
    static let passwordResetCapabilityPath = "/api/v2/capabilities/password-reset"
    static let passwordResetsPath = "/api/v2/password-resets"

    /// `getPasswordResetCapability` for `serverURL`, without credentials.
    func passwordResetCapability(serverURL: String) async throws -> APIv2PasswordResetCapability {
        try await mapErrors {
            try await http.getUnauthenticated(serverURL: serverURL, path: Self.passwordResetCapabilityPath,
                quietStatuses: [404])
        }
    }

    /// Whether `serverURL` emails reset links on request. False on a server
    /// that predates the capability (a 404); nil when the read failed for any
    /// other reason, so a background refresh can keep what it knew.
    func passwordResetAvailable(serverURL: String) async -> Bool? {
        do {
            return try await passwordResetCapability(serverURL: serverURL).state == "available"
        } catch APIv2Error.serverUpdateRequired {
            return false
        } catch APIv2Error.httpStatus(404) {
            return false
        } catch APIv2Error.problem(let problem) where problem.status == 404 {
            return false
        } catch {
            return nil
        }
    }

    /// `requestPasswordReset` for the account `login` names, by username or
    /// email. The server answers 202 whether or not an account matched, so
    /// the answer says nothing about which accounts exist. Public and
    /// `non_retryable`: one dispatch with no bearer, like `login`.
    func requestPasswordReset(login: String) async throws {
        try await gate()
        let body = try JSONSerialization.data(withJSONObject: ["login": login])
        let response = try await mapErrors {
            try await http.requestData(method: "POST", path: Self.passwordResetsPath, body: body,
                quietStatuses: [409, 429])
        }
        guard response.statusCode == 202 else { throw APIv2Error.incompleteAuthResponse }
    }
}

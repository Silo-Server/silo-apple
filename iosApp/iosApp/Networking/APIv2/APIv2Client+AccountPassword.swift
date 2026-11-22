import Foundation

/// `GET /api/v2/account/password/capability`: whether this session may change
/// the account password, and the server's limits for a new one.
struct APIv2PasswordCapability: Decodable, Sendable {
    let state: String
    /// Absent unless `state` is `available`.
    let allowed: Bool?
    /// Fewest characters a new password may have.
    let minimumPasswordLength: Int?
    /// Most UTF-8 bytes a new password may have.
    let maximumPasswordBytes: Int?
}

/// The account's own password on the v2 wire. A session whose account holds
/// a temporary password (`password_change_required`) may call both, with no
/// profile selected; see silo-server `docs/auth-api.md`, "Temporary passwords".
///
/// Neither password is ever logged: they travel only in the request body.
extension APIv2Client {
    static let accountPasswordPath = "/api/v2/account/password"
    static let accountPasswordCapabilityPath = "/api/v2/account/password/capability"

    /// `getAccountPasswordCapability` for the account, with no profile declared.
    func passwordCapability(expectedAccount: RefreshAccountIdentity) async throws -> APIv2PasswordCapability {
        try await accountJSON(method: "GET", path: Self.accountPasswordCapabilityPath, status: 200,
            expectedAccount: expectedAccount)
    }

    /// `changePassword`: replaces the account password after checking the
    /// current one. 204 on success. Sent once: a replay would spend another
    /// attempt from the server's password-change budget. The access token
    /// that sent it keeps any temporary-password restriction until the
    /// session is refreshed.
    func changePassword(current: String, new: String, expectedAccount: RefreshAccountIdentity) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["current_password": current, "new_password": new])
        let response = try await accountRequest(method: "POST", path: Self.accountPasswordPath, body: body,
            expectedAccount: expectedAccount)
        guard response.statusCode == 204 else { throw APIv2Error.incompleteAuthResponse }
    }
}

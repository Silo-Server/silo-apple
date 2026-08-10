import Foundation

protocol InvitationClaimServing: Sendable {
    func lookupInvitation(
        endpoint: ServerEndpoint,
        token: String
    ) async throws -> InvitationLookupResponse

    func acceptInvitation(
        endpoint: ServerEndpoint,
        token: String,
        password: String
    ) async throws -> String
}

extension AuthService: InvitationClaimServing {}

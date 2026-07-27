import Foundation

/// Emailed-invitation claim flow (server: /api/v1/invitations/{token}).
/// The invitee's email address is their username; the claim screen asks for
/// a password and nothing else.
struct InvitationLookupResponse: Codable {
    let email: String
    let inviterName: String?
    let serverName: String
    let expiresAt: String
    let showTour: Bool?
}

/// Body for POST /api/v1/invitations/{token}/accept.
struct AcceptInvitationRequest: Codable {
    let password: String
}

import Foundation

/// Claim flow for an emailed invitation deep link (silo://invite?server=…&token=…).
/// The link carries the server and single-use token, so the invitee chooses
/// only a password; their email address becomes their username.
@Observable
@MainActor
class InviteClaimViewModel {
    var isLoadingInvitation: Bool = true
    var invitation: InvitationLookupResponse?
    var invitationInvalid: Bool = false
    var invitationLoadError: String?
    var password: String = ""
    var confirmPassword: String = ""
    var isSubmitting: Bool = false
    var error: String?

    private let auth: any InvitationClaimServing
    private var endpoint: ServerEndpoint?
    private var token: String = ""

    init(auth: any InvitationClaimServing = AuthService.shared) {
        self.auth = auth
    }

    func load(endpoint: ServerEndpoint, token: String) async {
        guard self.token != token || invitation == nil else { return }
        self.endpoint = endpoint
        self.token = token
        isLoadingInvitation = true
        invitationInvalid = false
        invitationLoadError = nil
        invitation = nil
        do {
            invitation = try await auth.lookupInvitation(endpoint: endpoint, token: token)
        } catch {
            if Self.isPermanentlyInvalid(error) {
                invitationInvalid = true
            } else {
                invitationLoadError = "Silo could not reach this invitation server. Check your connection and try again."
            }
        }
        isLoadingInvitation = false
    }

    func claim(router: AppRouter) async {
        guard password.count >= 8 else {
            error = "Password must be at least 8 characters."
            return
        }
        guard password == confirmPassword else {
            error = "Passwords do not match."
            return
        }

        isSubmitting = true
        error = nil
        defer { isSubmitting = false }

        do {
            guard let endpoint else { return }
            let claimedUserId = try await auth.acceptInvitation(
                endpoint: endpoint,
                token: token,
                password: password
            )
            if invitation?.showTour == false,
               let serverId = ServerRegistry.shared.activeServerId {
                OnboardingTourSuppression.set(for: serverId, userId: claimedUserId)
            }
            _ = try? await StartupContentPrefetcher.fetchProfiles()
            router.showProfileSelection(journeyLabels: ["Server", "Password", "Household"])
        } catch {
            self.error = "Could not create your account. The invitation may have expired or been used already."
        }
    }

    private static func isPermanentlyInvalid(_ error: Error) -> Bool {
        guard let httpError = error as? HTTPError,
              let statusCode = httpError.statusCode else {
            return false
        }
        return statusCode == 404 || statusCode == 410
    }
}

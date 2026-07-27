import Foundation

/// Claim flow for an emailed invitation deep link (silo://invite?server=…&token=…).
/// The link carries the server and single-use token, so the invitee chooses
/// only a password; their email address becomes their username.
@Observable
class InviteClaimViewModel {
    var isLoadingInvitation: Bool = true
    var invitation: InvitationLookupResponse?
    var invitationInvalid: Bool = false
    var password: String = ""
    var confirmPassword: String = ""
    var isSubmitting: Bool = false
    var error: String?

    private let auth = AuthService.shared
    private var serverUrl: String = ""
    private var token: String = ""

    func load(serverUrl: String, token: String) async {
        guard self.token != token || invitation == nil else { return }
        self.serverUrl = serverUrl
        self.token = token
        isLoadingInvitation = true
        invitationInvalid = false
        do {
            invitation = try await auth.lookupInvitation(serverUrl: serverUrl, token: token)
        } catch {
            invitationInvalid = true
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
            try await auth.acceptInvitation(serverUrl: serverUrl, token: token, password: password)
            await StartupContentPrefetcher.prefetchProfiles()
            router.showProfileSelection()
        } catch {
            self.error = "Could not create your account. The invitation may have expired or been used already."
        }
    }
}

#if os(iOS)
import Foundation

struct ServerInvitationNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
@Observable
final class ServerInvitationCoordinator {
    static let shared = ServerInvitationCoordinator()

    var pendingInvitation: ServerInvitation?
    private(set) var isConnecting = false
    private(set) var connectionError: String?
    var notice: ServerInvitationNotice?

    @ObservationIgnored private var pendingSignupInviteCode: String?
    @ObservationIgnored private let serverChecker: (String) async throws -> SetupStatus
    @ObservationIgnored private let signupStatusChecker: () async throws -> Bool

    init(
        serverChecker: @escaping (String) async throws -> SetupStatus = {
            try await AuthService.shared.checkServer(url: $0)
        },
        signupStatusChecker: @escaping () async throws -> Bool = {
            let status: SignupStatus = try await ContinuumAPI.shared.get("/api/v1/auth/signup")
            return status.enabled
        }
    ) {
        self.serverChecker = serverChecker
        self.signupStatusChecker = signupStatusChecker
    }

    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard let invitation = try? ServerInvitationParser.parse(url) else { return false }
        pendingInvitation = invitation
        connectionError = nil
        notice = nil
        return true
    }

    func cancel() {
        guard !isConnecting else { return }
        pendingInvitation = nil
        pendingSignupInviteCode = nil
        connectionError = nil
    }

    /// Contacts and saves the proposed server only after the confirmation UI
    /// invokes this method. The invitation stays pending during both probes.
    @discardableResult
    func confirm(router: AppRouter) async -> Bool {
        guard let invitation = pendingInvitation, !isConnecting else { return false }

        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }

        do {
            let setupStatus = try await serverChecker(invitation.serverURL.absoluteString)
            router.popToRoot()
            router.authState = .needsLogin

            if setupStatus.needsSetup {
                pendingSignupInviteCode = nil
                pendingInvitation = nil
                router.navigate(to: .serverNeedsSetup)
                return true
            }

            guard invitation.action == .signup else {
                pendingSignupInviteCode = nil
                pendingInvitation = nil
                return true
            }

            let signupEnabled = (try? await signupStatusChecker()) ?? false
            guard signupEnabled else {
                pendingSignupInviteCode = nil
                pendingInvitation = nil
                notice = ServerInvitationNotice(
                    title: "Sign up unavailable",
                    message: "This server is not accepting native signups right now. You can still sign in with an existing account."
                )
                return true
            }

            pendingSignupInviteCode = invitation.inviteCode
            pendingInvitation = nil
            await Task.yield()
            router.navigate(to: .signup)
            return true
        } catch {
            connectionError = "Silo could not verify this server. Check the address and try again."
            return false
        }
    }

    /// Transfers the secret into SignupView exactly once, after its native
    /// navigation destination has appeared.
    func consumeSignupInviteCode() -> String? {
        defer { pendingSignupInviteCode = nil }
        return pendingSignupInviteCode
    }
}
#endif

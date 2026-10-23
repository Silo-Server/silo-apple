import Foundation

/// "Forgot password?" from the login screen: asks the server to email the
/// account a reset link. The link opens the server's web reset screen, where
/// the account holder chooses a new password, then signs in here with it.
/// Mirrors the web client's `ForgotPassword` page; see silo-server
/// `docs/auth-api.md`, "Self-service password reset".
@MainActor
@Observable
final class ForgotPasswordModel {
    enum Phase: Equatable {
        case editing
        case sending
        /// The server accepted the request for `login`. It answers alike
        /// whether or not an account matched.
        case sent(login: String)
        /// The server stopped offering self-service reset after the login
        /// screen read its capability.
        case unavailable
    }

    var login: String
    private(set) var phase: Phase = .editing
    /// Settable so tests can stage the error the form shows.
    var error: FormError?

    private let auth: AuthService

    /// `login` starts as whatever the login screen's username field held.
    init(login: String = "", auth: AuthService = .shared) {
        self.login = login.trimmingCharacters(in: .whitespacesAndNewlines)
        self.auth = auth
    }

    var isSending: Bool { phase == .sending }

    /// Sends the request once. A failure leaves the form open to send again:
    /// a repeat is harmless, since the server mails an account at most one
    /// link every few minutes and each new link replaces the last.
    func send() async {
        guard phase == .editing else { return }
        let login = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else {
            error = FormError("Enter your username or email.")
            return
        }
        phase = .sending
        error = nil
        do {
            try await auth.requestPasswordReset(login: login)
            phase = .sent(login: login)
        } catch {
            if Self.isUnavailable(error) {
                phase = .unavailable
            } else {
                phase = .editing
                self.error = FormError(Self.message(for: error))
            }
        }
    }

    /// The server refused the request itself: an admin turned self-service
    /// reset off, or its email setup went away (`409 capability_*`).
    nonisolated static func isUnavailable(_ error: Error) -> Bool {
        guard case APIv2Error.problem(let problem) = error else { return false }
        return problem.status == 409
    }

    nonisolated static func message(for error: Error) -> String {
        switch error {
        case APIv2Error.problem(let problem) where problem.status == 429:
            return rateLimitedMessage
        case APIv2Error.httpStatus(429):
            return rateLimitedMessage
        case APIv2Error.incompleteAuthResponse:
            // A success other than 202, such as a captive portal's page; the
            // error's own copy is about sign-in.
            return "Couldn't send the request. Try again."
        default:
            return ErrorState(error).message
        }
    }

    nonisolated static let rateLimitedMessage = "Too many requests from this network. Wait a minute, then try again."
}

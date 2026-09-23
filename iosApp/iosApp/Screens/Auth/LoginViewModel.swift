import Foundation

@Observable
class LoginViewModel {
    var username: String = ""
    var password: String = ""
    var isLoading: Bool = false
    var error: String?

    private let auth = AuthService.shared

    /// Authenticate with username and password.
    func login(router: AppRouter) async {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "Please enter your username."
            return
        }
        guard !password.isEmpty else {
            error = "Please enter your password."
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            try await auth.login(username: username, password: password)
            await StartupContentPrefetcher.prefetchProfiles()
            router.showProfileSelection()
        } catch let loginError {
            self.error = Self.message(for: loginError)
        }
    }

    /// The sign-in failure as the login form shows it. v2 answers with
    /// problem documents, so the status says what went wrong; an update
    /// requirement (v1-only server, or 410 `client_upgrade_required`) keeps
    /// its own copy. Anything else falls back to the error's description.
    static func message(for error: Error) -> String {
        if let requirement = UpdateRequirement(error) { return requirement.message }
        let status: Int
        switch error {
        case APIv2Error.problem(let problem): status = problem.status
        case APIv2Error.httpStatus(let code): status = code
        default: return error.localizedDescription
        }
        switch status {
        case 401:
            return "Incorrect username or password."
        case 403:
            return "This account can't sign in. Contact your server administrator."
        case 400, 422:
            return "Check your username and password, then try again."
        case 429:
            return "Too many sign-in attempts. Wait a moment, then try again."
        default:
            return error.localizedDescription
        }
    }
}

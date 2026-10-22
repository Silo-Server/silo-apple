import Foundation

/// A new password's limits. The server enforces them; the form checks them
/// first so a typo doesn't spend an attempt from the password-change budget.
struct PasswordRequirements: Equatable, Sendable {
    /// Fewest characters (Unicode scalars, as the server counts them).
    let minimumLength: Int
    /// Most UTF-8 bytes.
    let maximumBytes: Int

    /// silo-server's limits, for when the capability document can't be read.
    static let serverDefault = PasswordRequirements(minimumLength: 8, maximumBytes: 72)

    init(minimumLength: Int, maximumBytes: Int) {
        self.minimumLength = minimumLength
        self.maximumBytes = maximumBytes
    }

    /// The capability's limits; a missing or zero limit keeps the default.
    init(_ capability: APIv2PasswordCapability) {
        let fallback = Self.serverDefault
        minimumLength = capability.minimumPasswordLength.flatMap { $0 > 0 ? $0 : nil } ?? fallback.minimumLength
        maximumBytes = capability.maximumPasswordBytes.flatMap { $0 > 0 ? $0 : nil } ?? fallback.maximumBytes
    }

    /// Why `password` and its `confirmation` can't be submitted, or nil.
    func problem(password: String, confirmation: String) -> String? {
        if password.isEmpty { return "Enter a new password." }
        if password != confirmation { return "The new passwords don't match." }
        if password.unicodeScalars.count < minimumLength { return "Use at least \(minimumLength) characters." }
        if password.utf8.count > maximumBytes { return "That password is too long. Use a shorter one." }
        return nil
    }
}

/// "Choose a new password": the only thing a session holding a temporary
/// password can do. The account replaces the password an admin set, the
/// session is refreshed so the server lifts its restriction, and sign-in
/// continues to profile selection. Mirrors the web client's
/// `ChoosePassword` page; see silo-server `docs/auth-api.md`,
/// "Temporary passwords".
@MainActor
@Observable
final class PasswordChangeModel {
    enum Phase: Equatable {
        case editing
        /// The change, then the session refresh, is in flight.
        case saving
        /// The password changed but the refresh did not complete; `retrying`
        /// while it runs again. The form stays closed: resubmitting would
        /// send the temporary password, which no longer works.
        case refreshFailed(retrying: Bool)
        /// The change failed and the account couldn't be read, so whether the
        /// password changed is unknown; `checking` while the account is read
        /// again. The form stays closed: sending it again could change the
        /// password twice.
        case unconfirmed(checking: Bool)
    }

    var currentPassword = ""
    var newPassword = ""
    var confirmation = ""
    private(set) var phase: Phase = .editing
    /// Settable so tests can stage the error the form shows.
    var error: FormError?
    /// The account's username, once read. Nil while loading or when the read fails.
    private(set) var accountName: String?
    private(set) var requirements = PasswordRequirements.serverDefault

    private let auth: AuthService

    init(auth: AuthService = .shared) {
        self.auth = auth
    }

    var isBusy: Bool {
        phase == .saving || phase == .refreshFailed(retrying: true) || phase == .unconfirmed(checking: true)
    }

    /// The screen's lead line, naming the account once it is known.
    var lead: String {
        let account = accountName.flatMap { $0.isEmpty ? nil : $0 } ?? "your account"
        return "An admin set a temporary password for \(account). Choose your own to continue."
    }

    var requirementsHint: String { "At least \(requirements.minimumLength) characters" }

    /// Reads the account and the server's password limits; both are allowed
    /// while the password is temporary. An account that no longer holds a
    /// temporary password already changed it (the refresh never finished,
    /// then the app relaunched): only the session still carries the
    /// restriction, so it is refreshed instead of asking for a temporary
    /// password that no longer works.
    func load(router: AppRouter) async {
        async let limits = auth.passwordRequirements()
        let account = try? await auth.currentAccount()
        accountName = account?.username
        requirements = await limits
        guard account?.passwordChangeRequired == false, phase == .editing else { return }
        phase = .refreshFailed(retrying: true)
        if await !continueSignIn(router: router) {
            phase = .refreshFailed(retrying: false)
        }
    }

    /// Changes the password, then finishes signing in. Returns whether the
    /// password changed.
    @discardableResult
    func save(router: AppRouter) async -> Bool {
        guard phase == .editing else { return false }
        if currentPassword.isEmpty {
            error = FormError("Enter the temporary password.")
            return false
        }
        if let problem = requirements.problem(password: newPassword, confirmation: confirmation) {
            error = FormError(problem)
            return false
        }
        phase = .saving
        error = nil
        do {
            try await auth.changePassword(current: currentPassword, new: newPassword)
        } catch {
            // A lost response can hide a change the server saved, and sending
            // the temporary password again then fails as incorrect. The
            // account says whether it still holds the temporary password.
            switch await temporaryPasswordRemains() {
            case true?:
                phase = .editing
                self.error = FormError(Self.message(for: error))
                return false
            case nil:
                phase = .unconfirmed(checking: false)
                return false
            case false?:
                break
            }
        }
        await finishChange(router: router)
        return true
    }

    /// "Try again" when the change's outcome is unknown: reads the account
    /// again rather than resending the password.
    func confirmChange(router: AppRouter) async {
        guard phase == .unconfirmed(checking: false) else { return }
        phase = .unconfirmed(checking: true)
        switch await temporaryPasswordRemains() {
        case true?:
            phase = .editing
            error = FormError("Your password wasn't changed. Try again.")
        case nil:
            phase = .unconfirmed(checking: false)
        case false?:
            phase = .refreshFailed(retrying: true)
            await finishChange(router: router)
        }
    }

    /// Whether the account still holds its temporary password; nil when it
    /// can't be read. A server that doesn't report it counts as holding it.
    private func temporaryPasswordRemains() async -> Bool? {
        guard let account = try? await auth.currentAccount() else { return nil }
        return account.passwordChangeRequired ?? true
    }

    /// The password changed: clears the form, then finishes signing in.
    private func finishChange(router: AppRouter) async {
        currentPassword = ""
        newPassword = ""
        confirmation = ""
        if await !continueSignIn(router: router) {
            phase = .refreshFailed(retrying: false)
        }
    }

    /// "Try again" after the password changed but the refresh failed.
    func retryRefresh(router: AppRouter) async {
        guard phase == .refreshFailed(retrying: false) else { return }
        phase = .refreshFailed(retrying: true)
        if await !continueSignIn(router: router) {
            phase = .refreshFailed(retrying: false)
        }
    }

    /// Refreshes the session so the server stops restricting it, then shows
    /// profile selection, unless the app left this screen meanwhile.
    private func continueSignIn(router: AppRouter) async -> Bool {
        guard await auth.refreshSessionAfterPasswordChange() else { return false }
        if router.authState == .needsPasswordChange {
            router.showProfileSelection()
        }
        return true
    }

    /// The server's refusal for a session whose account holds a temporary
    /// password.
    nonisolated static let requiredProblem = "password_change_required"

    /// Whether `error` says the account must change its password first.
    nonisolated static func isRequired(by error: Error) -> Bool {
        guard case APIv2Error.problem(let problem) = error else { return false }
        return problem.status == 403 && problem.identifier == requiredProblem
    }

    /// Copy for a failed change. A rejected new password shows the server's
    /// reason, which names the rule it broke.
    nonisolated static func message(for error: Error) -> String {
        if let requirement = UpdateRequirement(error) { return requirement.message }
        if case APIv2Error.problem(let problem) = error {
            let rejected = problem.errors?.first
            switch (problem.identifier, problem.status) {
            case ("validation_failed", 422) where rejected?.location == "body.current_password":
                return "That temporary password is incorrect."
            case ("validation_failed", 422):
                if let detail = rejected?.detail, !detail.isEmpty { return detail }
                return "Choose a different password, then try again."
            case (_, 429):
                return "Too many attempts. Wait a moment, then try again."
            case (_, 409):
                return "This account doesn't sign in with a Silo password. Ask your server admin for help."
            case (_, 403):
                return "This session can't change the password. Sign in with your own account and try again."
            default:
                break
            }
        }
        return ErrorState(error).message
    }
}

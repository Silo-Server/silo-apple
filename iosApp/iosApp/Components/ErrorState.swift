import Foundation

/// Normalized error payload for UI. Wraps `Error` with a humanized message
/// and — when the source is an `HTTPError`, `APIError` or a status-carrying
/// `APIv2Error` — the HTTP status code so `ErrorView` can pick recovery
/// actions without the UI needing to know about networking error types.
struct ErrorState: Equatable {
    let statusCode: Int?
    let message: String
    /// Set when the failure is a version mismatch between this app and the
    /// server; `message` then carries the matching update copy.
    let updateRequirement: UpdateRequirement?

    /// A 401: the refresh flow has given up and the user must re-authenticate.
    /// A 403 is a permission or policy denial, not session expiry; see
    /// `isForbidden`.
    var isAuthFailure: Bool {
        guard let statusCode else { return false }
        return statusCode == 401
    }

    /// The server refused the request for this account or profile. Signing in
    /// again does not change that.
    var isForbidden: Bool { updateRequirement == nil && statusCode == 403 }

    var isNotFound: Bool { updateRequirement == nil && statusCode == 404 }

    /// A retry might succeed without user action. `nil` status means a
    /// network-layer error (no HTTP response), which is also transient.
    var isTransient: Bool {
        guard updateRequirement == nil else { return false }
        guard let statusCode else { return true }
        return statusCode >= 500 || statusCode == 408 || statusCode == 429
    }

    init(statusCode: Int?, message: String, updateRequirement: UpdateRequirement? = nil) {
        self.statusCode = statusCode
        self.message = message
        self.updateRequirement = updateRequirement
    }

    init(_ error: Error) {
        if let requirement = UpdateRequirement(error) {
            self.statusCode = (error as? HTTPError)?.statusCode ?? Self.statusCode(v2: error)
            self.message = requirement.message
            self.updateRequirement = requirement
            return
        }
        self.updateRequirement = nil
        if Self.isProviderUnavailable(error) {
            // The session is fine; the sign-in provider could not confirm
            // it during a refresh. Transient, never "Session expired".
            self.statusCode = 503
            self.message = ExternalSignInError.reasonText("provider_unavailable")
            return
        }
        if let httpError = error as? HTTPError {
            self.statusCode = httpError.statusCode
            self.message = Self.humanize(httpError: httpError)
            return
        }
        if let code = Self.statusCode(v2: error) {
            // 401/404 keep the copy that matches ErrorView's "Session
            // expired" / "Not found" headlines. A 403 shows the server's
            // detail only for `permission_denied`; other problems carry the
            // server's own detail, which says more than a status category.
            self.statusCode = code
            switch error {
            case APIv2Error.problem(let problem) where code == 403:
                self.message = Self.forbiddenMessage(for: problem)
            case APIv2Error.problem where ![401, 404].contains(code):
                self.message = (error as? LocalizedError)?.errorDescription ?? Self.humanize(statusCode: code)
            default:
                self.message = Self.humanize(statusCode: code)
            }
            return
        }
        if let apiError = error as? APIError, case .httpError(let code) = apiError {
            self.statusCode = code
            self.message = Self.humanize(statusCode: code)
            return
        }
        self.statusCode = nil
        self.message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }

    private static func isProviderUnavailable(_ error: Error) -> Bool {
        switch error {
        case APIv2Error.problem(let problem): return problem.identifier == "provider_unavailable"
        case HTTPError.http(let code, let body): return HTTPClient.isProviderUnavailable(statusCode: code, body: body ?? "")
        default: return false
        }
    }

    /// The HTTP status behind a v2 failure. `APIv2Client` maps every non-2xx
    /// `HTTPError.http` into one of these two cases, so without this a v2 401
    /// or 404 would read as a status-less (transient) network error.
    private static func statusCode(v2 error: Error) -> Int? {
        switch error {
        case APIv2Error.problem(let problem): return problem.status
        case APIv2Error.httpStatus(let code): return code
        default: return nil
        }
    }

    /// The server documents a problem's `detail` as safe to show, and
    /// `permission_denied` details are written for people ("Downloads are not
    /// allowed."). The other 403 problems (`profile_verification_required`,
    /// `password_change_required`) carry protocol instructions, so they get
    /// local copy. A temporary password is not a missing permission, and the
    /// generic 403 copy would send the person to an admin who sees nothing
    /// wrong.
    private static func forbiddenMessage(for problem: APIv2Problem) -> String {
        let detail = problem.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if problem.identifier == "permission_denied", !detail.isEmpty {
            return problem.localized(detail)
        }
        if problem.identifier == PasswordChangeModel.requiredProblem {
            return passwordChangeRequiredMessage
        }
        return humanize(statusCode: 403)
    }

    /// Apple TV has no password change, so it sends the person to the mobile
    /// app or the web.
    #if os(tvOS)
    static var passwordChangeRequiredMessage: String {
        AppLanguage.string(.profilesErrorPasswordReset)
    }
    #else
    static var passwordChangeRequiredMessage: String {
        AppLanguage.string(.shellErrorTemporaryPassword)
    }
    #endif

    private static func humanize(httpError: HTTPError) -> String {
        switch httpError {
        case .serverUrlNotConfigured:
            return AppLanguage.string(.shellErrorNoServer)
        case .requestIdentityChanged, .authorityChanged:
            return AppLanguage.string(.shellErrorIdentityChanged)
        case .invalidURL:
            return AppLanguage.string(.shellErrorInvalidUrl)
        case .invalidResponse:
            return AppLanguage.string(.shellErrorInvalidResponse)
        case .network:
            return AppLanguage.string(.requestsErrorNetwork)
        case .decodingFailed:
            return AppLanguage.string(.shellErrorDecodingFailed)
        case .http(let code, _):
            return humanize(statusCode: code)
        }
    }

    private static func humanize(statusCode code: Int) -> String {
        switch code {
        case 401:
            return AppLanguage.string(.shellErrorSessionExpired)
        case 403:
            return AppLanguage.string(.requestsErrorPermission)
        case 404:
            return AppLanguage.string(.shellErrorNotFound)
        case 408, 504:
            return AppLanguage.string(.shellErrorTimeout)
        case 429:
            return AppLanguage.string(.shellErrorTooManyRequests)
        case 500...599:
            return AppLanguage.string(.shellErrorServerProblem)
        default:
            return AppLanguage.string(.shellErrorGeneric)
        }
    }
}

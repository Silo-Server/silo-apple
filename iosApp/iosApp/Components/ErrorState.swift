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
    /// local copy.
    private static func forbiddenMessage(for problem: APIv2Problem) -> String {
        let detail = problem.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if problem.identifier == "permission_denied", !detail.isEmpty {
            return detail
        }
        return humanize(statusCode: 403)
    }

    private static func humanize(httpError: HTTPError) -> String {
        switch httpError {
        case .serverUrlNotConfigured:
            return "No server is configured."
        case .requestIdentityChanged, .authorityChanged:
            return "The active server or profile changed. Try again."
        case .invalidURL:
            return "The request URL was invalid."
        case .invalidResponse:
            return "The server returned an unexpected response."
        case .network:
            return "Can't reach the server. Check your connection and try again."
        case .decodingFailed:
            return "The server response was in an unexpected format."
        case .http(let code, _):
            return humanize(statusCode: code)
        }
    }

    private static func humanize(statusCode code: Int) -> String {
        switch code {
        case 401:
            return "Your session has expired. Sign in again to continue."
        case 403:
            return "You don't have permission to do this. Ask your server admin if you need access."
        case 404:
            return "We couldn't find what you were looking for. It may have been removed or moved."
        case 408, 504:
            return "The server took too long to respond. Try again in a moment."
        case 429:
            return "Too many requests. Please wait a moment and try again."
        case 500...599:
            return "The server ran into a problem. Try again in a moment."
        default:
            return "Something went wrong while talking to the server."
        }
    }
}

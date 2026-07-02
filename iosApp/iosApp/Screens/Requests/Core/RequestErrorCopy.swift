import Foundation

/// Server reason/error token → user-facing copy. Covers both the soft
/// `RequestState.reason` on a non-requestable card and the structured
/// `{error, message}` envelope thrown by create/cancel as `HTTPError`.
/// Unknown tokens humanize (`some_new_reason` → "Some New Reason") so a
/// newly-added server reason never regresses to a blank chip.
enum RequestErrorCopy {
    static func message(forToken token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        switch token {
        case "already_requested": return "Already requested"
        case "already_available": return "Already in your library"
        case "quota_exceeded", "limit_reached": return "Request limit reached"
        case "requests_disabled": return "Requests are turned off"
        case "requesting_blocked", "blocked": return "You can't request media right now"
        case "validation_failed": return "That request couldn't be submitted"
        case "invalid_state": return "This request can no longer be changed"
        case "not_found": return "This title is no longer available"
        default: return humanize(token)
        }
    }

    /// Copy for a failed create/cancel, preferring the structured server
    /// token and falling back to `ErrorState`'s generic humanization.
    static func message(for error: Error) -> String {
        if let httpError = error as? HTTPError,
           let token = httpError.serverErrorCode,
           let copy = message(forToken: token) {
            return copy
        }
        return ErrorState(error).message
    }

    private static func humanize(_ token: String) -> String {
        token
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

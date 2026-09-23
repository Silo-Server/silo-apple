import Foundation

/// Server reason/error token → user-facing copy. Covers the soft
/// `RequestState.reason` on a non-requestable card and the v2 problem thrown
/// by create/cancel. Unknown tokens humanize (`some_new_reason` → "Some New
/// Reason") so a newly-added server reason never regresses to a blank chip.
enum RequestErrorCopy {
    /// Local reason for a create whose outcome is not known yet; the detail
    /// page shows it on the held primary action.
    static let unconfirmedToken = "request_unconfirmed"
    static let unconfirmedSubmitMessage = "We couldn't confirm the request. Check My Requests before trying again."
    static let unconfirmedCancelMessage = "We couldn't confirm the cancellation. Reopen My Requests to check it."

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
        case unconfirmedToken: return "Not confirmed yet"
        default: return humanize(token)
        }
    }

    /// Copy for a failed create/cancel. v2 folds "already requested",
    /// "already available", and "invalid state" into one `conflict` problem,
    /// and the quota message carries the counts, so the problem's `detail`
    /// (safe to show, per the contract) is the most specific copy there is.
    static func message(for error: Error) -> String {
        if case APIv2Error.problem(let problem) = error, !UpdateRequirement.isClientUpgradeRequired(problem) {
            switch problem.identifier {
            case "validation_failed":
                return message(forToken: "validation_failed") ?? problem.title
            case "capability_disabled", "capability_not_configured", "capability_unsupported":
                return message(forToken: "requests_disabled") ?? problem.title
            default:
                if !problem.detail.isEmpty { return problem.detail }
            }
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

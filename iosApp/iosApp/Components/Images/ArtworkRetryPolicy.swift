import Foundation
import Nuke

/// When a visible artwork load that failed is worth trying again.
///
/// - Transport failures and transient server statuses retry after 2 s, 5 s,
///   then 15 s, and then wait for the app to become active again.
/// - 401, 404, and 429 never retry. The server answers an expired artwork
///   signature with 404, so the same URL keeps failing; only a refetched
///   response with a fresh URL fixes it.
enum ArtworkRetryPolicy {
    static let delays: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]

    private static let retryableStatusCodes: Set<Int> = [408, 500, 502, 503, 504]

    /// Network conditions that a later attempt can plausibly get past.
    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .networkConnectionLost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .internationalRoamingOff,
        .callIsActive,
        .dataNotAllowed,
    ]

    /// The wait before the next attempt after `failedAttempts` consecutive
    /// failures ending in `error`, or nil when the load should stay failed.
    static func delay(afterFailure error: Error, failedAttempts: Int) -> Duration? {
        guard isRetryable(error), delays.indices.contains(failedAttempts - 1) else { return nil }
        return delays[failedAttempts - 1]
    }

    static func isRetryable(_ error: Error) -> Bool {
        guard case let ImagePipeline.Error.dataLoadingFailed(underlying) = error else { return false }
        if case let DataLoader.Error.statusCodeUnacceptable(status) = underlying {
            return retryableStatusCodes.contains(status)
        }
        if let urlError = underlying as? URLError {
            return retryableURLErrorCodes.contains(urlError.code)
        }
        return false
    }
}

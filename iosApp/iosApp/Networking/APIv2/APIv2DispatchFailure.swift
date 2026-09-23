import Foundation

/// Sorts a failed `non_retryable` mutation into definite failure or unknown
/// outcome. The server keeps no request identity for these, so a resend after
/// an unknown outcome can act twice.
///
/// - **Definite failure:** the request never left the device, or the server
///   answered with an error.
/// - **Unknown outcome:** the request may have reached the server but no
///   usable answer came back. Never resend it.
///
/// The rules live in `APIv2MutationOutcome`. Domain callers turn an owner
/// change once the request may have been sent into their own error, so a
/// bare owner-change error reaching this was raised before dispatch.
enum APIv2DispatchFailure {
    static func isUncertain(_ error: Error) -> Bool {
        APIv2MutationOutcome(error, dispatched: false).mayHaveApplied
    }
}

import Foundation

/// Sorts a failed create or cancel into the two outcomes the UI treats
/// differently. Both operations are `non_retryable`: the server keeps no
/// request identity, so a resend after an uncertain outcome can act twice.
///
/// - **Definite failure:** the request never left the device, or the server
///   answered with an error. Show the error; the user may try again.
/// - **Uncertain:** the request may have reached the server but no usable
///   answer came back. Never resend; hold the action until a fresh read
///   shows what the server did.
enum RequestMutationFailure {
    /// An uncertain outcome that a fresh read cannot settle, because the
    /// read would run under a different owner than the mutation did.
    static func isOwnerChanged(_ error: Error) -> Bool {
        (error as? APIv2RequestsError) == .outcomeUnknownOwnerChanged
    }

    /// Maps the shared classification (`APIv2MutationOutcome`). The requests
    /// transport turns an owner change once the request may have been sent
    /// into `outcomeUnknownOwnerChanged`, so a bare owner-change error here
    /// was raised before dispatch.
    static func isUncertain(_ error: Error) -> Bool {
        isOwnerChanged(error) || APIv2MutationOutcome(error, dispatched: false).mayHaveApplied
    }
}

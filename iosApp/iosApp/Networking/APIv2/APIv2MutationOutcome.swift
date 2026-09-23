import Foundation

/// Whether a failed v2 mutation reached the server: the three-outcome
/// failure model (plan §9), decided in one place so every lane gives the
/// same answer for the same error. Lanes map this onto their own result
/// types; they keep no transport or status lists of their own.
enum APIv2MutationOutcome: Equatable, Sendable {
    /// The server answered with an error (any non-2xx status or problem
    /// document). Release and report it.
    case definite
    /// Refused before any request byte left the device. Release it; nothing
    /// happened on the server.
    case notSent
    /// Sent, and no usable answer came back: the server may have acted.
    /// Never resend a `non_retryable` operation after this.
    case uncertain
    /// The owner changed. Before dispatch nothing was sent; after dispatch
    /// the answer was discarded and the server may have acted.
    case ownerChanged(beforeDispatch: Bool)

    /// Classifies a thrown error. `dispatched` comes from an
    /// `HTTPDispatchRecord` when the caller used one; it only decides
    /// whether an owner-change error came before or after the request was
    /// sent. Without one, an owner-change error counts as after dispatch,
    /// because `HTTPClient` raises the same error when it discards an answer.
    init(_ error: Error, dispatched: Bool? = nil) {
        switch error {
        case is APIv2OwnerChangedBeforeDispatch:
            self = .ownerChanged(beforeDispatch: true)
        case HTTPError.requestIdentityChanged, HTTPError.authorityChanged:
            self = .ownerChanged(beforeDispatch: dispatched == false)
        case HTTPError.serverUrlNotConfigured, HTTPError.invalidURL, is EncodingError:
            self = .notSent
        case HTTPError.network(let underlying):
            self = Self.transport(underlying)
        case let urlError as URLError:
            self = Self.transport(urlError)
        case HTTPError.http:
            self = .definite
        // A 2xx the operation does not declare, or an answer that names a
        // different row: the server acted, but the result can't be applied.
        case APIv2Error.httpStatus(let status):
            self = (200..<300).contains(status) ? .uncertain : .definite
        case APIv2Error.unexpectedSettingReceipt:
            self = .uncertain
        // A problem document, the legacy 404, or a refusal in `gate()`.
        case is APIv2Error:
            self = .definite
        // Cancellation, an unreadable answer and anything unrecognized may
        // have left the device.
        default:
            self = .uncertain
        }
    }

    /// The server may have applied the mutation: hold it, never replay it.
    var mayHaveApplied: Bool {
        switch self {
        case .uncertain, .ownerChanged(beforeDispatch: false): return true
        case .definite, .notSent, .ownerChanged(beforeDispatch: true): return false
        }
    }

    private static func transport(_ error: Error) -> APIv2MutationOutcome {
        guard let code = (error as? URLError)?.code else { return .uncertain }
        return APIv2Client.neverConnected.contains(code) ? .notSent : .uncertain
    }
}

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
    static func isUncertain(_ error: Error) -> Bool {
        switch error {
        case HTTPError.network(let underlying):
            return isUncertainTransport(underlying)
        case let urlError as URLError:
            return isUncertainTransport(urlError)
        case is CancellationError:
            return true
        // A 2xx with an unexpected status or an unreadable body: the server
        // acted, but the result cannot be applied.
        case APIv2Error.httpStatus(let status):
            return (200..<300).contains(status)
        case is DecodingError, HTTPError.decodingFailed, HTTPError.invalidResponse:
            return true
        default:
            return false
        }
    }

    private static func isUncertainTransport(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return true }
        return !neverSent.contains(code)
    }

    /// Transport failures that happen before any request bytes reach the
    /// server: no route, no connection, or a refused TLS handshake.
    private static let neverSent: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .badURL, .unsupportedURL, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
        .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
        .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
        .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired,
    ]
}

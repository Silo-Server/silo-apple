import Foundation

/// Whether a failed mutation reached the server, for the plan's three-outcome
/// failure model: a definite failure is released and reported, an owner
/// change applies nothing, and an unconfirmed one is never replayed
/// automatically.
enum MutationDelivery: String, Sendable {
    /// A response arrived, or the request never left the device.
    case definite
    /// The owner changed; nothing is applied under the new one.
    case ownerChanged = "owner_changed"
    /// The request may have reached the server without an answer.
    case unconfirmed

    init(_ error: Error) {
        if let http = error as? HTTPError {
            switch http {
            case .requestIdentityChanged, .authorityChanged:
                self = .ownerChanged
            case .serverUrlNotConfigured, .invalidURL, .encodingFailed, .http, .decodingFailed:
                self = .definite
            case .network(let underlying):
                self = Self.wasNeverSent(underlying) ? .definite : .unconfirmed
            case .invalidResponse:
                self = .unconfirmed
            }
            return
        }
        // Every APIv2Error is either a refusal before dispatch (`gate()`) or a
        // decoded server answer.
        if error is APIv2Error {
            self = .definite
            return
        }
        // Cancellation and anything unrecognized may have left the device.
        self = .unconfirmed
    }

    /// Transport failures that happen before any request byte reaches the
    /// server: no route, no name, no connection, or a failed TLS handshake.
    private static func wasNeverSent(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .callIsActive, .badURL, .unsupportedURL,
             .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            return true
        default:
            return false
        }
    }
}

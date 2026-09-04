import Foundation

/// Outcome of the one-shot v2 contract probe.
enum APIv2ProbeResult: Sendable, Equatable {
    /// The server serves API v2; `info` is its contract identity.
    case v2(APIv2SystemInfo)
    /// A v1-only alpha server: the legacy listener answered `/api/v2/*` with
    /// its plain 404. The client must be pointed at an updated server.
    case updateServer
    /// Any other outcome. None of these mean "old server", and none of them
    /// enable a v1 path for a pilot operation.
    case failure(APIv2ProbeFailure)
}

enum APIv2ProbeFailure: Sendable, Equatable {
    case timeout
    case tls
    case transport
    /// The server answered with a non-2xx status other than the legacy 404.
    case httpStatus(Int)
    /// 2xx, but the body is not a v2 info document (proxy HTML, malformed
    /// JSON, missing members).
    case malformedResponse
    /// A syntactically valid info document for a different API major.
    case unexpectedContract(apiMajor: Int)
}

/// Asks a server for `GET /api/v2/system/info` once and classifies the
/// answer per the compatibility rule (docs/architecture/api-contract.md,
/// "Client contract adoption"): only a syntactically valid info document
/// counts as v2, and only the legacy listener's 404 counts as update-server.
///
/// Called once when a server connection is established or its cached
/// identity is refreshed — never per request.
struct APIv2Probe: Sendable {
    static let path = "/api/v2/system/info"

    /// The exact body Go's `http.NotFound` writes, which is what a v1-only
    /// alpha server's legacy listener returns for any `/api/v2/*` path.
    static let legacyNotFoundBody = "404 page not found"

    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func probe(serverURL: String) async -> APIv2ProbeResult {
        do {
            let info: APIv2SystemInfo = try await httpClient.getUnauthenticated(
                serverURL: serverURL,
                path: Self.path,
                quietStatuses: [404]
            )
            guard info.apiMajor == 2 else {
                return .failure(.unexpectedContract(apiMajor: info.apiMajor))
            }
            return .v2(info)
        } catch HTTPError.http(let statusCode, let body) {
            if statusCode == 404, Self.isLegacyNotFound(body: body) {
                return .updateServer
            }
            return .failure(.httpStatus(statusCode))
        } catch HTTPError.decodingFailed {
            // Covers 200 with an HTML body (a proxy or captive portal), malformed
            // JSON, and a JSON body missing required members.
            return .failure(.malformedResponse)
        } catch HTTPError.network(let underlying) {
            return .failure(Self.classify(underlying))
        } catch {
            return .failure(.transport)
        }
    }

    /// The 404 rule: a 404 is update-server only when its body is exactly the
    /// text Go's `http.NotFound` writes (`"404 page not found"`, optional
    /// trailing newline). A 404 carrying anything else — an HTML error page
    /// from a reverse proxy, a JSON problem from some other service, an empty
    /// body — is an ordinary HTTP failure: it does not prove a Silo v1 server
    /// answered, so it must not tell the user to update one.
    static func isLegacyNotFound(body: String?) -> Bool {
        guard let body else { return false }
        return body.trimmingCharacters(in: .whitespacesAndNewlines) == legacyNotFoundBody
    }

    private static func classify(_ error: Error) -> APIv2ProbeFailure {
        guard let urlError = error as? URLError else { return .transport }
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return .tls
        default:
            return .transport
        }
    }
}

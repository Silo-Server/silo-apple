import Foundation

/// Why this app and the connected server cannot work together until one of
/// them is updated. Every screen that explains a failed server call asks this
/// type first, so a version mismatch reads as "update" rather than as an
/// unreachable or unrecognized server.
///
/// Neither case is a credential problem: an update-required answer never
/// signs the user out or removes a saved session.
enum UpdateRequirement: Equatable, Sendable {
    /// The server is v1-only: its legacy listener answered a `/api/v2` route
    /// with Go's plain 404 (`APIv2Probe.isLegacyNotFound`), or the recorded
    /// probe verdict refused the call (`APIv2Error.serverUpdateRequired`).
    case server
    /// The server no longer accepts this version of the app: HTTP 410 with
    /// the `client_upgrade_required` problem type.
    case app

    static let serverMessage = "This server needs to be updated before this version of Silo can use it."
    static let appMessage = "Update Silo to keep using this server."

    /// The final segment of the problem `type` URI the server sends.
    static let clientUpgradeRequiredProblem = "client_upgrade_required"

    var message: String {
        switch self {
        case .server: return Self.serverMessage
        case .app: return Self.appMessage
        }
    }

    /// Classifies an error from either request layer. A bare 410 is not an
    /// update prompt (the server also uses 410 for ended playback sessions and
    /// expired sign-in codes), and a legacy 404 surfaced as a v1 `HTTPError`
    /// is not either: only a `/api/v2` path proves the legacy listener
    /// answered, and `APIv2Client` already maps that case to
    /// `.serverUpdateRequired`.
    init?(_ error: Error) {
        switch error {
        case APIv2Error.serverUpdateRequired:
            self = .server
        case APIv2Error.problem(let problem) where Self.isClientUpgradeRequired(problem):
            self = .app
        case HTTPError.http(let statusCode, let body) where Self.isClientUpgradeRequired(statusCode: statusCode, body: body):
            self = .app
        default:
            return nil
        }
    }

    static func isClientUpgradeRequired(_ problem: APIv2Problem) -> Bool {
        problem.status == 410 && problem.identifier == clientUpgradeRequiredProblem
    }

    static func isClientUpgradeRequired(statusCode: Int, body: String?) -> Bool {
        guard statusCode == 410, let data = body?.data(using: .utf8),
              let problem = try? HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: data) else {
            return false
        }
        return isClientUpgradeRequired(problem)
    }
}

import Foundation
import OSLog

/// Waits on a device code until its request is decided: the one polling
/// policy for `POST /api/v2/auth/device/poll`. tvOS QR sign-in
/// (`QRLoginViewModel`), phone-to-TV pairing (`ReceiverPairingCoordinator`)
/// and the SiloRemote profile handoff (`RemotePlaybackIdentityManager`) all
/// poll through it; silo-android's `DeviceLoginRepository` follows the same
/// rules.
///
/// - The first poll goes out at once. After that the loop waits the last
///   `poll_after`, or the start `interval` until the server has answered.
/// - A transient failure (network loss, a 5xx or 429, a proxy error) is
///   polled again after the same wait: the code is still live on the server.
///   A re-poll is a new request, not a replay. If a lost answer had already
///   collected the tokens, the next poll reads `consumed` and ends the wait.
/// - Anything `classify(_:)` does not call transient ends the wait, as do the
///   `denied`, `expired` and `consumed` statuses. A status outside the
///   contract never gets this far (`APIv2DevicePoll.validated()` rejects it as
///   `incompleteAuthResponse`); the loop ends on one the same way.
/// - The wait also ends when the code's `expires_in` runs out, even if the
///   server stops answering.
///
/// Cancellation always wins: a cancelled task ends with `CancellationError`,
/// never a `Failure`, even when the cancel races an answer.
enum DeviceLoginPoller {
    /// How a request ended without an approval.
    enum Failure: Error, Equatable {
        case denied
        /// The status is `expired`, or the code's lifetime ran out here.
        case expired
        /// The tokens were already collected.
        case consumed
        /// The server answered 404: it expired and removed the request.
        case removed
    }

    /// What a failed poll means for the wait.
    enum ErrorClass: Equatable {
        /// Poll again after the current wait.
        case transient
        /// The server no longer has the request.
        case removed
        /// Polling again cannot help, and the caller reports the error: an
        /// update requirement, an approval whose tokens cannot be collected
        /// again (they are issued once), or a changed active account.
        case terminal
    }

    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "auth.device-poll")

    static func classify(_ error: Error) -> ErrorClass {
        // A v1-only server or a 410 `client_upgrade_required`.
        if UpdateRequirement(error) != nil { return .terminal }
        switch error {
        case APIv2Error.problem(let problem) where problem.status == 404:
            return .removed
        case APIv2Error.httpStatus(404):
            return .removed
        case APIv2Error.incompleteAuthResponse, HTTPError.requestIdentityChanged:
            return .terminal
        default:
            return .transient
        }
    }

    /// Polls until the request is approved and returns that answer. Throws a
    /// `Failure` when the request ends any other way, the poll's own error
    /// when `classify(_:)` calls it terminal, `incompleteAuthResponse` for a
    /// status outside the contract, and `CancellationError` once the task is
    /// cancelled.
    ///
    /// Runs on the main actor with its callers, so `poll` keeps the caller's
    /// isolation and nothing suspends between the last cancellation check and
    /// the caller acting on an approval. `sleep` and `now` exist for tests.
    @MainActor
    static func waitForApproval(
        interval: Int,
        expiresIn: Int,
        poll: () async throws -> APIv2DevicePoll,
        sleep: (Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        now: () -> Date = Date.init
    ) async throws -> APIv2DevicePoll {
        let deadline = now().addingTimeInterval(TimeInterval(expiresIn))
        var wait = max(1, interval)
        while now() < deadline {
            try Task.checkCancellation()
            let answer: APIv2DevicePoll
            do {
                answer = try await poll()
            } catch {
                try Task.checkCancellation()
                switch classify(error) {
                case .transient:
                    logger.notice("transient device-login poll failure; retrying: \(String(describing: error), privacy: .private)")
                    try await sleep(wait)
                    continue
                case .removed:
                    throw Failure.removed
                case .terminal:
                    throw error
                }
            }
            try Task.checkCancellation()
            switch DeviceLoginStatus(raw: answer.status) {
            case .approved:
                return answer
            case .pending:
                wait = max(1, answer.pollAfter)
                try await sleep(wait)
            case .denied:
                throw Failure.denied
            case .expired:
                throw Failure.expired
            case .consumed:
                throw Failure.consumed
            case .unknown:
                throw APIv2Error.incompleteAuthResponse
            }
        }
        // A cancel that landed as the last wait ended still wins.
        try Task.checkCancellation()
        throw Failure.expired
    }
}

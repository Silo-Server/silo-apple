import Foundation
import Observation

/// State + polling controller for the tvOS QR sign-in screen.
///
/// Lifecycle: the view calls `begin(deviceName:devicePlatform:)` once on
/// appear and `cancel()` on disappear. The model owns two tasks — a
/// polling loop timed by the server's `interval` (then each poll's
/// `poll_after`) and a 1-second countdown tick — and tears both down on
/// cancel, retry, or terminal status.
@MainActor
@Observable
class QRLoginViewModel {

    enum State: Equatable {
        case idle
        case starting
        case awaiting(DeviceLoginStartResponse)
        case approved
        case error(message: String)
    }

    private(set) var state: State = .idle
    private(set) var secondsRemaining: Int = 0

    private var pollTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var deviceName: String = ""
    private var devicePlatform: String = ""
    private var expectedAccount: RefreshAccountIdentity?

    private let auth: AuthService
    private let tokenStore: TokenStore

    init(auth: AuthService = .shared, tokenStore: TokenStore = .shared) {
        self.auth = auth
        self.tokenStore = tokenStore
    }

    func begin(deviceName: String, devicePlatform: String) async {
        self.deviceName = deviceName
        self.devicePlatform = devicePlatform
        await startSession()
    }

    func retry() async {
        cancel()
        await startSession()
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        countdownTask?.cancel()
        countdownTask = nil
    }

    private func startSession() async {
        state = .starting
        do {
            guard let account = await tokenStore.refreshAccountIdentity() else {
                throw HTTPError.serverUrlNotConfigured
            }
            // APIv2Client refuses the answer if the account changed in flight.
            let session = try await auth.startDeviceLogin(
                deviceName: deviceName,
                devicePlatform: devicePlatform,
                expectedAccount: account
            )
            expectedAccount = account
            state = .awaiting(session)
            startCountdown(expiresAt: session.expiresAt)
            startPolling(session: session)
        } catch {
            state = .error(message: Self.startFailureMessage(for: error))
        }
    }

    private func startCountdown(expiresAt: Date) {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let remaining = Int(expiresAt.timeIntervalSinceNow.rounded())
                self?.secondsRemaining = max(0, remaining)
                if remaining <= 0 { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func startPolling(session: DeviceLoginStartResponse) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            var interval = session.interval
            // Poll immediately so a fast approval is reflected within a
            // second instead of waiting the full server-requested interval.
            while !Task.isCancelled {
                guard let self else { return }
                if let pollAfter = await self.pollOnce(session: session) { interval = pollAfter }
                guard case .awaiting = self.state else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval)) * 1_000_000_000)
            }
        }
    }

    /// One poll. Returns the server's `poll_after` when it answered, so the
    /// loop waits as long as the server asked.
    private func pollOnce(session: DeviceLoginStartResponse) async -> Int? {
        guard let expectedAccount else {
            finalize(.error(message: Self.serverChangedMessage))
            return nil
        }
        do {
            let response = try await auth.pollDeviceLogin(
                deviceCode: session.deviceCode,
                expectedAccount: expectedAccount
            )
            switch DeviceLoginStatus(raw: response.status) {
            case .pending:
                break
            case .approved:
                // `validated()` guarantees tokens on `approved`. A temporary
                // session belongs to a SiloRemote handoff, never to sign-in.
                guard let tokens = response.tokens, !response.temporary else {
                    finalize(.error(message: APIv2Error.incompleteAuthResponse.localizedDescription))
                    return nil
                }
                // The tokens were issued once; a failed install cannot be
                // collected again, so it ends this attempt.
                do {
                    try await auth.installSession(
                        accessToken: tokens.accessToken,
                        refreshToken: tokens.refreshToken,
                        accountID: tokens.user.id,
                        expectedAccount: expectedAccount
                    )
                    finalize(.approved)
                } catch HTTPError.requestIdentityChanged {
                    finalize(.error(message: Self.serverChangedMessage))
                } catch {
                    finalize(.error(message: "Couldn't finish sign-in. \(error.localizedDescription)"))
                }
            case .denied:
                finalize(.error(message: "Sign-in was denied on the other device."))
            case .expired:
                finalize(.error(message: "This code expired before it was approved."))
            case .consumed:
                finalize(.error(message: "This code has already been used."))
            case .unknown:
                finalize(.error(message: "Unexpected status from server: \(response.status)"))
            }
            return response.pollAfter
        } catch {
            if case .terminal(let message) = Self.pollFailure(for: error) {
                finalize(.error(message: message))
            }
            return nil
        }
    }

    nonisolated static let serverChangedMessage = "The active server changed during sign-in. Please try again."

    enum PollFailure: Equatable {
        /// Transient: keep polling until the countdown runs out.
        case keepPolling
        case terminal(message: String)
    }

    /// Sorts a failed poll. A v1-only server or a 410
    /// `client_upgrade_required` shows the update message, a 404 problem
    /// means the server removed the request, and an incomplete approval
    /// cannot be collected again (its tokens are issued once). Anything else
    /// is treated as transient.
    nonisolated static func pollFailure(for error: Error) -> PollFailure {
        if let requirement = UpdateRequirement(error) {
            return .terminal(message: requirement.message)
        }
        switch error {
        case APIv2Error.problem(let problem) where problem.status == 404:
            return .terminal(message: "This sign-in request has expired.")
        case APIv2Error.httpStatus(404):
            return .terminal(message: "This sign-in request has expired.")
        case APIv2Error.incompleteAuthResponse:
            return .terminal(message: error.localizedDescription)
        case HTTPError.requestIdentityChanged:
            return .terminal(message: serverChangedMessage)
        default:
            return .keepPolling
        }
    }

    /// An update requirement shows its own message instead of a generic
    /// start failure.
    nonisolated static func startFailureMessage(for error: Error) -> String {
        if let requirement = UpdateRequirement(error) { return requirement.message }
        return "Couldn't start sign-in. \(error.localizedDescription)"
    }

    /// Apply a terminal state and tear down the countdown tick.
    /// The poll task terminates itself by checking `state` after returning.
    private func finalize(_ newState: State) {
        countdownTask?.cancel()
        countdownTask = nil
        state = newState
    }
}

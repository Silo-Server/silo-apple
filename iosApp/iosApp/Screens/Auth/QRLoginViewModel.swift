import Foundation
import Observation

/// State + polling controller for the tvOS QR sign-in screen.
///
/// Lifecycle: the view calls `begin(deviceName:devicePlatform:)` once on
/// appear and `cancel()` on disappear. The model owns two tasks — a
/// polling loop timed by the server's `interval` and a 1-second countdown
/// tick — and tears both down on cancel, retry, or terminal status.
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

    private let auth = AuthService.shared

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
            guard let account = await TokenStore.shared.refreshAccountIdentity() else {
                throw HTTPError.serverUrlNotConfigured
            }
            let session = try await auth.startDeviceLogin(
                deviceName: deviceName,
                devicePlatform: devicePlatform
            )
            guard await TokenStore.shared.refreshAccountIdentity() == account else {
                throw HTTPError.requestIdentityChanged
            }
            expectedAccount = account
            state = .awaiting(session)
            startCountdown(expiresAt: session.expiresAt)
            startPolling(session: session)
        } catch {
            state = .error(message: "Couldn't start sign-in. \(error.localizedDescription)")
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
        let intervalNs = UInt64(max(1, session.interval)) * 1_000_000_000
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Poll immediately so a fast approval is reflected within a
            // second instead of waiting the full server-requested interval.
            while !Task.isCancelled {
                await self.pollOnce(session: session)
                if case .awaiting = self.state {
                    try? await Task.sleep(nanoseconds: intervalNs)
                    continue
                }
                return
            }
        }
    }

    private func pollOnce(session: DeviceLoginStartResponse) async {
        do {
            let response = try await auth.pollDeviceLogin(deviceCode: session.deviceCode)
            switch DeviceLoginStatus(raw: response.status) {
            case .pending:
                return
            case .approved:
                guard let accessToken = response.accessToken,
                      let refreshToken = response.refreshToken,
                      let expectedAccount else {
                    finalize(.error(message: "Server approved the session but did not return tokens."))
                    return
                }
                try await auth.installSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    expectedAccount: expectedAccount
                )
                finalize(.approved)
            case .denied:
                finalize(.error(message: "Sign-in was denied on the other device."))
            case .expired:
                finalize(.error(message: "This code expired before it was approved."))
            case .consumed:
                finalize(.error(message: "This code has already been used."))
            case .unknown:
                finalize(.error(message: "Unexpected status from server: \(response.status)"))
            }
        } catch HTTPError.http(let code, _) where code == 404 {
            // Server cleaned up the pairing row before it was approved.
            finalize(.error(message: "This sign-in request has expired."))
        } catch HTTPError.requestIdentityChanged {
            finalize(.error(message: "The active server changed during sign-in. Please try again."))
        } catch {
            // Transient network error — keep trying until the countdown
            // times out the session server-side.
        }
    }

    /// Apply a terminal state and tear down the countdown tick.
    /// The poll task terminates itself by checking `state` after returning.
    private func finalize(_ newState: State) {
        countdownTask?.cancel()
        countdownTask = nil
        state = newState
    }
}

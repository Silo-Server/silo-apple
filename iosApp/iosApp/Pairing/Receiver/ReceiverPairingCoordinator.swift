import Foundation
import OSLog

/// Drives the TV side of a pairing session over an accepted `PairingChannel`.
/// Persist-on-success: a pushed server URL is written to ServerRegistry /
/// TokenStore ONLY after its poll returns tokens (design spec §5/§6).
///
/// State drives the in-place pairing UI inside `TVServerSetupView`:
/// `idle` (advertising) → `linked` (phone connected, picking servers) →
/// `consentRequested` (the session's one TV-side gate: the user must allow
/// the first pushed server before ANY network call is made on its behalf) →
/// `awaitingApproval` (match code shown) → `signedIn` (per server) →
/// `completed` (all done; the view dwells then advances). A failure that ends
/// the session STAYS on screen as `failed` so the user gets an explanation;
/// cancels and drops return to `idle` so a fresh attempt just works.
///
/// Compiled on every platform (only tvOS uses it) so the iOS test bundle can
/// drive the state machine with a scripted channel.
@MainActor
@Observable
final class ReceiverPairingCoordinator {
    enum State: Equatable {
        case idle
        /// A phone has connected and is choosing servers on its end.
        case linked
        /// A phone asked to sign this TV in to a server; waiting for the user
        /// to allow it. The channel is unauthenticated (public PSK), so
        /// without this gate any LAN device could push a server while the TV
        /// sits on its setup screen.
        case consentRequested(serverName: String)
        /// Showing the match code for the named server while the phone
        /// approves. `automatic` = a later server in a multi-server push; the
        /// phone verifies the code programmatically instead of asking the
        /// user to compare again, and the copy must not claim otherwise.
        case awaitingApproval(serverName: String, matchCode: String, automatic: Bool)
        /// A single server finished signing in (interim, during multi-server).
        case signedIn(serverCount: Int)
        /// Terminal success; every signed-in server, named for the summary.
        case completed(serverNames: [String])
        /// Terminal failure for the last attempted server. Kept on screen
        /// (never clobbered back to idle by the phone's `done`/EOF) so the
        /// user sees what happened; "Try again" returns to idle.
        case failed(String)
    }

    /// How long a connected phone may sit completely silent (no message, no
    /// in-flight attempt) before the TV drops it and goes back to
    /// advertising. Prevents a wedged or hostile connection from holding
    /// setup mode hostage — the listener only accepts one peer at a time.
    static let idleTimeout: Duration = .seconds(180)

    private(set) var state: State = .idle

    private let api: any PairingDeviceAuthorizing
    private let persist: @MainActor (_ url: String, _ fetchedName: String?, _ access: String, _ refresh: String) async -> Bool
    private var signedInNames: [String] = []
    private var consented = false
    private var pendingPush: (serverURL: String, serverName: String?)?
    /// The session currently being driven, so `cancel()`/consent can reach it.
    private var activeSession: (any PairingChannel)?
    /// The in-flight start+poll for the current server. Run as a separate
    /// cancellable task so the stream reader below is NEVER blocked by polling.
    private var pollTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    /// Prevent the stream reader from starting replacement work while an
    /// explicit TV-side teardown is waiting for the current attempt to reach
    /// its cancellation-safe boundary.
    private var isCancelling = false
    private static let logger = Logger(subsystem: "com.continuum.app", category: "pairing.receiver")

    init(
        api: any PairingDeviceAuthorizing = PairingDeviceAPI(),
        persist: @escaping @MainActor (String, String?, String, String) async -> Bool = ReceiverPairingCoordinator.persistServer
    ) {
        self.api = api
        self.persist = persist
    }

    /// Consume the session stream. The stream is ALWAYS being read here; each
    /// server's start+poll runs as a cancellable child task so a Cancel
    /// message or a dropped connection aborts the attempt immediately rather
    /// than after the poll loop finishes (design spec §7).
    func run(session: any PairingChannel, stream: AsyncThrowingStream<PairingMessage, Error>) async {
        isCancelling = false
        signedInNames = []
        consented = false
        pendingPush = nil
        activeSession = session
        let device = AppleDeviceIdentity.current
        do {
            try await session.send(.hello(
                tvName: device.name,
                tvDeviceId: device.id,
                state: .setup,
                supportedVersions: [PairingProtocol.version]
            ))
            // A phone is on the line; it now picks servers on its end.
            state = .linked
            armIdleTimer(session)
            for try await message in stream {
                guard !isCancelling else { continue }
                armIdleTimer(session)
                switch message {
                case let .pushServer(serverURL, serverName):
                    // The protocol is one-server-at-a-time: a new push while
                    // one is in flight means the phone gave up on the
                    // previous server — supersede it, don't ignore the push.
                    pollTask?.cancel()
                    await pollTask?.value
                    guard !isCancelling else { return }
                    if consented {
                        beginAttempt(serverURL: serverURL, serverName: serverName, session: session)
                    } else {
                        pendingPush = (serverURL, serverName)
                        state = .consentRequested(serverName: serverName ?? ServerRegistry.normalize(url: serverURL))
                    }
                case .done:
                    // An in-flight server has no committed result; abandon it.
                    pollTask?.cancel()
                    await pollTask?.value
                    await concludeSession(session)
                    return
                case let .cancel(reason):
                    Self.logger.notice("peer cancelled: \(reason, privacy: .public)")
                    pollTask?.cancel()
                    await pollTask?.value
                    if signedInNames.isEmpty {
                        await teardown(session: session, resetState: true)
                    } else {
                        // A peer timeout can race the persistence boundary.
                        // Never discard a sign-in that already committed.
                        state = .completed(serverNames: signedInNames)
                        await teardown(session: session, resetState: false)
                    }
                    return
                case .hello, .deviceStarted, .serverResult:
                    break // TV → phone kinds; a conforming phone never sends these
                }
            }
            // Stream ended without a Done (peer closed the connection).
            guard !isCancelling else { return }
            await onStreamClosed(session)
        } catch {
            guard !isCancelling else { return }
            // Stream threw: the connection dropped mid-session.
            Self.logger.error("session error: \(String(describing: error), privacy: .public)")
            await onStreamClosed(session)
        }
    }

    private func onStreamClosed(_ session: any PairingChannel) async {
        pollTask?.cancel()
        await pollTask?.value
        await concludeSession(session)
    }

    /// Land on the right terminal (or idle) state for however the session
    /// ended. Anything already signed in is a real success even if the
    /// confirmation frames were lost, so show the summary; a lone failure
    /// keeps its explanation on screen; otherwise return to idle so the
    /// advertiser can accept a fresh attempt.
    private func concludeSession(_ session: any PairingChannel) async {
        if !signedInNames.isEmpty {
            state = .completed(serverNames: signedInNames)
            await teardown(session: session, resetState: false)
        } else if case .failed = state {
            await teardown(session: session, resetState: false)
        } else {
            await teardown(session: session, resetState: true)
        }
    }

    // MARK: - Consent

    /// User allowed the pending server on the TV. Consent is per-session: the
    /// same phone may push more servers without being re-asked.
    func allowPendingServer() {
        guard case .consentRequested = state, let push = pendingPush, let session = activeSession else { return }
        consented = true
        pendingPush = nil
        beginAttempt(serverURL: push.serverURL, serverName: push.serverName, session: session)
    }

    /// User declined the pending server — end the session; the phone is told
    /// it was cancelled on the TV.
    func denyPendingServer() async {
        guard case .consentRequested = state, let session = activeSession else { return }
        pendingPush = nil
        // Closing unwinds `run` (no successes yet), which resets to idle.
        await session.closeGracefully(goodbye: .cancel(reason: "consent_denied"))
    }

    // MARK: - Cancel / teardown

    /// Abort the active session from the UI (Cancel button, "Try again" on
    /// the failure screen, or leaving the setup screen). The phone is told
    /// this was a deliberate TV-side cancel, not a dropped connection.
    func cancel() async {
        guard !isCancelling else { return }
        isCancelling = true
        let session = activeSession
        activeSession = nil
        let task = pollTask
        pollTask = nil
        task?.cancel()
        // A cancellation can race the non-cancellable half of persistence
        // after tokens have committed. Let that task publish its signed-in
        // result before sending the cancel frame, so the phone cannot repaint
        // a successful setup as cancelled.
        await task?.value
        idleTask?.cancel()
        idleTask = nil
        if let session {
            await session.closeGracefully(goodbye: .cancel(reason: "receiver_cancelled"))
        }
        state = .idle
    }

    /// Cancel any in-flight poll, close the session, and (optionally) return
    /// the UI to idle so the advertiser can accept a fresh connection.
    private func teardown(session: any PairingChannel, resetState: Bool) async {
        pollTask?.cancel()
        pollTask = nil
        idleTask?.cancel()
        idleTask = nil
        await session.close()
        activeSession = nil
        if resetState { state = .idle }
    }

    // MARK: - Idle watchdog

    /// Re-armed on every inbound message; suspended while a poll is in
    /// flight (a poll is bounded by the server's own device-code expiry).
    private func armIdleTimer(_ session: any PairingChannel) {
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            Self.logger.notice("pairing session idle timeout; dropping peer")
            // Closing finishes the stream; `run` unwinds and resets state.
            await session.closeGracefully(goodbye: .cancel(reason: "idle_timeout"))
        }
    }

    // MARK: - Per-server attempt

    private func beginAttempt(serverURL: String, serverName: String?, session: any PairingChannel) {
        // "Automatic" only once a sign-in has been COMMITTED: the phone
        // auto-approves only after its user confirmed a match code, and the
        // first confirmed approval is what produces the first success. A
        // pre-confirm failure on server 1 must not flip server 2's copy to
        // "verifying automatically" while the phone is still asking the user
        // to compare codes.
        let automatic = !signedInNames.isEmpty
        idleTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.handlePushServer(serverURL: serverURL, serverName: serverName, session: session, automatic: automatic)
            self?.attemptEnded(session)
        }
    }

    private func attemptEnded(_ session: any PairingChannel) {
        guard activeSession != nil else { return }
        armIdleTimer(session)
    }

    private func handlePushServer(serverURL: String, serverName: String?, session: any PairingChannel, automatic: Bool) async {
        let normalized = ServerRegistry.normalize(url: serverURL)
        let displayName = serverName ?? normalized
        let device = AppleDeviceIdentity.current
        do {
            // 1. Start device auth against the PENDING candidate (not persisted).
            let started = try await api.start(serverURL: normalized, deviceName: device.name, devicePlatform: device.platform)
            state = .awaitingApproval(serverName: displayName, matchCode: started.matchCode, automatic: automatic)
            try await session.send(.deviceStarted(serverURL: normalized, userCode: started.userCode, matchCode: started.matchCode))

            // 2. Poll until approved or the device code expires.
            let deadline = Date().addingTimeInterval(TimeInterval(started.expiresIn))
            var pollInterval = max(1, started.interval)
            while Date() < deadline {
                try Task.checkCancellation() // abort promptly on peer cancel / drop
                let poll: DeviceLoginPollResponse
                do {
                    poll = try await api.poll(serverURL: normalized, deviceCode: started.deviceCode)
                } catch {
                    try Task.checkCancellation()
                    if case PairingDeviceAPI.APIError.http(404) = error {
                        throw error // the server has expired and removed this request
                    }
                    // Match the ordinary device-login flow and Android TV:
                    // a deploy, proxy hiccup, or brief network loss must not
                    // invalidate a still-live device code.
                    Self.logger.notice("transient device-login poll failure; retrying")
                    try await Task.sleep(for: .seconds(pollInterval))
                    continue
                }
                try Task.checkCancellation() // a cancel that raced the network must win — persist nothing
                switch poll.status {
                case "approved":
                    guard let access = poll.accessToken, let refresh = poll.refreshToken else {
                        throw PairingDeviceAPI.APIError.decode
                    }
                    guard await persist(normalized, serverName, access, refresh) else {
                        return
                    }
                    signedInNames.append(displayName)
                    state = .signedIn(serverCount: signedInNames.count)
                    // Best-effort: the tokens are committed, so a lost
                    // confirmation frame must not repaint a real sign-in as a
                    // failure. If the send is lost the phone may undercount,
                    // but EOF-after-success still completes on both ends.
                    await session.queue(.serverResult(serverURL: normalized, status: .signedIn, error: nil))
                    return
                case "denied", "expired", "consumed":
                    throw PairingDeviceAPI.APIError.http(409)
                default: // "pending"
                    pollInterval = max(1, poll.pollAfter ?? pollInterval)
                    try await Task.sleep(for: .seconds(pollInterval))
                }
            }
            throw PairingDeviceAPI.APIError.http(408) // local timeout
        } catch {
            // Persist-on-success: nothing was written, so nothing to roll back.
            if Task.isCancelled {
                // Peer cancelled, superseded this server, or the connection
                // dropped. The attempt is void; whoever cancelled owns state.
                Self.logger.notice("server pairing attempt cancelled")
                return
            }
            Self.logger.error("server pairing failed: \(String(describing: error), privacy: .private)")
            state = .failed(displayName)
            try? await session.send(.serverResult(serverURL: normalized, status: .failed, error: "auth_failed"))
        }
    }

    /// Commit the now-trusted server + tokens. Runs only after a successful poll.
    static func persistServer(url: String, fetchedName: String?, access: String, refresh: String) async -> Bool {
        let id = ServerRegistry.serverId(for: url)
        let entry = ServerEntry(id: id, url: url, fetchedName: fetchedName, profileId: nil, lastUsedAt: Date())
        // Device authorization can replace the account for an already-saved
        // server URL. Preserve its name, but never carry the previous account's
        // profile selection across that credential boundary.
        guard let transitionLease = await HTTPClient.shared.beginIdentityTransition() else {
            return false
        }
        guard !Task.isCancelled else {
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            return false
        }
        await HTTPClient.shared.cancelInFlightRequests()
        guard !Task.isCancelled else {
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            return false
        }
        let previousTokenServerID = await TokenStore.shared.getActiveServerId()
        // From this first persistent mutation onward the transaction must
        // finish even if the pairing task is cancelled. Publishing failure
        // after committed credentials would make the phone and TV disagree.
        guard ServerRegistry.shared.addOrUpdate(entry, preservingProfile: false) != nil else {
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            return false
        }
        await TokenStore.shared.setServerUrl(url)
        await TokenStore.shared.switchActiveServer(serverId: id)
        await TokenStore.shared.setProfileId(nil)
        await TokenStore.shared.setProfileToken(nil)
        await TokenStore.shared.saveTokens(accessToken: access, refreshToken: refresh)
        guard await ServerRegistry.shared.commitSwitchTo(
            serverId: id,
            holding: transitionLease
        ) else {
            await TokenStore.shared.switchActiveServer(serverId: previousTokenServerID)
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            return false
        }
        await HTTPClient.shared.endIdentityTransition(transitionLease)
        await ServerRegistry.shared.refreshFeaturesAfterGatedServerSwitch()
        return true
    }
}

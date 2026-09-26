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
        /// Checking which of the server's addresses this TV can reach, and
        /// starting device authorization there.
        case reaching(serverName: String)
        /// The pushed address did not answer from this TV. `help` names the
        /// network provider behind it when the server listed one; `alternate`
        /// is a verified address of the same server the user may choose
        /// instead. Nothing switches without that choice.
        case unreachable(serverName: String, help: String, alternate: ServerEndpoint?)
        /// Terminal failure for the last attempted server. Kept on screen
        /// (never clobbered back to idle by the phone's `done`/EOF) so the
        /// user sees what happened; "Try again" returns to idle. `help` is
        /// the recovery text for the failure, when there is a specific one.
        case failed(serverName: String, code: PairingFailureCode, help: String?)
    }

    /// One server pushed by the phone, with the identity and alternate
    /// addresses it offered (absent from older phones).
    struct PushedServer: Equatable, Sendable {
        let serverURL: String
        let serverName: String?
        let serverIdentity: String?
        let endpoints: [ServerEndpoint]

        var displayName: String { serverName ?? ServerRegistry.normalize(url: serverURL) }

        /// The provider entry behind the pushed address, when the server
        /// listed it: this is what makes the unreachable copy name the
        /// provider to set up rather than guessing from the hostname.
        var pushedProvider: ServerEndpoint? {
            let pushed = ServerRegistry.normalize(url: serverURL)
            return endpoints.first { $0.kind == .provider && $0.url == pushed }
        }

        func unreachableHelp() -> String {
            if let provider = pushedProvider {
                return provider.unreachableHelp(serverName: displayName)
            }
            return "This Apple TV can't reach \(displayName) at \(ServerRegistry.normalize(url: serverURL)). Check its network connection and try again."
        }
    }

    /// What the receiver commits once a poll returns tokens.
    struct PersistedPairing: Equatable, Sendable {
        /// The address that worked from this TV. It may differ from the
        /// pushed one; the phone's saved address is never changed.
        let url: String
        let fetchedName: String?
        let verifiedServerId: String?
        let accessToken: String
        let refreshToken: String
        /// The account the tokens authenticate (`TokenPair.user.id`), bound
        /// as the session's verified account.
        let accountID: String
    }

    private enum AlternateChoice: Sendable {
        case useAlternate(ServerEndpoint)
        case retry
        case cancelled
    }

    /// How long a connected phone may sit completely silent (no message, no
    /// in-flight attempt) before the TV drops it and goes back to
    /// advertising. Prevents a wedged or hostile connection from holding
    /// setup mode hostage — the listener only accepts one peer at a time.
    static let idleTimeout: Duration = .seconds(180)

    private(set) var state: State = .idle

    private let api: any PairingDeviceAuthorizing
    private let identityProbe: @Sendable (_ serverURL: String) async -> ServerIdentityProbeResult
    private let persist: @MainActor (PersistedPairing) async -> Bool
    private var signedInNames: [String] = []
    private var consented = false
    private var pendingPush: PushedServer?
    /// The TV user's pending choice while `state` is `.unreachable`.
    private var alternateDecision: CheckedContinuation<AlternateChoice, Never>?
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
    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "pairing.receiver")

    init(
        api: any PairingDeviceAuthorizing = PairingDeviceAPI(),
        identityProbe: @escaping @Sendable (String) async -> ServerIdentityProbeResult = { url in
            await ServerIdentityResolver().probeIdentity(serverURL: url)
        },
        persist: @escaping @MainActor (PersistedPairing) async -> Bool = ReceiverPairingCoordinator.persistServer
    ) {
        self.api = api
        self.identityProbe = identityProbe
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
                case let .pushServer(serverURL, serverName, serverIdentity, endpoints):
                    // The protocol is one-server-at-a-time: a new push while
                    // one is in flight means the phone gave up on the
                    // previous server — supersede it, don't ignore the push.
                    pollTask?.cancel()
                    await pollTask?.value
                    guard !isCancelling else { return }
                    let push = PushedServer(
                        serverURL: serverURL,
                        serverName: serverName,
                        serverIdentity: ServerIdentity.usable(serverIdentity),
                        endpoints: endpoints ?? []
                    )
                    if consented {
                        beginAttempt(push, session: session)
                    } else {
                        pendingPush = push
                        state = .consentRequested(serverName: push.displayName)
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
        beginAttempt(push, session: session)
    }

    // MARK: - Unreachable address

    /// User chose the verified alternate address shown on the unreachable
    /// screen. Device authorization runs there; the address that works is
    /// what this TV saves.
    func useAlternateAddress() {
        guard case let .unreachable(_, _, alternate) = state, let alternate else { return }
        resumeAlternateDecision(.useAlternate(alternate))
    }

    /// User set up the network provider (or fixed the connection) and wants
    /// the pushed address tried again.
    func retryPushedAddress() {
        guard case .unreachable = state else { return }
        resumeAlternateDecision(.retry)
    }

    private func resumeAlternateDecision(_ choice: AlternateChoice) {
        guard let decision = alternateDecision else { return }
        alternateDecision = nil
        decision.resume(returning: choice)
    }

    private func awaitAlternateDecision() async -> AlternateChoice {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                alternateDecision = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeAlternateDecision(.cancelled) }
        }
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

    private func beginAttempt(_ push: PushedServer, session: any PairingChannel) {
        // "Automatic" only once a sign-in has been COMMITTED: the phone
        // auto-approves only after its user confirmed a match code, and the
        // first confirmed approval is what produces the first success. A
        // pre-confirm failure on server 1 must not flip server 2's copy to
        // "verifying automatically" while the phone is still asking the user
        // to compare codes.
        let automatic = !signedInNames.isEmpty
        idleTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.handlePushServer(push, session: session, automatic: automatic)
            self?.attemptEnded(session)
        }
    }

    private func attemptEnded(_ session: any PairingChannel) {
        guard activeSession != nil else { return }
        armIdleTimer(session)
    }

    private func handlePushServer(_ push: PushedServer, session: any PairingChannel, automatic: Bool) async {
        // Every frame back to the phone names the PUSHED address, whatever
        // address this TV ends up using: phones key their per-server state
        // on the URL they sent.
        let pushedURL = ServerRegistry.normalize(url: push.serverURL)
        let displayName = push.displayName
        let device = AppleDeviceIdentity.current
        do {
            // 0. Decide which address to sign in at. Legacy pushes (no
            //    identity) use the pushed address exactly, as before.
            state = .reaching(serverName: displayName)
            let loginURL = try await resolveLoginURL(push, pushedURL: pushedURL)

            // 1. Start device auth against the PENDING candidate (not persisted).
            let started: DeviceLoginStartResponse
            do {
                started = try await api.start(serverURL: loginURL, deviceName: device.name, devicePlatform: device.platform)
            } catch {
                try Task.checkCancellation()
                if let requirement = UpdateRequirement(error) { throw AttemptFailure.updateRequired(requirement) }
                throw error is URLError ? AttemptFailure.unreachable : error
            }
            state = .awaitingApproval(serverName: displayName, matchCode: started.matchCode, automatic: automatic)
            try await session.send(.deviceStarted(serverURL: pushedURL, userCode: started.userCode, matchCode: started.matchCode))

            // 2. Poll until approved or the device code expires.
            let deadline = Date().addingTimeInterval(TimeInterval(started.expiresIn))
            var pollInterval = max(1, started.interval)
            while Date() < deadline {
                try Task.checkCancellation() // abort promptly on peer cancel / drop
                let poll: APIv2DevicePoll
                do {
                    poll = try await api.poll(serverURL: loginURL, deviceCode: started.deviceCode)
                } catch {
                    try Task.checkCancellation()
                    if let requirement = UpdateRequirement(error) { throw AttemptFailure.updateRequired(requirement) }
                    if Self.isMissingRequest(error) {
                        throw AttemptFailure.expired // the server has expired and removed this request
                    }
                    // An approval without usable tokens cannot be collected
                    // again: the server issues them once.
                    if case APIv2Error.incompleteAuthResponse = error { throw error }
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
                    // `validated()` guarantees complete tokens on `approved`.
                    guard let tokens = poll.tokens else { throw APIv2Error.incompleteAuthResponse }
                    // Nothing is committed when this returns false. The catch
                    // stays silent when the attempt was cancelled (whoever
                    // cancelled owns state) and otherwise shows the failure
                    // and tells the phone, so neither device waits it out.
                    guard await persist(PersistedPairing(
                        url: loginURL,
                        fetchedName: push.serverName,
                        verifiedServerId: push.serverIdentity,
                        accessToken: tokens.accessToken,
                        refreshToken: tokens.refreshToken,
                        accountID: tokens.user.id
                    )) else {
                        throw AttemptFailure.saveFailed
                    }
                    signedInNames.append(displayName)
                    state = .signedIn(serverCount: signedInNames.count)
                    // Best-effort: the tokens are committed, so a lost
                    // confirmation frame must not repaint a real sign-in as a
                    // failure. If the send is lost the phone may undercount,
                    // but EOF-after-success still completes on both ends.
                    await session.queue(.serverResult(serverURL: pushedURL, status: .signedIn, error: nil))
                    return
                case "denied":
                    throw AttemptFailure.denied
                case "expired", "consumed":
                    throw AttemptFailure.expired
                default: // "pending"
                    pollInterval = max(1, poll.pollAfter)
                    try await Task.sleep(for: .seconds(pollInterval))
                }
            }
            throw AttemptFailure.expired // local timeout
        } catch {
            // Persist-on-success: nothing was written, so nothing to roll back.
            if Task.isCancelled {
                // Peer cancelled, superseded this server, or the connection
                // dropped. The attempt is void; whoever cancelled owns state.
                Self.logger.notice("server pairing attempt cancelled")
                return
            }
            Self.logger.error("server pairing failed: \(String(describing: error), privacy: .private)")
            let failure = error as? AttemptFailure
            let code = failure?.code ?? .authFailed
            state = .failed(serverName: displayName, code: code, help: failure?.help(for: push))
            try? await session.send(.serverResult(serverURL: pushedURL, status: .failed, error: code.rawValue))
        }
    }

    private enum AttemptFailure: Error {
        case unreachable
        case identityMismatch
        case denied
        case expired
        /// The server is v1-only, or no longer accepts this app version.
        case updateRequired(UpdateRequirement)
        /// The phone approved, but this TV could not commit the server and
        /// its tokens, so the new sign-in was not saved.
        case saveFailed

        var code: PairingFailureCode {
            switch self {
            case .unreachable: return .unreachable
            case .identityMismatch: return .identityMismatch
            case .denied: return .denied
            case .expired: return .expired
            case .updateRequired: return .updateRequired
            // No dedicated wire code: phones already explain `auth_failed`.
            case .saveFailed: return .authFailed
            }
        }

        func help(for push: PushedServer) -> String? {
            switch self {
            case .unreachable: return push.unreachableHelp()
            case .updateRequired(let requirement): return requirement.message
            case .saveFailed:
                return "This Apple TV couldn’t save the sign-in to \(push.displayName). Try again from your iPhone, or add your server manually."
            case .identityMismatch, .denied, .expired: return nil
            }
        }
    }

    /// A poll the server answers with 404 names a request it no longer has
    /// (expired and removed); a legacy 404 was already classified as an
    /// update requirement.
    private static func isMissingRequest(_ error: Error) -> Bool {
        switch error {
        case APIv2Error.problem(let problem): return problem.status == 404
        case APIv2Error.httpStatus(404): return true
        default: return false
        }
    }

    /// The address to run device authorization at.
    ///
    /// With an identity, the pushed address must answer with that identity
    /// from this TV. If it does not answer at all, the server's other
    /// addresses are checked for the same identity and the first match is
    /// OFFERED, never taken: the user sees why the pushed address failed
    /// (usually a network provider to set up on the TV) and chooses between
    /// the alternate and a retry. An address answering with a different
    /// identity is never used, whether pushed or alternate.
    private func resolveLoginURL(_ push: PushedServer, pushedURL: String) async throws -> String {
        guard let expected = push.serverIdentity else { return pushedURL }
        while true {
            try Task.checkCancellation()
            switch await identityProbe(pushedURL) {
            case .identity(let id) where id == expected:
                return pushedURL
            case .identity, .unsupportedServer:
                // The phone verified this identity at this very address; a
                // different answer from here is not the server it meant.
                throw AttemptFailure.identityMismatch
            case .unreachable:
                break
            }

            let alternate = await firstReachableAlternate(push, pushedURL: pushedURL, expected: expected)
            try Task.checkCancellation()
            state = .unreachable(serverName: push.displayName, help: push.unreachableHelp(), alternate: alternate)
            switch await awaitAlternateDecision() {
            case .useAlternate(let endpoint):
                state = .reaching(serverName: push.displayName)
                return endpoint.url
            case .retry:
                state = .reaching(serverName: push.displayName)
                continue
            case .cancelled:
                throw CancellationError()
            }
        }
    }

    private func firstReachableAlternate(
        _ push: PushedServer,
        pushedURL: String,
        expected: String
    ) async -> ServerEndpoint? {
        for endpoint in push.endpoints where endpoint.url != pushedURL {
            if Task.isCancelled { return nil }
            if case .identity(let id) = await identityProbe(endpoint.url), id == expected {
                return endpoint
            }
        }
        return nil
    }

    /// Commit the now-trusted server + tokens. Runs only after a successful poll.
    static func persistServer(_ pairing: PersistedPairing) async -> Bool {
        let url = pairing.url
        let access = pairing.accessToken
        let refresh = pairing.refreshToken
        let id = ServerRegistry.serverId(for: url)
        let entry = ServerEntry(
            id: id,
            url: url,
            fetchedName: pairing.fetchedName,
            profileId: nil,
            lastUsedAt: Date(),
            verifiedServerId: pairing.verifiedServerId
        )
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
        let previousServerURL = await TokenStore.shared.getServerUrl()
        let previousProfileID = await TokenStore.shared.getProfileId()
        let previousProfileToken = await TokenStore.shared.getProfileToken()
        // Re-pairing an already saved server replaces its credential slot in
        // the session install below (and adopts the slot even when the write fails
        // part way), before the registry commit can still fail. Keep what
        // the slot and its server-scoped profile proof held, so either
        // failure puts it back instead of leaving the new credentials, an
        // adoption marker, or a tombstone behind a reported failure.
        let previousSession = await TokenStore.shared.accountSessionSnapshot(for: id)
        guard previousSession != .unreadable else {
            // A slot that cannot be read cannot be restored either; refuse
            // before anything is mutated rather than fail half way.
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            return false
        }
        // `addOrUpdate(preservingProfile: false)` forgets the durable profile
        // choice for this server id. When the pairing then fails, the previous
        // session is kept, so its remembered profile must come back too or the
        // next launch lands on profile selection for no reason.
        let launchPreferences = ProfileLaunchPreferences.shared
        let previousRememberedProfile = launchPreferences.rememberedProfile(for: id)
        let previousSelectionRequired = launchPreferences.state.selectionRequiredServerIDs.contains(id)
        func restoreRememberedProfile() {
            if let remembered = previousRememberedProfile {
                launchPreferences.remember(
                    profileID: remembered.profileID,
                    requiresPIN: remembered.requiredPINAtSelection,
                    accountEpoch: remembered.accountEpoch,
                    for: id
                )
            }
            if previousSelectionRequired {
                launchPreferences.markSelectionRequired(for: id)
            }
        }
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
        // One rollback for both failure points below. The slot is restored
        // first (a failed install has still blocked the runtime session
        // and may have adopted the slot; a failed commit has the candidate's
        // tokens persisted in it), then the URL and profile, so the previous
        // server reads exactly as it did before pairing started. When the
        // slot itself cannot be restored the token store keeps that server
        // blocked (fail closed) and pairing still reports failure; the
        // registry entry stays either way so the user can retry.
        func rollBack() async {
            let restored = await TokenStore.shared.restoreAccountSession(previousSession, for: id)
            if !restored {
                Self.logger.error("pairing rollback could not restore the previous session; the server stays blocked until relaunch")
            }
            await TokenStore.shared.setServerUrl(previousServerURL)
            await TokenStore.shared.switchActiveServer(serverId: previousTokenServerID)
            await TokenStore.shared.setProfileId(previousProfileID)
            _ = await TokenStore.shared.setProfileToken(previousProfileToken)
            restoreRememberedProfile()
            await HTTPClient.shared.endIdentityTransition(transitionLease)
        }
        do {
            try await TokenStore.shared.installAccountSession(
                accessToken: access,
                refreshToken: refresh,
                accountID: pairing.accountID,
                clearProfile: false
            )
        } catch {
            Self.logger.error("pairing session install failed: \(String(describing: error), privacy: .private)")
            await rollBack()
            return false
        }
        guard await ServerRegistry.shared.commitSwitchTo(
            serverId: id,
            holding: transitionLease
        ) else {
            await rollBack()
            return false
        }
        await HTTPClient.shared.endIdentityTransition(transitionLease)
        await ServerRegistry.shared.refreshFeaturesAfterGatedServerSwitch()
        return true
    }
}

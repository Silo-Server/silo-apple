import Foundation
import Observation

/// State and polling for the TV sign-in screen (device authorization).
///
/// The screen shows one code at a time: the QR code, the eight-digit code
/// and `<host>/activate` all name the same request. The model keeps that
/// code current without the viewer doing anything:
///
/// - A code that expires while the screen is visible is replaced in place,
///   for up to `Timing.renewalLimit` (about an hour). After that the model
///   pauses until someone asks for a new code.
/// - Polls follow the server's `interval` and `poll_after`. Network errors,
///   5xx and 429 back off exponentially to `Timing.maxBackoff`, and a
///   failure streak longer than the thresholds shows "can't reach the
///   server" or "too many requests" while retrying continues.
/// - Polling never outlives the code: the local deadline is the start
///   answer's `expires_in` from when it arrived, moved to each pending
///   poll's `expires_at`. Past the deadline the code is polled once more
///   before it is replaced, so a late approval or extension wins.
/// - `setActive(false)` (background, screensaver) pauses polling after the
///   request in flight; `setActive(true)` polls at once, or renews an
///   expired code.
/// - `stop()`, `retry()`, a renewal and a successful password sign-in
///   withdraw the request on the server when it supports
///   `cancelDeviceLogin`, so an abandoned code can't be approved later.
/// - Nothing cancels a poll that may be collecting an approval except
///   `stop()`: pausing, `retry()` and `suspendForPasswordSignIn()` let it
///   finish, so tokens the server handed over are always installed.
@MainActor
@Observable
class QRLoginViewModel: NearbySignInCodeSource {

    enum Status: Equatable {
        /// No code yet.
        case gettingCode
        /// A code is showing and nobody has opened it yet.
        case waiting
        /// An approver opened the request; the code stays put.
        case opened
        /// The session is installed. `account` names who it signed in as.
        case approved(account: String?)
        /// Approved on the phone, but this TV could not save the session.
        case couldNotFinish
        case denied
        /// Renewed for about an hour with no approval.
        case paused
        /// The server has not answered for a while; retrying continues.
        case unreachable
        /// The server keeps answering 429; retrying continues.
        case rateLimited
        case updateRequired(message: String)
        /// The server does not offer device sign-in; use a password.
        case noDeviceSignIn
        case failed(message: String)

        /// States the model leaves only on a user action.
        var isTerminal: Bool {
            switch self {
            case .gettingCode, .waiting, .opened, .unreachable, .rateLimited: return false
            case .approved, .couldNotFinish, .denied, .paused, .updateRequired, .noDeviceSignIn, .failed: return true
            }
        }
    }

    struct Timing: Sendable {
        /// Failure streak while getting a code before "can't reach".
        var unreachableWhileStarting: TimeInterval = 10
        /// Failure streak while polling before "can't reach".
        var unreachableWhilePolling: TimeInterval = 30
        /// 429 streak before "too many requests".
        var rateLimitedAfter: TimeInterval = 60
        var maxBackoff: TimeInterval = 30
        /// How long codes renew themselves before the screen pauses.
        var renewalLimit: TimeInterval = 3600
        /// Smallest wait between polls, whatever the server says.
        var minimumPoll: TimeInterval = 1
        /// How long a nearby phone waits for a code to appear.
        var nearbyCodeWait: TimeInterval = 15

        static let standard = Timing()
    }

    private(set) var status: Status = .gettingCode {
        didSet { resolveNearbyWaiters() }
    }
    /// The request whose code is on screen, nil while there is none.
    private(set) var session: DeviceLoginStartResponse? {
        didSet { resolveNearbyWaiters() }
    }
    /// The code on screen replaced an expired one; announced politely.
    private(set) var codeWasRenewed = false
    /// The last `verification_uri` and `verification_uri_complete` a start
    /// returned, so the typed-URL step keeps naming the server's page while
    /// no code is showing.
    private(set) var lastVerificationUris: (uri: String, complete: String)?

    private var deviceName = ""
    private var devicePlatform = ""
    private var capability: APIv2DeviceCapability?
    private var capabilityLoaded = false
    private var expectedAccount: RefreshAccountIdentity?
    private var localDeadline: Date?
    private var renewalWindowStart: Date?
    private var loopTask: Task<Void, Never>?
    private var loopGeneration = 0
    private var napTask: Task<Void, Never>?
    private var isActive = true
    private var passwordHold = false
    /// `retry()` is waiting for the request in flight before starting over.
    private var restartHold = false
    /// Bumped by every `retry()` and `stop()`: a `retry()` that wakes to a
    /// newer number was overtaken (a `stop()` from "Change server", or a
    /// later retry) and must not start a loop of its own.
    private var intentGeneration = 0
    /// `expires_at` minus the local clock, from the start answer: moves a
    /// poll's `expires_at` onto this device's clock.
    private var serverClockOffset: TimeInterval = 0
    private var nearbyWaiters: [UUID: (deviceCode: String, continuation: CheckedContinuation<NearbySignInOutcome, Never>)] = [:]

    private let auth: AuthService
    private let tokenStore: TokenStore
    private let timing: Timing
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let now: @Sendable () -> Date
    private let devices: any PairingDeviceAuthorizing

    init(
        auth: AuthService = .shared,
        tokenStore: TokenStore = .shared,
        timing: Timing = .standard,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .milliseconds(Int64(max(0, seconds) * 1000)))
        },
        now: @escaping @Sendable () -> Date = { Date() },
        // Withdrawals go to an explicit URL with no credentials: the device
        // code is the only authority, and a password sign-in or server
        // switch that just replaced the session must not stop them.
        devices: any PairingDeviceAuthorizing = PairingDeviceAPI()
    ) {
        self.auth = auth
        self.tokenStore = tokenStore
        self.timing = timing
        self.sleeper = sleeper
        self.now = now
        self.devices = devices
    }

    /// Whether the code, QR and URL should be on screen.
    var showsCode: Bool {
        guard session != nil else { return false }
        switch status {
        case .waiting, .opened, .unreachable, .rateLimited: return true
        default: return false
        }
    }

    // MARK: - Lifecycle

    /// Start once on appear. Idempotent while running.
    func begin(deviceName: String, devicePlatform: String) async {
        self.deviceName = deviceName
        self.devicePlatform = devicePlatform
        guard loopTask == nil, !status.isTerminal else { return }
        renewalWindowStart = now()
        startLoop()
    }

    /// "Try again" / "Show a new code": withdraw whatever is showing and
    /// start a fresh renewal window. A request in flight finishes first, as
    /// for a password sign-in: it may be collecting an approval, and the
    /// server hands tokens over only once. A `stop()` or another `retry()`
    /// that arrives while this one waits wins.
    ///
    /// The screen says "Getting a sign-in code…" at once, even while a
    /// request that may hang until its timeout finishes. During a password
    /// sign-in the code is reset but polling stays off:
    /// `finishPasswordSignIn(succeeded: false)` starts it again, so a device
    /// approval can't race the password.
    func retry() async {
        intentGeneration += 1
        let generation = intentGeneration
        if loopTask != nil {
            restartHold = true
            napTask?.cancel()
            // An approval the request in flight collects overwrites this.
            if !isApproved { status = .gettingCode }
            await loopTask?.value
            guard intentGeneration == generation else { return }
        }
        restartHold = false
        // Never undo a sign-in, however it finished.
        if isApproved { return }
        stopLoop()
        withdrawOnServer()
        clearSession()
        codeWasRenewed = false
        status = .gettingCode
        renewalWindowStart = now()
        guard !passwordHold else { return }
        startLoop()
    }

    private var isApproved: Bool {
        if case .approved = status { return true }
        return false
    }

    /// Leaving the screen or switching server: stop and withdraw the code.
    /// A nearby phone waiting on the code is told the attempt ended before
    /// the code disappears, so it doesn't read as expired.
    func stop() {
        intentGeneration += 1
        restartHold = false
        failNearbyWaiters(.authFailed)
        stopLoop()
        withdrawOnServer()
        clearSession()
    }

    /// Scene phase: pause polling in the background, poll at once on
    /// return. Pausing lets the request in flight finish rather than
    /// cancelling it, so an approval it collects is still installed.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        guard active else {
            napTask?.cancel()
            return
        }
        guard !status.isTerminal, !passwordHold, !deviceName.isEmpty else { return }
        // Coming back is someone at the TV again: codes may renew for
        // another window. A loop still finishing its last request carries on.
        renewalWindowStart = now()
        if loopTask == nil {
            startLoop()
        } else {
            napTask?.cancel()
        }
    }

    /// Whether a nearby phone could sign this TV in right now: false once
    /// the server is known to offer no device sign-in, or needs an update.
    var offersNearbySignIn: Bool {
        switch status {
        case .noDeviceSignIn, .updateRequired: return false
        default: return true
        }
    }

    // MARK: - Password single-flight

    /// Call before sending a password or network identity sign-in. Stops
    /// polling, letting a poll already in flight finish. Returns false when
    /// the phone approval won (the session is installed; the caller must not
    /// sign in again).
    func suspendForPasswordSignIn() async -> Bool {
        passwordHold = true
        napTask?.cancel()
        await loopTask?.value
        if case .approved = status { return false }
        return true
    }

    /// The password or network identity sign-in finished. On success the
    /// pending code is withdrawn; on failure polling resumes (renewing an
    /// expired code).
    func finishPasswordSignIn(succeeded: Bool) {
        passwordHold = false
        if succeeded {
            stop()
        } else if !status.isTerminal, isActive, !deviceName.isEmpty, loopTask == nil {
            startLoop()
        }
    }

    // MARK: - Nearby phone (LAN receiver in sign-in mode)

    /// The code on screen for a nearby phone to approve, waiting briefly
    /// when a code is still being fetched. A phone reaching a paused,
    /// declined or unfinished screen means someone is at the TV, so it gets
    /// a new code, as "Show a new code" would. Nil when none is available,
    /// and always nil during a password sign-in, which a device approval
    /// must not race.
    func codeForNearbyApproval() async -> DeviceLoginStartResponse? {
        let deadline = now().addingTimeInterval(timing.nearbyCodeWait)
        var restarted = false
        while true {
            if passwordHold { return nil }
            if let session, status == .waiting || status == .opened { return session }
            if now() >= deadline || Task.isCancelled { return nil }
            if status.isTerminal {
                guard !restarted, Self.restartsForNearbyPhone(status) else { return nil }
                restarted = true
                await retry()
                continue
            }
            await sleeper(0.25)
        }
    }

    nonisolated static func restartsForNearbyPhone(_ status: Status) -> Bool {
        switch status {
        case .paused, .denied, .couldNotFinish: return true
        default: return false
        }
    }

    /// Waits until the request behind `deviceCode` signs in, fails, or is
    /// replaced by another code.
    func nearbyApprovalOutcome(deviceCode: String) async -> NearbySignInOutcome {
        if let immediate = nearbyOutcome(for: deviceCode) { return immediate }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let immediate = nearbyOutcome(for: deviceCode) {
                    continuation.resume(returning: immediate)
                } else {
                    nearbyWaiters[id] = (deviceCode, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.nearbyWaiters.removeValue(forKey: id)?.continuation.resume(returning: .failed(.authFailed))
            }
        }
    }

    private func nearbyOutcome(for deviceCode: String) -> NearbySignInOutcome? {
        switch status {
        case .approved: return .signedIn
        case .couldNotFinish: return .failed(.saveFailed)
        case .denied: return .failed(.denied)
        case .updateRequired: return .failed(.updateRequired)
        case .paused, .noDeviceSignIn, .failed: return .failed(.expired)
        case .gettingCode, .waiting, .opened, .unreachable, .rateLimited:
            return session?.deviceCode == deviceCode ? nil : .failed(.expired)
        }
    }

    private func resolveNearbyWaiters() {
        for (id, waiter) in nearbyWaiters {
            guard let outcome = nearbyOutcome(for: waiter.deviceCode) else { continue }
            nearbyWaiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func failNearbyWaiters(_ code: PairingFailureCode) {
        let waiters = nearbyWaiters
        nearbyWaiters.removeAll()
        for waiter in waiters.values { waiter.continuation.resume(returning: .failed(code)) }
    }

    // MARK: - Loop

    private func startLoop() {
        guard loopTask == nil else { return }
        loopGeneration += 1
        let generation = loopGeneration
        loopTask = Task { @MainActor [weak self] in
            await self?.run()
            if self?.loopGeneration == generation { self?.loopTask = nil }
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
        napTask?.cancel()
        napTask = nil
    }

    /// Sleep that `suspendForPasswordSignIn` can cut short without
    /// cancelling a network call.
    private func nap(_ seconds: TimeInterval) async {
        guard shouldContinue else { return }
        let sleeper = self.sleeper
        let task = Task { await sleeper(seconds) }
        napTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if napTask == task { napTask = nil }
    }

    private var shouldContinue: Bool { !Task.isCancelled && !passwordHold && !restartHold && isActive }

    private func run() async {
        guard let account = await tokenStore.refreshAccountIdentity() else {
            status = .failed(message: Self.serverChangedMessage)
            return
        }
        if expectedAccount != account {
            expectedAccount = account
            capabilityLoaded = false
        }
        if !capabilityLoaded {
            await loadCapability(account)
            guard shouldContinue else { return }
            if let capability, !capability.offersDeviceSignIn {
                status = .noDeviceSignIn
                return
            }
        }

        var streakStart: Date?
        var rateLimitedStart: Date?
        var backoff: TimeInterval = 0

        // A streak starts when its first failing request was sent, so a
        // request that hangs until its timeout already counts.
        var sentAt = now()
        func recordFailure(rateLimited: Bool, threshold: TimeInterval) -> TimeInterval {
            let at = now()
            if streakStart == nil { streakStart = sentAt }
            // A waiting `retry()` keeps "Getting a sign-in code…" up.
            if rateLimited {
                if rateLimitedStart == nil { rateLimitedStart = sentAt }
                if at.timeIntervalSince(rateLimitedStart!) >= timing.rateLimitedAfter, !restartHold { status = .rateLimited }
            } else {
                rateLimitedStart = nil
                if at.timeIntervalSince(streakStart!) >= threshold, !restartHold { status = .unreachable }
            }
            let base = max(timing.minimumPoll, TimeInterval(session?.interval ?? 1))
            backoff = backoff == 0 ? base : min(timing.maxBackoff, backoff * 2)
            return backoff
        }
        func recordSuccess() {
            streakStart = nil
            rateLimitedStart = nil
            backoff = 0
        }

        // Set when the code on screen was polled after its local deadline
        // (or the server said it ended): only then is it replaced.
        var polledPastDeadline = false
        // The server already ended the code, so a renewal has nothing to withdraw.
        var endedOnServer = false

        while shouldContinue {
            // 1. Make sure a live code is showing.
            if session == nil || (isPastDeadline && polledPastDeadline) {
                if let expired = session {
                    // Expired while visible: renew in place, within the
                    // window, and withdraw the old code so an approver who
                    // opens it late can't approve a code nobody collects.
                    if !endedOnServer { withdraw(expired.deviceCode) }
                    clearSession()
                    codeWasRenewed = true
                }
                polledPastDeadline = false
                endedOnServer = false
                // Renewals (not the first code) stop after the window.
                if codeWasRenewed, let windowStart = renewalWindowStart,
                   now().timeIntervalSince(windowStart) >= timing.renewalLimit {
                    status = .paused
                    return
                }
                if status == .waiting || status == .opened { status = .gettingCode }
                sentAt = now()
                let started = await startCode(account)
                // A stopped loop must not touch what a newer one shows.
                guard !Task.isCancelled else {
                    if case .started(let orphan) = started { withdraw(orphan.deviceCode) }
                    return
                }
                switch started {
                case .started(let started):
                    recordSuccess()
                    showSession(started)
                    // The capability read failed earlier but the server
                    // answers now: learn whether this code can be withdrawn.
                    if !capabilityLoaded { await loadCapability(account) }
                case .terminal(let terminal):
                    status = terminal
                    return
                case .rateLimited:
                    await nap(recordFailure(rateLimited: true, threshold: timing.unreachableWhileStarting))
                    continue
                case .transient:
                    await nap(recordFailure(rateLimited: false, threshold: timing.unreachableWhileStarting))
                    continue
                }
                continue
            }

            // 2. Poll the code on screen. Past its local deadline this is
            //    the last poll before it is replaced.
            guard let current = session else { continue }
            polledPastDeadline = isPastDeadline
            sentAt = now()
            let polled = await pollCode(current, account: account)
            // Only `stop()` cancels; pausing lets this answer land.
            guard !Task.isCancelled else { return }
            switch polled {
            case .pending(let opened, let pollAfter, let expiresAt):
                recordSuccess()
                if let expiresAt {
                    localDeadline = expiresAt.addingTimeInterval(-serverClockOffset)
                }
                // A waiting `retry()` keeps "Getting a sign-in code…" up.
                if !restartHold {
                    if opened {
                        status = .opened
                    } else if status != .opened {
                        status = .waiting
                    }
                }
                // A code still past its deadline is replaced at once.
                if !isPastDeadline {
                    await nap(max(timing.minimumPoll, TimeInterval(pollAfter)))
                }
            case .finished(let terminal):
                // Status first: a nearby phone waiting on this code must
                // read the outcome, not a vanished code.
                status = terminal
                clearSession()
                return
            case .approved(let terminal):
                status = terminal
                return
            case .expired:
                recordSuccess()
                // Renew on the next pass, with nothing left to withdraw.
                localDeadline = now()
                polledPastDeadline = true
                endedOnServer = true
            case .rateLimited:
                await nap(recordFailure(rateLimited: true, threshold: timing.unreachableWhilePolling))
            case .transient:
                await nap(recordFailure(rateLimited: false, threshold: timing.unreachableWhilePolling))
            }
        }
    }

    private var isPastDeadline: Bool {
        guard let localDeadline else { return true }
        return now() >= localDeadline
    }

    private func showSession(_ started: DeviceLoginStartResponse) {
        let received = now()
        localDeadline = received.addingTimeInterval(TimeInterval(max(0, started.expiresIn)))
        serverClockOffset = started.expiresAt.timeIntervalSince(received) - TimeInterval(max(0, started.expiresIn))
        session = started
        lastVerificationUris = (started.verificationUri, started.verificationUriComplete)
        // A waiting `retry()` withdraws this code at once; don't flash it.
        if !restartHold { status = .waiting }
    }

    private func clearSession() {
        session = nil
        localDeadline = nil
    }

    private func loadCapability(_ account: RefreshAccountIdentity) async {
        do {
            let read = try await auth.deviceLoginCapability(expectedAccount: account)
            // A stopped run's late answer, or one for an account this screen
            // has since left, must not stand in for the current one.
            guard !Task.isCancelled, expectedAccount == account else { return }
            capability = read
            capabilityLoaded = true
        } catch {
            guard !Task.isCancelled, expectedAccount == account else { return }
            // An older server without the document still offers device
            // sign-in. A transient failure is read again after the next
            // successful start.
            capability = nil
            capabilityLoaded = !Self.isTransient(error)
        }
    }

    // MARK: - One start / one poll

    enum StartResult: Equatable {
        case started(DeviceLoginStartResponse)
        case terminal(Status)
        case rateLimited
        case transient
    }

    private func startCode(_ account: RefreshAccountIdentity) async -> StartResult {
        do {
            let started = try await auth.startDeviceLogin(
                deviceName: deviceName,
                devicePlatform: devicePlatform,
                expectedAccount: account
            )
            return .started(started)
        } catch {
            return Self.startResult(for: error)
        }
    }

    /// Sorts a failed start. An update requirement shows its own message; a
    /// server that answers 403 or 404 for start has device sign-in turned
    /// off; a changed active server ends the attempt.
    nonisolated static func startResult(for error: Error) -> StartResult {
        if let requirement = UpdateRequirement(error) { return .terminal(.updateRequired(message: requirement.message)) }
        if let status = problemStatus(error) {
            if status == 403 || status == 404 { return .terminal(.noDeviceSignIn) }
            if status == 429 { return .rateLimited }
        }
        switch error {
        case HTTPError.requestIdentityChanged, HTTPError.serverUrlNotConfigured:
            return .terminal(.failed(message: serverChangedMessage))
        default:
            return .transient
        }
    }

    enum PollResult: Equatable {
        /// `expiresAt` is the request's current expiry on the server's
        /// clock, absent from servers that predate it.
        case pending(opened: Bool, pollAfter: Int, expiresAt: Date?)
        /// The request ended without a session.
        case finished(Status)
        case approved(Status)
        /// Expired, gone, used or withdrawn: show a new code.
        case expired
        case rateLimited
        case transient
    }

    private func pollCode(_ current: DeviceLoginStartResponse, account: RefreshAccountIdentity) async -> PollResult {
        let response: APIv2DevicePoll
        do {
            response = try await auth.pollDeviceLogin(deviceCode: current.deviceCode, expectedAccount: account)
        } catch {
            return Self.pollResult(for: error)
        }
        switch DeviceLoginStatus(raw: response.status) {
        case .pending:
            return .pending(opened: response.opened == true, pollAfter: response.pollAfter, expiresAt: response.expiresAt)
        case .approved:
            // `validated()` guarantees tokens on `approved`. A temporary
            // session belongs to a SiloRemote handoff, never to sign-in.
            guard let tokens = response.tokens, !response.temporary else { return .finished(.couldNotFinish) }
            // The tokens were issued once; a failed install cannot be
            // collected again, so it ends this attempt.
            do {
                try await auth.installSession(
                    accessToken: tokens.accessToken,
                    refreshToken: tokens.refreshToken,
                    accountID: tokens.user.id,
                    expectedAccount: account
                )
                return .approved(.approved(account: ServerIdentity.usable(tokens.user.username)))
            } catch HTTPError.requestIdentityChanged {
                return .finished(.failed(message: Self.serverChangedMessage))
            } catch {
                return .finished(.couldNotFinish)
            }
        case .denied:
            return .finished(.denied)
        case .expired, .consumed, .canceled:
            return .expired
        case .unknown:
            return .transient
        }
    }

    /// Sorts a failed poll. An update requirement ends the attempt; a 404
    /// problem means the server removed the request (show a new code); an
    /// approval without usable tokens cannot be collected again. 429 and
    /// everything else retry with backoff.
    nonisolated static func pollResult(for error: Error) -> PollResult {
        if let requirement = UpdateRequirement(error) { return .finished(.updateRequired(message: requirement.message)) }
        if let status = problemStatus(error) {
            if status == 404 { return .expired }
            if status == 429 { return .rateLimited }
        }
        switch error {
        case APIv2Error.incompleteAuthResponse:
            return .finished(.couldNotFinish)
        case HTTPError.requestIdentityChanged:
            return .finished(.failed(message: serverChangedMessage))
        default:
            return .transient
        }
    }

    nonisolated private static func problemStatus(_ error: Error) -> Int? {
        switch error {
        case APIv2Error.problem(let problem): return problem.status
        case APIv2Error.httpStatus(let status): return status
        case HTTPError.http(let status, _): return status
        default: return nil
        }
    }

    nonisolated private static func isTransient(_ error: Error) -> Bool {
        if UpdateRequirement(error) != nil { return false }
        if let status = problemStatus(error) { return status == 429 || status >= 500 }
        return true
    }

    // MARK: - Withdraw

    private func withdrawOnServer() {
        guard let pending = session, status != .couldNotFinish else { return }
        if case .approved = status { return }
        withdraw(pending.deviceCode)
    }

    /// Best effort, only when the server supports it (the shared withdraw
    /// policy): an abandoned code can no longer be approved. Its answer
    /// changes nothing on the TV.
    private func withdraw(_ deviceCode: String) {
        guard let serverURL = expectedAccount?.serverURL else { return }
        let devices = self.devices, capability = self.capability
        Task.detached { await devices.withdraw(serverURL: serverURL, deviceCode: deviceCode, capability: capability) }
    }

    // MARK: - Messages

    nonisolated static let serverChangedMessage = "The active server changed during sign-in. Please try again."
}

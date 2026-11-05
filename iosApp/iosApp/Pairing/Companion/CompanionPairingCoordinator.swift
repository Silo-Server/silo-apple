#if os(iOS)
import Foundation
import Network
import OSLog
import UIKit

/// Drives the phone side: connect to a discovered TV, let the user pick which
/// accounts on which saved servers to send (a sign-in TV gets its own server
/// and one account, no chooser), then approve each target with that
/// account's own bearer, in order: the phone's active account first, then
/// list order. A TV with TXT `acct=1` takes any accounts; one without takes
/// one per server (an older Roku one in all), and `lim` caps the count.
///
/// Comparisons (contract §C.5): the person always compares the first
/// target's code. A request whose lookup shows the session binding of a
/// compared request is approved without asking again; one with no binding
/// is compared on its own, naming its account and server; one with another
/// binding is refused. A failed target never ends the session, but an
/// approval whose outcome is unknown (its answer was lost) does.
///
/// People compare the TV's user code, the one its sign-in screen shows. The
/// match code stays on the wire as a consistency check: the code the TV
/// relayed must be the one the server reports for that request, or the
/// approval is refused. TVs released before user codes show only the match
/// words, so the setup confirm step names them on a secondary line until
/// the TV apps that show user codes have shipped. A sign-in TV always shows
/// its code (older TVs never advertised their sign-in screen).
///
/// Structure: one `run()` task consumes the inbound stream for the session's
/// whole life (mirroring the receiver), so the coordinator is never deaf — a
/// TV-side cancel or a dropped connection is surfaced immediately even while
/// the flow is paused waiting on the user's match-code decision. User actions
/// only mutate state and send; every inbound message lands in `handle`.
///
/// Every wait on the peer is bounded by a watchdog, so a stale Bonjour
/// endpoint or a wedged TV becomes an explanatory error instead of a
/// permanent spinner.
@MainActor
@Observable
final class CompanionPairingCoordinator {
    enum State: Equatable {
        case connecting
        /// Connected; offer the phone's saved servers and their accounts.
        case pickAccounts(tvName: String, sections: [CompanionServerSection])
        /// Awaiting the user's comparison of the TV's sign-in code for one
        /// target, with what approving grants: the server, and the account
        /// (nil when it couldn't be read). `matchWords` is what older TVs
        /// show instead (the server's match code), nil for a sign-in TV;
        /// remove it once the Apple TV and Android TV apps that show user
        /// codes have shipped. `step` ("2 of 4") is nil for a lone target.
        case confirmMatch(
            tvName: String,
            serverName: String,
            serverHost: String,
            accountName: String?,
            code: String,
            matchWords: String?,
            step: String? = nil
        )
        /// Pushing/approving the targets.
        case working(progress: String)
        /// `signedIn` is one line per server ("Home — alex, sam"); `failed`
        /// pairs each target that did not sign in with the reason, already
        /// phrased for the user.
        case finished(signedIn: [String], failed: [FailedServer])
        case error(String)
    }

    /// One sign-in the phone sends: a server, and which of its saved
    /// accounts approves it. `localAccountId` is nil for the account the
    /// phone uses on that server when no saved account names it.
    struct PairingTarget: Equatable {
        let server: ServerEntry
        var localAccountId: String? = nil
        /// Sent as `pushServer.accountName` and named in results.
        var username: String? = nil

        /// "Home — sam", or "Home" when the account has no name.
        var displayName: String {
            guard let username else { return server.displayName }
            return "\(server.displayName) — \(username)"
        }

        /// "sam on Home", or "Home".
        var progressName: String {
            guard let username else { return server.displayName }
            return "\(username) on \(server.displayName)"
        }
    }

    /// One line per server, in sending order: "Home — alex, sam".
    nonisolated static func summaryLines(_ targets: [PairingTarget]) -> [String] {
        var order: [String] = []
        var names: [String: [String]] = [:]
        var servers: [String: ServerEntry] = [:]
        for target in targets {
            let id = target.server.id
            if servers[id] == nil {
                order.append(id)
                servers[id] = target.server
            }
            if let username = target.username, !(names[id] ?? []).contains(username) {
                names[id, default: []].append(username)
            }
        }
        return order.compactMap { id in
            guard let server = servers[id] else { return nil }
            let accounts = names[id] ?? []
            return accounts.isEmpty ? server.displayName : "\(server.displayName) — \(accounts.joined(separator: ", "))"
        }
    }

    struct FailedServer: Equatable, Sendable {
        let name: String
        let code: PairingFailureCode
        /// Why the phone itself couldn't approve (no usable session, a
        /// refused approval), already phrased; nil for what the TV reported.
        var message: String? = nil

        /// What to tell the phone user. The TV shows the detailed recovery
        /// (provider setup, alternate address); the phone summarises it.
        var summary: String {
            if let message { return "\(name): \(message)" }
            switch code {
            case .unreachable:
                return "\(name): the TV couldn't reach this address. Follow the steps on the TV, or set the TV up with the server's public address."
            case .identityMismatch:
                return "\(name): the address answered as a different server."
            case .denied:
                return "\(name): the sign-in was declined."
            case .expired:
                return "\(name): the code expired before it was approved."
            case .updateRequired:
                return "\(name): the server or Silo needs to be updated first."
            case .saveFailed:
                return "\(name): the TV approved the sign-in but couldn't save it. Try again."
            case .limitReached:
                return "\(name): the TV can't keep any more accounts."
            case .authFailed:
                return "\(name): the TV couldn't finish signing in."
            }
        }
    }

    enum Timeouts {
        /// Connect + TLS + the TV's `hello`. Generous enough for peer-to-peer
        /// Wi-Fi bring-up, short enough that a vanished TV isn't a trap.
        static let hello: Duration = .seconds(15)
        /// First `deviceStarted` waits on the TV user allowing the setup
        /// request on their screen — leave time to find the remote.
        static let firstDeviceStarted: Duration = .seconds(90)
        static let deviceStarted: Duration = .seconds(30)
        /// When the push offered alternate addresses, a newer TV may probe
        /// each one and then ask its user whether to use the one that
        /// answered, so `deviceStarted` can legitimately take longer. The
        /// protocol has no progress frame an older TV would tolerate, so the
        /// phone waits longer instead.
        static let firstDeviceStartedWithEndpoints: Duration = .seconds(240)
        static let deviceStartedWithEndpoints: Duration = .seconds(180)
        static let serverResult: Duration = .seconds(30)
    }

    private(set) var state: State = .connecting

    private let api: any PairingDeviceAuthorizing
    private let channel: any PairingChannel
    private let stream: AsyncThrowingStream<PairingMessage, Error>
    /// "iPhone" or "iPad" — pairing copy names the device the user is holding.
    private let deviceModel: String
    private let availableServers: @MainActor () async -> [ServerEntry]
    private let accessToken: @MainActor (String) async -> ApproverBearer
    /// The accounts saved for a server, the one in use first.
    private let accounts: @MainActor (ServerEntry) async -> [CompanionAccountOption]
    private let activeServerId: @MainActor () -> String?
    /// A bearer for one saved account, renewed first like `accessToken`.
    private let accountAccessToken: @MainActor (_ serverId: String, _ localAccountId: String) async -> ApproverBearer
    /// The addresses a server offers besides the phone's own, or nil when the
    /// server predates the contract or the read fails. Best effort: the push
    /// then carries the phone's address alone, as before.
    private let serverEndpoints: @MainActor (ServerEntry, _ bearer: String) async -> [ServerEndpoint]?
    /// Who approving signs the TV in as, or nil when it can't be read.
    private let accountName: @MainActor (ServerEntry, _ bearer: String) async -> String?

    private var tvName: String
    /// A sign-in TV's own server: pushed alone, with no chooser.
    private let fixedServer: ServerEntry?
    /// The account a sign-in TV is signed in as, chosen on the card; nil for
    /// the one the phone uses there.
    private let fixedAccount: CompanionAccountOption?
    /// A Roku shows its user code on every screen.
    let isRoku: Bool
    /// What the TV takes from one session (TXT `acct`, `lim`).
    let chooser: CompanionAccountChooser
    private var sections: [CompanionServerSection] = []
    private var queue: [PairingTarget] = []
    private var targetCount = 0
    /// The binding of a request the person compared (contract §C.5). Later
    /// requests showing it are approved without another comparison.
    private var trustedBinding: String?
    /// What the pending comparison trusts once confirmed.
    private var pendingTrust: String?
    private var isFirstPush = true
    private var pendingUserCode: String?
    private var signedIn: [PairingTarget] = []
    private var failed: [FailedServer] = []
    private var runTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// Set once the flow reaches a deliberate end (summary, error, or a
    /// user-initiated cancel), so a trailing stream close can't repaint the
    /// terminal state and late messages are ignored.
    private var concluded = false
    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "pairing.companion")

    init(
        channel: any PairingChannel,
        stream: AsyncThrowingStream<PairingMessage, Error>,
        tvName: String = "TV",
        fixedServer: ServerEntry? = nil,
        fixedAccount: CompanionAccountOption? = nil,
        isRoku: Bool = false,
        acceptsSeveralAccounts: Bool = false,
        accountLimit: Int? = nil,
        api: any PairingDeviceAuthorizing = PairingDeviceAPI(),
        deviceModel: String? = nil,
        availableServers: @escaping @MainActor () async -> [ServerEntry] = { ServerRegistry.shared.sortedEntries },
        // Renewed first when it has expired or is about to: an approval is
        // sent once and never replayed after a 401.
        accessToken: @escaping @MainActor (String) async -> ApproverBearer = { await HTTPClient.shared.freshAccessToken(serverId: $0) },
        serverEndpoints: @escaping @MainActor (ServerEntry, String) async -> [ServerEndpoint]? = CompanionPairingCoordinator.offeredEndpoints,
        accountName: @escaping @MainActor (ServerEntry, String) async -> String? = { server, bearer in
            await LiveTVApprovalAPI().accountName(serverURL: server.url, bearer: bearer)
        },
        accounts: @escaping @MainActor (ServerEntry) async -> [CompanionAccountOption] = CompanionPairingCoordinator.accountOptions,
        accountAccessToken: @escaping @MainActor (String, String) async -> ApproverBearer = {
            await HTTPClient.shared.freshAccessToken(serverId: $0, localAccountId: $1)
        },
        activeServerId: @escaping @MainActor () -> String? = { ServerRegistry.shared.activeServerId }
    ) {
        self.channel = channel
        self.stream = stream
        self.tvName = tvName
        self.fixedServer = fixedServer
        self.fixedAccount = fixedAccount
        self.isRoku = isRoku
        self.chooser = CompanionAccountChooser(isRoku: isRoku, acceptsSeveralAccounts: acceptsSeveralAccounts, limit: accountLimit)
        self.activeServerId = activeServerId
        self.api = api
        self.deviceModel = deviceModel ?? UIDevice.current.model
        self.availableServers = availableServers
        self.accessToken = accessToken
        self.serverEndpoints = serverEndpoints
        self.accountName = accountName
        self.accounts = accounts
        self.accountAccessToken = accountAccessToken
    }

    /// Open the transport for a discovered TV and start its coordinator.
    /// The view never touches the session; it renders `state` and forwards
    /// user intent.
    static func connect(
        to tv: DiscoveredTV,
        server: ServerEntry? = nil,
        account: CompanionAccountOption? = nil
    ) async -> CompanionPairingCoordinator {
        let session = PairingSession(endpoint: tv.endpoint, isRoku: tv.isRoku)
        let stream = await session.open()
        let coordinator = CompanionPairingCoordinator(channel: session, stream: stream, tvName: tv.name,
            fixedServer: server, fixedAccount: account, isRoku: tv.isRoku,
            acceptsSeveralAccounts: tv.acceptsSeveralAccounts, accountLimit: tv.accountLimit)
        coordinator.start()
        return coordinator
    }

    /// Begin consuming the session. Idempotent; the stream has exactly one
    /// reader for the coordinator's whole life.
    func start() {
        guard runTask == nil else { return }
        armWatchdog(Timeouts.hello, "Couldn’t reach \(tvName). Make sure it’s still on its setup or sign-in screen, then try again.")
        runTask = Task { await run() }
    }

    private func run() async {
        do {
            for try await message in stream {
                await handle(message)
            }
            streamEnded(error: nil)
        } catch {
            streamEnded(error: error)
        }
    }

    private func streamEnded(error: Error?) {
        disarmWatchdog()
        guard !concluded else { return }
        concluded = true
        if let error {
            Self.logger.error("session error: \(String(describing: error), privacy: .public)")
        }
        state = .error("Connection to \(tvName) was lost.")
    }

    // MARK: - Inbound messages

    private func handle(_ message: PairingMessage) async {
        guard !concluded else { return }
        switch message {
        case let .hello(name, _, receiverState, supported):
            disarmWatchdog()
            tvName = name
            guard supported.contains(PairingProtocol.version) else {
                await conclude(.error("Update Silo on both devices to continue."), goodbye: .cancel(reason: "version_unsupported"))
                return
            }
            if let fixedServer {
                // A sign-in TV: push only the server it asked for.
                guard receiverState == .login else {
                    await conclude(.error("\(tvName) is no longer on its sign-in screen."), goodbye: .cancel(reason: "state_changed"))
                    return
                }
                // One account per sign-in screen (decision D3).
                queue = [PairingTarget(server: fixedServer, localAccountId: fixedAccount?.localAccountId,
                                       username: fixedAccount?.username)]
                targetCount = 1
                await pushNext()
                return
            }
            var sections: [CompanionServerSection] = []
            for server in await availableServers() {
                let options = await accounts(server)
                if !options.isEmpty { sections.append(CompanionServerSection(server: server, accounts: options)) }
            }
            guard !concluded else { return }
            guard sections.contains(where: { $0.accounts.contains { !$0.needsSignIn } }) else {
                await conclude(.error("Sign in to a server on this \(deviceModel) first."), goodbye: .cancel(reason: "no_servers"))
                return
            }
            self.sections = sections
            state = .pickAccounts(tvName: name, sections: sections)
        case let .deviceStarted(_, userCode, matchCode):
            disarmWatchdog()
            await handleDeviceStarted(userCode: userCode, channelCode: matchCode)
        case let .serverResult(serverURL, status, error):
            // A result names the address it was pushed with. One for another
            // server is late or stray and must not be credited to this target.
            guard let target = queue.first,
                  ServerRegistry.normalize(url: serverURL) == ServerRegistry.normalize(url: target.server.url) else {
                Self.logger.error("ignoring a result for a server other than the current target")
                return
            }
            disarmWatchdog()
            recordResult(target, signedInOK: status == .signedIn, code: PairingFailureCode(wire: error))
            await pushNext()
        case .cancel:
            await conclude(.error("\(isSignIn ? "Sign-in" : "Setup") was cancelled on \(tvName)."), goodbye: nil)
        case .pushServer, .done:
            break // phone → TV kinds; a conforming TV never sends these
        }
    }

    private func handleDeviceStarted(userCode: String, channelCode: String) async {
        guard let target = queue.first else { return }
        let server = target.server
        let approver = await bearer(for: target)
        guard let token = approver.token else {
            await failCurrentAndAdvance(target, message: bearerFailureMessage(approver, server: server))
            return
        }
        do {
            let lookup = try await api.lookup(serverURL: server.url, bearer: token, userCode: userCode)
            guard let serverCode = lookup.matchCode, !serverCode.isEmpty else {
                // A request without its match code can't be bound to the
                // channel; a hard failure, never an unchecked approval.
                Self.logger.error("pairing server returned no match code")
                await failCurrentAndAdvance(target)
                return
            }
            // Bind every approval to the channel: the match code the TV
            // relayed must be the server's for this request, or someone is
            // splicing the session. Refuse.
            guard serverCode == channelCode else {
                Self.logger.error("pairing match code mismatch; refusing approval")
                await failCurrentAndAdvance(target)
                return
            }
            if let status = lookup.status, status != "pending" {
                await failCurrentAndAdvance(target, code: status == "denied" ? .denied : .expired)
                return
            }
            pendingUserCode = userCode
            switch PairingApprovalDecision.decide(trusted: trustedBinding, lookupBinding: lookup.binding) {
            case .approve:
                // Started by the TV holding the session secret the person
                // already vouched for; the server only mints tokens to it.
                await approveCurrent(target)
            case .refuse:
                // Another session's request spliced into this one.
                Self.logger.error("pairing session binding mismatch; refusing approval")
                await failCurrentAndAdvance(target)
            case .compare(let trust):
                // No watchdog while the user deliberates: the TV keeps its
                // device code alive, and the loop keeps reading, so a TV-side
                // cancel or drop is still surfaced immediately. People compare
                // the code the TV shows; the server's spelling of it wins.
                // A sign-in TV always shows the code: only TVs that show one
                // advertise their sign-in screen.
                pendingTrust = trust
                let shown = ServerIdentity.usable(lookup.userCode) ?? userCode
                let account = await accountName(server, token) ?? target.username
                guard !concluded, queue.first == target else { return }
                state = .confirmMatch(
                    tvName: tvName,
                    serverName: server.displayName,
                    serverHost: TVSignInPresentation.host(of: server.url),
                    accountName: account,
                    code: shown,
                    matchWords: isSignIn || isRoku ? nil : serverCode,
                    step: stepLabel
                )
            }
        } catch {
            await failCurrentAndAdvance(target, code: UpdateRequirement(error) == nil ? .authFailed : .updateRequired)
        }
    }

    // MARK: - User actions

    /// The chooser's starting selection: the account in use on the active
    /// server.
    var defaultSelection: Set<CompanionAccountChoice> {
        CompanionAccountChooser.defaultSelection(sections, activeServerId: activeServerId())
    }

    /// User chose accounts to send. They go in sending order (the active
    /// account first, then list order), trimmed to what the TV takes.
    func pushSelected(_ selection: Set<CompanionAccountChoice>) async {
        guard case .pickAccounts = state else { return }
        let ordered = chooser.sendingOrder(selection, in: sections, activeServerId: activeServerId())
        guard !ordered.isEmpty else { return }
        queue = ordered.map {
            PairingTarget(server: $0.server, localAccountId: $0.account.localAccountId, username: $0.account.username)
        }
        targetCount = queue.count
        await pushNext()
    }

    /// "2 of 4" while several targets are sent, nil for one.
    private var stepLabel: String? {
        guard targetCount > 1 else { return nil }
        let position = targetCount - queue.count + 1
        return "\(position) of \(targetCount)"
    }

    private func bearer(for target: PairingTarget) async -> ApproverBearer {
        guard let localAccountId = target.localAccountId else { return await accessToken(target.server.id) }
        return await accountAccessToken(target.server.id, localAccountId)
    }

    /// User confirmed the displayed match code matches the TV.
    func confirmMatch() async {
        guard case .confirmMatch = state, let target = queue.first else { return }
        // The person vouched for this request, so its binding (when it has
        // one and none is trusted yet) vouches for the TV's later requests.
        if trustedBinding == nil { trustedBinding = pendingTrust }
        pendingTrust = nil
        await approveCurrent(target)
    }

    /// User said the codes don't match — abort the whole session. After the
    /// first target, the accounts already signed in stay on the TV.
    func declineMatch() async {
        let isLaterTarget = targetCount - queue.count > 0
        let message = isLaterTarget
            ? "The codes didn’t match, so setup stopped. Accounts already signed in stay on the TV."
            : "The codes didn’t match, so \(isSignIn ? "sign-in" : "setup") was cancelled."
        await conclude(.error(message), goodbye: .cancel(reason: "match_declined"))
    }

    /// User backed out (Cancel button, or the card left the screen). The card
    /// dismisses itself, so no terminal state is shown.
    func cancel() async {
        guard !concluded else { return }
        concluded = true
        disarmWatchdog()
        await channel.closeGracefully(goodbye: .cancel(reason: "user_cancelled"))
    }

    // MARK: - Flow

    /// Signing in a TV on its sign-in screen rather than setting one up.
    var isSignIn: Bool { fixedServer != nil }

    private func pushNext() async {
        guard !concluded else { return }
        guard let target = queue.first else {
            await conclude(.finished(signedIn: Self.summaryLines(signedIn), failed: failed), goodbye: .done)
            return
        }
        let server = target.server
        let firstPush = isFirstPush
        isFirstPush = false
        if firstPush {
            state = .working(progress: "Continue on \(tvName): allow this \(deviceModel) to \(isSignIn ? "sign it in" : "set it up").")
        } else {
            state = .working(progress: progressText(for: target))
        }
        // A sign-in TV already reaches its server and ignores alternate
        // addresses, so they aren't sent to it.
        var endpoints: [ServerEndpoint]?
        if !isSignIn, server.verifiedServerId != nil,
           let token = await bearer(for: target).token {
            endpoints = await serverEndpoints(server, token)
        }
        guard !concluded, queue.first == target else { return }
        // Arm BEFORE the suspending send: the stream reader keeps running
        // while `send` is suspended, so a fast TV's `deviceStarted` could
        // otherwise land (and disarm nothing) before this task resumed and
        // armed a stale watchdog over the confirm screen.
        let offersAlternates = !(endpoints ?? []).isEmpty
        armWatchdog(
            firstPush
                ? (offersAlternates ? Timeouts.firstDeviceStartedWithEndpoints : Timeouts.firstDeviceStarted)
                : (offersAlternates ? Timeouts.deviceStartedWithEndpoints : Timeouts.deviceStarted),
            firstPush
                ? "\(tvName) didn’t respond. Make sure you allowed the request on the TV, then try again."
                : "\(tvName) stopped responding."
        )
        do {
            try await channel.send(.pushServer(
                serverURL: server.url,
                serverName: server.displayName,
                serverIdentity: server.verifiedServerId,
                endpoints: endpoints,
                accountName: target.username
            ))
        } catch {
            await conclude(.error("Connection to \(tvName) was lost."), goodbye: nil)
        }
    }

    /// "Signing in sam on Home… (2 of 4)".
    private func progressText(for target: PairingTarget) -> String {
        let base = "Signing in \(target.progressName)…"
        return stepLabel.map { "\(base) (\($0))" } ?? base
    }

    private func approveCurrent(_ target: PairingTarget) async {
        let server = target.server
        state = .working(progress: progressText(for: target))
        let approver = await bearer(for: target)
        guard !concluded, queue.first == target else { return }
        guard let token = approver.token else {
            // This target fails; the rest still go (contract §C.6). The TV
            // drops the waiting request when the next push arrives.
            await failCurrentAndAdvance(target, message: bearerFailureMessage(approver, server: server))
            return
        }
        // Armed before the suspending approve call (same reasoning as
        // `pushNext`): the TV reports back once its poll mints tokens, and
        // the window covers the HTTP round-trip plus that report.
        armWatchdog(Timeouts.serverResult, "\(tvName) stopped responding while finishing sign-in.")
        do {
            try await api.approve(serverURL: server.url, bearer: token, userCode: pendingUserCode ?? "")
        } catch {
            // The approval is never re-sent, even when its answer was lost.
            disarmWatchdog()
            guard !concluded, queue.first == target else { return }
            guard Self.isDefiniteRefusal(error) else {
                // The server may have approved it after all, and the TV's
                // late result could then be credited to the next target
                // (two accounts share a server address). End the session.
                await conclude(
                    .error(stoppedMessage(approveFailureMessage(for: error, server: server))),
                    goodbye: .cancel(reason: "approve_failed")
                )
                return
            }
            // A definite refusal: this target fails and the rest still go;
            // the TV drops the request it was polling when the next push
            // (or `done`) arrives.
            await failCurrentAndAdvance(
                target,
                code: UpdateRequirement(error) == nil ? .authFailed : .updateRequired,
                message: approveFailureMessage(for: error, server: server)
            )
        }
    }

    /// Why there is no bearer to approve with. Only a session the server
    /// refused asks the person to sign in again.
    private func bearerFailureMessage(_ bearer: ApproverBearer, server: ServerEntry) -> String {
        switch bearer {
        case .providerUnavailable:
            return ExternalSignInError.reasonText("provider_unavailable")
        case .unreachable:
            return "Couldn’t reach \(server.displayName) to approve the sign-in. Check this \(deviceModel)’s connection and try again."
        case .token, .rejected:
            return "Sign in to \(server.displayName) on this \(deviceModel) again, then try again."
        }
    }

    /// Whether the server definitely did not approve: it refused the
    /// session, the request, or this app or server version. A lost answer,
    /// timeout, 5xx or unreadable reply leaves the outcome unknown, and so
    /// does a 409: the request may already be approved by another phone or
    /// collected by the TV, whose result could then be credited to the next
    /// target.
    nonisolated static func isDefiniteRefusal(_ error: Error) -> Bool {
        if UpdateRequirement(error) != nil { return true }
        let refusals: Set<Int> = [401, 403, 404, 410]
        switch error {
        case APIv2Error.problem(let problem):
            return problem.identifier == "provider_unavailable" || refusals.contains(problem.status)
        case APIv2Error.httpStatus(let status):
            return refusals.contains(status)
        default:
            return false
        }
    }

    /// `message`, plus a note that earlier sign-ins are kept once any
    /// target has signed in.
    private func stoppedMessage(_ message: String) -> String {
        signedIn.isEmpty ? message : "\(message) Accounts already signed in stay on the TV."
    }

    /// What to tell the user when the approval failed. A 409 means the
    /// request was already approved or declined, and a 410 means it expired.
    private func approveFailureMessage(for error: Error, server: ServerEntry) -> String {
        if let requirement = UpdateRequirement(error) { return requirement.message }
        switch error {
        case APIv2Error.problem(let problem) where problem.identifier == "provider_unavailable":
            return ExternalSignInError.reasonText("provider_unavailable")
        case APIv2Error.problem(let problem) where problem.status == 401:
            return "Sign in to \(server.displayName) on this \(deviceModel) again, then try again."
        case APIv2Error.problem(let problem) where problem.status == 409:
            return "This sign-in request was already approved or declined. Start again on \(tvName)."
        case APIv2Error.problem(let problem) where problem.status == 410 || problem.status == 404:
            return "The code expired before it was approved. Start again on \(tvName)."
        case is URLError:
            return "Couldn’t reach \(server.displayName) to approve the sign-in. Check this \(deviceModel)’s connection and try again."
        default:
            return "\(server.displayName) couldn’t approve the sign-in. Try again."
        }
    }

    private func recordResult(_ target: PairingTarget, signedInOK: Bool, code: PairingFailureCode) {
        if signedInOK {
            signedIn.append(target)
        } else {
            failed.append(FailedServer(name: target.displayName, code: code))
        }
        queue.removeFirst()
    }

    /// A server failed before approval (token missing, lookup failed, or the
    /// codes couldn't be bound). Move on; the TV abandons its in-flight
    /// attempt as soon as the next `pushServer` arrives.
    private func failCurrentAndAdvance(
        _ target: PairingTarget,
        code: PairingFailureCode = .authFailed,
        message: String? = nil
    ) async {
        failed.append(FailedServer(name: target.displayName, code: code, message: message))
        if !queue.isEmpty { queue.removeFirst() }
        await pushNext()
    }

    private func conclude(_ terminal: State, goodbye: PairingMessage?) async {
        guard !concluded else { return }
        concluded = true
        disarmWatchdog()
        state = terminal
        if let goodbye {
            await channel.closeGracefully(goodbye: goodbye)
        } else {
            await channel.close()
        }
    }

    // MARK: - Watchdog

    private func armWatchdog(_ timeout: Duration, _ message: String) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timedOut(message)
        }
    }

    private func disarmWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func timedOut(_ message: String) async {
        guard !concluded else { return }
        Self.logger.error("pairing wait timed out: \(message, privacy: .public)")
        await conclude(.error(message), goodbye: .cancel(reason: "timeout"))
    }

    // MARK: - Servers

    /// The phone's servers that currently have a stored access token.
    static func serversWithTokens() async -> [ServerEntry] {
        var result: [ServerEntry] = []
        for entry in ServerRegistry.shared.sortedEntries {
            if let token = await TokenStore.shared.getAccessToken(for: entry.id), !token.isEmpty {
                result.append(entry)
            }
        }
        return result
    }

    /// The accounts saved for `server` as the chooser lists them: the one
    /// requests there use first, then most recently used, with accounts that
    /// must sign in again on this phone marked. A server with a session but
    /// no saved account record lists its account in use, unnamed.
    static func accountOptions(on server: ServerEntry) async -> [CompanionAccountOption] {
        let saved = ((try? AccountStore.shared.accounts(onServer: server.id)) ?? [])
            .map(SavedAccountSummary.init)
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
        let inUse = await TokenStore.shared.requestAccountId(onServer: server.id)
        let ordered = saved.filter { $0.localAccountId == inUse } + saved.filter { $0.localAccountId != inUse }
        guard !ordered.isEmpty else {
            let token = await TokenStore.shared.getAccessToken(for: server.id)
            return (token ?? "").isEmpty ? [] : [.inUse(on: server)]
        }
        return ordered.map {
            CompanionAccountOption(serverId: server.id, localAccountId: $0.localAccountId, username: $0.username,
                                   needsSignIn: $0.needsSignIn, isInUse: $0.localAccountId == inUse)
        }
    }

    /// The other addresses `server` offers, from its connections document,
    /// read with that server's own token. Only used when the document
    /// confirms the identity the phone already verified for the server.
    static func offeredEndpoints(for server: ServerEntry, bearer: String) async -> [ServerEndpoint]? {
        guard let document = await ServerIdentityResolver().fetchConnections(
            serverURL: server.url, bearer: bearer
        ), document.serverId == server.verifiedServerId else {
            return nil
        }
        let endpoints = document.usableEndpoints
        return endpoints.isEmpty ? nil : endpoints
    }
}
#endif

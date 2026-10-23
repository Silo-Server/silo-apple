#if os(iOS)
import Foundation
import Network
import OSLog
import UIKit

/// Drives the phone side: connect to a discovered TV, let the user pick which
/// signed-in accounts to sign it in with (a sign-in TV gets the one account
/// chosen on the card, no chooser), have the user compare the TV's sign-in
/// code once, then approve each account. Each account is one push of its
/// server, approved with that account's bearer, so two accounts on one
/// server are two pushes of it: the TV runs a device request for each.
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
        /// Connected; offer the phone's signed-in accounts
        /// (`signedInAccounts()`), the current one first.
        case pickAccounts(tvName: String, accounts: [CompanionPairingAccount])
        /// Awaiting the user's comparison of the TV's sign-in code for the
        /// first account, with what approving grants: the server, and the
        /// account (nil when it couldn't be read). `matchWords` is what
        /// older TVs show instead (the server's match code), nil for a
        /// sign-in TV; remove it once the Apple TV and Android TV apps that
        /// show user codes have shipped.
        case confirmMatch(
            tvName: String,
            serverName: String,
            serverHost: String,
            accountName: String?,
            code: String,
            matchWords: String?
        )
        /// Pushing/approving the remaining accounts after confirmation.
        case working(progress: String)
        /// Each account that signed in (`CompanionPairingAccount.label`), and
        /// each that did not with the reason the TV reported, already
        /// phrased for the user.
        case finished(signedIn: [String], failed: [FailedAccount])
        case error(String)
    }

    struct FailedAccount: Equatable, Sendable {
        /// The account's `label`.
        let name: String
        let code: PairingFailureCode

        /// What to tell the phone user. The TV shows the detailed recovery
        /// (provider setup, alternate address); the phone summarises it.
        var summary: String {
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
    private let availableAccounts: @MainActor () async -> [CompanionPairingAccount]
    private let accessToken: @MainActor (SiloAccountRef) async -> ApproverBearer
    /// The addresses a server offers besides the phone's own, or nil when the
    /// server predates the contract or the read fails. Best effort: the push
    /// then carries the phone's address alone, as before.
    private let serverEndpoints: @MainActor (ServerEntry, _ bearer: String) async -> [ServerEndpoint]?
    /// Who approving signs the TV in as, or nil when it can't be read.
    private let accountName: @MainActor (ServerEntry, _ bearer: String) async -> String?

    private var tvName: String
    /// The account a sign-in TV is signed in with: its server is pushed
    /// alone, with no chooser.
    private let fixedAccount: CompanionPairingAccount?
    private var queue: [CompanionPairingAccount] = []
    private var confirmed = false
    private var isFirstPush = true
    private var pendingUserCode: String?
    private var signedIn: [String] = []
    private var failed: [FailedAccount] = []
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
        fixedAccount: CompanionPairingAccount? = nil,
        api: any PairingDeviceAuthorizing = PairingDeviceAPI(),
        deviceModel: String? = nil,
        availableAccounts: @escaping @MainActor () async -> [CompanionPairingAccount] = CompanionPairingCoordinator.signedInAccounts,
        // That account's own bearer, renewed first when it has expired or is
        // about to: an approval is sent once and never replayed after a 401.
        accessToken: @escaping @MainActor (SiloAccountRef) async -> ApproverBearer = { await HTTPClient.shared.freshAccessToken(for: $0) },
        serverEndpoints: @escaping @MainActor (ServerEntry, String) async -> [ServerEndpoint]? = CompanionPairingCoordinator.offeredEndpoints,
        accountName: @escaping @MainActor (ServerEntry, String) async -> String? = { server, bearer in
            await LiveTVApprovalAPI().accountName(serverURL: server.url, bearer: bearer)
        }
    ) {
        self.channel = channel
        self.stream = stream
        self.tvName = tvName
        self.fixedAccount = fixedAccount
        self.api = api
        self.deviceModel = deviceModel ?? UIDevice.current.model
        self.availableAccounts = availableAccounts
        self.accessToken = accessToken
        self.serverEndpoints = serverEndpoints
        self.accountName = accountName
    }

    /// Open the transport for a discovered TV and start its coordinator.
    /// The view never touches the session; it renders `state` and forwards
    /// user intent.
    static func connect(to tv: DiscoveredTV, account: CompanionPairingAccount? = nil) async -> CompanionPairingCoordinator {
        let session = PairingSession(endpoint: tv.endpoint)
        let stream = await session.open()
        let coordinator = CompanionPairingCoordinator(channel: session, stream: stream, tvName: tv.name, fixedAccount: account)
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
            if let fixedAccount {
                // A sign-in TV: push only the server it asked for.
                guard receiverState == .login else {
                    await conclude(.error("\(tvName) is no longer on its sign-in screen."), goodbye: .cancel(reason: "state_changed"))
                    return
                }
                queue = [fixedAccount]
                await pushNext()
                return
            }
            let accounts = await availableAccounts()
            guard !accounts.isEmpty else {
                await conclude(.error("Sign in to a server on this \(deviceModel) first."), goodbye: .cancel(reason: "no_servers"))
                return
            }
            state = .pickAccounts(tvName: name, accounts: accounts)
        case let .deviceStarted(_, userCode, matchCode):
            disarmWatchdog()
            await handleDeviceStarted(userCode: userCode, channelCode: matchCode)
        case let .serverResult(_, status, error):
            disarmWatchdog()
            recordResult(signedInOK: status == .signedIn, code: PairingFailureCode(wire: error))
            await pushNext()
        case .cancel:
            await conclude(.error("\(isSignIn ? "Sign-in" : "Setup") was cancelled on \(tvName)."), goodbye: nil)
        case .pushServer, .done:
            break // phone → TV kinds; a conforming TV never sends these
        }
    }

    private func handleDeviceStarted(userCode: String, channelCode: String) async {
        guard let account = queue.first else { return }
        let server = account.server
        guard let token = await accessToken(account.id).token else {
            await failCurrentAndAdvance(account)
            return
        }
        do {
            let lookup = try await api.lookup(serverURL: server.url, bearer: token, userCode: userCode)
            guard let serverCode = lookup.matchCode, !serverCode.isEmpty else {
                // A request without its match code can't be bound to the
                // channel; a hard failure, never an unchecked approval.
                Self.logger.error("pairing server returned no match code")
                await failCurrentAndAdvance(account)
                return
            }
            // Bind every approval to the channel: the match code the TV
            // relayed must be the server's for this request, or someone is
            // splicing the session. Refuse.
            guard serverCode == channelCode else {
                Self.logger.error("pairing match code mismatch; refusing approval")
                await failCurrentAndAdvance(account)
                return
            }
            if let status = lookup.status, status != "pending" {
                await failCurrentAndAdvance(account, code: status == "denied" ? .denied : .expired)
                return
            }
            pendingUserCode = userCode
            if confirmed {
                // Confirm-once multi-account: the user compared codes for
                // the first account only; later ones pass the binding above.
                await approveCurrent(account)
            } else {
                // No watchdog while the user deliberates: the TV keeps its
                // device code alive, and the loop keeps reading, so a TV-side
                // cancel or drop is still surfaced immediately. People compare
                // the code the TV shows; the server's spelling of it wins.
                // A sign-in TV always shows the code: only TVs that show one
                // advertise their sign-in screen.
                let shown = ServerIdentity.usable(lookup.userCode) ?? userCode
                // The account is named as this device saved it; the server
                // is asked only when it hasn't named the account yet.
                var name = account.username
                if name == nil { name = await accountName(server, token) }
                guard !concluded, queue.first?.id == account.id else { return }
                state = .confirmMatch(
                    tvName: tvName,
                    serverName: server.displayName,
                    serverHost: TVSignInPresentation.host(of: server.url),
                    accountName: name,
                    code: shown,
                    matchWords: isSignIn ? nil : serverCode
                )
            }
        } catch {
            await failCurrentAndAdvance(account, code: UpdateRequirement(error) == nil ? .authFailed : .updateRequired)
        }
    }

    // MARK: - User actions

    /// User chose the accounts to sign the TV in with (order = approval
    /// order).
    func pushSelected(_ accounts: [CompanionPairingAccount]) async {
        guard case .pickAccounts = state, !accounts.isEmpty else { return }
        queue = accounts
        await pushNext()
    }

    /// User confirmed the displayed match code matches the TV.
    func confirmMatch() async {
        guard case .confirmMatch = state, let account = queue.first else { return }
        confirmed = true
        await approveCurrent(account)
    }

    /// User said the codes don't match — abort the whole session.
    func declineMatch() async {
        await conclude(.error("The codes didn’t match, so \(isSignIn ? "sign-in" : "setup") was cancelled."), goodbye: .cancel(reason: "match_declined"))
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
    var isSignIn: Bool { fixedAccount != nil }

    private func pushNext() async {
        guard !concluded else { return }
        guard let account = queue.first else {
            await conclude(.finished(signedIn: signedIn, failed: failed), goodbye: .done)
            return
        }
        let firstPush = isFirstPush
        isFirstPush = false
        if firstPush {
            state = .working(progress: "Continue on \(tvName): allow this \(deviceModel) to \(isSignIn ? "sign it in" : "set it up").")
        } else {
            state = .working(progress: "Setting up \(account.label)…")
        }
        let server = account.server
        // A sign-in TV already reaches its server and ignores alternate
        // addresses, so they aren't sent to it.
        var endpoints: [ServerEndpoint]?
        if !isSignIn, server.verifiedServerId != nil,
           let token = await accessToken(account.id).token {
            endpoints = await serverEndpoints(server, token)
        }
        guard !concluded, queue.first?.id == account.id else { return }
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
                endpoints: endpoints
            ))
        } catch {
            await conclude(.error("Connection to \(tvName) was lost."), goodbye: nil)
        }
    }

    private func approveCurrent(_ account: CompanionPairingAccount) async {
        state = .working(progress: "Approving \(account.label)…")
        let server = account.server
        let bearer = await accessToken(account.id)
        guard let token = bearer.token else {
            await conclude(.error(bearerFailureMessage(bearer, account: account)), goodbye: .cancel(reason: "approve_failed"))
            return
        }
        // Armed before the suspending approve call (same reasoning as
        // `pushNext`): the TV reports back once its poll mints tokens, and
        // the window covers the HTTP round-trip plus that report.
        armWatchdog(Timeouts.serverResult, "\(tvName) stopped responding while finishing sign-in.")
        do {
            try await api.approve(serverURL: server.url, bearer: token, userCode: pendingUserCode ?? "")
        } catch {
            // The TV is still polling this server; without the approval it can
            // only wait out its device code. Ending the session keeps both
            // screens honest instead of leaving the TV stuck on a dead code.
            // The approval is never re-sent, even when its answer was lost.
            await conclude(
                .error(approveFailureMessage(for: error, account: account)),
                goodbye: .cancel(reason: "approve_failed")
            )
        }
    }

    /// Why there is no bearer to approve with. Only a session the server
    /// refused asks the person to sign in again.
    private func bearerFailureMessage(_ bearer: ApproverBearer, account: CompanionPairingAccount) -> String {
        switch bearer {
        case .providerUnavailable:
            return ExternalSignInError.reasonText("provider_unavailable")
        case .unreachable:
            return "Couldn’t reach \(account.server.displayName) to approve the sign-in. Check this \(deviceModel)’s connection and try again."
        case .token, .rejected:
            return signInAgainMessage(account)
        }
    }

    /// Asks the person to sign in to that account again, naming it when the
    /// server has.
    private func signInAgainMessage(_ account: CompanionPairingAccount) -> String {
        let server = account.server.displayName
        guard let username = account.username else {
            return "Sign in to \(server) on this \(deviceModel) again, then try again."
        }
        return "Sign in to \(server) as \(username) on this \(deviceModel) again, then try again."
    }

    /// What to tell the user when the approval failed. A 409 means the
    /// request was already approved or declined, and a 410 means it expired.
    private func approveFailureMessage(for error: Error, account: CompanionPairingAccount) -> String {
        if let requirement = UpdateRequirement(error) { return requirement.message }
        let server = account.server
        switch error {
        case APIv2Error.problem(let problem) where problem.identifier == "provider_unavailable":
            return ExternalSignInError.reasonText("provider_unavailable")
        case APIv2Error.problem(let problem) where problem.status == 401:
            return signInAgainMessage(account)
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

    private func recordResult(signedInOK: Bool, code: PairingFailureCode) {
        guard let account = queue.first else { return }
        if signedInOK {
            signedIn.append(account.label)
        } else {
            failed.append(FailedAccount(name: account.label, code: code))
        }
        queue.removeFirst()
    }

    /// An account failed before approval (token missing, lookup failed, or
    /// the codes couldn't be bound). Move on; the TV abandons its in-flight
    /// attempt as soon as the next `pushServer` arrives.
    private func failCurrentAndAdvance(_ account: CompanionPairingAccount, code: PairingFailureCode = .authFailed) async {
        failed.append(FailedAccount(name: account.label, code: code))
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

    // MARK: - Accounts

    /// The phone's signed-in accounts, the current one first, then in the
    /// order they were added (`pairingAccounts`). Read from stored sign-ins
    /// only, never the network. Before sign-in migration each server with a
    /// stored token is its own account.
    static func signedInAccounts() async -> [CompanionPairingAccount] {
        let tokens = TokenStore.shared
        let registry = ServerRegistry.shared
        let snapshot: SiloAccountDirectorySnapshot
        do {
            snapshot = try await tokens.directory()
        } catch SavedSignInAccessError.notMigrated {
            let active = registry.activeServerId
            return await serversWithTokens().map { server in
                CompanionPairingAccount(sessionOf: server, isCurrent: server.id == active)
            }
        } catch {
            return []
        }
        let directory = SiloAccountDirectory(snapshot: snapshot, servers: registry.entries,
                                             state: ProfileLaunchState(),
                                             currentAccountID: await tokens.currentAccount())
        var serverDefaults: Set<SiloAccountRef> = []
        for serverID in Set(directory.accounts.map(\.serverID)) {
            if let account = await tokens.backgroundAccount(forServer: serverID) {
                serverDefaults.insert(account)
            }
        }
        return pairingAccounts(in: directory, servers: registry.entries, serverDefaults: serverDefaults)
    }

    /// The accounts a TV can be signed in with: the directory's signed-in
    /// accounts on saved servers, the current one first, then in index
    /// order. A pending legacy account is left out unless it is the current
    /// one: the server hasn't named it, so it can't be told apart from the
    /// server's other accounts. `serverDefaults` are the accounts each
    /// server's background work uses (`TokenStore.backgroundAccount`).
    nonisolated static func pairingAccounts(
        in directory: SiloAccountDirectory,
        servers: [ServerEntry],
        serverDefaults: Set<SiloAccountRef>
    ) -> [CompanionPairingAccount] {
        let entryByID = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = directory.currentAccountID
        let accounts = directory.accounts.compactMap { account -> CompanionPairingAccount? in
            guard account.isSignedIn, account.key != nil || account.id == current,
                  let server = entryByID[account.serverID] else { return nil }
            return CompanionPairingAccount(account, server: server, isCurrent: account.id == current,
                                           isServerDefault: serverDefaults.contains(account.id))
        }
        return accounts.filter(\.isCurrent) + accounts.filter { !$0.isCurrent }
    }

    /// The phone's servers that currently have a stored access token: the
    /// background account's on each (`TokenStore.getAccessToken(for:)`).
    /// "Sign in a TV" still chooses among servers.
    static func serversWithTokens() async -> [ServerEntry] {
        var result: [ServerEntry] = []
        for entry in ServerRegistry.shared.sortedEntries {
            if let token = await TokenStore.shared.getAccessToken(for: entry.id), !token.isEmpty {
                result.append(entry)
            }
        }
        return result
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

/// One signed-in account the phone can sign a TV in with, shown as Choose
/// an Account shows it.
struct CompanionPairingAccount: Equatable, Identifiable {
    let id: SiloAccountRef
    let server: ServerEntry
    /// The server account's username; nil until the server names it.
    let username: String?
    /// The card's first line and other lines (`SiloAccountDirectory.Account`).
    let name: String
    let detailLines: [String]
    /// The server's name, with its host when two saved servers share it.
    let serverName: String
    let profiles: [SavedSignInProfile]
    /// The account this phone uses now.
    let isCurrent: Bool
    /// The account work for its server uses when none is chosen there
    /// (`TokenStore.backgroundAccount(forServer:)`).
    let isServerDefault: Bool

    /// How the summary names the account: "alex on Home Silo", or the
    /// server's name before the server named the account.
    var label: String {
        username.map { "\($0) on \(serverName)" } ?? serverName
    }
}

extension CompanionPairingAccount {
    init(_ account: SiloAccountDirectory.Account, server: ServerEntry, isCurrent: Bool, isServerDefault: Bool) {
        self.init(id: account.id, server: server, username: account.username, name: account.name,
                  detailLines: account.detailLines, serverName: account.serverName, profiles: account.profiles,
                  isCurrent: isCurrent, isServerDefault: isServerDefault)
    }

    /// A server's own session, before sign-in migration.
    init(sessionOf server: ServerEntry, isCurrent: Bool) {
        self.init(id: .pendingLegacy(serverID: server.id), server: server, username: nil, name: server.displayName,
                  detailLines: [TVSignInPresentation.host(of: server.url)], serverName: server.displayName,
                  profiles: [], isCurrent: isCurrent, isServerDefault: true)
    }
}
#endif

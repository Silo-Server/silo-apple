#if os(iOS)
import Foundation
import Network
import OSLog
import UIKit

/// Drives the phone side: connect to a discovered TV, let the user pick which
/// servers to push, confirm the (server-authoritative) match code once, then
/// approve each chosen server.
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
        /// Connected; offer the phone's servers (those with a stored token).
        case pickServers(tvName: String, servers: [ServerEntry])
        /// Awaiting the user's match-code confirmation for the first server.
        case confirmMatch(tvName: String, serverName: String, matchCode: String)
        /// Pushing/approving the remaining servers after confirmation.
        case working(progress: String)
        case finished(signedIn: [String], failed: [String])
        case error(String)
    }

    enum Timeouts {
        /// Connect + TLS + the TV's `hello`. Generous enough for peer-to-peer
        /// Wi-Fi bring-up, short enough that a vanished TV isn't a trap.
        static let hello: Duration = .seconds(15)
        /// First `deviceStarted` waits on the TV user allowing the setup
        /// request on their screen — leave time to find the remote.
        static let firstDeviceStarted: Duration = .seconds(90)
        static let deviceStarted: Duration = .seconds(30)
        static let serverResult: Duration = .seconds(30)
    }

    private(set) var state: State = .connecting

    private let api: any PairingDeviceAuthorizing
    private let channel: any PairingChannel
    private let stream: AsyncThrowingStream<PairingMessage, Error>
    /// "iPhone" or "iPad" — pairing copy names the device the user is holding.
    private let deviceModel: String
    private let availableServers: @MainActor () async -> [ServerEntry]
    private let accessToken: @MainActor (String) async -> String?

    private var tvName: String
    private var queue: [ServerEntry] = []
    private var confirmed = false
    private var isFirstPush = true
    private var pendingUserCode: String?
    private var signedIn: [String] = []
    private var failed: [String] = []
    private var runTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// Set once the flow reaches a deliberate end (summary, error, or a
    /// user-initiated cancel), so a trailing stream close can't repaint the
    /// terminal state and late messages are ignored.
    private var concluded = false
    private static let logger = Logger(subsystem: "com.continuum.app", category: "pairing.companion")

    init(
        channel: any PairingChannel,
        stream: AsyncThrowingStream<PairingMessage, Error>,
        tvName: String = "Apple TV",
        api: any PairingDeviceAuthorizing = PairingDeviceAPI(),
        deviceModel: String = UIDevice.current.model,
        availableServers: @escaping @MainActor () async -> [ServerEntry] = CompanionPairingCoordinator.serversWithTokens,
        accessToken: @escaping @MainActor (String) async -> String? = { await TokenStore.shared.getAccessToken(for: $0) }
    ) {
        self.channel = channel
        self.stream = stream
        self.tvName = tvName
        self.api = api
        self.deviceModel = deviceModel
        self.availableServers = availableServers
        self.accessToken = accessToken
    }

    /// Open the transport for a discovered TV and start its coordinator.
    /// The view never touches the session; it renders `state` and forwards
    /// user intent.
    static func connect(to tv: DiscoveredTV) async -> CompanionPairingCoordinator {
        let session = PairingSession(endpoint: tv.endpoint)
        let stream = await session.open()
        let coordinator = CompanionPairingCoordinator(channel: session, stream: stream, tvName: tv.name)
        coordinator.start()
        return coordinator
    }

    /// Begin consuming the session. Idempotent; the stream has exactly one
    /// reader for the coordinator's whole life.
    func start() {
        guard runTask == nil else { return }
        armWatchdog(Timeouts.hello, "Couldn’t reach \(tvName). Make sure it’s still on its setup screen, then try again.")
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
        case let .hello(name, _, _, supported):
            disarmWatchdog()
            tvName = name
            guard supported.contains(PairingProtocol.version) else {
                await conclude(.error("Update Silo on both devices to continue."), goodbye: .cancel(reason: "version_unsupported"))
                return
            }
            let servers = await availableServers()
            guard !servers.isEmpty else {
                await conclude(.error("Sign in to a server on this \(deviceModel) first."), goodbye: .cancel(reason: "no_servers"))
                return
            }
            state = .pickServers(tvName: name, servers: servers)
        case let .deviceStarted(_, userCode, matchCode):
            disarmWatchdog()
            await handleDeviceStarted(userCode: userCode, channelCode: matchCode)
        case let .serverResult(_, status, _):
            disarmWatchdog()
            recordResult(signedInOK: status == .signedIn)
            await pushNext()
        case .cancel:
            await conclude(.error("Setup was cancelled on \(tvName)."), goodbye: nil)
        case .pushServer, .done:
            break // phone → TV kinds; a conforming TV never sends these
        }
    }

    private func handleDeviceStarted(userCode: String, channelCode: String) async {
        guard let server = queue.first else { return }
        guard let token = await accessToken(server.id), !token.isEmpty else {
            await failCurrentAndAdvance(server)
            return
        }
        do {
            // Display the SERVER's authoritative match code, not the channel's.
            let lookup = try await api.lookup(serverURL: server.url, bearer: token, userCode: userCode)
            guard let serverCode = lookup.matchCode, !serverCode.isEmpty else {
                // The match code is the flow's one trust anchor; a missing code
                // is a hard failure, never an empty prompt.
                Self.logger.error("server \(server.url, privacy: .public) returned no match code")
                await failCurrentAndAdvance(server)
                return
            }
            pendingUserCode = userCode
            if confirmed {
                // Confirm-once multi-server: the user compared codes for the
                // first server only. Bind later approvals to the channel — if
                // the code the TV displayed doesn't match the server's
                // authoritative one, someone is splicing the session; refuse.
                guard serverCode == channelCode else {
                    Self.logger.error("match code mismatch for \(server.url, privacy: .public); refusing auto-approve")
                    await failCurrentAndAdvance(server)
                    return
                }
                await approveCurrent(server)
            } else {
                // No watchdog while the user deliberates: the TV keeps its
                // device code alive, and the loop keeps reading, so a TV-side
                // cancel or drop is still surfaced immediately.
                state = .confirmMatch(tvName: tvName, serverName: server.displayName, matchCode: serverCode)
            }
        } catch {
            await failCurrentAndAdvance(server)
        }
    }

    // MARK: - User actions

    /// User tapped a set of servers to push (order = approval order).
    func pushSelected(_ servers: [ServerEntry]) async {
        guard case .pickServers = state, !servers.isEmpty else { return }
        queue = servers
        await pushNext()
    }

    /// User confirmed the displayed match code matches the TV.
    func confirmMatch() async {
        guard case .confirmMatch = state, let server = queue.first else { return }
        confirmed = true
        await approveCurrent(server)
    }

    /// User said the codes don't match — abort the whole session.
    func declineMatch() async {
        await conclude(.error("The codes didn’t match, so setup was cancelled."), goodbye: .cancel(reason: "match_declined"))
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

    private func pushNext() async {
        guard !concluded else { return }
        guard let server = queue.first else {
            await conclude(.finished(signedIn: signedIn, failed: failed), goodbye: .done)
            return
        }
        let firstPush = isFirstPush
        isFirstPush = false
        if firstPush {
            state = .working(progress: "Continue on \(tvName) — allow this \(deviceModel) to set it up.")
        } else {
            state = .working(progress: "Setting up \(server.displayName)…")
        }
        // Arm BEFORE the suspending send: the stream reader keeps running
        // while `send` is suspended, so a fast TV's `deviceStarted` could
        // otherwise land (and disarm nothing) before this task resumed and
        // armed a stale watchdog over the confirm screen.
        armWatchdog(
            firstPush ? Timeouts.firstDeviceStarted : Timeouts.deviceStarted,
            firstPush
                ? "\(tvName) didn’t respond. Make sure you allowed the request on the TV, then try again."
                : "\(tvName) stopped responding."
        )
        do {
            try await channel.send(.pushServer(serverURL: server.url, serverName: server.displayName))
        } catch {
            await conclude(.error("Connection to \(tvName) was lost."), goodbye: nil)
        }
    }

    private func approveCurrent(_ server: ServerEntry) async {
        state = .working(progress: "Approving \(server.displayName)…")
        let token = await accessToken(server.id) ?? ""
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
            await conclude(
                .error("Couldn’t reach \(server.displayName) to approve the sign-in. Check this \(deviceModel)’s connection and try again."),
                goodbye: .cancel(reason: "approve_failed")
            )
        }
    }

    private func recordResult(signedInOK: Bool) {
        guard let server = queue.first else { return }
        if signedInOK {
            signedIn.append(server.displayName)
        } else {
            failed.append(server.displayName)
        }
        queue.removeFirst()
    }

    /// A server failed before approval (token missing, lookup failed, or the
    /// codes couldn't be bound). Move on; the TV abandons its in-flight
    /// attempt as soon as the next `pushServer` arrives.
    private func failCurrentAndAdvance(_ server: ServerEntry) async {
        failed.append(server.displayName)
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

    /// Whether this device has anything to hand off — gates the discovery
    /// card so a signed-out phone is never invited into a dead-end flow.
    static func hasServerWithToken() async -> Bool {
        await !serversWithTokens().isEmpty
    }
}
#endif

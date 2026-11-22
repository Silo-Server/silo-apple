import Foundation
import Network

/// TLS-PSK parameter builder shared by every Silo LAN protocol. The keys are
/// FIXED, non-secret strings compiled into the app: opportunistic
/// confidentiality only, NOT an authentication boundary. Each protocol layers
/// its own trust anchor on top (pairing: the server-issued match code;
/// SiloControl: same-account discovery). A PSK lets both an `NWListener` and
/// an outbound `NWConnection` negotiate TLS without certificate/identity
/// management.
enum SiloLANTLS {
    static func parameters(psk: String, identity: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let pskData = Data(psk.utf8)
        let identityData = Data(identity.utf8)
        let key = pskData.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityDispatch = identityData.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            key as __DispatchData,
            identityDispatch as __DispatchData
        )
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t.AES_128_GCM_SHA256
        )
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }
}

/// A layer under the framing that seals each frame body once both peers
/// have exchanged one plain opening frame. SiloControl uses it for a Roku at
/// level `sealed` (`SiloControlSealedChannel`), where TLS is unavailable.
/// The session owns its value and calls it only from the actor.
protocol SiloFrameSealing: Sendable {
    /// The plain frame body this side sends before anything else.
    var openingFrame: Data { get }
    /// Whether the peer's opening frame has arrived and frames are sealed.
    var isKeyed: Bool { get }
    /// Reads the peer's first frame. Throws when it isn't an opening frame
    /// this side can key from; the session then ends with that error.
    mutating func receiveOpening(_ body: Data) throws
    mutating func seal(_ payload: Data) throws -> Data
    mutating func open(_ body: Data) throws -> Data
}

/// One `NWConnection` carrying length-prefixed JSON frames of a single
/// message type. The shared transport under companion pairing and
/// SiloControl — both sides of each protocol use it (inbound via
/// `init(connection:)` from an `NWListener`, outbound via `init(endpoint:)`).
///
/// Behaviors:
/// - Ordered outbound FIFO: `enqueue` is fire-and-forget, `send` is awaited,
///   and both route through one drain task so frames never reorder.
/// - `closeGracefully(goodbye:)` sends a final frame ahead of the FIN under a
///   watchdog, so a wedged connection can never hang the caller.
/// - A single idempotent teardown path for every terminal exit (explicit
///   close, `.failed`, `.cancelled`, receive error, EOF).
actor FramedJSONSession<Message: Codable & Sendable> {
    enum SessionError: Error {
        case closed
    }

    private let connection: NWConnection
    private var frameBuffer = SiloFrameBuffer()
    private var continuation: AsyncThrowingStream<Message, Error>.Continuation?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var isOpen = false
    /// With sealing, nothing but the opening frame is written until the
    /// peer's opening frame keys the session.
    private var sealing: (any SiloFrameSealing)?
    private var keyedWaiter: CheckedContinuation<Void, Error>?
    /// The sealing layer's error that ended the session, handed to the sends
    /// it fails so a caller can say why (e.g. the TV refused the pairing).
    private var sealingFailure: Error?

    // Ordered outbound queue: enqueue() is nonisolated + FIFO; a single drain
    // task sends one frame at a time so messages never reorder. `send()` goes
    // through the SAME queue (carrying a completion continuation) so an
    // awaited send can't race ahead of, or behind, an enqueued frame.
    private struct OutboundItem {
        let message: Message
        let completion: CheckedContinuation<Void, Error>?
    }
    private let outbound: AsyncStream<OutboundItem>
    private let outboundContinuation: AsyncStream<OutboundItem>.Continuation

    /// Inbound side: wrap a connection handed up by an `NWListener`.
    init(connection: NWConnection) {
        self.connection = connection
        (outbound, outboundContinuation) = AsyncStream.makeStream()
    }

    /// Outbound side: connect to a discovered endpoint using the protocol's
    /// parameters, sealing frames when `sealing` is given.
    init(endpoint: NWEndpoint, parameters: NWParameters, sealing: (any SiloFrameSealing)? = nil) {
        connection = NWConnection(to: endpoint, using: parameters)
        self.sealing = sealing
        (outbound, outboundContinuation) = AsyncStream.makeStream()
    }

    /// Start the connection and begin the receive loop. Returns a stream of
    /// decoded inbound messages; the stream finishes on close and throws on
    /// transport/decode error.
    func open() -> AsyncThrowingStream<Message, Error> {
        guard !isOpen else { return AsyncThrowingStream { $0.finish() } }
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            self.isOpen = true
            // Start the outbound drain immediately, not on `.ready`: callers
            // may await `send()` straight after `open()` (e.g. the receiver's
            // `hello`), and a connection that fails during TLS setup must
            // fail those buffered continuations — `teardown` finishes the
            // FIFO, but only a running drain resumes its buffered items.
            // Writes queued before `.ready` simply park in `NWConnection`
            // until the transport comes up or is cancelled.
            Task { [weak self] in await self?.startDrainLoop() }
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    Task { await self.receiveLoop() }
                case .failed(let error):
                    Task { await self.teardown(error) }
                case .waiting:
                    // Transient for an outbound connection (no route yet,
                    // Wi-Fi associating, peer-to-peer bring-up). NW keeps
                    // retrying and can still reach `.ready`, so don't finish.
                    // Callers bound this with their own deadlines.
                    break
                case .cancelled:
                    Task { await self.teardown(nil) }
                default:
                    break
                }
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.close() }
            }
            self.connection.start(queue: .main)
        }
    }

    /// Fire-and-forget, ordered. Safe to call from any context; FIFO is
    /// preserved by call order because all call sites are @MainActor.
    nonisolated func enqueue(_ message: Message) {
        outboundContinuation.yield(OutboundItem(message: message, completion: nil))
    }

    private func startDrainLoop() async {
        if let opening = sealing?.openingFrame {
            do {
                try await writeFrame(opening)
                try await waitUntilKeyed()
            } catch {
                teardown(error)
            }
        }
        for await item in outbound {
            guard isOpen else {
                item.completion?.resume(throwing: sealingFailure ?? SessionError.closed)
                continue
            }
            do {
                try await writeRaw(item.message)
                item.completion?.resume()
            } catch {
                item.completion?.resume(throwing: error)
                teardown(error)
                // Keep draining after teardown: the `guard isOpen` branch fails
                // any already-queued sends fast instead of leaving their
                // awaiters hung. The loop ends when `teardown` finishes the
                // stream and the buffered items drain.
            }
        }
    }

    /// Awaited, ordered send. Routes through the same FIFO as `enqueue` so the
    /// write can't reorder relative to queued frames, and surfaces the write
    /// result to the caller.
    func send(_ message: Message) async throws {
        guard isOpen else { throw sealingFailure ?? SessionError.closed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            outboundContinuation.yield(OutboundItem(message: message, completion: cont))
        }
    }

    private func writeRaw(_ message: Message) async throws {
        var payload = try encoder.encode(message)
        if sealing != nil {
            do {
                payload = try sealing!.seal(payload)
            } catch {
                sealingFailure = error
                throw error
            }
        }
        try await writeFrame(payload)
    }

    private func writeFrame(_ payload: Data) async throws {
        let framed = try SiloFrame.encode(payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    func close() {
        teardown(nil)
    }

    /// Send a final `goodbye` frame (ordered after any pending sends) and
    /// await the write before tearing down, so the frame is handed to the
    /// transport ahead of the FIN. This lets the peer tell a deliberate
    /// disconnect from a dropped connection. Bounded by a watchdog so a
    /// wedged connection can't hang the caller: if the write hasn't
    /// completed in time, tear down anyway (the send continuation is then
    /// failed by the drain loop).
    func closeGracefully(goodbye: Message) async {
        guard isOpen else { return }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.close()
        }
        try? await send(goodbye)
        watchdog.cancel()
        teardown(nil)
    }

    private func waitUntilKeyed() async throws {
        guard isOpen else { throw sealingFailure ?? SessionError.closed }
        guard sealing?.isKeyed == false else { return }
        try await withCheckedThrowingContinuation { keyedWaiter = $0 }
    }

    private func teardown(_ error: Error?) {
        guard isOpen else { return }
        isOpen = false
        keyedWaiter?.resume(throwing: sealingFailure ?? SessionError.closed)
        keyedWaiter = nil
        connection.cancel()
        // Don't cancel the drain task — finishing the stream lets it drain any
        // buffered items and resume their `send` continuations with
        // `SessionError.closed` (the `guard isOpen` branch) instead of leaking
        // a hung awaiter. The task self-completes once the buffer empties.
        outboundContinuation.finish()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
    }

    /// The message bytes in a received frame body, or nil for the peer's
    /// opening frame, which keys a sealed session and wakes the writer.
    private func unsealed(_ body: Data) throws -> Data? {
        guard sealing != nil else { return body }
        do {
            if sealing!.isKeyed { return try sealing!.open(body) }
            try sealing!.receiveOpening(body)
        } catch {
            sealingFailure = error
            throw error
        }
        keyedWaiter?.resume()
        keyedWaiter = nil
        return nil
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: Error?) {
        guard isOpen, continuation != nil else { return }
        if let error {
            teardown(error)
            return
        }
        if let data, !data.isEmpty {
            do {
                for body in try frameBuffer.append(data) {
                    guard let payload = try unsealed(body) else { continue }
                    let message = try decoder.decode(Message.self, from: payload)
                    continuation?.yield(message)
                }
            } catch {
                teardown(error)
                return
            }
        }
        if isComplete {
            teardown(nil)
            return
        }
        receiveLoop()
    }
}

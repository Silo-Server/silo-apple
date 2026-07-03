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

/// One `NWConnection` carrying length-prefixed JSON frames of a single
/// message type. The shared transport under companion pairing and
/// SiloControl — both sides of each protocol use it (inbound via
/// `init(connection:)` from an `NWListener`, outbound via `init(endpoint:)`).
///
/// Hardened behaviors (originally battle-tested in SiloControl, now shared):
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
    private var drainTask: Task<Void, Never>?

    /// Inbound side: wrap a connection handed up by an `NWListener`.
    init(connection: NWConnection) {
        self.connection = connection
        (outbound, outboundContinuation) = AsyncStream.makeStream()
    }

    /// Outbound side: connect to a discovered endpoint using the protocol's
    /// TLS-PSK parameters.
    init(endpoint: NWEndpoint, parameters: NWParameters) {
        connection = NWConnection(to: endpoint, using: parameters)
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
            self.drainTask = Task { [weak self] in await self?.startDrainLoop() }
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
        for await item in outbound {
            guard isOpen else {
                item.completion?.resume(throwing: SessionError.closed)
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
        guard isOpen else { throw SessionError.closed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            outboundContinuation.yield(OutboundItem(message: message, completion: cont))
        }
    }

    private func writeRaw(_ message: Message) async throws {
        let payload = try encoder.encode(message)
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

    private func teardown(_ error: Error?) {
        guard isOpen else { return }
        isOpen = false
        connection.cancel()
        // Don't cancel the drain task — finishing the stream lets it drain any
        // buffered items and resume their `send` continuations with
        // `SessionError.closed` (the `guard isOpen` branch) instead of leaking
        // a hung awaiter. The task self-completes once the buffer empties.
        drainTask = nil
        outboundContinuation.finish()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
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
                for payload in try frameBuffer.append(data) {
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

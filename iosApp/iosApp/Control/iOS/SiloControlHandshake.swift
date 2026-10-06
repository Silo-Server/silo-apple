#if os(iOS)
import Foundation

/// Why a launch's profile handoff failed.
enum SiloControlHandoffError: LocalizedError, Equatable {
    case updateRequired
    case timedOut
    case cancelled(String)
    case identityChanged
    case invalidResponse
    /// The connection the handoff ran on closed, or the client moved to
    /// another one.
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .updateRequired:
            return "Update Silo on the TV to play with your profile."
        case .timedOut:
            return "The TV took too long to prepare your profile."
        case .cancelled(let message):
            return message
        case .identityChanged:
            return "Your server or profile changed. Try playing again."
        case .invalidResponse:
            return "The TV could not verify your playback profile."
        case .connectionClosed:
            return "Lost connection to the TV."
        }
    }
}

/// What the phone waits for from the TV on one SiloControl connection: the
/// TV's hello, which fixes the protocol version, and the TV's replies to a
/// profile handoff offer.
///
/// `SiloControlClient` makes one per connection, feeds it that connection's
/// frames, and closes it when the connection goes away. Closing ends every
/// wait at once with `.connectionClosed`, so a TV that drops mid-handoff
/// fails the launch immediately rather than at the wait's deadline. A closed
/// handshake stays closed; the next connection gets a new one, so a launch
/// can never read another connection's hello or replies.
@MainActor
final class SiloControlHandshake {
    enum FirstReply: Equatable {
        case challenge(SiloControlHandoffChallenge)
        case ready(SiloControlHandoffReady)
    }

    private var isClosed = false
    private var receivedHello = false
    private var helloVersion: Int?
    private var handoffRequestId: String?
    private var challenge: SiloControlHandoffChallenge?
    private var ready: SiloControlHandoffReady?
    private var cancellation: SiloControlHandoffCancel?
    private let changes = SiloControlChangeSignal()

    /// Records the TV's hello, or a handoff reply to the pending offer, and
    /// wakes the waits. Replies to any other offer, and every other frame,
    /// are ignored.
    func receive(_ message: SiloControlMessage) {
        guard !isClosed else { return }
        switch message {
        case .hello(let hello):
            receivedHello = true
            helloVersion = SiloControlProtocol.negotiatedVersion(with: hello.supportedVersions)
        case .handoffChallenge(let challenge):
            guard challenge.requestId == handoffRequestId else { return }
            self.challenge = challenge
        case .handoffReady(let ready):
            guard ready.requestId == handoffRequestId else { return }
            self.ready = ready
        case .handoffCancel(let cancel):
            guard cancel.requestId == handoffRequestId else { return }
            cancellation = cancel
        default:
            return
        }
        changes.notify()
    }

    /// Starts accepting replies to the offer `requestId`, dropping any
    /// earlier offer's.
    func beginHandoff(requestId: String) {
        handoffRequestId = requestId
        challenge = nil
        ready = nil
        cancellation = nil
    }

    /// Stops accepting handoff replies.
    func endHandoff() {
        handoffRequestId = nil
        challenge = nil
        ready = nil
        cancellation = nil
    }

    /// Fails every current and future wait with `.connectionClosed`.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        changes.notify()
    }

    /// The protocol version the TV's hello agreed, or nil when the two
    /// devices share none or no hello arrives within `timeout`.
    func negotiatedVersion(within timeout: Duration) async throws -> Int? {
        do {
            return try await wait(within: timeout) { receivedHello ? .some(helloVersion) : nil }
        } catch SiloControlHandoffError.timedOut {
            return nil
        }
    }

    /// The TV's first reply to the offer `requestId`: a challenge to approve,
    /// or, when the TV already holds this phone's profile, a ready straight
    /// away.
    func firstReply(to requestId: String, within timeout: Duration) async throws -> FirstReply {
        try await wait(within: timeout) {
            try throwIfCancelled(requestId)
            if let ready, ready.requestId == requestId { return .ready(ready) }
            if let challenge, challenge.requestId == requestId { return .challenge(challenge) }
            return nil
        }
    }

    /// The TV's ready for the offer `requestId`, including one that arrived
    /// while the phone was still approving the challenge.
    func ready(for requestId: String, within timeout: Duration) async throws -> SiloControlHandoffReady {
        try await wait(within: timeout) {
            try throwIfCancelled(requestId)
            if let ready, ready.requestId == requestId { return ready }
            return nil
        }
    }

    private func throwIfCancelled(_ requestId: String) throws {
        if let cancellation, cancellation.requestId == requestId {
            throw SiloControlHandoffError.cancelled(cancellation.message ?? "The TV cancelled profile setup.")
        }
    }

    /// Returns `value()` once it's non-nil. Each frame and `close()` wakes
    /// the loop to check again; `close()`, the deadline and task
    /// cancellation end it.
    private func wait<Value>(
        within timeout: Duration,
        for value: () throws -> Value?
    ) async throws -> Value {
        let deadline = ContinuousClock.now + timeout
        while true {
            if isClosed { throw SiloControlHandoffError.connectionClosed }
            if let value = try value() { return value }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw SiloControlHandoffError.timedOut }
            await changes.nextChange(before: deadline)
        }
    }
}

/// Parks a main-actor wait until something it watches may have changed.
/// Producers call `notify()`. A parked wait also ends at its deadline or when
/// its task is cancelled. Waiters re-check their own condition after every
/// wake, so an early wake is harmless.
@MainActor
final class SiloControlChangeSignal {
    private var parked: [UUID: CheckedContinuation<Void, Never>] = [:]

    func nextChange(before deadline: ContinuousClock.Instant) async {
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(until: deadline)
            guard !Task.isCancelled else { return }
            self?.wake(id)
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { parked[id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wake(id) }
        }
    }

    func notify() {
        let waiting = parked
        parked.removeAll()
        for continuation in waiting.values { continuation.resume() }
    }

    private func wake(_ id: UUID) {
        parked.removeValue(forKey: id)?.resume()
    }
}
#endif

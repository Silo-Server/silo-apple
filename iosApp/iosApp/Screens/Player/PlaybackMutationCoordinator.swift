import Foundation
import Observation

@Observable
@MainActor
final class PlaybackStopNotices {
    static let shared = PlaybackStopNotices()
    private(set) var pending: Set<UUID> = []
    func setPending(_ id: UUID, _ value: Bool) {
        if value { pending.insert(id) } else { pending.remove(id) }
    }
}

/// Retains sequenced mutation intent independently of the player/bridge lifetime.
/// Cross-process replay is not activated without authenticated installation identity.
actor PlaybackMutationCoordinator {
    static let shared = PlaybackMutationCoordinator()

    private struct Context: Sendable {
        let recordID: UUID
        let sessionID: String
        let authority: PlaybackMutationAuthority
    }
    private let api: SiloAPI
    private let tokens: TokenStore
    private let store: PlaybackMutationStore
    private let retryDelays: [Duration]
    private var contexts: [String: Context] = [:]
    private var draining: Set<UUID> = []

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared, store: PlaybackMutationStore = .shared,
         retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5), .seconds(5), .seconds(5)]) {
        self.api = api
        self.tokens = tokens
        self.store = store
        self.retryDelays = retryDelays
    }

    func register(sessionID: String, features: [String], auth: CapturedDurableAccountAuth,
                  installationID: String? = nil) async throws {
        guard features.contains(PlaybackSequencedContract.feature) else { return }
        let authority = try PlaybackMutationAuthority(auth: auth, installationID: installationID)
        _ = try await currentAuth(authority)
        let saved = try await store.register(sessionID: sessionID, authority: authority)
        _ = try await currentAuth(authority)
        // A bare server session ID must never retarget an older bridge's
        // delayed callback to another account/profile/origin in this process.
        if let existing = contexts[sessionID], existing.authority != authority {
            throw PlaybackSequencedError.authorityChanged
        }
        contexts[sessionID] = Context(recordID: saved.id, sessionID: sessionID, authority: authority)
    }

    func handles(_ sessionID: String) -> Bool { contexts[sessionID] != nil }

    private func currentAuth(_ authority: PlaybackMutationAuthority) async throws -> CapturedOrdinaryRequestAuth {
        guard let current = await tokens.captureDurableAccountAuth(),
              try PlaybackMutationAuthority(auth: current, installationID: authority.installationID) == authority else {
            throw PlaybackSequencedError.authorityChanged
        }
        return current.request
    }

    func report(sessionID: String, position: Double, isPaused: Bool) async throws {
        guard let context = contexts[sessionID] else { throw PlaybackSequencedError.invalidSession }
        let auth = try await currentAuth(context.authority)
        let sample = try await store.prepareProgress(context.recordID, authority: context.authority,
            position: position, isPaused: isPaused)
        let receipt = try await api.reportSequencedPlaybackProgress(sessionID: sessionID, sample: sample, auth: auth)
        _ = try await currentAuth(context.authority)
        try await store.acknowledgeProgress(context.recordID, authority: context.authority, sent: sample, receipt: receipt)
    }

    @discardableResult
    func stop(sessionID: String, position: Double?, isPaused: Bool) async throws -> Bool {
        guard let context = contexts[sessionID] else { throw PlaybackSequencedError.invalidSession }
        await PlaybackStopNotices.shared.setPending(context.recordID, true)
        let stop = try await store.prepareStop(context.recordID, authority: context.authority, position: position, isPaused: isPaused)
        let saved = try await store.session(context.recordID, authority: context.authority)
        if saved.stopState == .terminal {
            await PlaybackStopNotices.shared.setPending(context.recordID, false)
            return true
        }
        guard draining.insert(context.recordID).inserted else { return false }
        defer { draining.remove(context.recordID) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        for attempt in 0...retryDelays.count {
            do {
                try Task.checkCancellation()
                let auth = try await currentAuth(context.authority)
                let receipt = try await api.stopSequencedPlayback(sessionID: context.sessionID, stop: stop, auth: auth)
                _ = try await currentAuth(context.authority)
                try await store.acknowledgeStop(context.recordID, authority: context.authority, sent: stop, receipt: receipt)
                if receipt.outcome != .draining {
                    await PlaybackStopNotices.shared.setPending(context.recordID, false)
                    return true
                }
            } catch PlaybackSequencedError.authorityChanged { return false }
            catch HTTPError.requestIdentityChanged { return false }
            catch HTTPError.http(let code, _) where [400, 401, 403, 404, 409, 422].contains(code) { return false }
            catch is CancellationError { return false }
            catch { /* Preserve exact durable intent after an uncertain response. */ }
            guard attempt < retryDelays.count, ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: retryDelays[attempt]) } catch { return false }
        }
        return false
    }

    /// Explicit same-process user retry. Unknown-installation records are never
    /// loaded into this context map automatically after process restart.
    func retryPendingStops() async {
        for context in Array(contexts.values) {
            guard let session = try? await store.session(context.recordID, authority: context.authority),
                  session.stop != nil, session.stopState != .terminal else { continue }
            _ = try? await stop(sessionID: context.sessionID, position: nil, isPaused: true)
        }
    }
}

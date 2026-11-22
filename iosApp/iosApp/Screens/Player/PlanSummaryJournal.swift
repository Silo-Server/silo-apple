import Foundation
import os
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// Plans' `plan_summary` route events, kept on the device until the server
/// has them.
///
/// The spec is the server repo's `docs/design/2026-10-17-buffering-quality.md`,
/// *Telemetry*: a plan also stops being the playing plan when the app ends.
/// Its summary goes at that moment where the platform allows it; otherwise
/// the running summary is kept, updated each time the app leaves the
/// foreground, and sent at the next launch while its playback attempt is
/// current (under 24 hours). Each plan's summary has one `event_id`, so a
/// resend is a no-op: the server takes it once.
///
/// A suspended iOS or tvOS app that is killed hears nothing, so the player
/// keeps the running summary whenever the app leaves the foreground, and
/// every summary it sends is kept first and forgotten once the server
/// answers.
@MainActor
final class PlanSummaryJournal {
    static let shared = PlanSummaryJournal()

    /// One plan's summary, and whose session may send it.
    struct Entry: Codable, Equatable, Sendable {
        let eventId: String
        let installationID: String
        let serverId: String
        let profileId: String
        /// When the plan was adopted: its playback attempt is at least this
        /// old.
        let planStartedAt: Date
        var event: PlaybackV3RouteEvent

        var withoutThroughput: Entry {
            guard event.diagnostics["throughput_kbps"] != nil else { return self }
            var entry = self
            var diagnostics = event.diagnostics
            diagnostics["throughput_kbps"] = nil
            entry.event = PlaybackV3RouteEvent(
                protocolVersion: event.protocolVersion,
                playbackAttemptId: event.playbackAttemptId,
                sessionId: event.sessionId,
                planId: event.planId,
                planAttemptId: event.planAttemptId,
                planAttemptKey: event.planAttemptKey,
                event: event.event,
                failureClassification: event.failureClassification,
                fallbackReason: event.fallbackReason,
                appliedQuirkIds: event.appliedQuirkIds,
                quirkRegistryRevision: event.quirkRegistryRevision,
                outputContextId: event.outputContextId,
                diagnostics: diagnostics
            )
            return entry
        }
    }

    /// Sends one entry as `owner`. Throws as the route-event request does.
    typealias Send = @Sendable (Entry, CapturedOrdinaryRequestAuth) async throws -> Void
    /// Makes an entry and the owner that sends it; nil when there is none.
    typealias Build = @MainActor () async -> (entry: Entry, owner: CapturedOrdinaryRequestAuth)?

    /// How long a playback attempt stays current.
    static let attemptLifetime: TimeInterval = 24 * 60 * 60

    #if os(macOS)
    /// Posted on the main thread as the Mac app is asked to quit, before it
    /// waits for ``waitForWork(upTo:)``: players end their plans then.
    static let appWillQuit = Notification.Name("SiloPlanSummaryAppWillQuit")
    /// How long a quitting Mac waits for summaries on their way.
    static let quitWait: Duration = .seconds(2)
    #endif

    private let defaults: UserDefaults
    private let send: Send
    private static let storageKey = "playback.planSummaryJournal"
    /// Work from ``record(sending:_:)`` that has not finished.
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    /// Running summaries this run kept. Their plans may still be playing,
    /// so a replay leaves them; a plan's final summary may be replayed.
    private var runningThisRun: Set<String> = []
    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "PlanSummary")

    init(
        defaults: UserDefaults = .standard,
        send: @escaping Send = { entry, owner in
            try await PlaybackV2SessionAuthority(owner: owner, installationID: entry.installationID)
                .reportRouteEvent(entry.event, eventID: entry.eventId)
        }
    ) {
        self.defaults = defaults
        self.send = send
    }

    var entries: [Entry] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Keeps `entry`, replacing an earlier summary of the same plan.
    func keep(_ entry: Entry) {
        store(entries.filter { $0.eventId != entry.eventId } + [entry])
    }

    func forget(eventId: String) {
        store(entries.filter { $0.eventId != eventId })
    }

    /// Keeps the entry `build` makes and, with `sending`, sends it now: it is
    /// forgotten once the server answers, and one the network cut short goes
    /// at the next launch. Counted as in flight from this call, so a Mac that
    /// quits waits for it, and run as background work on iOS and tvOS so a
    /// suspension does not cut it short.
    func record(sending: Bool, _ build: @escaping Build) {
        let id = UUID()
        #if os(iOS) || os(tvOS)
        let background = BackgroundWork(name: "SiloPlanSummary")
        #endif
        inFlight[id] = Task { [weak self] in
            if let built = await build(), let self {
                if sending {
                    runningThisRun.remove(built.entry.eventId)
                } else {
                    runningThisRun.insert(built.entry.eventId)
                }
                // What is kept is what a later launch sends, and that carries
                // no throughput: the server files a sample under the network
                // that delivers it.
                keep(built.entry.withoutThroughput)
                if sending { await deliver(built.entry, as: built.owner) }
            }
            self?.inFlight[id] = nil
            #if os(iOS) || os(tvOS)
            background.end()
            #endif
        }
    }

    /// Sends what an earlier run kept for `owner`'s server and profile, and
    /// forgets what is too old to send. The rest waits for its own sign-in.
    func replay(as owner: CapturedOrdinaryRequestAuth, now: Date = Date()) async {
        let current = entries.filter { now.timeIntervalSince($0.planStartedAt) < Self.attemptLifetime }
        if current.count != entries.count { store(current) }
        for entry in current
        where entry.serverId == owner.account.serverId && entry.profileId == owner.profileId
            && !runningThisRun.contains(entry.eventId) {
            await deliver(entry, as: owner)
        }
    }

    /// Waits for the work in flight, at most `limit`: a Mac that quits holds
    /// its termination this long. Work still running then goes on, and what
    /// it kept is sent at the next launch.
    func waitForWork(upTo limit: Duration) async {
        let work = Array(inFlight.values)
        guard !work.isEmpty else { return }
        // Waiting on a task's value ignores cancellation, so the two waits
        // race to resume once rather than being joined.
        let done = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                for task in work { await task.value }
                if done.claim() { continuation.resume() }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                if done.claim() { continuation.resume() }
            }
        }
    }

    var hasWorkInFlight: Bool { !inFlight.isEmpty }

    private func deliver(_ entry: Entry, as owner: CapturedOrdinaryRequestAuth) async {
        do {
            try await send(entry, owner)
            forget(eventId: entry.eventId)
        } catch where Self.serverAnswered(error) {
            // Refused: sending it again would be refused the same way.
            Self.logger.warning("plan summary refused: \(MediaLogRedactor.sanitize(error), privacy: .public)")
            forget(eventId: entry.eventId)
        } catch {
            Self.logger.notice("plan summary kept for the next launch: \(MediaLogRedactor.sanitize(error), privacy: .public)")
        }
    }

    /// Whether `error` is the server's answer rather than a request that
    /// never got one.
    nonisolated static func serverAnswered(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let httpError = error as? HTTPError else { return true }
        switch httpError {
        case .network, .requestIdentityChanged, .authorityChanged:
            return false
        default:
            return true
        }
    }

    /// Claimed once, by whichever caller gets there first.
    @MainActor
    private final class Once {
        private var claimed = false

        func claim() -> Bool {
            defer { claimed = true }
            return !claimed
        }
    }

    private func store(_ entries: [Entry]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

#if os(iOS) || os(tvOS)
/// A background task that ends once, when the work does or when the
/// system's time for it runs out.
@MainActor
final class BackgroundWork {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif

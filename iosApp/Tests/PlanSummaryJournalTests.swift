import XCTest
@testable import Silo

/// Plan summaries kept on the device for when the app ends before its plan:
/// the server repo's buffering-quality spec, *Telemetry*.
@MainActor
final class PlanSummaryJournalTests: XCTestCase {
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        private var samples: [String?] = []
        var failure: Error?
        /// How long each send waits before it answers.
        var delay: Duration?

        func append(_ entry: PlanSummaryJournal.Entry) throws {
            try lock.withLock {
                values.append(entry.eventId)
                samples.append(entry.event.diagnostics["throughput_kbps"])
                if let failure { throw failure }
            }
        }

        var eventIds: [String] { lock.withLock { values } }
        var throughputs: [String?] { lock.withLock { samples } }
    }

    private var sent = Sent()
    private var journal: PlanSummaryJournal!
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() async throws {
        let name = "PlanSummaryJournalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let sent = sent
        journal = PlanSummaryJournal(defaults: defaults) { entry, _ in
            if let delay = sent.delay { try await Task.sleep(for: delay) }
            try sent.append(entry)
        }
    }

    private func entry(_ eventId: String, server: String = "server", profile: String = "profile",
                       startedHoursAgo: Double = 1, playedMs: String = "1000",
                       throughputKbps: String? = nil) -> PlanSummaryJournal.Entry {
        PlanSummaryJournal.Entry(
            eventId: eventId, installationID: "installation", serverId: server, profileId: profile,
            planStartedAt: now.addingTimeInterval(-startedHoursAgo * 3_600),
            event: PlaybackV3RouteEvent(
                protocolVersion: 3, playbackAttemptId: "attempt", sessionId: "session", planId: "plan",
                planAttemptId: nil, planAttemptKey: nil, event: "plan_summary", failureClassification: nil,
                fallbackReason: nil, appliedQuirkIds: [], quirkRegistryRevision: nil, outputContextId: nil,
                diagnostics: ["played_ms": playedMs, "throughput_kbps": throughputKbps].compactMapValues { $0 }
            )
        )
    }

    private func owner(server: String = "server", profile: String? = "profile") -> CapturedOrdinaryRequestAuth {
        CapturedOrdinaryRequestAuth(
            account: RefreshAccountIdentity(serverId: server, serverURL: "https://silo.example", credentialGenerationID: UUID()),
            credentialOwner: .persistentServer(serverId: server),
            accessToken: "token", profileId: profile, profileToken: nil
        )
    }

    func testAPlansLaterSummaryReplacesItsEarlierOne() {
        journal.keep(entry("a", playedMs: "1000"))
        journal.keep(entry("b"))
        journal.keep(entry("a", playedMs: "5000"))
        XCTAssertEqual(journal.entries.map(\.eventId), ["b", "a"])
        XCTAssertEqual(journal.entries.last?.event.diagnostics["played_ms"], "5000")
    }

    /// The next launch sends what the server and profile it signs in to
    /// kept, under the same `event_id`; another profile's waits, and one past
    /// its attempt's 24 hours is dropped.
    func testALaunchSendsWhatItsSessionKept() async {
        journal.keep(entry("mine"))
        journal.keep(entry("other profile", profile: "someone else"))
        journal.keep(entry("other server", server: "elsewhere"))
        journal.keep(entry("too old", startedHoursAgo: 25))

        await journal.replay(as: owner(), now: now)

        XCTAssertEqual(sent.eventIds, ["mine"])
        XCTAssertEqual(journal.entries.map(\.eventId), ["other profile", "other server"])
    }

    /// One the network cut short stays for the next launch; one the server
    /// refused would be refused again.
    func testOnlyAnAnsweredSendIsForgotten() async {
        journal.keep(entry("a"))
        sent.failure = HTTPError.network(underlying: URLError(.notConnectedToInternet))
        await journal.replay(as: owner(), now: now)
        XCTAssertEqual(journal.entries.map(\.eventId), ["a"])

        sent.failure = PlaybackSequencedError.invalidResponse
        await journal.replay(as: owner(), now: now)
        XCTAssertTrue(journal.entries.isEmpty)
        XCTAssertEqual(sent.eventIds, ["a", "a"], "the same event_id both times")
    }

    /// A quitting Mac waits no longer than its limit, even for a send that
    /// is still waiting on the server; that summary stays kept.
    func testTheQuitWaitEndsAtItsLimit() async {
        sent.delay = .seconds(5)
        let auth = owner()
        let slow = entry("slow")
        journal.record(sending: true) { (slow, auth) }
        let clock = ContinuousClock()
        let started = clock.now
        await journal.waitForWork(upTo: .milliseconds(200))
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(2))
        XCTAssertTrue(journal.hasWorkInFlight)
        XCTAssertEqual(journal.entries.map(\.eventId), ["slow"])
    }

    /// A summary this run kept belongs to a plan that may still be playing:
    /// a sign-in during the run replays only what earlier runs kept.
    func testAReplayLeavesThisRunsSummaries() async {
        let auth = owner()
        let running = entry("running")
        journal.record(sending: false) { (running, auth) }
        await journal.waitForWork(upTo: .seconds(5))
        journal.keep(entry("earlier run"))

        await journal.replay(as: auth, now: now)

        XCTAssertEqual(sent.eventIds, ["earlier run"])
        XCTAssertEqual(journal.entries.map(\.eventId), ["running"])
    }

    /// A summary sent live is kept until the server has it, so a quit or kill
    /// mid-send still delivers it; a running one is only kept.
    func testARecordedSummaryIsKeptUntilSent() async {
        let auth = owner()
        let kept = entry("running")
        journal.record(sending: false) { (kept, auth) }
        await journal.waitForWork(upTo: .seconds(5))
        XCTAssertEqual(journal.entries.map(\.eventId), ["running"])
        XCTAssertTrue(sent.eventIds.isEmpty)

        sent.failure = HTTPError.network(underlying: URLError(.timedOut))
        let final = entry("running", playedMs: "9000", throughputKbps: "21000")
        journal.record(sending: true) { (final, auth) }
        XCTAssertTrue(journal.hasWorkInFlight, "counted from the call, before it runs")
        await journal.waitForWork(upTo: .seconds(5))
        // A later launch sends no throughput: it could credit another network.
        XCTAssertEqual(journal.entries, [entry("running", playedMs: "9000")], "the final summary, for the next launch")
        XCTAssertEqual(sent.throughputs, ["21000"], "the live send carries it")

        sent.failure = nil
        journal.record(sending: true) { (final, auth) }
        await journal.waitForWork(upTo: .seconds(5))
        XCTAssertTrue(journal.entries.isEmpty)
        XCTAssertFalse(journal.hasWorkInFlight)
    }
}

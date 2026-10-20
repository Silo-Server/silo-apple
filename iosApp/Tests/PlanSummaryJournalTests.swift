import XCTest
@testable import Silo

/// Plan summaries kept on the device for when the app ends before its plan:
/// the server repo's buffering-quality spec, *Telemetry*.
@MainActor
final class PlanSummaryJournalTests: XCTestCase {
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(eventId: String, profileId: String?)] = []
        var failure: Error?

        func append(_ entry: PlanSummaryJournal.Entry, _ owner: CapturedOrdinaryRequestAuth) throws {
            try lock.withLock {
                values.append((entry.eventId, owner.profileId))
                if let failure { throw failure }
            }
        }

        var eventIds: [String] { lock.withLock { values.map(\.eventId) } }
    }

    private var sent = Sent()
    private var journal: PlanSummaryJournal!
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUp() async throws {
        let name = "PlanSummaryJournalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let sent = sent
        journal = PlanSummaryJournal(defaults: defaults) { entry, owner in try sent.append(entry, owner) }
    }

    private func entry(_ eventId: String, server: String = "server", profile: String = "profile",
                       startedHoursAgo: Double = 1, playedMs: String = "1000") -> PlanSummaryJournal.Entry {
        PlanSummaryJournal.Entry(
            eventId: eventId, installationID: "installation", serverId: server, profileId: profile,
            planStartedAt: now.addingTimeInterval(-startedHoursAgo * 3_600),
            event: PlaybackV3RouteEvent(
                protocolVersion: 3, playbackAttemptId: "attempt", sessionId: "session", planId: "plan",
                planAttemptId: nil, planAttemptKey: nil, event: "plan_summary", failureClassification: nil,
                fallbackReason: nil, appliedQuirkIds: [], quirkRegistryRevision: nil, outputContextId: nil,
                diagnostics: ["played_ms": playedMs]
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
        let final = entry("running", playedMs: "9000")
        journal.record(sending: true) { (final, auth) }
        XCTAssertTrue(journal.hasWorkInFlight, "counted from the call, before it runs")
        await journal.waitForWork(upTo: .seconds(5))
        XCTAssertEqual(journal.entries, [final], "the final summary, for the next launch")

        sent.failure = nil
        journal.record(sending: true) { (final, auth) }
        await journal.waitForWork(upTo: .seconds(5))
        XCTAssertTrue(journal.entries.isEmpty)
        XCTAssertFalse(journal.hasWorkInFlight)
    }
}

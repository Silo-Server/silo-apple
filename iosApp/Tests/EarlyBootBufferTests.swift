import XCTest
@testable import Silo

/// Coverage for the early-boot staging buffer: startup breadcrumbs emitted
/// before the diagnostics consent context resolves are held in memory, and
/// reach the journal only when the first consent establish of the launch
/// permits it. The gate itself is unchanged — these tests assert the buffer
/// never routes around it.
final class EarlyBootBufferTests: XCTestCase {
    // MARK: - Buffer mechanics

    func testBoundedBufferDropsOldestFirstOnOverflow() {
        let buffer = makeBuffer(capacity: 3)

        for index in 0..<5 {
            XCTAssertTrue(buffer.record(
                category: .lifecycle,
                tag: "Boot\(index)",
                message: "phase changed",
                attrs: ["phase": .string("phase-\(index)")],
                captureSessionID: "run-overflow"
            ))
        }

        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.lines.count, 3)
        XCTAssertEqual(snapshot.droppedCount, 2)
        // Oldest-first eviction: the two earliest lines are gone, the newest
        // three survive in order.
        XCTAssertEqual(tags(snapshot.lines), ["Boot2", "Boot3", "Boot4"])
    }

    func testStagedLinesAreRenderedThroughDiagLog() throws {
        let buffer = makeBuffer()

        XCTAssertTrue(buffer.record(
            category: .lifecycle,
            tag: "App",
            message: "app launched",
            attrs: ["state": .string("launch")],
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            captureSessionID: "run-render"
        ))

        let rendered = try XCTUnwrap(buffer.snapshot().lines.first)
        let line = try DiagnosticsJSONCoding.makeDecoder().decode(
            DiagnosticsLogLine.self,
            from: Data(rendered.utf8)
        )
        // Same shape as any other breadcrumb: contract-valid, carrying the
        // capture-session id, with only registered attribute keys.
        XCTAssertNoThrow(try line.validate())
        XCTAssertEqual(line.run, "run-render")
        XCTAssertEqual(line.cat, .lifecycle)
        XCTAssertEqual(line.tag, "App")
        XCTAssertEqual(line.attrs?["state"], .string("launch"))
    }

    func testRedactionMatchesEveryOtherLine() throws {
        let buffer = makeBuffer()

        XCTAssertTrue(buffer.record(
            category: .lifecycle,
            tag: "Startup",
            message: "restored session failed for user@example.com",
            captureSessionID: "run-redact"
        ))

        let rendered = try XCTUnwrap(buffer.snapshot().lines.first)
        XCTAssertFalse(rendered.contains("user@example.com"))
        XCTAssertTrue(rendered.contains("[redacted_email]"))
    }

    func testNonBreadcrumbCategoriesAreNotStaged() {
        let buffer = makeBuffer()

        // The journal only accepts lifecycle/playback/focus, so staging a
        // network line would only burn a slot on a line that can never flush.
        XCTAssertFalse(buffer.record(
            category: .network,
            tag: "API",
            message: "request failed",
            captureSessionID: "run-category"
        ))
        XCTAssertTrue(buffer.snapshot().lines.isEmpty)
    }

    func testDrainClearsAndSealsAgainstLaterStaging() {
        let buffer = makeBuffer()
        XCTAssertTrue(buffer.record(category: .lifecycle, tag: "Boot", message: "started"))

        XCTAssertEqual(buffer.drain().count, 1)
        XCTAssertTrue(buffer.snapshot().lines.isEmpty)
        XCTAssertTrue(buffer.isSealed)

        // After the launch's consent decision, later lines belong to an
        // established account and go through the journal's own gate.
        XCTAssertFalse(buffer.record(category: .lifecycle, tag: "Later", message: "state changed"))
        XCTAssertTrue(buffer.snapshot().lines.isEmpty)
    }

    func testDiscardDropsLinesWithoutFlushingAndSeals() {
        let buffer = makeBuffer()
        XCTAssertTrue(buffer.record(category: .lifecycle, tag: "Boot", message: "started"))

        buffer.discard()

        XCTAssertTrue(buffer.snapshot().lines.isEmpty)
        XCTAssertTrue(buffer.isSealed)
        XCTAssertTrue(buffer.drain().isEmpty)
    }

    func testStagingWindowExpiryDiscardsUnflushedLines() {
        // A launch that never establishes a binding (parked in sign-in) must
        // not retain its lines indefinitely and hand them to a later account.
        var expiration: (() -> Void)?
        let buffer = EarlyBootBuffer(capacity: 8, stagingWindow: 60) { _, work in
            expiration = work
        }

        XCTAssertTrue(buffer.record(category: .lifecycle, tag: "Boot", message: "started"))
        XCTAssertFalse(buffer.snapshot().lines.isEmpty)

        let fireExpiration = try? XCTUnwrap(expiration)
        fireExpiration?()

        XCTAssertTrue(buffer.snapshot().lines.isEmpty)
        XCTAssertTrue(buffer.isSealed)
    }

    func testConcurrentStagingIsThreadSafe() {
        let iterations = 400
        let buffer = makeBuffer(capacity: iterations)

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            buffer.record(
                category: .lifecycle,
                tag: "Boot\(index)",
                message: "phase changed",
                captureSessionID: "run-concurrent"
            )
        }

        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.lines.count, iterations)
        XCTAssertEqual(Set(snapshot.lines).count, iterations)
        XCTAssertEqual(snapshot.droppedCount, 0)
    }

    // MARK: - Consent decision at the first establish

    func testFirstEstablishWithPermittingConsentFlushes() {
        let store = makeConsentStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-flush", accountUserID: "acct")
        store.setMode(.ask, for: binding, noticeVersion: 1)

        XCTAssertEqual(
            DiagnosticsCoordinator.earlyBootStagingDecision(
                previousBinding: nil,
                binding: binding,
                noticeVersion: 1,
                statusAvailable: true,
                consentStore: store
            ),
            .flush
        )
    }

    func testFirstEstablishWithNeverConsentDiscards() {
        let store = makeConsentStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-never", accountUserID: "acct")
        store.setMode(.never, for: binding, noticeVersion: 1)

        XCTAssertEqual(
            DiagnosticsCoordinator.earlyBootStagingDecision(
                previousBinding: nil,
                binding: binding,
                noticeVersion: 1,
                statusAvailable: true,
                consentStore: store
            ),
            .discard
        )
    }

    func testFirstEstablishWithUnavailableStatusDiscards() {
        let store = makeConsentStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-unavail", accountUserID: "acct")
        store.setMode(.ask, for: binding, noticeVersion: 1)

        XCTAssertEqual(
            DiagnosticsCoordinator.earlyBootStagingDecision(
                previousBinding: nil,
                binding: binding,
                noticeVersion: 1,
                statusAvailable: false,
                consentStore: store
            ),
            .discard
        )
    }

    func testBindingChangeDiscardsRatherThanAttributingToTheNewAccount() {
        let store = makeConsentStore()
        let previous = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "acct-a")
        let arriving = DiagnosticsBinding(serverInstanceID: "srv-b", accountUserID: "acct-b")
        // The arriving account permits capture — the staged lines are still
        // dropped, because they belong to the launch, not to this account.
        store.setMode(.ask, for: arriving, noticeVersion: 1)

        XCTAssertEqual(
            DiagnosticsCoordinator.earlyBootStagingDecision(
                previousBinding: previous,
                binding: arriving,
                noticeVersion: 1,
                statusAvailable: true,
                consentStore: store
            ),
            .discard
        )
    }

    func testAccountSwitchOnSameServerAlsoDiscards() {
        let store = makeConsentStore()
        let previous = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "acct-a")
        let arriving = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "acct-b")
        store.setMode(.ask, for: arriving, noticeVersion: 1)

        XCTAssertEqual(
            DiagnosticsCoordinator.earlyBootStagingDecision(
                previousBinding: previous,
                binding: arriving,
                noticeVersion: 1,
                statusAvailable: true,
                consentStore: store
            ),
            .discard
        )
    }

    func testPlainRefreshOfTheSameBindingIsIgnored() {
        let store = makeConsentStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "acct-a")
        store.setMode(.ask, for: binding, noticeVersion: 1)

        // Not a first establish, so there is nothing staged to decide about;
        // the same binding's existing on-disk trail is left alone.
        XCTAssertEqual(
            DiagnosticsCoordinator.earlyBootStagingDecision(
                previousBinding: binding,
                binding: binding,
                noticeVersion: 1,
                statusAvailable: true,
                consentStore: store
            ),
            .ignore
        )
    }

    // MARK: - Flush goes through the journal's write-time gate

    func testFlushWritesStagedLinesWhenTheJournalGateIsOpen() throws {
        let directory = try makeTemporaryDirectory()
        let journal = BreadcrumbJournal(directory: directory, isEnabled: { true })
        let buffer = makeBuffer()

        XCTAssertTrue(buffer.record(
            category: .lifecycle,
            tag: "App",
            message: "app launched",
            attrs: ["state": .string("launch")],
            captureSessionID: "run-flush"
        ))
        XCTAssertTrue(buffer.record(
            category: .lifecycle,
            tag: "Startup",
            message: "server unreachable at boot",
            attrs: ["outcome": .string("failure")],
            captureSessionID: "run-flush"
        ))

        XCTAssertEqual(DiagnosticsCoordinator.flushEarlyBootBuffer(buffer, into: journal), 2)

        let lines = journal.readAll()
        XCTAssertEqual(lines.map(\.tag), ["App", "Startup"])
        XCTAssertTrue(lines.allSatisfy { $0.run == "run-flush" })
        XCTAssertEqual(lines.first?.attrs?["state"], .string("launch"))
        // Drained: a second flush cannot duplicate the same lines.
        XCTAssertEqual(DiagnosticsCoordinator.flushEarlyBootBuffer(buffer, into: journal), 0)
        XCTAssertEqual(journal.readAll().count, 2)
    }

    func testFlushWritesNothingWhenTheJournalGateIsClosed() throws {
        let directory = try makeTemporaryDirectory()
        // The journal's own enabled-gate is the single point of enforcement:
        // even a flush that reached this far writes nothing when consent does
        // not allow it, and no file is created.
        let journal = BreadcrumbJournal(directory: directory, isEnabled: { false })
        let buffer = makeBuffer()

        XCTAssertTrue(buffer.record(
            category: .lifecycle,
            tag: "App",
            message: "app launched",
            captureSessionID: "run-denied"
        ))

        XCTAssertEqual(DiagnosticsCoordinator.flushEarlyBootBuffer(buffer, into: journal), 0)
        XCTAssertTrue(journal.readAll().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDiscardedBufferWritesNothingOnALaterFlush() throws {
        let directory = try makeTemporaryDirectory()
        let journal = BreadcrumbJournal(directory: directory, isEnabled: { true })
        let buffer = makeBuffer()

        XCTAssertTrue(buffer.record(
            category: .lifecycle,
            tag: "App",
            message: "app launched",
            captureSessionID: "run-discarded"
        ))
        // The discard path (refused consent, binding change, destination or
        // profile change) must make the lines unrecoverable, not merely
        // deferred.
        buffer.discard()

        XCTAssertEqual(DiagnosticsCoordinator.flushEarlyBootBuffer(buffer, into: journal), 0)
        XCTAssertTrue(journal.readAll().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Isolation hooks

    func testDestinationChangeDiscardsTheStagedLines() {
        let buffer = EarlyBootBuffer.shared
        buffer.resetForTests()
        // `diagnosticsDestinationWillChange` latches a process-wide transition
        // flag; clear it so it does not close the gate for later tests.
        addTeardownBlock {
            buffer.resetForTests()
            DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(nil)
        }

        XCTAssertTrue(buffer.record(category: .lifecycle, tag: "Boot", message: "started"))
        DiagnosticsCoordinator.diagnosticsDestinationWillChange()

        XCTAssertTrue(buffer.snapshot().lines.isEmpty)
        XCTAssertTrue(buffer.isSealed)
    }

    func testProfileChangeDiscardsTheStagedLines() {
        let buffer = EarlyBootBuffer.shared
        buffer.resetForTests()
        addTeardownBlock {
            buffer.resetForTests()
            DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(nil)
        }

        XCTAssertTrue(buffer.record(category: .lifecycle, tag: "Boot", message: "started"))
        DiagnosticsCoordinator.activeProfileWillChange()

        XCTAssertTrue(buffer.snapshot().lines.isEmpty)
        XCTAssertTrue(buffer.isSealed)
    }

    func testRecordBreadcrumbStagesWhenTheProcessJournalIsGatedOff() {
        let buffer = EarlyBootBuffer.shared
        // Close the process-wide gate first (it also seals the buffer), then
        // reset the buffer to its launch state so this reproduces a cold boot.
        DiagnosticsCoordinator.activeProfileWillChange()
        DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(nil)
        buffer.resetForTests()
        addTeardownBlock {
            buffer.resetForTests()
            DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(nil)
        }

        // No resolvable context, so the process journal refuses the write; the
        // line lands in the staging buffer instead of being discarded.
        XCTAssertFalse(DiagnosticsCoordinator.recordBreadcrumb(
            category: .lifecycle,
            tag: "App",
            message: "app launched",
            attrs: ["state": .string("launch")]
        ))
        XCTAssertEqual(tags(buffer.snapshot().lines), ["App"])
    }

    // MARK: - Helpers

    private func makeBuffer(capacity: Int = 32) -> EarlyBootBuffer {
        // No expiration scheduling: these tests drive drain/discard explicitly.
        EarlyBootBuffer(capacity: capacity, stagingWindow: 60) { _, _ in }
    }

    private func makeConsentStore() -> DiagnosticsConsentStore {
        let suite = UserDefaults(suiteName: "early-boot-tests-\(UUID().uuidString)")!
        return DiagnosticsConsentStore(
            defaults: SharedDefaults(suite: suite, standard: suite),
            onNeverSelected: { _ in }
        )
    }

    private func tags(_ renderedLines: [String]) -> [String] {
        let decoder = DiagnosticsJSONCoding.makeDecoder()
        return renderedLines.compactMap { rendered in
            try? decoder.decode(DiagnosticsLogLine.self, from: Data(rendered.utf8)).tag
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarlyBootBufferTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

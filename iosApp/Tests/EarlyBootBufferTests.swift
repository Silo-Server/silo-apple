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
        // reset the buffer and the launch's decision latch so this reproduces a
        // cold boot rather than whatever state an earlier test left behind.
        DiagnosticsCoordinator.activeProfileWillChange()
        DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(nil)
        DiagnosticsCoordinator.installBreadcrumbDecisionInEffectForTests(false)
        buffer.resetForTests()
        addTeardownBlock {
            buffer.resetForTests()
            DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(nil)
            DiagnosticsCoordinator.installBreadcrumbDecisionInEffectForTests(false)
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

    // MARK: - The previous run's journal survives a pre-consent launch

    /// The load-bearing case for the tvOS abnormal-exit report.
    ///
    /// `BreadcrumbJournal.appendRenderedLine` purges the whole journal
    /// directory whenever its gate is closed. A cold launch starts with the
    /// gate closed (no consent context, profile eligibility unresolved), so if
    /// a launch breadcrumb is offered to the journal before the launch's
    /// consent decision exists, the purge takes the *previous* run's trail with
    /// it — and that trail is the entire content of the abnormal-exit report
    /// `captureAbnormalExit` builds minutes later, after authentication.
    func testPreConsentLaunchBreadcrumbsDoNotPurgeThePreviousRunJournal() throws {
        let binding = installTestBinding()
        openProcessCaptureGate(for: binding)

        // The previous run, capturing normally, then dying without a clean
        // termination line.
        XCTAssertTrue(DiagnosticsCoordinator.recordBreadcrumb(
            category: .lifecycle,
            tag: "PreviousRun",
            message: "app launched",
            attrs: ["state": .string("launch")]
        ))
        XCTAssertTrue(journalTags().contains("PreviousRun"))

        simulateColdLaunch()

        // `SiloApp.init` → `LaunchTimeline.recordProcessStart()`. Refused,
        // because no account is established yet — which is staging, not denial.
        XCTAssertFalse(DiagnosticsCoordinator.recordBreadcrumb(
            category: .lifecycle,
            tag: "App",
            message: "app launched",
            attrs: ["state": .string("launch"), "launch_type": .string("cold")]
        ))

        XCTAssertEqual(tags(EarlyBootBuffer.shared.snapshot().lines), ["App"])
        XCTAssertTrue(
            journalTags().contains("PreviousRun"),
            "the crashed run's breadcrumbs must still be readable when captureAbnormalExit runs"
        )
    }

    func testProfileResolutionDuringLaunchKeepsThePreviousRunJournal() {
        // `ContentView.checkInitialState` resolves the restored session through
        // `AuthService.resolveActiveProfileForSession`, which opens with this
        // boundary — before authentication resolves, and therefore before
        // `ExitSentinel.captureLeftoverIfNeeded()` gets to read the journal.
        let binding = installTestBinding()
        openProcessCaptureGate(for: binding)
        XCTAssertTrue(DiagnosticsCoordinator.recordBreadcrumb(
            category: .lifecycle,
            tag: "PreviousRun",
            message: "app launched"
        ))

        simulateColdLaunch()
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .lifecycle,
            tag: "App",
            message: "app launched"
        )

        DiagnosticsCoordinator.activeProfileWillChange()

        XCTAssertTrue(journalTags().contains("PreviousRun"))
        // The launch's own staged lines are still dropped: they cannot follow
        // the user into the profile arriving now.
        XCTAssertTrue(EarlyBootBuffer.shared.snapshot().lines.isEmpty)
        XCTAssertTrue(EarlyBootBuffer.shared.isSealed)
    }

    // MARK: - A decided refusal still purges

    func testDeniedFirstEstablishPurgesTheJournalAndRefusesLaterLines() {
        let binding = installTestBinding()
        openProcessCaptureGate(for: binding)
        XCTAssertTrue(DiagnosticsCoordinator.recordBreadcrumb(
            category: .lifecycle,
            tag: "PreviousRun",
            message: "app launched"
        ))

        simulateColdLaunch()
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .lifecycle,
            tag: "App",
            message: "app launched"
        )
        XCTAssertFalse(EarlyBootBuffer.shared.snapshot().lines.isEmpty)

        // Authentication resolves and the account's stored choice turns out to
        // be "Never". Reopen every *other* gate input first, so consent is the
        // only thing refusing and the purge cannot be attributed to unresolved
        // profile eligibility. `purgeImmediately: false` suppresses the consent
        // store's own purge callback, so what this asserts is that the staging
        // decision clears the trail rather than inheriting a clearing someone
        // else already did.
        DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(
            DiagnosticsCoordinator.BreadcrumbConsentContext(
                binding: binding,
                noticeVersion: 1,
                isAvailable: true
            )
        )
        DiagnosticsCoordinator.installActiveProfileBreadcrumbEligibilityForTests(true)
        DiagnosticsConsentStore.shared.setMode(
            .never,
            for: binding,
            noticeVersion: 1,
            purgeImmediately: false
        )
        DiagnosticsCoordinator.applyEarlyBootStagingForTests(
            previousBinding: nil,
            binding: binding,
            noticeVersion: 1,
            statusAvailable: true
        )

        XCTAssertTrue(journalTags().isEmpty, "a Never account must be left with no on-disk trail")
        XCTAssertTrue(EarlyBootBuffer.shared.snapshot().lines.isEmpty)
        XCTAssertTrue(DiagnosticsCoordinator.breadcrumbDecisionInEffectForTests)

        // Post-decision, a refusal is a denial: the line is neither written nor
        // re-staged in memory.
        XCTAssertFalse(DiagnosticsCoordinator.recordBreadcrumb(
            category: .lifecycle,
            tag: "AfterDenial",
            message: "state changed"
        ))
        XCTAssertTrue(EarlyBootBuffer.shared.snapshot().lines.isEmpty)
        XCTAssertTrue(journalTags().isEmpty)
    }

    func testProfileSwitchAfterTheDecisionStillPurgesTheJournal() {
        // The isolation purge is unchanged once the launch's decision is in
        // effect: from that point the trail can hold this launch's own lines
        // for the outgoing profile.
        let binding = installTestBinding()
        openProcessCaptureGate(for: binding)
        XCTAssertTrue(DiagnosticsCoordinator.recordBreadcrumb(
            category: .lifecycle,
            tag: "ThisRun",
            message: "app launched"
        ))
        XCTAssertTrue(DiagnosticsCoordinator.breadcrumbDecisionInEffectForTests)

        DiagnosticsCoordinator.activeProfileWillChange()

        XCTAssertTrue(journalTags().isEmpty)
    }

    // MARK: - Helpers

    /// A binding scoped to this test run, with its consent record and the
    /// process-wide breadcrumb state restored afterwards. These tests drive the
    /// real process journal (that is the object under test), so teardown also
    /// empties it.
    private func installTestBinding() -> DiagnosticsBinding {
        let binding = DiagnosticsBinding(
            serverInstanceID: "early-boot-journal-tests",
            accountUserID: "acct"
        )
        // The latch and the journal are process-wide and outlive a test, so
        // start from the launch state rather than from whatever ran before.
        DiagnosticsCoordinator.installBreadcrumbDecisionInEffectForTests(false)
        DiagnosticsCoordinator.purgeBreadcrumbJournal()
        EarlyBootBuffer.shared.resetForTests()
        addTeardownBlock {
            DiagnosticsConsentStore.shared.remove(binding: binding)
            DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(nil)
            DiagnosticsCoordinator.installActiveProfileBreadcrumbEligibilityForTests(false)
            DiagnosticsCoordinator.installBreadcrumbDecisionInEffectForTests(false)
            DiagnosticsCoordinator.resetCaptureGateCacheForTests()
            DiagnosticsCoordinator.purgeBreadcrumbJournal()
            EarlyBootBuffer.shared.resetForTests()
        }
        return binding
    }

    /// The one state where capture is legitimately on: an available context for
    /// a non-`never` binding with the active profile resolved as a non-child.
    private func openProcessCaptureGate(for binding: DiagnosticsBinding) {
        DiagnosticsConsentStore.shared.setMode(.ask, for: binding, noticeVersion: 1)
        DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(
            DiagnosticsCoordinator.BreadcrumbConsentContext(
                binding: binding,
                noticeVersion: 1,
                isAvailable: true
            )
        )
        DiagnosticsCoordinator.installActiveProfileBreadcrumbEligibilityForTests(true)
        DiagnosticsCoordinator.resetCaptureGateCacheForTests()
    }

    /// Return the process-wide breadcrumb state to what it looks like at
    /// `SiloApp.init`: no live consent context, profile eligibility unresolved,
    /// no decision yet, nothing staged — while leaving the journal on disk,
    /// which is the previous run's evidence.
    ///
    /// Emptying the last-known-status store matters: it is App-Group-persistent
    /// and is what `resolvedBreadcrumbContext()` falls back to, so without this
    /// a machine that has run the app before resolves a real snapshot and the
    /// gate never reaches the unresolved state under test.
    private func simulateColdLaunch() {
        let previousIndex = DiagnosticsCoordinator.takeLastKnownStatusIndexForTests()
        addTeardownBlock {
            DiagnosticsCoordinator.restoreLastKnownStatusIndexForTests(previousIndex)
        }
        DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(nil)
        DiagnosticsCoordinator.installActiveProfileBreadcrumbEligibilityForTests(false)
        DiagnosticsCoordinator.installBreadcrumbDecisionInEffectForTests(false)
        DiagnosticsCoordinator.resetCaptureGateCacheForTests()
        EarlyBootBuffer.shared.resetForTests()
        XCTAssertFalse(
            DiagnosticsCoordinator.isDiagnosticsCaptureEnabled,
            "precondition: a cold launch begins with the capture gate closed"
        )
    }

    /// Tags currently readable from the *process* breadcrumb journal — the same
    /// read `captureAbnormalExit` performs when it builds the report.
    private func journalTags() -> [String] {
        let data = DiagnosticsCoordinator.shared.breadcrumbsData()
        let decoder = DiagnosticsJSONCoding.makeDecoder()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                try? decoder.decode(DiagnosticsLogLine.self, from: Data(line.utf8)).tag
            }
    }

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

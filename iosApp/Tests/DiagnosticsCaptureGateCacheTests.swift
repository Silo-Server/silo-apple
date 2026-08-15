import XCTest
@testable import Silo

/// The synchronous capture gate is evaluated by `DiagTrace.shouldCapture` on
/// every instrumented call — including the verbose lines it then suppresses, of
/// which `HTTPClient.perform` emits one per HTTP response. It is memoized so
/// that hot path does not decode the whole consent-record dictionary per call.
///
/// The memo is not a second source of truth, and these tests exist to keep it
/// that way: it must fail closed at every boundary, and a consent revocation
/// must stop capture on the very next call with no explicit invalidation from
/// the revoking call site.
final class DiagnosticsCaptureGateCacheTests: XCTestCase {
    private let binding = DiagnosticsBinding(
        serverInstanceID: "capture-gate-cache-tests",
        accountUserID: "acct"
    )

    override func setUp() {
        super.setUp()
        openGate()
    }

    override func tearDown() {
        DiagnosticsConsentStore.shared.remove(binding: binding)
        DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(nil)
        DiagnosticsCoordinator.installActiveProfileBreadcrumbEligibilityForTests(false)
        DiagnosticsCoordinator.resetCaptureGateCacheForTests()
        super.tearDown()
    }

    // MARK: - The memo actually memoizes

    func testRepeatedGateReadsEvaluateTheAuthoritativePathOnce() {
        XCTAssertTrue(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)
        let afterWarmUp = DiagnosticsCoordinator.captureGateAuthoritativeEvaluationCountForTests

        for _ in 0..<500 {
            XCTAssertTrue(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)
        }

        // Every one of those 500 reads is a `DiagTrace.shouldCapture` call in
        // production. None of them may reach UserDefaults/JSONDecoder again.
        // The counter is process-wide, so allow a small slack for a background
        // journal/sentinel read landing mid-loop; the property under test is
        // "one evaluation, not five hundred".
        assertAuthoritativeEvaluationsDidNotGrow(from: afterWarmUp)
    }

    func testMemoizedDecisionMatchesTheAuthoritativeDecisionWhenClosed() {
        // Same warm/repeat shape with the gate closed: a cached `false` must
        // stay false, never decay into the default.
        DiagnosticsCoordinator.installActiveProfileBreadcrumbEligibilityForTests(false)

        XCTAssertFalse(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)
        let afterWarmUp = DiagnosticsCoordinator.captureGateAuthoritativeEvaluationCountForTests
        for _ in 0..<500 {
            XCTAssertFalse(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)
        }
        assertAuthoritativeEvaluationsDidNotGrow(from: afterWarmUp)
    }

    // MARK: - Fails closed when unresolved

    func testUnresolvedProfileEligibilityFailsClosedEvenAfterAWarmTrue() {
        // A cold launch into a restored child profile resolves eligibility
        // asynchronously. Until it lands positively, the gate is closed — a
        // memo warmed while an adult profile was active must not carry over.
        XCTAssertTrue(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)

        DiagnosticsCoordinator.installActiveProfileBreadcrumbEligibilityForTests(false)

        XCTAssertFalse(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)
    }

    func testUnresolvedConsentContextFailsClosedEvenAfterAWarmTrue() {
        // No resolvable context means no account has been established on this
        // launch. `breadcrumbCaptureEnabled(for:)` documents that this stays
        // off rather than defaulting on; the memo must preserve that exactly.
        //
        // Clearing the live context alone does not produce that state:
        // `resolvedBreadcrumbContext()` then falls back to the last-known-status
        // store, which is App-Group-persistent, so a simulator that has run the
        // app before still resolves a real snapshot for the active server and
        // the gate legitimately stays open. Empty the fallback too, so this
        // asserts the unresolved case rather than the machine's leftover state.
        let previousIndex = DiagnosticsCoordinator.takeLastKnownStatusIndexForTests()
        defer { DiagnosticsCoordinator.restoreLastKnownStatusIndexForTests(previousIndex) }

        XCTAssertTrue(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)

        DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(nil)

        XCTAssertFalse(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)
    }

    func testUnavailableServerStatusFailsClosedEvenAfterAWarmTrue() {
        XCTAssertTrue(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)

        DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(
            DiagnosticsCoordinator.BreadcrumbConsentContext(
                binding: binding,
                noticeVersion: 1,
                isAvailable: false
            )
        )

        XCTAssertFalse(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)
    }

    // MARK: - Every invalidation boundary

    func testDestinationChangeBoundaryClosesTheMemoizedGate() {
        assertBoundaryClosesGate {
            DiagnosticsCoordinator.diagnosticsDestinationWillChange()
        }
    }

    func testActiveProfileWillChangeBoundaryClosesTheMemoizedGate() {
        assertBoundaryClosesGate {
            DiagnosticsCoordinator.activeProfileWillChange()
        }
    }

    func testActiveProfileDidChangeBoundaryClosesTheMemoizedGate() {
        // `activeProfileDidChange` invalidates synchronously and confirms
        // asynchronously; the synchronous half is what the log gate sees, and
        // it must close immediately rather than wait for the child lookup —
        // that is exactly the "can't capture even one breadcrumb before the
        // child lookup lands" property. Sample once, immediately, because the
        // async confirm may legitimately reopen the gate afterwards.
        XCTAssertTrue(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)

        DiagnosticsCoordinator.activeProfileDidChange()
        let immediatelyAfter = DiagnosticsCoordinator.isDiagnosticsCaptureEnabled

        XCTAssertFalse(immediatelyAfter)
    }

    func testAuthenticationBecameUnavailableBoundaryClosesTheMemoizedGate() {
        assertBoundaryClosesGate {
            DiagnosticsCoordinator.authenticationStateBecameUnavailable()
        }
    }

    // MARK: - Consent revocation

    func testConsentRevocationImmediatelyStopsCapture() {
        // The revoking call site does not touch the coordinator's cache: the
        // consent store's own mutation generation is part of the memo key, so
        // a "Never" selection is visible on the very next gate read.
        XCTAssertTrue(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)

        DiagnosticsConsentStore.shared.setMode(.never, for: binding, noticeVersion: 1)

        XCTAssertFalse(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)
        XCTAssertFalse(DiagTrace.shouldCapture(.essential))
    }

    func testConsentRestorationIsAlsoVisibleImmediately() {
        DiagnosticsConsentStore.shared.setMode(.never, for: binding, noticeVersion: 1)
        XCTAssertFalse(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)

        DiagnosticsConsentStore.shared.setMode(.ask, for: binding, noticeVersion: 1)

        XCTAssertTrue(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled)
    }

    // MARK: - The predicate must not write UserDefaults

    func testCapturePredicateDoesNotPersistTheNoticeVersionMigration() {
        let suite = UserDefaults(suiteName: "capture-gate-cache-\(UUID().uuidString)")!
        let store = DiagnosticsConsentStore(
            defaults: SharedDefaults(suite: suite, standard: suite),
            onNeverSelected: { _ in }
        )
        store.setMode(.always, for: binding, noticeVersion: 1)
        let generationBefore = store.mutationGeneration

        // Asking "may I capture?" under a bumped notice version must not
        // rewrite the stored record. Evaluating a log predicate cannot be
        // allowed to mutate persisted consent.
        XCTAssertTrue(store.persistentCaptureEnabled(for: binding, currentNoticeVersion: 2))

        XCTAssertEqual(store.mutationGeneration, generationBefore)
        XCTAssertEqual(store.record(for: binding, currentNoticeVersion: 1).mode, .always)
    }

    func testExplicitRecordCallStillPersistsTheNoticeVersionMigration() {
        let suite = UserDefaults(suiteName: "capture-gate-cache-\(UUID().uuidString)")!
        let store = DiagnosticsConsentStore(
            defaults: SharedDefaults(suite: suite, standard: suite),
            onNeverSelected: { _ in }
        )
        store.setMode(.always, for: binding, noticeVersion: 1)

        // The migration is hoisted to the explicit call sites (status refresh,
        // capture-context build, settings screen), not removed.
        XCTAssertEqual(store.record(for: binding, currentNoticeVersion: 2).mode, .ask)
        XCTAssertEqual(store.record(for: binding, currentNoticeVersion: 2).noticeVersion, 2)
        XCTAssertEqual(store.record(for: binding, currentNoticeVersion: 1).mode, .ask)
    }

    func testResolvedRecordAndRecordAgreeOnCaptureForEveryStoredMode() {
        // The memo is only sound if the side-effect-free read answers the
        // capture question identically to the persisting one.
        for mode in DiagnosticsConsentChoice.allCases {
            let suite = UserDefaults(suiteName: "capture-gate-cache-\(UUID().uuidString)")!
            let store = DiagnosticsConsentStore(
                defaults: SharedDefaults(suite: suite, standard: suite),
                onNeverSelected: { _ in }
            )
            store.setMode(mode, for: binding, noticeVersion: 1)

            for noticeVersion in [1, 2] {
                XCTAssertEqual(
                    store.resolvedRecord(for: binding, currentNoticeVersion: noticeVersion).mode != .never,
                    store.record(for: binding, currentNoticeVersion: noticeVersion).mode != .never,
                    "mode=\(mode) noticeVersion=\(noticeVersion)"
                )
            }
        }
    }

    // MARK: - The memo never disagrees with the authoritative gate

    func testMemoizedAnswerAlwaysMatchesTheUncachedGate() {
        // The cache is a memo of the authoritative path, so at every state
        // these two must agree. Asserting against the real predicate rather
        // than a literal keeps the memo honest if the gating logic changes.
        let states: [(String, () -> Void)] = [
            ("open", { self.openGate() }),
            ("child profile", {
                DiagnosticsCoordinator.installActiveProfileBreadcrumbEligibilityForTests(false)
            }),
            ("no context", {
                DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(nil)
            }),
            ("reopened", { self.openGate() }),
            ("consent never", {
                DiagnosticsConsentStore.shared.setMode(.never, for: self.binding, noticeVersion: 1)
            }),
            ("consent ask again", {
                DiagnosticsConsentStore.shared.setMode(.ask, for: self.binding, noticeVersion: 1)
            }),
            ("status unavailable", {
                DiagnosticsCoordinator.installBreadcrumbConsentContextForTests(
                    DiagnosticsCoordinator.BreadcrumbConsentContext(
                        binding: self.binding,
                        noticeVersion: 1,
                        isAvailable: false
                    )
                )
            })
        ]

        for (label, transition) in states {
            transition()
            XCTAssertEqual(
                DiagnosticsCoordinator.isDiagnosticsCaptureEnabled,
                DiagnosticsCoordinator.uncachedCaptureEnabledForTests,
                "memo disagreed with the authoritative gate after: \(label)"
            )
        }
    }

    // MARK: - Cache mechanics in isolation

    func testInFlightComputationCannotPublishAcrossAnInvalidation() {
        let cache = DiagnosticsCaptureGateCache()
        let key = makeKey(epoch: cache.currentEpoch)

        // Simulates a consent revocation landing between the authoritative
        // computation and its publish. The stale `true` must be dropped, and
        // the answer for this call must be `false`.
        cache.invalidate()

        XCTAssertFalse(cache.store(true, for: key, still: key))
        XCTAssertNil(cache.value(for: key))
        XCTAssertNil(cache.value(for: makeKey(epoch: cache.currentEpoch)))
    }

    func testKeyMovingDuringComputationDiscardsTheResult() {
        let cache = DiagnosticsCaptureGateCache()
        let key = makeKey(epoch: cache.currentEpoch)
        let moved = makeKey(epoch: cache.currentEpoch, consentGeneration: 99)

        XCTAssertFalse(cache.store(true, for: key, still: moved))
        XCTAssertNil(cache.value(for: key))
    }

    func testPositiveDecisionsExpireButNegativeOnesDoNot() {
        var clock: TimeInterval = 0
        let cache = DiagnosticsCaptureGateCache(now: { clock })
        let key = makeKey(epoch: cache.currentEpoch)

        XCTAssertTrue(cache.store(true, for: key, still: key))
        XCTAssertEqual(cache.value(for: key), true)
        clock += DiagnosticsCaptureGateCache.positiveLifetime + 1
        // Bounded staleness: a `true` must be re-derived rather than trusted
        // indefinitely, so no unmodelled input can latch capture on.
        XCTAssertNil(cache.value(for: key))

        XCTAssertFalse(cache.store(false, for: key, still: key))
        clock += DiagnosticsCaptureGateCache.positiveLifetime * 100
        // Staying off too long is the safe direction; the boundary hooks are
        // what reopen the gate.
        XCTAssertEqual(cache.value(for: key), false)
    }

    func testAKeyMissAlwaysRecomputesRatherThanGuessing() {
        let cache = DiagnosticsCaptureGateCache()
        let key = makeKey(epoch: cache.currentEpoch)
        XCTAssertTrue(cache.store(true, for: key, still: key))

        for other in [
            makeKey(epoch: cache.currentEpoch &+ 1),
            makeKey(epoch: cache.currentEpoch, consentGeneration: 1),
            makeKey(epoch: cache.currentEpoch, serverRegistryID: "other-server"),
            makeKey(epoch: cache.currentEpoch, destination: .selfHosted)
        ] {
            XCTAssertNil(cache.value(for: other))
        }
    }

    // MARK: - Helpers

    private func makeKey(
        epoch: UInt64,
        consentGeneration: UInt64 = 0,
        serverRegistryID: String? = "server-a",
        destination: DiagnosticsDestinationChoice = .hosted
    ) -> DiagnosticsCaptureGateCache.Key {
        DiagnosticsCaptureGateCache.Key(
            epoch: epoch,
            consentGeneration: consentGeneration,
            serverRegistryID: serverRegistryID,
            destination: destination
        )
    }

    /// The evaluation counter is process-wide; another subsystem's gate read
    /// can land between the two samples. 500 memoized reads must still cost far
    /// fewer than 500 authoritative evaluations.
    private func assertAuthoritativeEvaluationsDidNotGrow(
        from baseline: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let growth = DiagnosticsCoordinator.captureGateAuthoritativeEvaluationCountForTests - baseline
        XCTAssertLessThan(
            growth,
            10,
            "500 memoized gate reads caused \(growth) authoritative evaluations",
            file: file,
            line: line
        )
    }

    /// Warm the memo to `true`, cross `boundary`, and require the very next
    /// gate read to be closed.
    private func assertBoundaryClosesGate(
        _ boundary: () -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled, file: file, line: line)

        boundary()

        XCTAssertFalse(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled, file: file, line: line)
        // Reopening after the boundary requires the authoritative path to say
        // so again; the stale `true` must not come back on its own.
        XCTAssertFalse(DiagnosticsCoordinator.isDiagnosticsCaptureEnabled, file: file, line: line)
    }

    /// Put the process-wide gate in the one state where capture is legitimately
    /// on: an available context for a non-`never` binding, with the active
    /// profile positively resolved as a non-child.
    private func openGate() {
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
}

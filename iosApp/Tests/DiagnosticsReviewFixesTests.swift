import XCTest
@testable import Silo

/// Focused coverage for the behavior fixes made in response to the PR #96
/// review: permanent-failure gating, consent notice refresh on upload,
/// binding-scoped playback sessions, and byte-safe stack truncation.
final class DiagnosticsReviewFixesTests: XCTestCase {
    // MARK: - Permanent-failure state (#3 too_large, #9 needsServerUpdate)

    func testPendingReportStateDecodesLegacyStateWithoutTooLarge() throws {
        let legacy = try DiagnosticsJSONCoding.makeDecoder().decode(
            PendingReportState.self,
            from: Data(#"{"needs_server_update": true}"#.utf8)
        )
        XCTAssertTrue(legacy.needsServerUpdate)
        XCTAssertFalse(legacy.tooLarge)
        XCTAssertTrue(legacy.isPermanentFailure)
    }

    func testPendingReportStatePermanentFailureCombinations() {
        XCTAssertFalse(PendingReportState.empty.isPermanentFailure)
        XCTAssertTrue(PendingReportState(needsServerUpdate: true).isPermanentFailure)
        XCTAssertTrue(PendingReportState(needsServerUpdate: false, tooLarge: true).isPermanentFailure)
    }

    // MARK: - Consent notice + mode refresh before upload (#2, round 3)

    func testUpdatingConsentRefreshesModeAndNoticeVersion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PendingReportStore(rootDirectory: root)

        // Captured under Always; the server notice then advanced, demoting the
        // account Always→Ask (prompt). The rewrite must not keep claiming
        // always for the new notice.
        let report = try store.save(makeCapture(noticeVersion: 1, consentMode: .always))
        XCTAssertEqual(report.manifest.consent.mode, .always)

        let updated = store.updatingConsent(report, mode: .prompt, noticeVersion: 2)
        XCTAssertEqual(updated.manifest.consent.mode, .prompt)
        XCTAssertEqual(updated.manifest.consent.noticeVersion, 2)
        // Evidence stays frozen: the captured timestamp is unchanged.
        XCTAssertEqual(updated.binding.capturedAt, report.binding.capturedAt)

        // The change is persisted to disk, so a re-read report is not stale.
        let reloaded = store.report(id: report.id)
        XCTAssertEqual(reloaded?.manifest.consent.mode, .prompt)
        XCTAssertEqual(reloaded?.manifest.consent.noticeVersion, 2)
    }

    // MARK: - Binding-scoped playback sessions (#10)

    func testRecentSessionsAreScopedToTheirBinding() {
        let suite = UserDefaults(suiteName: "diag-tests-\(UUID().uuidString)")!
        let tracker = RecentSessionTracker(defaults: SharedDefaults(suite: suite, standard: suite))

        let serverA = DiagnosticsBinding(serverInstanceID: "server-a", accountUserID: "account-a")
        let serverB = DiagnosticsBinding(serverInstanceID: "server-b", accountUserID: "account-b")

        tracker.record(sessionID: "sess-a", binding: serverA)
        tracker.record(sessionID: "sess-b", binding: serverB)

        XCTAssertEqual(tracker.recentSessionIDs(for: serverA), ["sess-a"])
        XCTAssertEqual(tracker.recentSessionIDs(for: serverB), ["sess-b"])
    }

    func testRecentSessionsWithoutBindingNeverMatchAReport() {
        let suite = UserDefaults(suiteName: "diag-tests-\(UUID().uuidString)")!
        let tracker = RecentSessionTracker(defaults: SharedDefaults(suite: suite, standard: suite))
        let binding = DiagnosticsBinding(serverInstanceID: "server-a", accountUserID: "account-a")

        tracker.record(sessionID: "legacy", binding: nil)

        XCTAssertTrue(tracker.recentSessionIDs(for: binding).isEmpty)
    }

    // MARK: - Byte-safe stack truncation (#11)

    func testStackExcerptTruncatesToUTF8ByteLimit() throws {
        // 12 frames of multibyte symbols exceed 8192 UTF-8 bytes when joined.
        let frame: [String: Any] = ["symbolName": String(repeating: "é", count: 1000), "offset": 1]
        let payload: [String: Any] = ["callStacks": [["callStackRootFrames": Array(repeating: frame, count: 12)]]]
        let rawJSON = try JSONSerialization.data(withJSONObject: payload)

        let crash = MetricKitDiagnosticParser.crashInfo(
            rawJSON: rawJSON,
            type: .crash,
            periodStart: Date(),
            periodEnd: Date()
        )
        let excerpt = try XCTUnwrap(crash.stackExcerpt)
        XCTAssertGreaterThan(excerpt.utf8.count, 0)
        XCTAssertLessThanOrEqual(excerpt.utf8.count, 8192)
        // Passes the same validation the server enforces.
        XCTAssertNoThrow(try crash.validate())
    }

    // MARK: - Declined-prompt suppression (round 2 #6)

    func testPendingReportStateDecodesLegacyStateWithoutPromptDeclined() throws {
        let legacy = try DiagnosticsJSONCoding.makeDecoder().decode(
            PendingReportState.self,
            from: Data(#"{"needs_server_update": false, "too_large": false}"#.utf8)
        )
        XCTAssertFalse(legacy.promptDeclined)
        XCTAssertFalse(legacy.isPermanentFailure)
    }

    func testMarkPromptDeclinedPersistsAndStaysSendable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PendingReportStore(rootDirectory: root)

        let report = try store.save(makeCapture(noticeVersion: 1))
        XCTAssertFalse(report.state.promptDeclined)

        store.markPromptDeclined(report)

        let reloaded = try XCTUnwrap(store.report(id: report.id))
        XCTAssertTrue(reloaded.state.promptDeclined)
        // A declined prompt is not a permanent failure: the report is still
        // visible and sendable from settings, it just never re-prompts.
        XCTAssertFalse(reloaded.state.isPermanentFailure)
    }

    // MARK: - Abnormal-exit marker binding (round 2 #3)

    func testExitSentinelMarkerRoundTripsBindingAndProfile() throws {
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "acct-a")
        let marker = ExitSentinelMarker(
            runID: "run-1",
            startedAt: "2026-07-20T10:00:00Z",
            binding: binding,
            profileID: "prof-1"
        )
        let data = try DiagnosticsJSONCoding.makeEncoder().encode(marker)
        let decoded = try DiagnosticsJSONCoding.makeDecoder().decode(ExitSentinelMarker.self, from: data)
        XCTAssertEqual(decoded, marker)
        XCTAssertEqual(decoded.binding, binding)
        XCTAssertEqual(decoded.profileID, "prof-1")
    }

    func testExitSentinelMarkerDecodesLegacyWithoutBinding() throws {
        let legacy = Data(#"{"run_id":"run-2","started_at":"2026-07-20T10:00:00Z"}"#.utf8)
        let decoded = try DiagnosticsJSONCoding.makeDecoder().decode(ExitSentinelMarker.self, from: legacy)
        XCTAssertEqual(decoded.runID, "run-2")
        XCTAssertNil(decoded.binding)
        XCTAssertNil(decoded.profileID)
    }

    // MARK: - Breadcrumb capture defaults off (round 2 #4)

    func testBreadcrumbCaptureDisabledWithoutContext() {
        let store = makeConsentStore()
        // No resolvable consent context on a fresh launch must not default on.
        XCTAssertFalse(DiagnosticsCoordinator.breadcrumbCaptureEnabled(for: nil, consentStore: store))
    }

    func testBreadcrumbCaptureRespectsStoredConsent() {
        let store = makeConsentStore()

        let neverBinding = DiagnosticsBinding(serverInstanceID: "srv-never", accountUserID: "acct")
        store.setMode(.never, for: neverBinding, noticeVersion: 1)
        let neverContext = DiagnosticsCoordinator.BreadcrumbConsentContext(
            binding: neverBinding,
            noticeVersion: 1
        )
        XCTAssertFalse(DiagnosticsCoordinator.breadcrumbCaptureEnabled(for: neverContext, consentStore: store))

        let askBinding = DiagnosticsBinding(serverInstanceID: "srv-ask", accountUserID: "acct")
        store.setMode(.ask, for: askBinding, noticeVersion: 1)
        let askContext = DiagnosticsCoordinator.BreadcrumbConsentContext(
            binding: askBinding,
            noticeVersion: 1
        )
        XCTAssertTrue(DiagnosticsCoordinator.breadcrumbCaptureEnabled(for: askContext, consentStore: store))
    }

    // MARK: - Breadcrumbs disabled when status unavailable (round 3)

    func testBreadcrumbCaptureDisabledWhenStatusUnavailable() {
        let store = makeConsentStore()

        // Consent allows capture (Ask), but the server reports diagnostics as
        // unavailable — breadcrumb capture must stay off, matching the
        // persistent-capture availability gate.
        let binding = DiagnosticsBinding(serverInstanceID: "srv-unavail", accountUserID: "acct")
        store.setMode(.ask, for: binding, noticeVersion: 1)

        let unavailable = DiagnosticsCoordinator.BreadcrumbConsentContext(
            binding: binding,
            noticeVersion: 1,
            isAvailable: false
        )
        XCTAssertFalse(DiagnosticsCoordinator.breadcrumbCaptureEnabled(for: unavailable, consentStore: store))

        let available = DiagnosticsCoordinator.BreadcrumbConsentContext(
            binding: binding,
            noticeVersion: 1,
            isAvailable: true
        )
        XCTAssertTrue(DiagnosticsCoordinator.breadcrumbCaptureEnabled(for: available, consentStore: store))
    }

    // MARK: - Offline capture fallback restricted to transient failures (round 4)

    func testCaptureFallbackAllowsTransientFailures() {
        // Offline / transport failures and 5xx server errors are transient: a
        // persistent capture may fall back to the last-known snapshot.
        XCTAssertTrue(DiagnosticsCoordinator.isTransientCaptureFallbackFailure(
            HTTPError.network(underlying: URLError(.notConnectedToInternet))
        ))
        XCTAssertTrue(DiagnosticsCoordinator.isTransientCaptureFallbackFailure(
            URLError(.timedOut)
        ))
        XCTAssertTrue(DiagnosticsCoordinator.isTransientCaptureFallbackFailure(
            HTTPError.http(statusCode: 500, body: nil)
        ))
        XCTAssertTrue(DiagnosticsCoordinator.isTransientCaptureFallbackFailure(
            HTTPError.http(statusCode: 503, body: nil)
        ))
    }

    func testCaptureFallbackFailsClosedOnDefinitiveFailures() {
        // Auth/permission failures, a missing endpoint, other 4xx, malformed
        // responses, and identity-level coordinator errors must NOT fall back —
        // the session may be signed out or the endpoint gone, so capturing
        // against the last-known binding would misattribute the report.
        for status in [400, 401, 403, 404, 409, 422] {
            XCTAssertFalse(
                DiagnosticsCoordinator.isTransientCaptureFallbackFailure(
                    HTTPError.http(statusCode: status, body: nil)
                ),
                "HTTP \(status) must fail closed"
            )
        }
        XCTAssertFalse(DiagnosticsCoordinator.isTransientCaptureFallbackFailure(
            HTTPError.invalidResponse
        ))
        XCTAssertFalse(DiagnosticsCoordinator.isTransientCaptureFallbackFailure(
            HTTPError.decodingFailed(type: "X", underlying: URLError(.cannotDecodeContentData))
        ))
        XCTAssertFalse(DiagnosticsCoordinator.isTransientCaptureFallbackFailure(
            DiagnosticsCoordinatorError.identityChanged
        ))
        XCTAssertFalse(DiagnosticsCoordinator.isTransientCaptureFallbackFailure(
            DiagnosticsCoordinatorError.missingAccountUserID
        ))
    }

    // MARK: - Profile-mismatch upload gate (round 4, finding 6)

    func testProfileUploadMismatchHoldsOnlyOnBothPresentDisagreement() {
        // Both present and different -> the server would reject with
        // profile_mismatch, so the client must hold the report.
        XCTAssertTrue(DiagnosticsCoordinator.isProfileUploadMismatch(captured: "profile-a", active: "profile-b"))
        XCTAssertTrue(DiagnosticsCoordinator.isProfileUploadMismatch(captured: " profile-a ", active: "profile-b"))

        // Same profile (after trim) -> no conflict.
        XCTAssertFalse(DiagnosticsCoordinator.isProfileUploadMismatch(captured: "profile-a", active: "profile-a"))
        XCTAssertFalse(DiagnosticsCoordinator.isProfileUploadMismatch(captured: " profile-a ", active: "profile-a"))

        // Either side nil/blank -> the server resolves from the single present
        // value with no conflict, so these must NOT be held.
        XCTAssertFalse(DiagnosticsCoordinator.isProfileUploadMismatch(captured: nil, active: "profile-b"))
        XCTAssertFalse(DiagnosticsCoordinator.isProfileUploadMismatch(captured: "profile-a", active: nil))
        XCTAssertFalse(DiagnosticsCoordinator.isProfileUploadMismatch(captured: nil, active: nil))
        XCTAssertFalse(DiagnosticsCoordinator.isProfileUploadMismatch(captured: "   ", active: "profile-b"))
        XCTAssertFalse(DiagnosticsCoordinator.isProfileUploadMismatch(captured: "profile-a", active: "   "))
    }

    // MARK: - Exit sentinel leftover preservation (round 6 #3)

    func testExitSentinelStorePreservesLeftoverAcrossArmAndTerminate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExitSentinelStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let currentURL = directory.appendingPathComponent("exit-sentinel.json", isDirectory: false)
        let store = ExitSentinelMarkerStore(currentURL: currentURL)

        // A previous run exited uncleanly: its marker is still in the current
        // slot at relaunch.
        let crashed = ExitSentinelMarker(
            runID: "crashed-run",
            startedAt: "2026-07-20T10:00:00.000Z",
            binding: DiagnosticsBinding(serverInstanceID: "srv", accountUserID: "acct"),
            profileID: "prof"
        )
        store.writeCurrent(crashed)

        // Relaunch arms this run: promote the leftover first, then overwrite the
        // current slot with the new run's marker.
        XCTAssertEqual(store.preserveLeftoverFromCurrentSlot(currentRunID: "relaunch-run"), crashed)
        store.writeCurrent(ExitSentinelMarker(runID: "relaunch-run", startedAt: "2026-07-20T11:00:00.000Z"))

        // The crash evidence lives in the leftover slot, distinct from the
        // current-run slot, so arming did not destroy it.
        XCTAssertEqual(store.readLeftover(), crashed)
        XCTAssertEqual(store.readCurrent()?.runID, "relaunch-run")

        // A normal background/terminate of the relaunch clears only the current
        // slot — the un-captured crash marker must survive for the next launch.
        store.clearCurrent()
        XCTAssertNil(store.readCurrent())
        XCTAssertEqual(store.readLeftover(), crashed)

        // Next launch, current slot empty: the persisted leftover is surfaced
        // again for a capture retry.
        let nextLaunch = ExitSentinelMarkerStore(currentURL: currentURL)
        XCTAssertEqual(nextLaunch.preserveLeftoverFromCurrentSlot(currentRunID: "next-run"), crashed)

        // Only an explicit clear (successful capture) discards it.
        nextLaunch.clearLeftover()
        XCTAssertNil(nextLaunch.readLeftover())
    }

    func testExitSentinelStoreDoesNotPromoteCurrentRunOrClobberLeftover() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExitSentinelStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = ExitSentinelMarkerStore(
            currentURL: directory.appendingPathComponent("exit-sentinel.json", isDirectory: false)
        )

        // The current run's own marker is not crash evidence: it must not be
        // promoted into the leftover slot.
        store.writeCurrent(ExitSentinelMarker(runID: "current-run", startedAt: "2026-07-20T10:00:00.000Z"))
        XCTAssertNil(store.preserveLeftoverFromCurrentSlot(currentRunID: "current-run"))
        XCTAssertNil(store.readLeftover())

        // A leftover a prior relaunch already failed to capture is never
        // clobbered by a newer crash marker (the single-slot capture path keeps
        // the older evidence deterministically).
        let firstCrash = ExitSentinelMarker(runID: "first-crash", startedAt: "2026-07-20T09:00:00.000Z")
        store.writeCurrent(firstCrash)
        XCTAssertEqual(store.preserveLeftoverFromCurrentSlot(currentRunID: "run-a"), firstCrash)

        let secondCrash = ExitSentinelMarker(runID: "second-crash", startedAt: "2026-07-20T09:30:00.000Z")
        store.writeCurrent(secondCrash)
        XCTAssertEqual(store.preserveLeftoverFromCurrentSlot(currentRunID: "run-b"), firstCrash)
        XCTAssertEqual(store.readLeftover(), firstCrash)
    }

    func testExitSentinelStoreLeftoverURLIsDistinctSibling() {
        let currentURL = URL(fileURLWithPath: "/tmp/diag/exit-sentinel.json")
        let store = ExitSentinelMarkerStore(currentURL: currentURL)
        XCTAssertEqual(store.currentURL, currentURL)
        XCTAssertEqual(store.leftoverURL, URL(fileURLWithPath: "/tmp/diag/exit-sentinel-leftover.json"))
        XCTAssertNotEqual(store.currentURL, store.leftoverURL)
    }

    // MARK: - MetricKit breadcrumb window filtering (round 6 #4)

    func testBreadcrumbsInWindowKeepsOnlyIncidentWindowLines() {
        func line(at seconds: TimeInterval) -> DiagnosticsLogLine {
            DiagnosticsLogLine(
                ts: DiagnosticsTimestamp.string(from: Date(timeIntervalSince1970: seconds)),
                run: "run",
                lvl: .info,
                cat: .lifecycle,
                tag: "Scene",
                msg: "state"
            )
        }
        let unparseable = DiagnosticsLogLine(
            ts: "not-a-date", run: "run", lvl: .info, cat: .lifecycle, tag: "Scene", msg: "state"
        )

        let beforeWindow = line(at: 500)       // older retained segment
        let atStart = line(at: 1_000)
        let midWindow = line(at: 1_050)
        let atEnd = line(at: 1_100)
        let withinMargin = line(at: 1_125)     // clock skew after periodEnd
        let relaunch = line(at: 5_000)         // next-launch breadcrumb

        let filtered = DiagnosticsCoordinator.breadcrumbsInWindow(
            [beforeWindow, atStart, midWindow, atEnd, withinMargin, relaunch, unparseable],
            from: Date(timeIntervalSince1970: 1_000),
            to: Date(timeIntervalSince1970: 1_100),
            margin: 30
        )

        XCTAssertEqual(filtered, [atStart, midWindow, atEnd, withinMargin])
    }

    // MARK: - Helpers

    private func makeConsentStore() -> DiagnosticsConsentStore {
        let suite = UserDefaults(suiteName: "diag-tests-\(UUID().uuidString)")!
        return DiagnosticsConsentStore(
            defaults: SharedDefaults(suite: suite, standard: suite),
            onNeverSelected: { _ in }
        )
    }

    private func makeCapture(noticeVersion: Int, consentMode: ConsentMode = .manual) -> PendingReportCapture {
        let binding = DiagnosticsBinding(serverInstanceID: "server-a", accountUserID: "account-a")
        let context = DiagnosticsCaptureContext(
            binding: binding,
            profileID: nil,
            consentMode: consentMode,
            noticeVersion: noticeVersion,
            appVersion: "1.0.0",
            appBuild: "1",
            platform: .ios,
            osVersion: "18.0"
        )
        let manifest = context.makeManifestDraft(
            type: .manual,
            capturedAt: Date(),
            crash: nil,
            deviceSummary: DiagnosticsManifest.DeviceSummary(
                manufacturer: "Apple",
                model: "iPhone",
                os: "iOS 18.0",
                formFactor: "phone"
            ),
            playbackSessionIDs: [],
            consentMode: consentMode
        )
        return PendingReportCapture(
            binding: binding,
            profileID: nil,
            type: .manual,
            fingerprint: DiagnosticsSHA256.hex(data: Data("fixture-\(noticeVersion)".utf8)),
            capturedAt: Date(),
            manifest: manifest,
            deviceSnapshot: DeviceSnapshotBuilder.live.build(provenance: .preFailure),
            artifacts: []
        )
    }
}

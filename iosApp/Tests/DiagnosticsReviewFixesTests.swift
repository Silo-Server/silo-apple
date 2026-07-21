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

    // MARK: - Consent notice refresh before upload (#2)

    func testUpdatingConsentNoticeVersionRewritesOnlyThatField() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PendingReportStore(rootDirectory: root)

        let report = try store.save(makeCapture(noticeVersion: 1))
        XCTAssertEqual(report.manifest.consent.noticeVersion, 1)

        let updated = store.updatingConsentNoticeVersion(report, to: 5)
        XCTAssertEqual(updated.manifest.consent.noticeVersion, 5)
        // Evidence stays frozen: mode and captured timestamp are unchanged.
        XCTAssertEqual(updated.manifest.consent.mode, report.manifest.consent.mode)
        XCTAssertEqual(updated.binding.capturedAt, report.binding.capturedAt)

        // The change is persisted to disk, so a re-read report is not stale.
        let reloaded = store.report(id: report.id)
        XCTAssertEqual(reloaded?.manifest.consent.noticeVersion, 5)
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

    // MARK: - Helpers

    private func makeCapture(noticeVersion: Int) -> PendingReportCapture {
        let binding = DiagnosticsBinding(serverInstanceID: "server-a", accountUserID: "account-a")
        let context = DiagnosticsCaptureContext(
            binding: binding,
            profileID: nil,
            consentMode: .manual,
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
            consentMode: .manual
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

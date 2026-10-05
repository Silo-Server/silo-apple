import XCTest
@testable import Silo

final class PendingReportStoreTests: XCTestCase {
    func testCapKeepsThreeNewestReportsPerBinding() throws {
        let store = try makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let start = Date(timeIntervalSince1970: 1_000)

        for index in 0..<4 {
            _ = try store.save(makeCapture(
                binding: binding,
                fingerprint: "fp-\(index)",
                capturedAt: start.addingTimeInterval(TimeInterval(index))
            ))
        }

        let reports = store.listReports(for: binding, now: start.addingTimeInterval(10))
        XCTAssertEqual(reports.count, 3)
        XCTAssertEqual(reports.map(\.binding.fingerprint), ["fp-1", "fp-2", "fp-3"])
    }

    /// A capture the full store would evict straight away is not written at
    /// all. It counts as handled (its fingerprint is seen), so a caller such
    /// as the exit sentinel can clear its retry marker instead of retrying
    /// the same capture on every foreground.
    func testCaptureEvictedOnArrivalIsSettledWithoutBeingWritten() throws {
        let store = try makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let start = Date(timeIntervalSince1970: 1_000)

        for index in 1...3 {
            _ = try store.save(makeCapture(
                binding: binding,
                fingerprint: "new-\(index)",
                capturedAt: start.addingTimeInterval(TimeInterval(index))
            ))
        }

        let pendingBefore = try FileManager.default.contentsOfDirectory(atPath: store.pendingDirectory.path)
        XCTAssertThrowsError(try store.save(makeCapture(
            binding: binding,
            fingerprint: "delayed-old",
            capturedAt: start
        ))) { error in
            XCTAssertEqual(error as? DiagnosticsStoreError, .evictedOnArrival)
        }
        XCTAssertTrue(store.hasSeenFingerprint("delayed-old", now: start.addingTimeInterval(10)))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: store.pendingDirectory.path).sorted(),
            pendingBefore.sorted()
        )
        XCTAssertEqual(
            store.listReports(for: binding, now: start.addingTimeInterval(10)).map(\.binding.fingerprint),
            ["new-1", "new-2", "new-3"]
        )
    }

    func testExpiredReportsAreDeletedOnScan() throws {
        let store = try makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let now = Date(timeIntervalSince1970: 10_000)

        _ = try store.save(makeCapture(
            binding: binding,
            fingerprint: "expired",
            capturedAt: now.addingTimeInterval(-8 * 24 * 60 * 60)
        ))

        XCTAssertEqual(store.listReports(for: binding, now: now), [])
    }

    func testBindingIsolationAndUploadability() throws {
        let store = try makeStore()
        let first = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let second = DiagnosticsBinding(serverInstanceID: "srv-b", accountUserID: "42")

        let firstReport = try store.save(makeCapture(binding: first, fingerprint: "first"))
        let secondReport = try store.save(makeCapture(binding: second, fingerprint: "second"))

        XCTAssertEqual(store.listReports(for: first).map(\.id), [firstReport.id])
        XCTAssertEqual(store.listReports(for: second).map(\.id), [secondReport.id])
        XCTAssertTrue(firstReport.isUploadable(to: first))
        XCTAssertFalse(firstReport.isUploadable(to: second))
    }

    func testInvalidArtifactSaveDoesNotPublishPartialReportDirectory() throws {
        let store = try makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let capture = makeCapture(
            binding: binding,
            fingerprint: "bad-artifact",
            artifacts: [
                PendingReportArtifact(relativePath: "../outside.txt", data: Data("leak".utf8)),
            ]
        )

        XCTAssertThrowsError(try store.save(capture))
        XCTAssertEqual(store.listReports(for: binding), [])
        let publishedEntries = try FileManager.default.contentsOfDirectory(
            at: store.pendingDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(publishedEntries.isEmpty)
    }

    func testPurgeByServerInstanceIDRemovesAllAccountsForRemovedServer() throws {
        let store = try makeStore()
        let first = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let second = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "43")
        let otherServer = DiagnosticsBinding(serverInstanceID: "srv-b", accountUserID: "42")

        _ = try store.save(makeCapture(binding: first, fingerprint: "first"))
        _ = try store.save(makeCapture(binding: second, fingerprint: "second"))
        let survivor = try store.save(makeCapture(binding: otherServer, fingerprint: "survivor"))

        store.purge(serverInstanceID: "srv-a")

        XCTAssertEqual(store.listReports().map(\.id), [survivor.id])
    }

    func testFingerprintAutoUploadThrottleIsOncePerDayPerBinding() throws {
        let store = try makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let now = Date(timeIntervalSince1970: 20_000)

        XCTAssertTrue(store.canAutoUpload(fingerprint: "fp", binding: binding, now: now))
        store.recordAutoUploadAttempt(fingerprint: "fp", binding: binding, now: now)
        XCTAssertFalse(store.canAutoUpload(fingerprint: "fp", binding: binding, now: now.addingTimeInterval(60)))
        XCTAssertTrue(store.canAutoUpload(fingerprint: "fp", binding: binding, now: now.addingTimeInterval(25 * 60 * 60)))
    }

    // MARK: - Repeats of one issue

    func testRepeatWithinADayCountsOnTheExistingReport() throws {
        let store = try makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let start = Date(timeIntervalSince1970: 100_000)

        let first = try store.save(makeCapture(binding: binding, fingerprint: "event-1", capturedAt: start, issue: "issue-a"))
        let second = try store.save(makeCapture(
            binding: binding,
            fingerprint: "event-2",
            capturedAt: start.addingTimeInterval(60 * 60),
            issue: "issue-a"
        ))
        let third = try store.save(makeCapture(
            binding: binding,
            fingerprint: "event-3",
            capturedAt: start.addingTimeInterval(23 * 60 * 60),
            issue: "issue-a"
        ))

        XCTAssertNil(first.manifest.report.occurrenceCount)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(third.id, first.id)
        XCTAssertEqual(third.manifest.report.occurrenceCount, 3)
        XCTAssertEqual(store.listReports(for: binding).map(\.id), [first.id])
        // Each event is still recorded, so the same evidence is never re-added.
        XCTAssertTrue(store.hasSeenFingerprint("event-3", now: start.addingTimeInterval(23 * 60 * 60)))

        let manifestJSON = try String(
            contentsOf: first.directoryURL.appendingPathComponent("manifest.json"),
            encoding: .utf8
        )
        XCTAssertTrue(manifestJSON.contains(#""occurrence_count":3"#) || manifestJSON.contains(#""occurrence_count" : 3"#))
    }

    func testRepeatAfterTheWindowStartsANewReport() throws {
        let store = try makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let start = Date(timeIntervalSince1970: 100_000)

        _ = try store.save(makeCapture(binding: binding, fingerprint: "event-1", capturedAt: start, issue: "issue-a"))
        let later = try store.save(makeCapture(
            binding: binding,
            fingerprint: "event-2",
            capturedAt: start.addingTimeInterval(PendingReportStore.repeatGroupingWindow + 60),
            issue: "issue-a"
        ))

        XCTAssertEqual(store.listReports(for: binding).count, 2)
        XCTAssertNil(later.manifest.report.occurrenceCount)
    }

    func testOtherIssuesProfilesAndUngroupedReportsAreNotCounted() throws {
        let store = try makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let start = Date(timeIntervalSince1970: 100_000)

        _ = try store.save(makeCapture(binding: binding, fingerprint: "a", capturedAt: start, issue: "issue-a"))
        _ = try store.save(makeCapture(binding: binding, fingerprint: "b", capturedAt: start.addingTimeInterval(1), issue: "issue-b"))
        _ = try store.save(makeCapture(
            binding: binding,
            fingerprint: "c",
            capturedAt: start.addingTimeInterval(2),
            issue: "issue-a",
            profileID: "profile-b"
        ))

        XCTAssertEqual(store.listReports(for: binding).count, 3)
        XCTAssertTrue(store.listReports(for: binding).allSatisfy { $0.manifest.report.occurrenceCount == nil })
    }

    func testRepeatDoesNotJoinAReportWhoseDeliveryStarted() throws {
        let store = try makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let start = Date(timeIntervalSince1970: 100_000)

        let first = try store.save(makeCapture(binding: binding, fingerprint: "event-1", capturedAt: start, issue: "issue-a"))
        store.markHostedProcessing(first, shortID: "SILO-ABC")
        let second = try store.save(makeCapture(
            binding: binding,
            fingerprint: "event-2",
            capturedAt: start.addingTimeInterval(60),
            issue: "issue-a"
        ))

        XCTAssertNotEqual(second.id, first.id)
        XCTAssertNil(store.report(id: first.id, now: start)?.manifest.report.occurrenceCount)
    }

    // MARK: - Eviction order

    func testFullStoreEvictsAppErrorsBeforeCrashesThenOldest() throws {
        let store = try makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let start = Date(timeIntervalSince1970: 100_000)
        func save(_ fingerprint: String, _ type: ReportType, at offset: TimeInterval) throws {
            _ = try store.save(makeCapture(
                binding: binding,
                fingerprint: fingerprint,
                capturedAt: start.addingTimeInterval(offset),
                type: type
            ))
        }
        func remaining() -> [String] {
            store.listReports(for: binding).map(\.binding.fingerprint)
        }

        try save("manual", .manual, at: 0)
        try save("crash-1", .crash, at: 1)
        try save("hang", .hang, at: 2)

        // The hang goes before the older crash and the user's own report.
        try save("exit", .abnormalExit, at: 3)
        XCTAssertEqual(remaining(), ["manual", "crash-1", "exit"])

        // A new hang is the least important report, so it is the one dropped.
        XCTAssertThrowsError(try save("hang-2", .hang, at: 4)) { error in
            XCTAssertEqual(error as? DiagnosticsStoreError, .evictedOnArrival)
        }
        XCTAssertEqual(remaining(), ["manual", "crash-1", "exit"])

        // An unconfirmed exit goes before a crash.
        try save("crash-2", .crash, at: 5)
        XCTAssertEqual(remaining(), ["manual", "crash-1", "crash-2"])

        // Within a rank the oldest goes first; the manual report stays.
        try save("crash-3", .crash, at: 6)
        XCTAssertEqual(remaining(), ["manual", "crash-2", "crash-3"])
    }

    private func makeStore() throws -> PendingReportStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingReportStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return PendingReportStore(rootDirectory: directory)
    }

    private func makeCapture(
        binding: DiagnosticsBinding,
        fingerprint: String,
        capturedAt: Date = Date(timeIntervalSince1970: 1_000),
        artifacts: [PendingReportArtifact] = [],
        type: ReportType = .abnormalExit,
        issue: String? = nil,
        profileID: String = "profile-a"
    ) -> PendingReportCapture {
        let device = makeDeviceSnapshot(capturedAt: capturedAt)
        let crash = DiagnosticsCrashInfo(
            summary: "Silo did not shut down cleanly last time",
            stackExcerpt: nil,
            thread: "unknown",
            foreground: true,
            source: .exitSentinel,
            provenance: .postRestart,
            occurredAt: DiagnosticsTimestamp.string(from: capturedAt)
        )
        let context = DiagnosticsCaptureContext(
            binding: binding,
            profileID: "profile-a",
            consentMode: .prompt,
            noticeVersion: 1,
            appVersion: "1.0.0",
            appBuild: "1",
            platform: .ios,
            osVersion: "26.0"
        )
        let manifest = context.makeManifestDraft(
            type: type,
            capturedAt: capturedAt,
            crash: crash,
            deviceSummary: DiagnosticsManifest.DeviceSummary(
                manufacturer: "Apple",
                model: "iPhone17,2",
                os: "26.0",
                formFactor: "phone"
            ),
            playbackSessionIDs: []
        )
        return PendingReportCapture(
            binding: binding,
            profileID: profileID,
            type: type,
            fingerprint: fingerprint,
            capturedAt: capturedAt,
            manifest: manifest,
            deviceSnapshot: device,
            artifacts: artifacts,
            issueFingerprint: issue
        )
    }

    private func makeDeviceSnapshot(capturedAt: Date) -> DeviceSnapshotPayload {
        DeviceSnapshotPayload(
            capturedAt: DiagnosticsTimestamp.string(from: capturedAt),
            provenance: .postRestart,
            identity: .object([
                "manufacturer": .string("Apple"),
                "model": .string("iPhone17,2"),
                "device": .string("Unit Test"),
                "form_factor": .string("phone"),
            ]),
            display: .object(["mode": .string("not_collected")]),
            audio: .object(["passthrough": .string("unknown")]),
            videoCodecs: .string("not_collected"),
            network: .object(["transport": .string("not_collected")])
        )
    }
}

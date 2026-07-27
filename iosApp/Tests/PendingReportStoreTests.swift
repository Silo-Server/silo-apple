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

    func testCapDoesNotMarkImmediatelyEvictedCaptureAsSeen() throws {
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

        XCTAssertThrowsError(try store.save(makeCapture(
            binding: binding,
            fingerprint: "delayed-old",
            capturedAt: start
        )))
        XCTAssertFalse(store.hasSeenFingerprint("delayed-old", now: start.addingTimeInterval(10)))
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
        artifacts: [PendingReportArtifact] = []
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
            type: .abnormalExit,
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
            profileID: "profile-a",
            type: .abnormalExit,
            fingerprint: fingerprint,
            capturedAt: capturedAt,
            manifest: manifest,
            deviceSnapshot: device,
            artifacts: artifacts
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

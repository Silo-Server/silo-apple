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

    func testSnapshotWritersKeepFlagsWrittenSinceTheSnapshot() throws {
        let store = try makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let snapshot = try store.save(makeCapture(binding: binding, fingerprint: "stale-snapshot"))

        store.markServerRejected(snapshot)
        store.markTooLarge(snapshot)
        store.markNeedsServerUpdate(snapshot)
        store.markPromptDeclined(snapshot)

        // No `now:` skips the 7-day expiry pass, which would delete this
        // 1970-dated capture.
        let persisted = try XCTUnwrap(store.listReports(for: binding).first)
        XCTAssertTrue(persisted.state.serverRejected)
        XCTAssertTrue(persisted.state.tooLarge)
        XCTAssertTrue(persisted.state.needsServerUpdate)
        XCTAssertTrue(persisted.state.promptDeclined)
    }

    func testDecliningAPromptKeepsAnInFlightDeliveryClaim() throws {
        let store = try makeStore()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let snapshot = try store.save(makeCapture(binding: binding, fingerprint: "claimed-then-declined"))

        XCTAssertTrue(try store.claimSelfHostedDelivery(snapshot))
        store.markPromptDeclined(snapshot)

        let persisted = try XCTUnwrap(store.listReports(for: binding).first)
        XCTAssertTrue(persisted.state.deliveryUncertain)
        XCTAssertTrue(persisted.state.promptDeclined)
        XCTAssertFalse(
            try store.claimSelfHostedDelivery(snapshot),
            "A report whose first delivery is unanswered must not be sent again"
        )
    }

    func testLookupsOnAnEmptyStoreCreateNoFiles() throws {
        let store = try makeStore()
        let root = store.pendingDirectory.deletingLastPathComponent()
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")

        XCTAssertFalse(store.hasSeenFingerprint("fp"))
        XCTAssertTrue(store.canAutoUpload(fingerprint: "fp", binding: binding))
        XCTAssertEqual(store.listReports(), [])
        XCTAssertEqual(store.listReports(for: binding), [])
        XCTAssertEqual(try store.hostedDeletionIntents(), [])
        XCTAssertEqual(try store.hostedReadyReceiptIDs(), [])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.path),
            "Lookups must not create the store's directories or ledgers"
        )
    }

    func testFingerprintLookupsLeaveLedgersUntouchedUntilMaintenance() throws {
        let store = try makeStore()
        let root = store.pendingDirectory.deletingLastPathComponent()
        let seenFile = root.appendingPathComponent("seen-fingerprints.json")
        let throttleFile = root.appendingPathComponent("auto-upload-throttle.json")
        let binding = DiagnosticsBinding(serverInstanceID: "srv-a", accountUserID: "42")
        let day: TimeInterval = 24 * 60 * 60
        let start = Date(timeIntervalSince1970: 1_000)
        _ = try store.save(makeCapture(binding: binding, fingerprint: "old", capturedAt: start))
        _ = try store.save(makeCapture(
            binding: binding,
            fingerprint: "recent",
            capturedAt: start.addingTimeInterval(20 * day)
        ))
        store.recordAutoUploadAttempt(fingerprint: "old", binding: binding, now: start)
        let seenFileNumber = try fileNumber(seenFile)
        let throttleFileNumber = try fileNumber(throttleFile)
        let lookupTime = start.addingTimeInterval(40 * day)

        // Answers still apply the 30-day window, without pruning the files.
        XCTAssertFalse(store.hasSeenFingerprint("old", now: lookupTime))
        XCTAssertTrue(store.hasSeenFingerprint("recent", now: lookupTime))
        XCTAssertTrue(store.canAutoUpload(fingerprint: "old", binding: binding, now: lookupTime))
        XCTAssertEqual(try fileNumber(seenFile), seenFileNumber, "A lookup must not rewrite the seen ledger")
        XCTAssertEqual(try fileNumber(throttleFile), throttleFileNumber, "A lookup must not rewrite the throttle ledger")

        store.performMaintenance(now: lookupTime)

        XCTAssertEqual(try dateMapKeys(seenFile), ["recent"])
        XCTAssertEqual(try dateMapKeys(throttleFile), [])
        XCTAssertTrue(store.hasSeenFingerprint("recent", now: lookupTime))

        let prunedSeenFileNumber = try fileNumber(seenFile)
        store.performMaintenance(now: lookupTime)
        XCTAssertEqual(
            try fileNumber(seenFile),
            prunedSeenFileNumber,
            "Maintenance must not rewrite a ledger that has nothing to prune"
        )
    }

    func testListingHidesReadyReceiptedEvidenceUntilMaintenanceRemovesIt() throws {
        let remover = SwitchableRemover()
        let store = try makeStore(hostedDeletionRemover: remover.remove)
        let binding = DiagnosticsBinding.hosted(serverRegistryID: "srv-hosted", accountUserID: "42")
        let report = try store.save(makeCapture(binding: binding, fingerprint: "ready-leftover", capturedAt: Date()))
        // The collector accepted the report, but removing its directory failed.
        XCTAssertThrowsError(try store.recordHostedReadyAndDelete(report))
        remover.isEnabled = true

        XCTAssertEqual(store.listReports(), [])
        XCTAssertEqual(store.listReports(for: binding, now: Date()), [])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: report.directoryURL.path),
            "Listing must hide accepted evidence without deleting it"
        )

        store.performMaintenance()

        XCTAssertFalse(FileManager.default.fileExists(atPath: report.directoryURL.path))
        XCTAssertEqual(try store.hostedReadyReceiptIDs(), [report.id])
    }

    func testReadyReceiptLookupsDoNotPruneTheLedger() throws {
        let store = try makeStore()
        let ledger = store.pendingDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("hosted-ready-receipts.json")
        let binding = DiagnosticsBinding.hosted(serverRegistryID: "srv-hosted", accountUserID: "42")
        let report = try store.save(makeCapture(binding: binding, fingerprint: "expired-ready", capturedAt: Date()))
        let readyAt = Date().addingTimeInterval(-(PendingReportStore.hostedReadyReceiptInterval + 60))
        try store.recordHostedReadyAndDelete(report, now: readyAt)

        // The directory is gone and the receipt is past retention, so lookups
        // leave it out, but only maintenance removes it from the ledger.
        XCTAssertEqual(try store.hostedReadyReceiptIDs(), [])
        XCTAssertEqual(store.listReports(), [])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ledger.path),
            "Lookups must not prune the READY ledger"
        )

        store.performMaintenance()

        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.path))
    }

    func testMaintenanceKeepsReadyReceiptedEvidenceWhileAnErasureLedgerIsUnreadable() throws {
        let remover = SwitchableRemover()
        let store = try makeStore(hostedDeletionRemover: remover.remove)
        let root = store.pendingDirectory.deletingLastPathComponent()
        let binding = DiagnosticsBinding.hosted(serverRegistryID: "srv-hosted", accountUserID: "42")
        let report = try store.save(makeCapture(binding: binding, fingerprint: "ready-corrupt", capturedAt: Date()))
        XCTAssertThrowsError(try store.recordHostedReadyAndDelete(report))
        remover.isEnabled = true
        try Data("invalid ledger".utf8).write(to: root.appendingPathComponent("hosted-deletion-intents.json"))

        store.performMaintenance()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: report.directoryURL.path),
            "Maintenance must not remove evidence while erasure state is unreadable"
        )
    }

    func testHostedPurgesStillRemoveReadyReceiptedEvidence() throws {
        let binding = DiagnosticsBinding.hosted(serverRegistryID: "srv-hosted", accountUserID: "42")
        let purges: [(name: String, run: (PendingReportStore) throws -> Void)] = [
            ("purge(binding:)", { _ = $0.purge(binding: binding) }),
            ("purge(serverInstanceID:)", { $0.purge(serverInstanceID: binding.serverInstanceID) }),
            ("stageHostedDeletionsAndPurge(binding:)", { try $0.stageHostedDeletionsAndPurge(binding: binding) }),
            ("stageHostedDeletionsAndPurge(serverInstanceID:)", {
                try $0.stageHostedDeletionsAndPurge(serverInstanceID: binding.serverInstanceID)
            }),
        ]

        for purge in purges {
            let remover = SwitchableRemover()
            let store = try makeStore(hostedDeletionRemover: remover.remove)
            let report = try store.save(makeCapture(
                binding: binding,
                fingerprint: "ready-\(purge.name)",
                capturedAt: Date()
            ))
            XCTAssertThrowsError(try store.recordHostedReadyAndDelete(report))
            remover.isEnabled = true

            try purge.run(store)

            XCTAssertFalse(
                FileManager.default.fileExists(atPath: report.directoryURL.path),
                "\(purge.name) must remove evidence the collector already accepted"
            )
        }
    }

    private func makeStore(
        hostedDeletionRemover: ((URL) throws -> Void)? = nil
    ) throws -> PendingReportStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingReportStoreTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return PendingReportStore(rootDirectory: directory, hostedDeletionRemover: hostedDeletionRemover)
    }

    /// Atomic writes replace the file, so a changed file number means the
    /// ledger was rewritten.
    private func fileNumber(_ url: URL) throws -> NSNumber {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)
    }

    private func dateMapKeys(_ url: URL) throws -> Set<String> {
        let map = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String]
        return Set(try XCTUnwrap(map).keys)
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

/// Fails every removal until enabled, standing in for a removal that was
/// interrupted after the READY receipt was written.
private final class SwitchableRemover {
    var isEnabled = false

    func remove(_ url: URL) throws {
        guard isEnabled else { throw DiagnosticsStoreError.invalidHostedEnvelope }
        try FileManager.default.removeItem(at: url)
    }
}

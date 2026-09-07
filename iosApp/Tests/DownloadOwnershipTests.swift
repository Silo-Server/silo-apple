import Foundation
import XCTest
@testable import Silo

final class DownloadOwnershipTests: XCTestCase {
    @MainActor
    func testProductionActivationUsesFreshAuthorityRootAndPreservesLegacyBytes() async throws {
        let (_, authority, root, tokens) = try await harness()
        let legacy = Data("existing queue bytes must remain untouched".utf8)
        let legacyURL = root.appendingPathComponent("store.json")
        try legacy.write(to: legacyURL)
        let manager = DownloadManager(rootOverride: root, tokenStore: tokens,
            captureAuthority: { await tokens.captureDurableAccountAuth() })
        let activated = await manager.activateScopeIfNeeded()
        XCTAssertTrue(activated)
        let ownedRoot = try DownloadFilePaths.ownedScopeDirectory(authority: authority, rootOverride: root)
        let store = ProgressBootstrapStore(localRoot: ownedRoot, authority: authority)
        let state = try await store.localSnapshot()
        XCTAssertTrue(state.downloads.records.isEmpty)
        XCTAssertTrue(state.downloads.progressQueue.isEmpty)
        XCTAssertTrue(state.quarantinedLegacy.isEmpty)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("assets/ownership.json").path))
        manager.clearForSignOut()
        let restarted = DownloadManager(rootOverride: root, tokenStore: tokens,
            captureAuthority: { await tokens.captureDurableAccountAuth() })
        let reopened = await restarted.activateScopeIfNeeded()
        XCTAssertTrue(reopened)
        let after = try await store.localSnapshot()
        XCTAssertEqual(after.ownerGeneration, state.ownerGeneration)
        restarted.clearForSignOut()
    }

    @MainActor
    func testNewAccountEpochCannotAdoptPreviousProductionQueue() async throws {
        let (_, authority, root, tokens) = try await harness()
        let originalRoot = try DownloadFilePaths.ownedScopeDirectory(authority: authority, rootOverride: root)
        let old = ProgressBootstrapStore(localRoot: originalRoot, authority: authority)
        let initial = try await old.openFreshLocal()
        _ = try await old.applyLocal(.registered([row()], .init()), generation: initial.ownerGeneration)
        let stateURL = originalRoot.appendingPathComponent("authorities/\(authority.accountEpoch.uuidString)/state.json")
        let before = try Data(contentsOf: stateURL)
        try await tokens.installAccountSession(accessToken: "new-access", refreshToken: "new-refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let manager = DownloadManager(rootOverride: root, tokenStore: tokens,
            captureAuthority: { await tokens.captureDurableAccountAuth() })
        let activated = await manager.activateScopeIfNeeded()
        XCTAssertTrue(activated)
        XCTAssertNil(manager.record(id: "download"))
        let captured = await tokens.captureDurableAccountAuth()
        let current = try DownloadLocalAuthority(XCTUnwrap(captured))
        XCTAssertNotEqual(try DownloadFilePaths.ownedScopeDirectory(authority: current, rootOverride: root), originalRoot)
        XCTAssertEqual(try Data(contentsOf: stateURL), before)
        manager.clearForSignOut()
    }

    func testFreshLocalRefusesLegacyBytesInsideItsNamespace() async throws {
        let (store, _, root, _) = try await harness()
        let data = Data("legacy with unknown owner".utf8)
        let url = root.appendingPathComponent("store.json")
        try data.write(to: url)
        do { _ = try await store.openFreshLocal(); XCTFail("Must not claim legacy storage") }
        catch DownloadOwnershipError.disabled {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testSubscriptionValidatorSurvivesRestartAndStaleCollectionCannotOverwriteEdit() async throws {
        let (store, authority, root, _) = try await harness()
        let state = try await store.openLocal(legacyData: nil, permitMigration: true)
        let data = Data(#"{"id":"monitor","series_id":"series","mode":"specific_seasons","season_numbers":[0,2],"delete_watched":true,"max_storage_bytes":42,"active":false,"etag":"\"opaque-tag\""}"#.utf8)
        let row = try HTTPClient.makeJSONDecoder().decode(ServerSubscription.self, from: data)
        try DownloadSubscriptionV2.validate(row)
        _ = try await store.applyLocal(.subscription(row, "Series"), generation: state.ownerGeneration)
        let restarted = ProgressBootstrapStore(localRoot: root, authority: authority)
        let loaded = try await restarted.openLocal(legacyData: nil, permitMigration: true)
        let saved = try XCTUnwrap(loaded.downloads.subscriptions.first)
        XCTAssertEqual(saved.etag, "\"opaque-tag\"")
        XCTAssertEqual(saved.seasonNumbers, [0, 2]); XCTAssertFalse(saved.active)
        do {
            _ = try await restarted.applyLocal(.subscriptionCollection([], expected: []), generation: loaded.ownerGeneration)
            XCTFail("stale list erased monitor")
        } catch {}
        let final = try await restarted.localSnapshot()
        XCTAssertEqual(final.downloads.subscriptions, [saved])
    }

    func testCreationRetainsExactReplacementIDAndRevision() async throws {
        let (store, _, _, _) = try await harness()
        let state = try await store.openLocal(legacyData: nil, permitMigration: true)
        let row = try HTTPClient.makeJSONDecoder().decode(ServerDownloadRow.self,
            from: Data(#"{"id":"exact-entry","content_id":"movie","media_file_id":42,"revision":3,"quality":"original","status":"ready"}"#.utf8))
        let local = try await store.applyLocal(.registered([row], .init()), generation: state.ownerGeneration)
        let record = try XCTUnwrap(local.downloads.records["exact-entry"])
        let request = CreateDownloadRequest(contentId: "movie", episodeId: nil, fileId: 42, quality: "1mbps", series: nil, seasonNumber: nil, caps: nil)
        let body = try DownloadCreateV2Body(request, existing: record, batchID: nil)
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(body)) as? [String: Any])
        XCTAssertEqual(fields["expected_download_id"] as? String, "exact-entry")
        XCTAssertEqual(fields["expected_revision"] as? Int, 3)
        XCTAssertEqual(fields["media_file_id"] as? String, "42")
        XCTAssertEqual(fields["quality"] as? String, "1mbps")
        XCTAssertNil(fields["expected_entries"])
        let absent = try DownloadCreateV2Body(request, existing: nil, batchID: nil)
        XCTAssertEqual(absent.expectedRevision, 0); XCTAssertNil(absent.expectedDownloadId)
    }

    func testStatusEventsSurviveRestartAndOldAcknowledgmentCannotClearCompletion() async throws {
        let (store, authority, root, _) = try await harness()
        let state = try await store.openLocal(legacyData: nil, permitMigration: true)
        let data = Data(#"{"id":"download","content_id":"movie","media_file_id":1,"revision":1,"quality":"original","status":"ready"}"#.utf8)
        let row = try HTTPClient.makeJSONDecoder().decode(ServerDownloadRow.self, from: data)
        _ = try await store.applyLocal(.registered([row], .init()), generation: state.ownerGeneration)
        let (_, operation) = try await store.beginLocalPipeline(id: "download", generation: state.ownerGeneration)
        let lease = try await store.localLease(downloadID: "download")
        let binding = DownloadTaskBinding(transferID: UUID(), sessionID: "session", taskID: 7, lease: lease, operationID: operation)
        let bound = try await store.bindLocalTask(binding, generation: state.ownerGeneration)
        let start = try XCTUnwrap(bound.downloads.records["download"]?.pendingStatusEvent)
        let restarted = ProgressBootstrapStore(localRoot: root, authority: authority)
        let retry = try await restarted.pendingLocalStatus(id: "download", generation: state.ownerGeneration)
        XCTAssertEqual(retry, start)
        let source = root.appendingPathComponent("status-input")
        try Data("bytes".utf8).write(to: source)
        let completed = try await store.completeLocalTask(source: source, suffix: "mp4", binding: binding, generation: state.ownerGeneration)
        let event = try XCTUnwrap(completed.downloads.records["download"]?.pendingStatusEvent)
        XCTAssertEqual(event.status, "completed")
        XCTAssertGreaterThan(event.updatedAt, start.updatedAt)
        XCTAssertEqual(event.revision, start.revision)
        let eventFormatter = ISO8601DateFormatter()
        eventFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let response = APIv2DownloadEntry(id: "download", contentId: "movie", episodeId: nil, batchId: nil,
            deviceId: event.deviceID, mediaFileId: "1", fileSize: 5, bytesSent: 5, kind: "", status: "completed",
            quality: "original", effectiveQuality: "original", deliveryFormat: "original", targetBitrateKbps: 0,
            revision: 1, createdAt: Date(), completedAt: nil, statusEventAt: eventFormatter.date(from: event.updatedAt))
        do {
            _ = try await store.acknowledgeLocalStatus(id: "download", event: start, row: response, generation: state.ownerGeneration)
            XCTFail("old response erased completion")
        } catch {}
        let retained = try await restarted.pendingLocalStatus(id: "download", generation: state.ownerGeneration)
        XCTAssertEqual(retained, event)
        _ = try await store.acknowledgeLocalStatus(id: "download", event: event, row: response, generation: state.ownerGeneration)
        let acked = try await restarted.pendingLocalStatus(id: "download", generation: state.ownerGeneration)
        XCTAssertNil(acked)
        let snapshot = try await restarted.localSnapshot()
        let record = try XCTUnwrap(snapshot.downloads.records["download"])
        XCTAssertEqual(record.lastStatusEventAt, event.updatedAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sameInstant = try XCTUnwrap(formatter.date(from: event.updatedAt))
        let next = try XCTUnwrap(DownloadStatusEvent.make(status: "completed", record: record, lease: lease, now: sameInstant))
        XCTAssertGreaterThan(next.updatedAt, event.updatedAt, "acknowledgment must not erase the millisecond ordering fence")
    }

    func testReplacementRetiresOldStatusWithoutRewritingItsRevision() async throws {
        let (store, _, _, _) = try await harness()
        let state = try await store.openLocal(legacyData: nil, permitMigration: true)
        func revisionRow(_ revision: Int) throws -> ServerDownloadRow {
            let text = "{\"id\":\"download\",\"content_id\":\"movie\",\"media_file_id\":1,\"revision\":\(revision),\"quality\":\"original\",\"status\":\"ready\"}"
            return try HTTPClient.makeJSONDecoder().decode(ServerDownloadRow.self, from: Data(text.utf8))
        }
        _ = try await store.applyLocal(.registered([revisionRow(1)], .init()), generation: state.ownerGeneration)
        let (_, operation) = try await store.beginLocalPipeline(id: "download", generation: state.ownerGeneration)
        let lease = try await store.localLease(downloadID: "download")
        let binding = DownloadTaskBinding(transferID: UUID(), sessionID: "session", taskID: 7, lease: lease, operationID: operation)
        let bound = try await store.bindLocalTask(binding, generation: state.ownerGeneration)
        let event = try XCTUnwrap(bound.downloads.records["download"]?.pendingStatusEvent)
        _ = try await store.applyLocal(.registered([revisionRow(2)], .init()), generation: state.ownerGeneration)
        let pending = try await store.pendingLocalStatus(id: "download", generation: state.ownerGeneration)
        XCTAssertNil(pending)
        XCTAssertEqual(event.revision, 1)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event.body)) as? [String: Any]
        XCTAssertEqual(encoded?["revision"] as? Int, 1)
    }

    private func harness() async throws -> (ProgressBootstrapStore, DownloadLocalAuthority, URL, TokenStore) {
        let name = "DownloadOwnershipTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root); UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil), defaults: SharedDefaults(suite: defaults, standard: defaults))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://downloads.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let captured = await tokens.captureDurableAccountAuth()
        let authority = try DownloadLocalAuthority(XCTUnwrap(captured))
        return (ProgressBootstrapStore(localRoot: root, authority: authority), authority, root, tokens)
    }

    @MainActor
    func testCanceledActivationCannotPublishOrClearNewAttempt() async throws {
        let (_, _, root, tokens) = try await harness()
        let auth = await tokens.captureDurableAccountAuth()
        let captured = try XCTUnwrap(auth)
        let gate = OwnershipCaptureGate(captured)
        let manager = DownloadManager(permitOwnershipTransfer: true, rootOverride: root,
            captureAuthority: { await gate.capture() })
        let old = Task { await manager.activateScopeIfNeeded() }
        await gate.waitUntilCaptured()
        manager.clearForSignOut()
        let current = Task { await manager.activateScopeIfNeeded() }
        await gate.release()
        let oldResult = await old.value
        let currentResult = await current.value
        XCTAssertFalse(oldResult)
        XCTAssertTrue(currentResult)
        XCTAssertEqual(manager.scopeProfileId, "profile")
        manager.clearForSignOut()
    }

    @MainActor
    func testOlderPublicationCannotReplaceNewerProgressOrCrossSignout() async throws {
        let (_, _, root, tokens) = try await harness()
        let auth = await tokens.captureDurableAccountAuth()
        let gate = OwnershipPublicationGate(try XCTUnwrap(auth))
        let manager = DownloadManager(permitOwnershipTransfer: true, rootOverride: root,
            captureAuthority: { await gate.capture() })
        let activated = await manager.activateScopeIfNeeded()
        XCTAssertTrue(activated)
        let authority = manager.captureOfflineProgressAuthority()
        await gate.blockSecondCapture()
        let first = try XCTUnwrap(manager.recordOfflineProgress(mediaItemId: "movie", position: 1,
            duration: 10, completed: false, authority: authority))
        await gate.waitUntilBlocked()
        let second = try XCTUnwrap(manager.recordOfflineProgress(mediaItemId: "movie", position: 2,
            duration: 10, completed: false, authority: authority))
        await second.value
        XCTAssertEqual(manager.file.localProgress["movie"]?.position, 2)
        await gate.release()
        await first.value
        XCTAssertEqual(manager.file.localProgress["movie"]?.position, 2)
        XCTAssertEqual(manager.file.progressQueue.count, 2)
        manager.clearForSignOut()
        XCTAssertNil(manager.recordOfflineProgress(mediaItemId: "movie", position: 3,
            duration: 10, completed: false, authority: authority))
        XCTAssertTrue(manager.file.progressQueue.isEmpty)
    }

    func testParkingRecoveryUsesCurrentContainerAndPreservesResumeBytes() async throws {
        let (_, _, root, _) = try await harness()
        let staging = root.appendingPathComponent("staging")
        let arrival = try DownloadArrivalParking.park(data: Data("resume".utf8), root: staging,
            sessionID: "session", taskID: 1, transferID: nil, status: 0)
        let moved = root.appendingPathComponent("relocated")
        try FileManager.default.moveItem(at: staging, to: moved)
        let recovered = try DownloadArrivalParking.recover(directory: moved.appendingPathComponent(arrival.arrivalID.uuidString))
        XCTAssertEqual(try Data(contentsOf: recovered.payload), Data("resume".utf8))
        XCTAssertNil(recovered.transferID)
        let sidecar = try String(contentsOf: recovered.directory.appendingPathComponent("arrival.json"), encoding: .utf8)
        XCTAssertFalse(sidecar.contains(root.path))
    }

    private func row(id: String = "download") throws -> ServerDownloadRow {
        let json = #"{"id":"ID","content_id":"movie","media_file_id":1,"quality":"original","status":"ready","file_size":8}"#.replacingOccurrences(of: "ID", with: id)
        return try HTTPClient.makeJSONDecoder().decode(ServerDownloadRow.self, from: Data(json.utf8))
    }

    func testMigrationKeepsExactUnknownQueueAndFencesLegacyWriter() async throws {
        let (store, _, root, _) = try await harness()
        let event = QueuedProgress(id: UUID(), mediaItemId: "movie", position: 0, duration: 0, updatedAt: Date(timeIntervalSince1970: 100), attempts: 3)
        var legacy = DownloadStoreFile.empty
        legacy.progressQueue = [event]
        legacy.localProgress["movie"] = LocalProgressEntry(position: 0, duration: 0, completed: false, updatedAt: event.updatedAt)
        let bytes = try JSONEncoder().encode(legacy)
        let legacyURL = root.appendingPathComponent("store.json")
        try bytes.write(to: legacyURL)
        let result = try await store.openLocal(legacyData: bytes, permitMigration: true)
        XCTAssertEqual(result.quarantinedLegacy, bytes)
        XCTAssertTrue(result.pending.isEmpty)
        XCTAssertTrue(result.downloads.progressQueue.isEmpty)
        XCTAssertNil(result.installationID)
        XCTAssertEqual(try Data(contentsOf: legacyURL), bytes)
        let assets = DownloadAssetOwnership(root: root)
        XCTAssertThrowsError(try assets.withLock { try assets.requireLegacyWriterLocked() })
    }

    func testMigrationReadsLatestLockedLegacyFileInsteadOfEarlierCallerSnapshot() async throws {
        let (store, _, root, _) = try await harness()
        let old = try JSONEncoder().encode(DownloadStoreFile.empty)
        var current = DownloadStoreFile.empty
        current.progressQueue = [QueuedProgress(id: UUID(), mediaItemId: "new", position: 4,
            duration: 10, updatedAt: Date(), attempts: 5)]
        let bytes = try JSONEncoder().encode(current)
        let assets = DownloadAssetOwnership(root: root)
        try assets.withLock { try bytes.write(to: root.appendingPathComponent("store.json"), options: .atomic) }
        let value = try await store.openLocal(legacyData: old, permitMigration: true)
        XCTAssertEqual(value.quarantinedLegacy, bytes)
        XCTAssertTrue(value.pending.isEmpty)
    }

    func testDormantBootstrapArchivePreservesReceiptAndNeverAcknowledgesPendingUpload() async throws {
        let (store, authority, _, _) = try await harness()
        let now = Date()
        let event = QueuedProgress(id: UUID(), mediaItemId: "movie", position: 0, duration: 0, updatedAt: now, attempts: 7)
        var downloads = DownloadStoreFile.empty
        downloads.progressQueue = [event]
        let zero = StoredProgressValue(position: 0, duration: 0, completed: false, updatedAt: now)
        let checkpoint = StoredProgressCheckpoint(snapshotID: "snapshot", generation: "generation", capturedAt: now,
            expiresAt: now.addingTimeInterval(60), itemCount: 1, receipt: "original-receipt")
        let archive = ProgressBootstrapStoreFile(version: 2,
            scope: ProgressBootstrapStoreScope(serverID: authority.serverID, origin: authority.origin,
                installationID: "unverified-installation", accountID: authority.accountID,
                profileID: authority.profileID, authorityID: authority.accountEpoch),
            revision: 4, downloads: downloads, serverProgress: ["movie": zero], pending: [event.id: zero],
            settledLocalProgress: [:], intent: nil, staging: nil, committed: checkpoint,
            retiredRequestIDs: [], upload: StoredProgressUpload(id: UUID(), events: [event]))
        let bytes = try JSONEncoder().encode(archive)
        let value = try await store.openLocal(legacyData: bytes, permitMigration: true)
        XCTAssertEqual(value.quarantinedLegacy, bytes)
        XCTAssertEqual(value.bootstrapArchive?.committed?.receipt, "original-receipt")
        XCTAssertEqual(value.bootstrapArchive?.upload?.events.first?.id, event.id)
        XCTAssertEqual(value.bootstrapArchive?.upload?.events.first?.attempts, 7)
        XCTAssertEqual(value.bootstrapArchive?.serverProgress["movie"], zero)
        XCTAssertNil(value.committed)
        XCTAssertNil(value.installationID)
        XCTAssertTrue(value.pending.isEmpty)
    }

    func testCorruptAndDisabledMigrationNeverPublishesMarker() async throws {
        let (store, authority, root, _) = try await harness()
        do { _ = try await store.openLocal(legacyData: Data("bad".utf8), permitMigration: true); XCTFail() } catch {}
        do { _ = try await store.openLocal(legacyData: nil, permitMigration: false); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("authorities/\(authority.accountEpoch)/owner.json").path))
    }

    func testCurrentStateCommandsPreserveConcurrentFieldsAndFalseZero() async throws {
        let (store, _, _, _) = try await harness()
        let initial = try await store.openLocal(legacyData: nil, permitMigration: true)
        let registered = try await store.applyLocal(.registered([row()], .init(title: "Title")), generation: initial.ownerGeneration)
        let event = QueuedProgress(id: UUID(), mediaItemId: "movie", position: 0, duration: 0, updatedAt: Date(), attempts: 0)
        _ = try await store.applyLocal(.progress(event, false), generation: initial.ownerGeneration)
        let result = try await store.applyLocal(.status("download", .paused, nil), generation: initial.ownerGeneration)
        XCTAssertEqual(result.downloads.records["download"]?.title, registered.downloads.records["download"]?.title)
        XCTAssertEqual(result.downloads.localProgress["movie"]?.position, 0)
        XCTAssertEqual(result.downloads.localProgress["movie"]?.completed, false)
        XCTAssertEqual(result.downloads.progressQueue.first?.id, event.id)
        let replay = try await store.applyLocal(.progress(event, false), generation: initial.ownerGeneration)
        XCTAssertEqual(replay.downloads.progressQueue.count, 1)
        XCTAssertEqual(replay.revision, result.revision)
    }

    func testStalePipelineCannotBindAfterPause() async throws {
        let (store, _, root, _) = try await harness()
        let initial = try await store.openLocal(legacyData: nil, permitMigration: true)
        _ = try await store.applyLocal(.registered([row()], .init()), generation: initial.ownerGeneration)
        let (_, operation) = try await store.beginLocalPipeline(id: "download", generation: initial.ownerGeneration)
        let lease = try await store.localLease(downloadID: "download")
        _ = try await store.applyLocal(.status("download", .paused, nil), generation: initial.ownerGeneration)
        let binding = DownloadTaskBinding(transferID: UUID(), sessionID: "session", taskID: 1, lease: lease, operationID: operation)
        do { _ = try await store.bindLocalTask(binding, generation: initial.ownerGeneration); XCTFail() } catch {}
        var resumed = false
        let state = try await store.localSnapshot()
        XCTAssertTrue(state.transfers.isEmpty)
        // No caller may resume when the record-side binding did not commit.
        if state.transfers[binding.transferID] != nil { try DownloadAssetOwnership(root: root).resume(binding) { resumed = true } }
        XCTAssertFalse(resumed)
    }

    func testNewEpochAdoptionFencesOldLeaseAndPreservesBytes() async throws {
        let (_, authority, root, tokens) = try await harness()
        let assets = DownloadAssetOwnership(root: root)
        let old = try assets.adopt(downloadID: "download", authority: authority, retainedFiles: [])
        let input = root.appendingPathComponent("input")
        try Data("original".utf8).write(to: input)
        var filename = ""
        try assets.attach(source: input, suffix: "bin", lease: old) { filename = $0 }
        try await tokens.installAccountSession(accessToken: "new", refreshToken: "new-refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let captured = await tokens.captureDurableAccountAuth()
        let nextAuthority = try DownloadLocalAuthority(XCTUnwrap(captured))
        let next = try assets.adoptReplacing(old, authority: nextAuthority)
        XCTAssertThrowsError(try assets.remove(lease: old, publish: {}))
        XCTAssertThrowsError(try assets.attach(source: input, suffix: "bin", lease: old, publish: { _ in }))
        XCTAssertThrowsError(try assets.adopt(downloadID: "download", authority: authority, retainedFiles: []))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("download/\(filename)")), Data("original".utf8))
        XCTAssertEqual(next.authority, nextAuthority)
    }

    func testReusedTaskIDsAndUnknownCallbacksParkDistinctBytes() async throws {
        let (_, _, root, _) = try await harness()
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let legacy = staging.appendingPathComponent("task-1.bin")
        try Data("legacy".utf8).write(to: legacy)
        var arrivals: [DownloadParkedArrival] = []
        for text in ["one", "two"] {
            let source = root.appendingPathComponent(text)
            try Data(text.utf8).write(to: source)
            arrivals.append(try DownloadArrivalParking.park(source: source, root: staging, sessionID: "session", taskID: 1, transferID: nil, status: 200))
        }
        XCTAssertNotEqual(arrivals[0].arrivalID, arrivals[1].arrivalID)
        XCTAssertEqual(try Data(contentsOf: arrivals[0].payload), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: arrivals[1].payload), Data("two".utf8))
        XCTAssertEqual(try Data(contentsOf: legacy), Data("legacy".utf8))
    }

    func testFailedAssetStateWriteKeepsBothInputsAndRecoversWithoutDeletion() async throws {
        let (_, authority, root, _) = try await harness()
        let assets = DownloadAssetOwnership(root: root)
        let lease = try assets.adopt(downloadID: "download", authority: authority, retainedFiles: [])
        let source = root.appendingPathComponent("input")
        try Data("valid".utf8).write(to: source)
        var filename = ""
        XCTAssertThrowsError(try assets.attach(source: source, suffix: "bin", lease: lease) { value in
            filename = value
            throw DownloadOwnershipError.disabled
        })
        XCTAssertEqual(try Data(contentsOf: source), Data("valid".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("download/\(filename)")), Data("valid".utf8))
        try assets.withLock { try assets.recoverLocked(authority: authority) }
        XCTAssertEqual(try Data(contentsOf: source), Data("valid".utf8))
    }
    func testInterruptedMarkerPublicationResumesExactCandidateAndOldBytes() async throws {
        let (_, authority, root, _) = try await harness()
        let fault = OwnershipWriteFault()
        fault.marker = true
        let store = ProgressBootstrapStore(localRoot: root, authority: authority, write: fault.write)
        let bytes = try JSONEncoder().encode(DownloadStoreFile.empty)
        do { _ = try await store.openLocal(legacyData: bytes, permitMigration: true); XCTFail() } catch {}
        let assets = DownloadAssetOwnership(root: root)
        XCTAssertThrowsError(try assets.withLock { try assets.requireLegacyWriterLocked() })
        fault.marker = false
        let recovered = try await store.openLocal(legacyData: Data("stale replacement".utf8), permitMigration: true)
        XCTAssertEqual(recovered.quarantinedLegacy, bytes)
        XCTAssertEqual(recovered.revision, 0)
    }

    func testFailedCommandWriteDoesNotPublishOrConsumeEvent() async throws {
        let (_, authority, root, _) = try await harness()
        let fault = OwnershipWriteFault()
        let store = ProgressBootstrapStore(localRoot: root, authority: authority, write: fault.write)
        let initial = try await store.openLocal(legacyData: nil, permitMigration: true)
        _ = try await store.applyLocal(.registered([row()], .init()), generation: initial.ownerGeneration)
        let before = try await store.localSnapshot()
        let event = QueuedProgress(id: UUID(), mediaItemId: "movie", position: 5, duration: 50, updatedAt: Date(), attempts: 2)
        fault.state = true
        for command in [DownloadLocalCommand.status("download", .paused, nil), .progress(event, false)] {
            do { _ = try await store.applyLocal(command, generation: initial.ownerGeneration); XCTFail() } catch {}
            let after = try await store.localSnapshot()
            XCTAssertEqual(after.revision, before.revision)
            XCTAssertEqual(after.downloads.records["download"]?.localStatus, before.downloads.records["download"]?.localStatus)
            XCTAssertTrue(after.downloads.progressQueue.isEmpty)
        }
        fault.state = false
        let persisted = try await store.applyLocal(.progress(event, false), generation: initial.ownerGeneration)
        XCTAssertEqual(persisted.downloads.progressQueue.first?.id, event.id)
        XCTAssertEqual(persisted.downloads.progressQueue.first?.attempts, 2)
    }

    func testAbsentServerRowsUseObservedOperationAndRetainInventory() async throws {
        let (store, _, _, _) = try await harness()
        let state = try await store.openLocal(legacyData: nil, permitMigration: true)
        let first = try await store.applyLocal(.registered([row()], .init()), generation: state.ownerGeneration)
        let (_, operation) = try await store.beginLocalPipeline(id: "download", generation: state.ownerGeneration)
        let stale = try await store.applyLocal(.absentServerRows(observed: first.recordOperations, present: []), generation: state.ownerGeneration)
        XCTAssertEqual(stale.downloads.records["download"]?.localStatus, .fetchingAssets)
        let current = try await store.applyLocal(.absentServerRows(observed: ["download": operation], present: []), generation: state.ownerGeneration)
        XCTAssertEqual(current.downloads.records["download"]?.localStatus, .failed)
        XCTAssertNotNil(current.downloads.records["download"])
    }

    func testUnversionedReplacementInvalidatesOldPipelineAndPreservesMissingRevision() async throws {
        let (store, _, _, _) = try await harness()
        let state = try await store.openLocal(legacyData: nil, permitMigration: true)
        let registered = try await store.applyLocal(.registered([row()], .init()), generation: state.ownerGeneration)
        XCTAssertNil(registered.downloads.records["download"]?.revision)
        let (_, operation) = try await store.beginLocalPipeline(id: "download", generation: state.ownerGeneration)
        let oldLease = try await store.localLease(downloadID: "download")
        let json = #"{"id":"download","content_id":"movie","media_file_id":2,"quality":"original","status":"ready","file_size":8}"#
        let replacement = try HTTPClient.makeJSONDecoder().decode(ServerDownloadRow.self, from: Data(json.utf8))
        let current = try await store.applyLocal(.registered([replacement], .init()), generation: state.ownerGeneration)
        XCTAssertNil(current.downloads.records["download"]?.revision)
        XCTAssertEqual(current.downloads.records["download"]?.mediaFileId, 2)
        XCTAssertNotEqual(current.recordOperations["download"], operation)
        XCTAssertNotEqual(current.leases["download"]?.generation, oldLease.generation)
        do { _ = try await store.deleteLocalRecord(oldLease, generation: state.ownerGeneration); XCTFail("Old delete removed replacement") } catch {}
        do {
            _ = try await store.applyLocal(.status("download", .failed, nil), generation: state.ownerGeneration,
                recordOperation: ("download", operation))
            XCTFail("Old pipeline overwrote replacement")
        } catch {}
    }

    func testPauseAfterBindingPreventsResume() async throws {
        let (store, _, _, tokens) = try await harness()
        let captured = await tokens.captureDurableAccountAuth()
        let auth = try XCTUnwrap(captured)
        let state = try await store.openLocal(legacyData: nil, permitMigration: true)
        _ = try await store.applyLocal(.registered([row()], .init()), generation: state.ownerGeneration)
        let (_, operation) = try await store.beginLocalPipeline(id: "download", generation: state.ownerGeneration)
        let lease = try await store.localLease(downloadID: "download")
        let binding = DownloadTaskBinding(transferID: UUID(), sessionID: "session", taskID: 7, lease: lease, operationID: operation)
        _ = try await store.bindLocalTask(binding, generation: state.ownerGeneration)
        _ = try await store.applyLocal(.status("download", .paused, nil), generation: state.ownerGeneration)
        do {
            try await store.resumeLocalTask(binding, generation: state.ownerGeneration, tokenStore: tokens, auth: auth) { XCTFail("Paused transfer resumed") }
            XCTFail("Paused binding was accepted")
        } catch {}
    }

    func testActualResumeAdmissionRejectsChangedProfileAndCanceledCaller() async throws {
        let (store, _, _, tokens) = try await harness()
        let state = try await store.openLocal(legacyData: nil, permitMigration: true)
        _ = try await store.applyLocal(.registered([row()], .init()), generation: state.ownerGeneration)
        let (_, operation) = try await store.beginLocalPipeline(id: "download", generation: state.ownerGeneration)
        let lease = try await store.localLease(downloadID: "download")
        let binding = DownloadTaskBinding(transferID: UUID(), sessionID: "session", taskID: 7, lease: lease, operationID: operation)
        _ = try await store.bindLocalTask(binding, generation: state.ownerGeneration)
        let captured = await tokens.captureDurableAccountAuth()
        let auth = try XCTUnwrap(captured)
        await tokens.setProfileId("different")
        do {
            try await store.resumeLocalTask(binding, generation: state.ownerGeneration, tokenStore: tokens, auth: auth) {
                XCTFail("Old profile resumed")
            }
            XCTFail("Old authority admitted")
        } catch {}
        await tokens.setProfileId("profile")
        let current = await tokens.captureDurableAccountAuth()
        let restored = try XCTUnwrap(current)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await store.resumeLocalTask(binding, generation: state.ownerGeneration, tokenStore: tokens, auth: restored) {
                    XCTFail("Canceled caller resumed")
                }
                XCTFail("Cancellation ignored")
            } catch {}
        }
        await canceled.value
    }

    func testRestartedPreparedBindingCanResumeWithCurrentAuthority() async throws {
        let (store, authority, root, tokens) = try await harness()
        let state = try await store.openLocal(legacyData: nil, permitMigration: true)
        _ = try await store.applyLocal(.registered([row()], .init()), generation: state.ownerGeneration)
        let (_, operation) = try await store.beginLocalPipeline(id: "download", generation: state.ownerGeneration)
        let lease = try await store.localLease(downloadID: "download")
        let binding = DownloadTaskBinding(transferID: UUID(), sessionID: "session", taskID: 7, lease: lease, operationID: operation)
        _ = try await store.bindLocalTask(binding, generation: state.ownerGeneration)
        let restarted = ProgressBootstrapStore(localRoot: root, authority: authority)
        let captured = await tokens.captureDurableAccountAuth()
        let auth = try XCTUnwrap(captured)
        let resumed = expectation(description: "prepared task resumed")
        try await restarted.resumeLocalTask(binding, generation: state.ownerGeneration, tokenStore: tokens, auth: auth) {
            resumed.fulfill()
        }
        await fulfillment(of: [resumed], timeout: 1)
    }

    @MainActor
    func testManagerRecoveryResumesSuspendedTaskInsteadOfCountingItAsRunning() async throws {
        let (store, _, root, tokens) = try await harness()
        let state = try await store.openLocal(legacyData: nil, permitMigration: true)
        _ = try await store.applyLocal(.registered([row()], .init()), generation: state.ownerGeneration)
        let (_, operation) = try await store.beginLocalPipeline(id: "download", generation: state.ownerGeneration)
        let lease = try await store.localLease(downloadID: "download")
        let delegate = DownloadSessionDelegate(parkingRoot: root, identifier: "ownership-test.\(UUID())")
        let transferID = UUID()
        let task = delegate.prepare(request: URLRequest(url: URL(string: "http://127.0.0.1:9/prepared-fixture")!), transferID: transferID)
        let binding = DownloadTaskBinding(transferID: transferID, sessionID: delegate.identifier,
            taskID: task.taskIdentifier, lease: lease, operationID: operation)
        _ = try await store.bindLocalTask(binding, generation: state.ownerGeneration)
        XCTAssertEqual(task.state, .suspended)
        let manager = DownloadManager(permitOwnershipTransfer: true, rootOverride: root, tokenStore: tokens,
            sessionDelegate: delegate, captureAuthority: { await tokens.captureDurableAccountAuth() })
        let activated = await manager.activateScopeIfNeeded()
        XCTAssertTrue(activated)
        await manager.recoverTransfers()
        XCTAssertNotEqual(task.state, .suspended)
        task.cancel()
        manager.clearForSignOut()
    }

    func testSharedAssetScopeRejectsDifferentProfileAndTraversal() async throws {
        let (_, authority, root, tokens) = try await harness()
        let assets = DownloadAssetOwnership(root: root)
        let lease = try assets.adopt(downloadID: "download", authority: authority, retainedFiles: [])
        XCTAssertThrowsError(try assets.adopt(downloadID: "../escape", authority: authority, retainedFiles: []))
        await tokens.setProfileId("different")
        let captured = await tokens.captureDurableAccountAuth()
        let other = try DownloadLocalAuthority(XCTUnwrap(captured))
        XCTAssertThrowsError(try assets.adopt(downloadID: "other", authority: other, retainedFiles: []))
        XCTAssertThrowsError(try assets.adoptReplacing(lease, authority: other))
        XCTAssertEqual(try assets.currentLease(downloadID: "download"), lease)
    }

    func testTaskReferenceCommitsBeforeResumeAndDuplicateCompletionIsRejected() async throws {
        let (store, _, root, _) = try await harness()
        let initial = try await store.openLocal(legacyData: nil, permitMigration: true)
        _ = try await store.applyLocal(.registered([row()], .init()), generation: initial.ownerGeneration)
        let (_, operation) = try await store.beginLocalPipeline(id: "download", generation: initial.ownerGeneration)
        let lease = try await store.localLease(downloadID: "download")
        let binding = DownloadTaskBinding(transferID: UUID(), sessionID: "session", taskID: 7, lease: lease, operationID: operation)
        let result = try await store.bindLocalTask(binding, generation: initial.ownerGeneration)
        var resumed = false
        try DownloadAssetOwnership(root: root).resume(binding) {
            XCTAssertEqual(result.transfers[binding.transferID], binding)
            XCTAssertEqual(result.downloads.records["download"]?.taskIdentifier, 7)
            resumed = true
        }
        XCTAssertTrue(resumed)
        let source = root.appendingPathComponent("input")
        try Data("media".utf8).write(to: source)
        let completed = try await store.completeLocalTask(source: source, suffix: "mp4", binding: binding, generation: initial.ownerGeneration)
        XCTAssertEqual(completed.downloads.records["download"]?.bytesDownloaded, 5)
        do { _ = try await store.completeLocalTask(source: source, suffix: "mp4", binding: binding, generation: initial.ownerGeneration); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: source), Data("media".utf8))
    }

    func testOverlappingOwnerCommandsUseCurrentRevision() async throws {
        let (store, authority, root, _) = try await harness()
        let initial = try await store.openLocal(legacyData: nil, permitMigration: true)
        let second = ProgressBootstrapStore(localRoot: root, authority: authority)
        let events = (0..<12).map { QueuedProgress(id: UUID(), mediaItemId: "item-\($0)", position: 0, duration: 0, updatedAt: Date(), attempts: 0) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, event) in events.enumerated() {
                group.addTask {
                    _ = try await (index.isMultiple(of: 2) ? store : second).applyLocal(.progress(event, false), generation: initial.ownerGeneration)
                }
            }
            try await group.waitForAll()
        }
        let result = try await store.localSnapshot()
        XCTAssertEqual(Set(result.downloads.progressQueue.map(\.id)), Set(events.map(\.id)))
        XCTAssertEqual(result.revision, 12)
    }

}

private final class OwnershipWriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var failMarker = false
    private var failState = false
    var marker: Bool {
        get { lock.withLock { failMarker } }
        set { lock.withLock { failMarker = newValue } }
    }
    var state: Bool {
        get { lock.withLock { failState } }
        set { lock.withLock { failState = newValue } }
    }
    func write(_ data: Data, _ url: URL) throws {
        if lock.withLock({ (failMarker && url.lastPathComponent == "owner.json") || (failState && url.lastPathComponent == "state.json") }) {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try data.write(to: url, options: .atomic)
    }
}

private actor OwnershipCaptureGate {
    let value: CapturedDurableAccountAuth
    var blocked: CheckedContinuation<Void, Never>?
    var observed: CheckedContinuation<Void, Never>?
    var entered = false
    init(_ value: CapturedDurableAccountAuth) { self.value = value }
    func capture() async -> CapturedDurableAccountAuth? {
        if !entered {
            entered = true
            observed?.resume()
            observed = nil
            await withCheckedContinuation { blocked = $0 }
        }
        return value
    }
    func waitUntilCaptured() async {
        if entered { return }
        await withCheckedContinuation { observed = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
}

private actor OwnershipPublicationGate {
    let value: CapturedDurableAccountAuth
    var remaining: Int?
    var blocked: CheckedContinuation<Void, Never>?
    var observer: CheckedContinuation<Void, Never>?
    init(_ value: CapturedDurableAccountAuth) { self.value = value }
    func blockSecondCapture() { remaining = 2 }
    func capture() async -> CapturedDurableAccountAuth? {
        if let count = remaining {
            remaining = count - 1
            if count == 1 {
                remaining = nil
                observer?.resume()
                observer = nil
                await withCheckedContinuation { blocked = $0 }
            }
        }
        return value
    }
    func waitUntilBlocked() async {
        if blocked != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
}

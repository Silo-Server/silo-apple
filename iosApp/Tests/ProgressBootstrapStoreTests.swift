import Foundation
import XCTest
@testable import Silo

final class ProgressBootstrapStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var scope: ProgressBootstrapStoreScope {
        ProgressBootstrapStoreScope(serverID: "server", origin: "https://storage.example", installationID: "installation",
            accountID: "12", profileID: "profile", authorityID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
    }
    private func destination() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("bootstrap-v2.json")
    }
    private func event(_ item: String = "pending", id: UUID = UUID(), attempts: Int = 3) -> QueuedProgress {
        QueuedProgress(id: id, mediaItemId: item, position: 20, duration: 100, updatedAt: now, attempts: attempts)
    }
    private func legacy(_ events: [QueuedProgress] = []) -> DownloadStoreFile {
        var file = DownloadStoreFile.empty
        file.progressQueue = events
        file.progressCursor = "legacy-delta-cursor"
        file.localProgress = ["old": LocalProgressEntry(position: 99, duration: 100, completed: true, updatedAt: now)]
        for event in events {
            file.localProgress[event.mediaItemId] = LocalProgressEntry(position: event.position, duration: event.duration,
                completed: true, updatedAt: event.updatedAt)
        }
        return file
    }
    private func intent(id: UUID = UUID()) -> StoredProgressIntent {
        StoredProgressIntent(requestID: id, limit: 2, generation: "generation", createdAt: now, maxItems: 10, maxBytes: 10000)
    }
    private func page(items: [String], total: Int, next: String? = nil) -> APIv2ProgressSnapshotResult {
        let value = APIv2ProgressSnapshot(snapshotId: "22222222-2222-4222-8222-222222222222", installationId: "installation",
            accountId: "12", profileId: "profile", generation: "generation", mode: "full_replace",
            capturedAt: now.addingTimeInterval(1), expiresAt: now.addingTimeInterval(3600), itemCount: total,
            items: items.map { APIv2ProgressEntry(mediaItemId: $0, positionSeconds: 0, durationSeconds: 0,
                completed: false, updatedAt: now.addingTimeInterval(1)) },
            page: APIv2Page(nextCursor: next, hasMore: next != nil), complete: next == nil,
            completionToken: next == nil ? "receipt" : nil)
        let account = RefreshAccountIdentity(serverId: "server", serverURL: "https://storage.example", credentialGenerationID: UUID())
        let wireIntent = APIv2ProgressSnapshotIntent(requestId: UUID(), limit: 2,
            identity: HTTPRequestIdentity(serverId: "server", serverURL: account.serverURL, profileId: "profile",
                clientFamily: AppleDeviceIdentity.current.clientFamily), account: account)
        return APIv2ProgressSnapshotResult(value: value, location: "/api/v2/sync/progress/snapshots/\(value.snapshotId)",
            continuation: next.map { APIv2ProgressSnapshotCursor(token: $0, snapshot: value, intent: wireIntent, seenCursors: [$0], seenItems: Set(items)) },
            receipt: next == nil ? APIv2ProgressCompletionReceipt(token: "receipt") : nil)
    }

    func testMigrationPreservesQueueAndLegacySourceBytes() async throws {
        let url = try destination()
        let rows = [event("first"), event("second", attempts: 7)]
        let original = legacy(rows)
        let bytes = try JSONEncoder().encode(original)
        let source = url.deletingLastPathComponent().appendingPathComponent("legacy.json")
        try bytes.write(to: source)
        let store = ProgressBootstrapStore(url: url, scope: scope)
        let migrated = try await store.migrate(legacyData: Data(contentsOf: source))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(migrated.downloads.progressQueue.map(\.id), rows.map(\.id))
        XCTAssertEqual(migrated.downloads.progressQueue.map(\.attempts), [3, 7])
        XCTAssertEqual(migrated.downloads.progressQueue.map(\.updatedAt), rows.map(\.updatedAt))
        XCTAssertEqual(migrated.pending[rows[0].id]?.completed, true)
        XCTAssertTrue(migrated.serverProgress.isEmpty)
        XCTAssertEqual(migrated.visibleProgress["old"]?.completed, true)
        let reopened = try await ProgressBootstrapStore(url: url, scope: scope).read()
        XCTAssertEqual(reopened.downloads.progressCursor, "legacy-delta-cursor")
        XCTAssertEqual(reopened.pending, migrated.pending)
    }

    func testCorruptOrFutureMigrationDoesNotCreateDestination() async throws {
        let url = try destination()
        let store = ProgressBootstrapStore(url: url, scope: scope)
        do { _ = try await store.migrate(legacyData: Data("broken".utf8)); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        var future = legacy(); future.version = 99
        do { _ = try await store.migrate(legacyData: JSONEncoder().encode(future)); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testIntentAndStagedCursorSurviveRestartWithoutPublishing() async throws {
        let url = try destination()
        let store = ProgressBootstrapStore(url: url, scope: scope)
        _ = try await store.migrate(legacyData: JSONEncoder().encode(legacy()))
        let request = intent()
        _ = try await store.begin(request)
        _ = try await store.stage(page(items: ["one"], total: 2, next: "opaque-cursor"), requestID: request.requestID, now: now)
        let restarted = ProgressBootstrapStore(url: url, scope: scope)
        let staged = try await restarted.read()
        XCTAssertEqual(staged.intent, request)
        XCTAssertEqual(staged.staging?.nextCursor, "opaque-cursor")
        XCTAssertNotNil(staged.visibleProgress["old"])
        XCTAssertNil(staged.visibleProgress["one"])
        _ = try await restarted.stage(page(items: ["two"], total: 2), requestID: request.requestID, now: now)
        let committed = try await restarted.apply(requestID: request.requestID, now: now)
        XCTAssertNil(committed.visibleProgress["old"])
        XCTAssertEqual(Set(committed.serverProgress.keys), ["one", "two"])
        XCTAssertNil(committed.downloads.progressCursor)
        do { _ = try await restarted.apply(requestID: request.requestID, now: now); XCTFail() } catch {}
        do { _ = try await restarted.begin(request); XCTFail("Retired UUID reused") } catch {}
    }

    func testReplacementClearsFalseZeroAndRetainsAllPendingRows() async throws {
        let url = try destination()
        let row = event()
        let store = ProgressBootstrapStore(url: url, scope: scope)
        _ = try await store.migrate(legacyData: JSONEncoder().encode(legacy([row])))
        let request = intent()
        _ = try await store.begin(request)
        _ = try await store.stage(page(items: ["old"], total: 1), requestID: request.requestID, now: now)
        let newer = event("new-local", attempts: 0)
        _ = try await store.record(newer, completed: false)
        let result = try await store.apply(requestID: request.requestID, now: now)
        XCTAssertEqual(result.serverProgress["old"]?.completed, false)
        XCTAssertEqual(result.serverProgress["old"]?.position, 0)
        XCTAssertEqual(result.serverProgress["old"]?.duration, 0)
        XCTAssertEqual(result.downloads.progressQueue.map(\.id), [row.id, newer.id])
        XCTAssertEqual(result.downloads.progressQueue.map(\.attempts), [3, 0])
        XCTAssertEqual(result.visibleProgress["pending"]?.completed, true)
        let emptyIntent = intent()
        _ = try await store.begin(emptyIntent)
        _ = try await store.stage(page(items: [], total: 0), requestID: emptyIntent.requestID, now: now)
        let empty = try await store.apply(requestID: emptyIntent.requestID, now: now)
        XCTAssertTrue(empty.serverProgress.isEmpty)
        XCTAssertNil(empty.visibleProgress["old"])
        XCTAssertEqual(empty.downloads.progressQueue.map(\.id), [row.id, newer.id])
    }

    func testUploadClaimExcludesBootstrapAndExactAckPreservesNewEvent() async throws {
        let url = try destination()
        let old = event()
        let store = ProgressBootstrapStore(url: url, scope: scope)
        _ = try await store.migrate(legacyData: JSONEncoder().encode(legacy([old])))
        let upload = try await store.claimUpload()
        do { _ = try await store.begin(intent()); XCTFail() } catch {}
        let newer = event(attempts: 0)
        _ = try await store.record(newer, completed: false)
        let result = try await store.acknowledge(uploadID: upload.id, succeeded: [old.id], maxRetries: 5)
        XCTAssertEqual(result.downloads.progressQueue.map(\.id), [newer.id])
        XCTAssertEqual(result.downloads.progressQueue[0].attempts, 0)
        do { _ = try await store.acknowledge(uploadID: upload.id, succeeded: [old.id], maxRetries: 5); XCTFail() } catch {}
        let request = intent()
        _ = try await store.begin(request)
        do { _ = try await store.claimUpload(); XCTFail() } catch {}
    }

    func testWriteFailureLeavesMemoryAndDiskUnchanged() async throws {
        let url = try destination()
        let failing = FailingProgressWriter()
        let store = ProgressBootstrapStore(url: url, scope: scope, write: failing.write)
        _ = try await store.migrate(legacyData: JSONEncoder().encode(legacy()))
        let request = intent()
        _ = try await store.begin(request)
        _ = try await store.stage(page(items: [], total: 0), requestID: request.requestID, now: now)
        let bytes = try Data(contentsOf: url)
        let before = try await store.read()
        failing.failNext()
        do { _ = try await store.apply(requestID: request.requestID, now: now); XCTFail() } catch {}
        let after = try await store.read()
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.visibleProgress, before.visibleProgress)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNotNil(after.intent)
        _ = try await store.apply(requestID: request.requestID, now: now)
        let reopened = try await ProgressBootstrapStore(url: url, scope: scope).read()
        XCTAssertTrue(reopened.visibleProgress.isEmpty)
    }

    func testSupersededWriterCannotOverwriteNewerDurableRevision() async throws {
        let url = try destination()
        let oldOwner = ProgressBootstrapStore(url: url, scope: scope)
        _ = try await oldOwner.migrate(legacyData: JSONEncoder().encode(legacy()))
        let newOwner = ProgressBootstrapStore(url: url, scope: scope)
        let row = event()
        _ = try await newOwner.record(row, completed: false)
        do { _ = try await oldOwner.record(event("late"), completed: true); XCTFail("Old whole-state writer won") } catch {}
        let reopened = try await ProgressBootstrapStore(url: url, scope: scope).read()
        XCTAssertEqual(reopened.downloads.progressQueue.map(\.id), [row.id])
    }

    func testFailedAckDoesNotSpendRetryBudgetOrLoseDurableClaim() async throws {
        let url = try destination()
        let failing = FailingProgressWriter()
        let store = ProgressBootstrapStore(url: url, scope: scope, write: failing.write)
        let row = event(attempts: 2)
        _ = try await store.migrate(legacyData: JSONEncoder().encode(legacy([row])))
        let upload = try await store.claimUpload()
        failing.failNext()
        do { _ = try await store.acknowledge(uploadID: upload.id, succeeded: [], maxRetries: 5); XCTFail() } catch {}
        let restarted = ProgressBootstrapStore(url: url, scope: scope)
        let retained = try await restarted.read()
        XCTAssertEqual(retained.upload?.id, upload.id)
        XCTAssertEqual(retained.downloads.progressQueue[0].attempts, 2)
        let acknowledged = try await restarted.acknowledge(uploadID: upload.id, succeeded: [], maxRetries: 5)
        XCTAssertEqual(acknowledged.downloads.progressQueue[0].attempts, 3)
        XCTAssertNil(acknowledged.upload)
    }

    func testWrongAuthorityAndExpiredOrAbandonedStageCannotApply() async throws {
        let url = try destination()
        let store = ProgressBootstrapStore(url: url, scope: scope)
        _ = try await store.migrate(legacyData: JSONEncoder().encode(legacy()))
        let foreign = ProgressBootstrapStoreScope(serverID: scope.serverID, origin: scope.origin, installationID: scope.installationID,
            accountID: scope.accountID, profileID: scope.profileID, authorityID: UUID())
        do { _ = try await ProgressBootstrapStore(url: url, scope: foreign).read(); XCTFail() } catch {}
        let request = intent()
        _ = try await store.begin(request)
        _ = try await store.stage(page(items: [], total: 0), requestID: request.requestID, now: now)
        do { _ = try await store.apply(requestID: request.requestID, now: now.addingTimeInterval(4000)); XCTFail() } catch {}
        _ = try await store.abandon(requestID: request.requestID)
        do { _ = try await store.apply(requestID: request.requestID, now: now); XCTFail() } catch {}
    }
}

private final class FailingProgressWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false
    func failNext() { lock.withLock { shouldFail = true } }
    func write(_ data: Data, _ url: URL) throws {
        if lock.withLock({ let result = shouldFail; shouldFail = false; return result }) { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
    }
}

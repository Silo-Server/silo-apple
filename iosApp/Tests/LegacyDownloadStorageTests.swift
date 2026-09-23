import XCTest
import Foundation
@testable import Silo

/// Covers the one-shot removal of downloads saved by earlier versions and
/// the store's refusal to overwrite a file it could not load.
final class LegacyDownloadStorageTests: XCTestCase {
    private var sandbox: URL!
    private var root: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyDownloadStorageTests-\(UUID().uuidString)", isDirectory: true)
        root = sandbox.appendingPathComponent("SiloDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Undo any permission changes so the sandbox can be deleted.
        if let enumerator = FileManager.default.enumerator(at: sandbox, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - Removal

    func testRemovalDeletesEveryLegacyFileAndRunsOnce() async throws {
        let scope = try writeScope(server: "server", profile: "profile", storeJSON: #"{"records":{"d1":{}}}"#)
        let download = scope.appendingPathComponent("d1", isDirectory: true)
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: download.appendingPathComponent("media.mp4"))
        try Data("resume".utf8).write(to: download.appendingPathComponent("resume.bin"))
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("staged".utf8).write(to: staging.appendingPathComponent("task-7.bin"))

        let store = makeStore()
        let initialState = await store.legacyStorageState()
        XCTAssertEqual(initialState, .removalNeeded)
        let hadDownloads = await store.removeLegacyStorage()
        XCTAssertTrue(hadDownloads)

        XCTAssertEqual(try contents(of: root), [LegacyDownloadStorage.markerFileName])
        XCTAssertEqual(try contents(of: sandbox), ["SiloDownloads"], "the moved-aside tree is deleted")
        let stateAfterRemoval = await store.legacyStorageState()
        XCTAssertEqual(stateAfterRemoval, .removed(noticePending: true))

        // A download saved after the removal must survive every later launch.
        let fresh = makeStore()
        var file = DownloadStoreFile.empty
        file.progressCursor = "after-upgrade"
        await fresh.save(file, serverId: "server", profileId: "profile")
        let stateOnRelaunch = await fresh.legacyStorageState()
        XCTAssertEqual(stateOnRelaunch, .removed(noticePending: true))
        let reloaded = await fresh.load(serverId: "server", profileId: "profile")
        XCTAssertEqual(reloaded.progressCursor, "after-upgrade")
    }

    func testRemovalWithoutDownloadsNeedsNoNotice() throws {
        // Every signed-in launch leaves an empty scope or a capability-only
        // store behind; neither is a download the user would miss.
        _ = try writeScope(server: "server", profile: "a", storeJSON: #"{"records":{},"capability":{}}"#)
        let emptyScope = root.appendingPathComponent("server/b", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyScope, withIntermediateDirectories: true)

        let legacy = LegacyDownloadStorage(root: root)
        XCTAssertFalse(try legacy.remove())
        XCTAssertEqual(legacy.state(), .removed(noticePending: false))
    }

    func testFreshInstallRecordsTheMarkerWithoutANotice() throws {
        try FileManager.default.removeItem(at: root)
        let legacy = LegacyDownloadStorage(root: root)
        XCTAssertEqual(legacy.state(), .removalNeeded)
        XCTAssertFalse(try legacy.remove())
        XCTAssertEqual(legacy.state(), .removed(noticePending: false))
    }

    func testInterruptedRemovalKeepsTheNoticeAndFinishesTheDelete() throws {
        // A run that moved the tree aside but died before writing its marker.
        let aside = sandbox.appendingPathComponent("SiloDownloads.removed-\(UUID().uuidString)", isDirectory: true)
        let scope = aside.appendingPathComponent("server/profile", isDirectory: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try Data(#"{"records":{"d1":{}}}"#.utf8).write(to: scope.appendingPathComponent("store.json"))
        try FileManager.default.removeItem(at: root)

        let legacy = LegacyDownloadStorage(root: root)
        XCTAssertTrue(try legacy.remove())
        XCTAssertEqual(try contents(of: sandbox), ["SiloDownloads"])
        XCTAssertEqual(legacy.state(), .removed(noticePending: true))
    }

    func testAcknowledgedNoticeStaysDismissed() async throws {
        _ = try writeScope(server: "server", profile: "profile", storeJSON: #"{"records":{"d1":{}}}"#)
        let store = makeStore()
        let hadDownloads = await store.removeLegacyStorage()
        XCTAssertTrue(hadDownloads)

        await store.acknowledgeLegacyRemovalNotice()

        let relaunched = makeStore()
        let state = await relaunched.legacyStorageState()
        XCTAssertEqual(state, .removed(noticePending: false))
    }

    func testRemovalDateSurvivesTheNoticeAcknowledgement() throws {
        _ = try writeScope(server: "server", profile: "profile", storeJSON: #"{"records":{"d1":{}}}"#)
        let removedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let legacy = LegacyDownloadStorage(root: root)
        XCTAssertNil(legacy.removalDate())

        XCTAssertTrue(try legacy.remove(at: removedAt))
        legacy.acknowledgeNotice()

        XCTAssertEqual(legacy.state(), .removed(noticePending: false))
        XCTAssertEqual(legacy.removalDate(), removedAt)
    }

    // MARK: - Server rows

    func testReconcileDropsServerRowsRegisteredBeforeTheRemoval() throws {
        // The server keeps listing what earlier versions registered for this
        // device, in every state those versions left behind.
        let rows = try decodeRows("""
        [
          {"id": "old-completed", "content_id": "m1", "status": "completed", "created_at": "2026-09-01T10:00:00Z"},
          {"id": "old-downloading", "content_id": "m2", "status": "downloading", "created_at": "2026-09-01T10:00:00Z"},
          {"id": "old-ready", "content_id": "m3", "status": "ready", "created_at": "2026-09-01T10:00:00Z"},
          {"id": "old-preparing", "content_id": "m4", "status": "preparing", "created_at": "2026-09-01T10:00:00Z"},
          {"id": "new-ready", "content_id": "m5", "status": "ready", "created_at": "2026-09-23T10:00:01Z"}
        ]
        """)
        let removedAt = ISO8601DateFormatter().date(from: "2026-09-23T10:00:00Z")!

        let split = DownloadManager.partitionUnknownRows(rows, legacyRemovalDate: removedAt)

        XCTAssertEqual(split.legacy.map(\.id), ["old-completed", "old-downloading", "old-ready", "old-preparing"])
        XCTAssertEqual(split.imported.map(\.id), ["new-ready"])
    }

    func testReconcileImportsEveryRowWhenNoRemovalDateIsKnown() throws {
        let rows = try decodeRows("""
        [{"id": "d1", "content_id": "m1", "status": "ready", "created_at": "2026-09-01T10:00:00Z"}]
        """)
        let split = DownloadManager.partitionUnknownRows(rows, legacyRemovalDate: nil)
        XCTAssertEqual(split.imported.map(\.id), ["d1"])
        XCTAssertTrue(split.legacy.isEmpty)
    }

    func testImportedRowsInDeviceReportedStatesCanStillDownload() {
        // A row this device reported as downloading or completed, but whose
        // local record is gone, must not sit in `.registering`: nothing
        // moves a record out of that state.
        XCTAssertEqual(DownloadManager.mapInitialStatus("completed"), .queued)
        XCTAssertEqual(DownloadManager.mapInitialStatus("downloading"), .queued)
        XCTAssertEqual(DownloadManager.mapInitialStatus("ready"), .queued)
        XCTAssertEqual(DownloadManager.mapInitialStatus("preparing"), .preparing)
    }

    // MARK: - Store load

    func testUndecodableStoreIsQuarantinedInsteadOfOverwritten() async throws {
        let garbage = Data("{\"version\": \"not a number\"".utf8)
        let scope = try writeScope(server: "server", profile: "profile", storeJSON: nil)
        let storeURL = scope.appendingPathComponent(DownloadFilePaths.storeFileName)
        try garbage.write(to: storeURL)
        let store = makeStore()

        let loaded = await store.load(serverId: "server", profileId: "profile")
        XCTAssertTrue(loaded.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))
        let quarantined = try contents(of: scope).filter { $0.hasPrefix("store.json.corrupt-") }
        XCTAssertEqual(quarantined.count, 1)
        let quarantinedURL = scope.appendingPathComponent(quarantined[0])
        XCTAssertEqual(try Data(contentsOf: quarantinedURL), garbage)

        // The empty registry now saves normally and leaves the original alone.
        var file = DownloadStoreFile.empty
        file.progressCursor = "new"
        await store.save(file, serverId: "server", profileId: "profile")
        let cursor = await store.load(serverId: "server", profileId: "profile").progressCursor
        XCTAssertEqual(cursor, "new")
        XCTAssertEqual(try Data(contentsOf: quarantinedURL), garbage)
    }

    func testStoreThatCannotBeQuarantinedIsNeverSaved() async throws {
        let garbage = Data("not json".utf8)
        let scope = try writeScope(server: "server", profile: "profile", storeJSON: nil)
        let storeURL = scope.appendingPathComponent(DownloadFilePaths.storeFileName)
        try garbage.write(to: storeURL)
        // A read-only scope directory makes the rename fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scope.path)
        let store = makeStore()

        let loaded = await store.load(serverId: "server", profileId: "profile")
        XCTAssertTrue(loaded.records.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scope.path)

        await store.save(.empty, serverId: "server", profileId: "profile")
        XCTAssertEqual(try Data(contentsOf: storeURL), garbage)
    }

    // MARK: - Helpers

    private func decodeRows(_ json: String) throws -> [ServerDownloadRow] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ServerDownloadRow].self, from: Data(json.utf8))
    }

    private func makeStore() -> DownloadStore {
        let root: URL = self.root
        return DownloadStore(rootDirectory: { root })
    }

    @discardableResult
    private func writeScope(server: String, profile: String, storeJSON: String?) throws -> URL {
        let scope = root
            .appendingPathComponent(server, isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        if let storeJSON {
            try Data(storeJSON.utf8).write(to: scope.appendingPathComponent(DownloadFilePaths.storeFileName))
        }
        return scope
    }

    private func contents(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}

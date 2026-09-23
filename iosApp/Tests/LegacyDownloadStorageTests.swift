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
        let removal = await store.removeLegacyStorage()
        XCTAssertEqual(removal, LegacyDownloadStorage.Removal(hadDownloads: true, completed: true))

        XCTAssertEqual(try contents(of: root), [LegacyDownloadStorage.markerFileName, "server"])
        XCTAssertEqual(try contents(of: scope), [DownloadFilePaths.storeFileName], "only a fresh store is left")
        XCTAssertEqual(try contents(of: sandbox), ["SiloDownloads"], "the moved-aside tree is deleted")
        let carried = await store.load(serverId: "server", profileId: "profile")
        XCTAssertTrue(carried.records.isEmpty)
        XCTAssertEqual(carried.legacyRowsPending, true, "the scope's first registry read deletes the old rows")
        XCTAssertEqual(carried.legacyMonitorsPending, true, "the scope's first monitor list sets the old monitors aside")
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
        XCTAssertEqual(legacy.remove(), LegacyDownloadStorage.Removal(hadDownloads: false, completed: true))
        XCTAssertEqual(legacy.state(), .removed(noticePending: false))
    }

    func testFreshInstallRecordsTheMarkerWithoutANotice() throws {
        try FileManager.default.removeItem(at: root)
        let legacy = LegacyDownloadStorage(root: root)
        XCTAssertEqual(legacy.state(), .removalNeeded)
        XCTAssertEqual(legacy.remove(), LegacyDownloadStorage.Removal(hadDownloads: false, completed: true))
        XCTAssertEqual(legacy.state(), .removed(noticePending: false))
    }

    func testMissingMarkerWithNothingOnDiskFlagsNoScope() async throws {
        // A reinstall or a restore to a new device: the marker went with the
        // downloads root, but the device id (and the rows and monitors this
        // version registered under it) survived. Nothing on disk is an
        // earlier version's, so nothing on the server may be judged legacy.
        let store = makeStore()
        let removal = await store.removeLegacyStorage()
        XCTAssertEqual(removal, LegacyDownloadStorage.Removal(hadDownloads: false, completed: true))
        XCTAssertEqual(try contents(of: root), [LegacyDownloadStorage.markerFileName])
        let loaded = await store.load(serverId: "server", profileId: "profile")
        XCTAssertNil(loaded.legacyRowsPending)
    }

    // MARK: - Queued offline progress

    func testQueuedProgressSurvivesTheRemoval() async throws {
        // A main-era store: no `state` on queue entries, dates as the default
        // JSONEncoder wrote them (seconds since 2001-01-01).
        let scope = try writeScope(server: "server", profile: "profile", storeJSON: """
        {"version":1,"records":{"d1":{}},"subscriptions":[],"localProgress":{},"progressQueue":[
          {"id":"6F1C0E1A-2B0F-4C38-9D4E-2C0B7B9A0001","mediaItemId":"episode-1","position":120.5,"duration":1500,"updatedAt":780000000,"attempts":2},
          {"id":"6F1C0E1A-2B0F-4C38-9D4E-2C0B7B9A0002","mediaItemId":"episode-1","position":900,"duration":1500,"updatedAt":780000600,"attempts":0},
          {"id":"6F1C0E1A-2B0F-4C38-9D4E-2C0B7B9A0003","mediaItemId":"movie-9","position":42,"duration":6000,"updatedAt":780000300,"attempts":0},
          {"id":"not-a-uuid","mediaItemId":"movie-10","position":1,"duration":2,"updatedAt":780000000}
        ]}
        """)
        try FileManager.default.createDirectory(
            at: scope.appendingPathComponent("d1", isDirectory: true), withIntermediateDirectories: true
        )
        let store = makeStore()

        let removal = await store.removeLegacyStorage()
        XCTAssertTrue(removal.completed)

        let loaded = await store.load(serverId: "server", profileId: "profile")
        XCTAssertTrue(loaded.records.isEmpty)
        let queue = loaded.progressQueue.sorted { $0.mediaItemId < $1.mediaItemId }
        XCTAssertEqual(queue.map(\.mediaItemId), ["episode-1", "movie-9"], "newest entry per item; the unreadable one is dropped")
        XCTAssertEqual(queue.map(\.position), [900, 42])
        XCTAssertEqual(queue.first?.id.uuidString, "6F1C0E1A-2B0F-4C38-9D4E-2C0B7B9A0002")
        XCTAssertEqual(queue.first?.updatedAt, Date(timeIntervalSinceReferenceDate: 780_000_600))
        XCTAssertEqual(queue.map(\.state), [.pending, .pending], "a main-era entry was never claimed for a v2 upload")
    }

    func testQueuedProgressWithoutDownloadsSurvivesWithoutANotice() async throws {
        _ = try writeScope(server: "server", profile: "profile", storeJSON: """
        {"records":{},"progressQueue":[
          {"id":"6F1C0E1A-2B0F-4C38-9D4E-2C0B7B9A0004","mediaItemId":"movie-1","position":30,"duration":600,"updatedAt":780000000,"attempts":0}
        ]}
        """)
        let store = makeStore()

        let removal = await store.removeLegacyStorage()
        XCTAssertEqual(removal, LegacyDownloadStorage.Removal(hadDownloads: false, completed: true))
        let state = await store.legacyStorageState()
        XCTAssertEqual(state, .removed(noticePending: false))
        let loaded = await store.load(serverId: "server", profileId: "profile")
        XCTAssertEqual(loaded.progressQueue.map(\.mediaItemId), ["movie-1"])
    }

    func testUndecodableStoreStillGivesUpItsQueue() async throws {
        // `records` in a shape this version can't decode must not block the
        // harvest.
        _ = try writeScope(server: "server", profile: "profile", storeJSON: """
        {"version":"x","records":[1,2],"progressQueue":[
          {"id":"6F1C0E1A-2B0F-4C38-9D4E-2C0B7B9A0005","mediaItemId":"movie-2","position":5,"duration":60,"updatedAt":780000000}
        ]}
        """)
        let store = makeStore()
        _ = await store.removeLegacyStorage()
        let loaded = await store.load(serverId: "server", profileId: "profile")
        XCTAssertEqual(loaded.progressQueue.map(\.mediaItemId), ["movie-2"])
    }

    func testFailedMarkerWriteStillFreesTheOldTreeAndReportsIncomplete() async throws {
        // An earlier-version scope directory named like the marker makes the
        // carried store occupy the marker path, so the marker write fails
        // after the move, the way a full disk would.
        _ = try writeScope(server: LegacyDownloadStorage.markerFileName, profile: "profile", storeJSON: """
        {"records":{"d1":{}},"progressQueue":[
          {"id":"6F1C0E1A-2B0F-4C38-9D4E-2C0B7B9A0006","mediaItemId":"movie-3","position":5,"duration":60,"updatedAt":780000000}
        ]}
        """)
        let store = makeStore()

        let removal = await store.removeLegacyStorage()

        XCTAssertEqual(removal, LegacyDownloadStorage.Removal(hadDownloads: true, completed: false))
        XCTAssertEqual(try contents(of: sandbox), ["SiloDownloads"], "the moved-aside tree is deleted anyway")
        let loaded = await store.load(serverId: LegacyDownloadStorage.markerFileName, profileId: "profile")
        XCTAssertEqual(loaded.progressQueue.map(\.mediaItemId), ["movie-3"], "the queue survives in the new root")
    }

    func testInterruptedRemovalKeepsTheNoticeAndFinishesTheDelete() throws {
        // A run that moved the tree aside but died before writing its marker.
        let aside = sandbox.appendingPathComponent("SiloDownloads.removed-\(UUID().uuidString)", isDirectory: true)
        let scope = aside.appendingPathComponent("server/profile", isDirectory: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try Data(#"{"records":{"d1":{}}}"#.utf8).write(to: scope.appendingPathComponent("store.json"))
        try FileManager.default.removeItem(at: root)

        let legacy = LegacyDownloadStorage(root: root)
        XCTAssertEqual(legacy.remove(), LegacyDownloadStorage.Removal(hadDownloads: true, completed: true))
        XCTAssertEqual(try contents(of: sandbox), ["SiloDownloads"])
        XCTAssertEqual(legacy.state(), .removed(noticePending: true))
    }

    func testAcknowledgedNoticeStaysDismissed() async throws {
        _ = try writeScope(server: "server", profile: "profile", storeJSON: #"{"records":{"d1":{}}}"#)
        let store = makeStore()
        let removal = await store.removeLegacyStorage()
        XCTAssertTrue(removal.hadDownloads)

        await store.acknowledgeLegacyRemovalNotice()

        let relaunched = makeStore()
        let state = await relaunched.legacyStorageState()
        XCTAssertEqual(state, .removed(noticePending: false))
    }

    // MARK: - Server rows

    func testFirstReadOfACarriedScopeDropsEveryUnknownRow() throws {
        // The server keeps listing what earlier versions registered for this
        // device, in every state those versions left behind. Timestamps don't
        // matter: a device clock ahead of or behind the server's must not
        // change the answer.
        let rows = try decodeRows("""
        [
          {"id": "old-completed", "content_id": "m1", "status": "completed", "created_at": "2026-09-01T10:00:00Z"},
          {"id": "old-downloading", "content_id": "m2", "status": "downloading", "created_at": "2026-09-01T10:00:00Z"},
          {"id": "old-ready", "content_id": "m3", "status": "ready", "created_at": "2099-01-01T10:00:00Z"},
          {"id": "old-preparing", "content_id": "m4", "status": "preparing", "created_at": "2026-09-23T10:00:01Z"}
        ]
        """)

        let split = DownloadManager.partitionUnknownRows(rows, legacyRowsPending: true)

        XCTAssertEqual(split.legacy.map(\.id), ["old-completed", "old-downloading", "old-ready", "old-preparing"])
        XCTAssertTrue(split.imported.isEmpty)
    }

    func testLaterReadsImportEveryUnknownRow() throws {
        // After the first complete read, or in a scope no earlier version
        // wrote (a reinstall), a row created long ago is still this version's.
        let rows = try decodeRows("""
        [{"id": "d1", "content_id": "m1", "status": "ready", "created_at": "2020-09-01T10:00:00Z"}]
        """)
        let split = DownloadManager.partitionUnknownRows(rows, legacyRowsPending: false)
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

    /// Registry entries from the fields a test cares about; the other
    /// required `DownloadEntry` fields get fixed values.
    private func decodeRows(_ json: String) throws -> [APIv2DownloadEntry] {
        let partial = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let defaults: [String: Any] = [
            "media_file_id": "1", "file_size": 1, "bytes_sent": 0, "kind": "queued", "quality": "original",
            "effective_quality": "original", "delivery_format": "original", "target_bitrate_kbps": 0,
            "revision": 1, "device_id": "device",
        ]
        let full = partial.map { defaults.merging($0) { _, row in row } }
        let data = try JSONSerialization.data(withJSONObject: full)
        return try HTTPClient.makeJSONDecoder().decode([APIv2DownloadEntry].self, from: data)
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

import XCTest
import Foundation
@testable import Silo

/// Covers reclaiming download storage no store tracks: when a store load
/// allows the sweep, which directories in the loaded scope it removes, and
/// how the data outside the active scope is grouped and removed.
final class DownloadStorageReclaimTests: XCTestCase {
    private static let account = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    private var sandbox: URL!
    private var root: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadStorageReclaimTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Store load outcome

    func testOnlyAnUnreadableStoreKeepsTheSweepOff() async throws {
        let root: URL = self.root
        let store = DownloadStore(rootDirectory: { root })

        let missing = await store.loadScope(serverId: "server", localAccountId: Self.account, profileId: "missing")
        XCTAssertEqual(missing.outcome, .missing)
        XCTAssertTrue(missing.tracksScopeStorage, "nothing can read a missing store's directories again")

        try writeStore(profile: "loaded", contents: Data(#"{"version":1,"records":{},"subscriptions":[],"progressQueue":[],"localProgress":{}}"#.utf8))
        let loaded = await store.loadScope(serverId: "server", localAccountId: Self.account, profileId: "loaded")
        XCTAssertEqual(loaded.outcome, .loaded)
        XCTAssertTrue(loaded.tracksScopeStorage)

        try writeStore(profile: "corrupt", contents: Data("not json".utf8))
        let quarantined = await store.loadScope(serverId: "server", localAccountId: Self.account, profileId: "corrupt")
        XCTAssertEqual(quarantined.outcome, .quarantined)
        XCTAssertTrue(quarantined.tracksScopeStorage, "nothing reads a quarantined store again")

        // Present but unreadable, as before first unlock.
        let locked = try writeStore(profile: "locked", contents: Data("{}".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let unreadable = await store.loadScope(serverId: "server", localAccountId: Self.account, profileId: "locked")
        XCTAssertEqual(unreadable.outcome, .unreadable)
        XCTAssertFalse(unreadable.tracksScopeStorage, "the store may still own every directory")

        // Undecodable and stuck in place.
        let stuck = try writeStore(profile: "stuck", contents: Data("not json".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stuck.deletingLastPathComponent().path)
        let unmovable = await store.loadScope(serverId: "server", localAccountId: Self.account, profileId: "stuck")
        XCTAssertEqual(unmovable.outcome, .unreadable)
        XCTAssertFalse(unmovable.tracksScopeStorage)
    }

    func testAnUnreadableRecordCostsOnlyItsOwnDirectory() async throws {
        let root: URL = self.root
        let store = DownloadStore(rootDirectory: { root })
        // Three finished downloads. The middle one has a status this build
        // does not know, as a newer build may have saved it.
        var file = DownloadStoreFile.empty
        for id in ["first", "newer", "last"] { file.records[id] = record(id: id) }
        let original = try storeJSON(file) { json in
            var records = try XCTUnwrap(json["records"] as? [String: [String: Any]])
            records["newer"]?["localStatus"] = "a-status-from-a-newer-build"
            json["records"] = records
        }
        let scope = try writeStore(profile: "profile", contents: original).deletingLastPathComponent()
        for id in file.records.keys {
            let directory = scope.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(count: 4).write(to: directory.appendingPathComponent("media.mp4"))
        }

        let loaded = await store.loadScope(serverId: "server", localAccountId: Self.account, profileId: "profile")

        XCTAssertEqual(loaded.outcome, .loaded)
        XCTAssertEqual(loaded.file.records.keys.sorted(), ["first", "last"])
        let untracked = DownloadStorageReclaim.untrackedDirectories(
            DownloadStorageReclaim.sweepCandidates(inScope: scope),
            recordIds: loaded.file.records.keys
        )
        XCTAssertEqual(untracked, ["newer"], "the sweep takes only the directory of the record that was left out")

        // The original stays beside the store, which was rewritten without
        // the record and now decodes whole.
        let storeURL = scope.appendingPathComponent(DownloadFilePaths.storeFileName)
        let rewritten = try JSONDecoder().decode(DownloadStoreFile.self, from: Data(contentsOf: storeURL))
        XCTAssertEqual(rewritten.records.keys.sorted(), ["first", "last"])
        let aside = try keptOriginals(in: scope)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try aside.first.map { try Data(contentsOf: scope.appendingPathComponent($0)) }, original)

        // A rewrite that did not land leaves the original in place. The
        // next load keeps the one copy instead of adding another.
        try original.write(to: storeURL)
        let retried = await store.loadScope(serverId: "server", localAccountId: Self.account, profileId: "profile")
        XCTAssertEqual(retried.outcome, .loaded)
        XCTAssertEqual(try keptOriginals(in: scope), aside)
    }

    func testUnreadableQueuedProgressAndResumePointsAreLeftOutAlone() async throws {
        let root: URL = self.root
        let store = DownloadStore(rootDirectory: { root })
        let sent = UUID()
        var file = DownloadStoreFile.empty
        file.records["download"] = record(id: "download")
        file.progressQueue = [sent, UUID()].map {
            QueuedProgress(id: $0, mediaItemId: "item", position: 1, duration: 2, updatedAt: Date(timeIntervalSinceReferenceDate: 1_000))
        }
        for id in ["watched", "damaged"] {
            file.localProgress[id] = LocalProgressEntry(
                position: 1, duration: 2, completed: true, updatedAt: Date(timeIntervalSinceReferenceDate: 1_000)
            )
        }
        try writeStore(profile: "profile", contents: storeJSON(file) { json in
            var queue = try XCTUnwrap(json["progressQueue"] as? [[String: Any]])
            queue[1]["state"] = "a-state-from-a-newer-build"
            json["progressQueue"] = queue
            var progress = try XCTUnwrap(json["localProgress"] as? [String: [String: Any]])
            progress["damaged"]?["completed"] = nil
            json["localProgress"] = progress
        })

        let loaded = await store.loadScope(serverId: "server", localAccountId: Self.account, profileId: "profile")

        XCTAssertEqual(loaded.outcome, .loaded)
        XCTAssertEqual(loaded.file.records.keys.sorted(), ["download"])
        XCTAssertEqual(loaded.file.progressQueue.map(\.id), [sent])
        XCTAssertEqual(loaded.file.localProgress.keys.sorted(), ["watched"])
    }

    func testAStoreIsQuarantinedWholeWhereLeavingAnElementOutIsNotSafe() async throws {
        let root: URL = self.root
        let store = DownloadStore(rootDirectory: { root })
        var file = DownloadStoreFile.empty
        file.records["download"] = record(id: "download")
        let unreadableRecord: (inout [String: Any]) throws -> Void = { json in
            var records = try XCTUnwrap(json["records"] as? [String: [String: Any]])
            records["download"]?["localStatus"] = "a-status-from-a-newer-build"
            json["records"] = records
        }

        // A monitor left out would leave its series without a storage limit.
        try writeStore(profile: "monitor", contents: storeJSON(file) { json in
            try unreadableRecord(&json)
            json["subscriptions"] = [["id": "monitor"]]
        })
        let monitor = await store.loadScope(serverId: "server", localAccountId: Self.account, profileId: "monitor")
        XCTAssertEqual(monitor.outcome, .quarantined)

        // An out-of-range number reads as infinite and can't be written back.
        let damaged = try XCTUnwrap(String(data: storeJSON(file, edit: unreadableRecord), encoding: .utf8))
            .replacingOccurrences(of: "\"retryCount\":0", with: "\"retryCount\":-1e999")
        XCTAssertTrue(damaged.contains("-1e999"))
        try writeStore(profile: "damaged", contents: Data(damaged.utf8))
        let infinite = await store.loadScope(serverId: "server", localAccountId: Self.account, profileId: "damaged")
        XCTAssertEqual(infinite.outcome, .quarantined)

        // Its first registry read deletes every server row the store does
        // not know, which would include the row of a record left out.
        file.legacyRowsPending = true
        try writeStore(profile: "legacy", contents: storeJSON(file, edit: unreadableRecord))
        let legacy = await store.loadScope(serverId: "server", localAccountId: Self.account, profileId: "legacy")
        XCTAssertEqual(legacy.outcome, .quarantined)
        XCTAssertNil(legacy.file.legacyRowsPending)
    }

    func testAStoreIsLeftAloneWhenItsOriginalCantBeKept() async throws {
        let root: URL = self.root
        let store = DownloadStore(rootDirectory: { root })
        var file = DownloadStoreFile.empty
        for id in ["first", "newer"] { file.records[id] = record(id: id) }
        let original = try storeJSON(file) { json in
            var records = try XCTUnwrap(json["records"] as? [String: [String: Any]])
            records["newer"]?["localStatus"] = "a-status-from-a-newer-build"
            json["records"] = records
        }
        let url = try writeStore(profile: "profile", contents: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.deletingLastPathComponent().path)

        let loaded = await store.loadScope(serverId: "server", localAccountId: Self.account, profileId: "profile")

        XCTAssertEqual(loaded.outcome, .unreadable)
        XCTAssertFalse(loaded.tracksScopeStorage, "the store on disk still owns every directory")
        // Nothing saves over the store while its original has no copy.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.deletingLastPathComponent().path)
        await store.save(.empty, serverId: "server", localAccountId: Self.account, profileId: "profile")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    // MARK: - Sweep of the loaded scope

    func testSweepSkipsFilesHiddenEntriesAndParkedTransfers() throws {
        let scope = try makeDirectory("server/profile")
        try writeFile("server/profile/owned/media.mp4", bytes: 4)
        try writeFile("server/profile/orphan/media.mp4", bytes: 4)
        _ = try makeDirectory("server/profile/empty")
        try writeFile("server/profile/parked/\(DownloadFilePaths.finishedTransferFilename)", bytes: 4)
        _ = try makeDirectory("server/profile/.hidden")
        try writeFile("server/profile/\(DownloadFilePaths.storeFileName)", bytes: 2)
        try writeFile("server/profile/\(DownloadFilePaths.storeFileName).corrupt-1", bytes: 2)

        let candidates = DownloadStorageReclaim.sweepCandidates(inScope: scope).sorted()

        XCTAssertEqual(candidates, ["empty", "orphan", "owned"], "the settle owns a parked transfer's directory")
    }

    func testEveryRecordKeepsItsDirectory() {
        // Ids are matched by their sanitized directory name. Status plays no
        // part: a record being registered, in a pipeline, or waiting out a
        // retry is in the store, so its directory stays.
        let untracked = DownloadStorageReclaim.untrackedDirectories(
            ["queued", "retrying", "odd_id", "orphan", "leftover"],
            recordIds: ["queued", "retrying", "odd/id", "not-on-disk"]
        )
        XCTAssertEqual(untracked, ["orphan", "leftover"])
    }

    func testSetAsideMovesOutOfTheRootAndDeleteFreesTheBytes() throws {
        let scope = try makeDirectory("server/profile")
        try writeFile("server/profile/orphan/media.mp4", bytes: 10)
        try writeFile("server/profile/orphan/poster.jpg", bytes: 5)
        try writeFile("server/profile/owned/media.mp4", bytes: 7)
        // Left by a process that ended before deleting what it set aside.
        let holding = sandbox.appendingPathComponent("SiloDownloads.reclaimed/earlier", isDirectory: true)
        try FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
        try Data(count: 3).write(to: holding.appendingPathComponent("media.mp4"))

        let moved = DownloadStorageReclaim.setAside([scope.appendingPathComponent("orphan")], root: root)

        XCTAssertEqual(moved, 1)
        let holdingFolder = sandbox.appendingPathComponent("SiloDownloads.reclaimed", isDirectory: true)
        XCTAssertEqual(try holdingFolder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try contents(of: scope), ["owned"])
        XCTAssertEqual(DownloadFilePaths.bytes(under: root), 7, "set-aside data no longer counts as the root's")
        XCTAssertEqual(DownloadStorageReclaim.deleteSetAside(root: root), 18)
        XCTAssertEqual(try contents(of: sandbox), ["SiloDownloads"])
        XCTAssertEqual(DownloadStorageReclaim.deleteSetAside(root: root), 0)
    }

    // MARK: - Storage outside the active scope

    func testOtherStorageGroupsByServerFolderAndLeavesOutTheActiveScope() throws {
        let oldServer = ServerRegistry.serverId(for: "https://old.example.com")
        try writeFile(LegacyDownloadStorage.markerFileName, bytes: 1)
        try writeFile("staging/task-1.bin", bytes: 1000)
        try writeFile("active/profile/d1/media.mp4", bytes: 100)
        try writeFile("active/profile/\(DownloadFilePaths.storeFileName)", bytes: 2)
        try writeFile("active/other-profile/d2/media.mp4", bytes: 50)
        try writeFile("active/acct-1/profile/d3/media.mp4", bytes: 30)
        try writeFile("\(oldServer)/profile/d4/media.mp4", bytes: 200)
        try writeFile("not a server/file.bin", bytes: 5)
        _ = try makeDirectory("empty-server/profile/d5")

        let groups = DownloadStorageReclaim.otherStorage(root: root, activeServerFolder: "active", activeProfileFolder: "profile")

        XCTAssertEqual(groups, [
            .init(folderName: oldServer, serverURL: "https://old.example.com", bytes: 200, isActiveServer: false),
            .init(folderName: "active", serverURL: nil, bytes: 80, isActiveServer: true),
            .init(folderName: "not a server", serverURL: nil, bytes: 5, isActiveServer: false),
        ])
    }

    func testRemovingTheActiveServersGroupKeepsTheActiveScope() throws {
        try writeFile("active/profile/d1/media.mp4", bytes: 100)
        try writeFile("active/other-profile/d2/media.mp4", bytes: 50)
        try writeFile("active/acct-1/profile/d3/media.mp4", bytes: 30)
        try writeFile("old/profile/d4/media.mp4", bytes: 200)

        for folder in ["active", "old"] {
            let targets = DownloadStorageReclaim.removalTargets(
                folderName: folder, root: root, activeServerFolder: "active", activeProfileFolder: "profile"
            )
            DownloadStorageReclaim.setAside(targets, root: root)
        }

        XCTAssertEqual(DownloadStorageReclaim.deleteSetAside(root: root), 280)
        XCTAssertEqual(try contents(of: root), ["active"])
        XCTAssertEqual(try contents(of: root.appendingPathComponent("active")), ["profile"])
        XCTAssertEqual(DownloadFilePaths.bytes(under: root), 100)
        XCTAssertTrue(DownloadStorageReclaim.otherStorage(root: root, activeServerFolder: "active", activeProfileFolder: "profile").isEmpty)
    }

    func testAMissingGroupRemovesNothing() {
        XCTAssertTrue(DownloadStorageReclaim.removalTargets(
            folderName: "gone", root: root, activeServerFolder: "active", activeProfileFolder: "profile"
        ).isEmpty)
    }

    // MARK: - Helpers

    @discardableResult
    private func writeStore(profile: String, contents: Data) throws -> URL {
        let url = DownloadFilePaths.scopePath(serverId: "server", localAccountId: Self.account, profileId: profile, root: root)
            .appendingPathComponent(DownloadFilePaths.storeFileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }

    /// The copies of a store's original kept beside it.
    private func keptOriginals(in scope: URL) throws -> [String] {
        try contents(of: scope).filter { $0.hasPrefix("\(DownloadFilePaths.storeFileName).corrupt-") }
    }

    /// A store as saved, after `edit` changed its JSON the way a version
    /// with other rules, or damage, would have.
    private func storeJSON(_ file: DownloadStoreFile, edit: (inout [String: Any]) throws -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any])
        try edit(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func record(id: String) -> DownloadRecord {
        DownloadRecord(
            id: id, contentId: "content-\(id)", episodeId: nil, batchId: nil, mediaFileId: "0", format: "original",
            serverStatus: "ready", localStatus: .completed, fileSize: 4, bytesDownloaded: 4,
            mediaFilename: "media.mp4", manifestFilename: nil, posterFilename: nil, backdropFilename: nil,
            logoFilename: nil, subtitleFilenames: [:], title: "Title", subtitle: nil, type: "movie",
            seriesId: nil, seriesTitle: nil, posterThumbhash: nil, container: nil, stableIdentity: nil,
            registeredAt: Date(timeIntervalSinceReferenceDate: 1_000), downloadedAt: nil, lastError: nil,
            retryCount: 0, taskIdentifier: nil
        )
    }

    private func makeDirectory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ path: String, bytes: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func contents(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}

import XCTest
import Foundation
@testable import Silo

/// Covers reclaiming download storage no store tracks: when a store load
/// allows the sweep, which directories in the loaded scope it removes, and
/// how the data outside the active scope is grouped and removed.
final class DownloadStorageReclaimTests: XCTestCase {
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

        let missing = await store.loadScope(serverId: "server", profileId: "missing")
        XCTAssertEqual(missing.outcome, .missing)
        XCTAssertTrue(missing.tracksScopeStorage, "nothing can read a missing store's directories again")

        try writeStore(profile: "loaded", contents: Data(#"{"version":1,"records":{},"subscriptions":[],"progressQueue":[],"localProgress":{}}"#.utf8))
        let loaded = await store.loadScope(serverId: "server", profileId: "loaded")
        XCTAssertEqual(loaded.outcome, .loaded)
        XCTAssertTrue(loaded.tracksScopeStorage)

        try writeStore(profile: "corrupt", contents: Data("not json".utf8))
        let quarantined = await store.loadScope(serverId: "server", profileId: "corrupt")
        XCTAssertEqual(quarantined.outcome, .quarantined)
        XCTAssertTrue(quarantined.tracksScopeStorage, "nothing reads a quarantined store again")

        // Present but unreadable, as before first unlock.
        let locked = try writeStore(profile: "locked", contents: Data("{}".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let unreadable = await store.loadScope(serverId: "server", profileId: "locked")
        XCTAssertEqual(unreadable.outcome, .unreadable)
        XCTAssertFalse(unreadable.tracksScopeStorage, "the store may still own every directory")

        // Undecodable and stuck in place.
        let stuck = try writeStore(profile: "stuck", contents: Data("not json".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stuck.deletingLastPathComponent().path)
        let unmovable = await store.loadScope(serverId: "server", profileId: "stuck")
        XCTAssertEqual(unmovable.outcome, .unreadable)
        XCTAssertFalse(unmovable.tracksScopeStorage)
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
        let url = root.appendingPathComponent("server/\(profile)/\(DownloadFilePaths.storeFileName)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
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

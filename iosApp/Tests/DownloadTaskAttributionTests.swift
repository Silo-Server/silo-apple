import Foundation
import XCTest
@testable import Silo

/// Every profile and server shares one background download session. These
/// cover how a transfer's events find the scope that started it, whichever
/// scope is loaded when they arrive.
final class DownloadTaskAttributionTests: XCTestCase {
    private var tempRoot: URL?

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    private func tag(_ serverId: String, _ profileId: String, _ downloadId: String) -> DownloadTaskTag {
        DownloadTaskTag(serverId: serverId, profileId: profileId, downloadId: downloadId)
    }

    private func record(_ id: String, _ status: LocalDownloadStatus, mediaFilename: String? = nil) -> DownloadRecord {
        DownloadRecord(
            id: id,
            contentId: "content-\(id)",
            episodeId: nil,
            batchId: nil,
            mediaFileId: "0",
            format: "original",
            serverStatus: "ready",
            localStatus: status,
            fileSize: 1_000,
            bytesDownloaded: 0,
            mediaFilename: mediaFilename,
            manifestFilename: "manifest.json",
            posterFilename: nil,
            backdropFilename: nil,
            logoFilename: nil,
            subtitleFilenames: [:],
            title: nil,
            subtitle: nil,
            type: "movie",
            seriesId: nil,
            posterThumbhash: nil,
            container: "mp4",
            stableIdentity: nil,
            registeredAt: Date(timeIntervalSince1970: 1_000_000),
            downloadedAt: nil,
            lastError: nil,
            retryCount: 0,
            taskIdentifier: nil
        )
    }

    private func disposition(
        _ tag: DownloadTaskTag?,
        loaded: (String, String),
        record: DownloadRecord?
    ) -> DownloadManager.FinishedTransferDisposition {
        DownloadManager.finishedTransferDisposition(
            tag: tag,
            loadedServerId: loaded.0,
            loadedProfileId: loaded.1,
            record: record
        )
    }

    // MARK: Tag

    func testTagRoundTripsThroughTaskDescription() {
        // Download ids are server-defined text.
        let original = tag("s1", "p1", #"d 1/"x",y"#)
        XCTAssertEqual(DownloadTaskTag(taskDescription: original.taskDescription), original)
        XCTAssertEqual(
            DownloadTaskTag(taskDescription: #"{"v":1,"server":"s1","profile":"p1","download":"d1"}"#),
            tag("s1", "p1", "d1")
        )

        XCTAssertNil(DownloadTaskTag(taskDescription: nil))
        XCTAssertNil(DownloadTaskTag(taskDescription: ""))
        XCTAssertNil(DownloadTaskTag(taskDescription: "not json"))
        XCTAssertNil(DownloadTaskTag(taskDescription: #"{"v":2,"server":"s1","profile":"p1","download":"d1"}"#))
        XCTAssertNil(DownloadTaskTag(taskDescription: #"{"v":1,"server":"s1","profile":"p1","download":""}"#))
    }

    func testUntaggedTaskIsAttributedByItsRequest() {
        let servers = [(id: "s0", url: "https://b.example"), (id: "s1", url: "https://a.example/mount")]
        let fileURL = URL(string: "https://a.example/mount/api/v2/downloads/d1/file")

        XCTAssertEqual(
            DownloadTaskTag.attributing(requestURL: fileURL, profileId: "p1", servers: servers),
            tag("s1", "p1", "d1")
        )
        XCTAssertNil(DownloadTaskTag.attributing(requestURL: fileURL, profileId: nil, servers: servers))
        XCTAssertNil(DownloadTaskTag.attributing(
            requestURL: URL(string: "https://a.example/mount/api/v2/downloads/d1/manifest"),
            profileId: "p1",
            servers: servers
        ))
        XCTAssertNil(DownloadTaskTag.attributing(
            requestURL: URL(string: "https://c.example/api/v2/downloads/d1/file"),
            profileId: "p1",
            servers: servers
        ))
    }

    /// Events carry what the delegate reads off the task: the tag this build
    /// set, or the request an earlier build's untagged task is attributed by.
    func testTaskRefReadsTheOwnerOffTheTask() {
        let fileURL = URL(string: "https://a.example/mount/api/v2/downloads/d1/file")!
        var request = URLRequest(url: fileURL)
        request.setValue("p1", forHTTPHeaderField: "X-Profile-Id")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: request)

        let untagged = DownloadTaskRef(task)
        XCTAssertNil(untagged.tag)
        XCTAssertEqual(untagged.taskId, task.taskIdentifier)
        XCTAssertEqual(
            DownloadTaskTag.attributing(
                requestURL: untagged.requestURL,
                profileId: untagged.requestProfileId,
                servers: [(id: "s1", url: "https://a.example/mount")]
            ),
            tag("s1", "p1", "d1")
        )

        task.taskDescription = tag("s2", "p2", "d2").taskDescription
        XCTAssertEqual(DownloadTaskRef(task).tag, tag("s2", "p2", "d2"))
    }

    // MARK: Finished transfers

    /// The old code looked the finish up in whichever store was loaded and
    /// deleted the file when that store had no record for it.
    func testFinishForAnotherScopeIsKeptForItsOwner() {
        let finished = tag("s1", "pA", "d1")

        // Another profile on the same server is loaded.
        XCTAssertEqual(disposition(finished, loaded: ("s1", "pB"), record: nil), .keepForOwner)
        // Signed out, a cold relaunch, or a scope still loading.
        XCTAssertEqual(disposition(finished, loaded: ("", ""), record: nil), .keepForOwner)
        // Another server whose store has a record with the same id.
        XCTAssertEqual(disposition(finished, loaded: ("s2", "pA"), record: record("d1", .downloading)), .keepForOwner)
    }

    func testFinishForTheLoadedScope() {
        let finished = tag("s1", "pA", "d1")
        let loaded = ("s1", "pA")

        XCTAssertEqual(disposition(finished, loaded: loaded, record: record("d1", .downloading)), .complete)
        // A finish that races a pause still completes.
        XCTAssertEqual(disposition(finished, loaded: loaded, record: record("d1", .paused)), .complete)
        // The record was deleted: its directory is left over.
        XCTAssertEqual(disposition(finished, loaded: loaded, record: nil), .discardDirectory)

        XCTAssertEqual(
            disposition(finished, loaded: loaded, record: record("d1", .completed, mediaFilename: "media.mp4")),
            .discardFile
        )
        // A revision replacement reset the record.
        XCTAssertEqual(disposition(finished, loaded: loaded, record: record("d1", .queued)), .discardFile)
        XCTAssertEqual(
            disposition(finished, loaded: loaded, record: record("d1", .revoked, mediaFilename: "media.mp4")),
            .discardFile
        )
        // No owner could be found for the task.
        XCTAssertEqual(disposition(nil, loaded: loaded, record: nil), .discardFile)
    }

    // MARK: Reconnect

    /// Task identifiers repeat across session instances, and the old
    /// reconnect kept a persisted id whenever any live task had that number.
    func testReconnectIgnoresAnotherScopesTaskWithTheSameNumber() {
        let live = DownloadManager.liveTaskIds(
            loadedServerId: "s1",
            loadedProfileId: "pB",
            tasks: [
                (taskId: 7, tag: tag("s1", "pA", "d1")),
                (taskId: 8, tag: nil),
                (taskId: 9, tag: tag("s1", "pB", "d2")),
            ]
        )

        XCTAssertEqual(live, ["d2": 9])
        XCTAssertNil(live["d1"])
        XCTAssertFalse(live.values.contains(7))
    }

    // MARK: Parked files

    func testFinishedTransfersAreFoundByDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("DownloadTaskAttributionTests-\(UUID().uuidString)", isDirectory: true)
        tempRoot = root
        let scope = DownloadFilePaths.scopeDirectory(serverId: "s1", profileId: "p1", root: root)
        let parkedName = DownloadFilePaths.directoryName(forDownloadId: "d 1")
        let parkedDirectory = scope.appendingPathComponent(parkedName, isDirectory: true)
        try fm.createDirectory(at: parkedDirectory, withIntermediateDirectories: true)
        let parked = parkedDirectory.appendingPathComponent(DownloadFilePaths.finishedTransferFilename)
        try Data("media".utf8).write(to: parked)
        try fm.createDirectory(at: scope.appendingPathComponent("d2", isDirectory: true), withIntermediateDirectories: true)

        let found = DownloadFilePaths.finishedTransfers(serverId: "s1", profileId: "p1", root: root)

        XCTAssertEqual(Set(found.keys), [parkedName])
        XCTAssertEqual(found[parkedName]?.standardizedFileURL.path, parked.standardizedFileURL.path)
        XCTAssertEqual(DownloadFilePaths.finishedTransfers(serverId: "s1", profileId: "other", root: root), [:])
    }
}

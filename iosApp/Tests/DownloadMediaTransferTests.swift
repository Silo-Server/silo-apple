import XCTest
import Foundation
@testable import Silo

/// Which finished downloads move between the device and an external drive,
/// and how a move lands on disk.
final class DownloadMediaTransferTests: XCTestCase {
    private let drive: DownloadMediaVolume = .external(id: "drive-1")

    private func record(
        _ id: String,
        status: LocalDownloadStatus = .completed,
        on volume: DownloadMediaVolume? = nil,
        pending: DownloadMediaVolume? = nil,
        downloadedAt: TimeInterval = 0
    ) throws -> DownloadRecord {
        let json = #"{"id":"\#(id)","contentId":"\#(id)","mediaFileId":"0","format":"original","serverStatus":"ready","localStatus":"\#(status.rawValue)","fileSize":10,"bytesDownloaded":10,"mediaFilename":"media.mp4","subtitleFilenames":{},"registeredAt":0,"retryCount":0}"#
        var record = try JSONDecoder().decode(DownloadRecord.self, from: Data(json.utf8))
        record.mediaVolume = volume
        record.pendingMediaVolume = pending
        record.downloadedAt = Date(timeIntervalSince1970: downloadedAt)
        return record
    }

    // MARK: - Choosing the next move

    func testNextJobMovesOnlyBetweenReachableVolumes() throws {
        let toDrive = try record("to-drive", pending: drive)
        let fromDrive = try record("from-drive", on: drive, pending: .device)
        let connected = DownloadMediaTransfer.nextJob(
            records: [toDrive, fromDrive], isAvailable: { _ in true }, skipping: []
        )
        XCTAssertNotNil(connected)

        let unplugged = DownloadMediaTransfer.nextJob(
            records: [toDrive, fromDrive], isAvailable: { $0 == .device }, skipping: []
        )
        XCTAssertNil(unplugged, "nothing moves to or from a drive that is not connected")
    }

    func testNextJobSkipsUnfinishedSettledAndSkippedRecords() throws {
        let records = [
            try record("downloading", status: .downloading, pending: drive),
            try record("already-there", on: drive, pending: drive),
            try record("not-waiting"),
            try record("skipped", pending: drive),
        ]
        XCTAssertNil(DownloadMediaTransfer.nextJob(records: records, isAvailable: { _ in true },
                                                   skipping: ["skipped"]))
    }

    func testNextJobTakesTheOldestDownloadFirst() throws {
        let newer = try record("newer", pending: drive, downloadedAt: 200)
        let older = try record("older", pending: drive, downloadedAt: 100)
        let job = DownloadMediaTransfer.nextJob(records: [newer, older], isAvailable: { _ in true }, skipping: [])
        XCTAssertEqual(job?.record.id, "older")
        XCTAssertEqual(job?.target, drive)
    }

    // MARK: - Changing the download location

    func testOnlyNewDownloadsLeavesSavedOnesWhereTheyAre() throws {
        let saved = try record("saved")
        let waiting = try record("waiting", pending: .external(id: "old-drive"))
        XCTAssertNil(DownloadMediaTransfer.retargeted(saved, to: drive, moveExisting: false))
        XCTAssertEqual(DownloadMediaTransfer.retargeted(waiting, to: drive, moveExisting: false), drive,
                       "a download still waiting to move follows the new choice")
        XCTAssertNil(DownloadMediaTransfer.retargeted(waiting, to: .device, moveExisting: false),
                     "a download waiting on the device is already where the new choice is")
    }

    func testMoveExistingMovesEveryFinishedDownloadNotAlreadyThere() throws {
        XCTAssertEqual(DownloadMediaTransfer.retargeted(try record("saved"), to: drive, moveExisting: true), drive)
        XCTAssertEqual(DownloadMediaTransfer.retargeted(try record("on-drive", on: drive), to: .device,
                                                        moveExisting: true), .device)
        XCTAssertNil(DownloadMediaTransfer.retargeted(try record("on-drive", on: drive), to: drive,
                                                      moveExisting: true))
        XCTAssertNil(DownloadMediaTransfer.retargeted(try record("failed", status: .failed), to: drive,
                                                      moveExisting: true))
    }

    // MARK: - Copying

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCopyReplacesTheDestinationAndLeavesNoPartialFile() throws {
        let folder = try temporaryFolder()
        let source = folder.appendingPathComponent("source.mp4")
        let destination = folder.appendingPathComponent("drive/scope/d1/media.mp4")
        try Data("new bytes".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination)

        try DownloadMediaTransfer.copy(source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("new bytes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the source goes only after the record saves")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
    }

    func testFailedCopyKeepsTheExistingDestination() throws {
        let folder = try temporaryFolder()
        let destination = folder.appendingPathComponent("media.mp4")
        try Data("old".utf8).write(to: destination)

        XCTAssertThrowsError(try DownloadMediaTransfer.copy(folder.appendingPathComponent("missing.mp4"),
                                                            to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("partial").path))
    }

    func testRemovingTheLastFileRemovesItsFolder() throws {
        let folder = try temporaryFolder()
        let alone = folder.appendingPathComponent("d1/media.mp4")
        let shared = folder.appendingPathComponent("d2/media.mp4")
        for url in [alone, shared] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("d2/manifest.json"))

        DownloadMediaTransfer.removeMedia(at: alone)
        DownloadMediaTransfer.removeMedia(at: shared)

        XCTAssertFalse(FileManager.default.fileExists(atPath: alone.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("d2/manifest.json").path),
                      "a device download's folder keeps its manifest and artwork")
    }
}

import XCTest
@testable import Silo

final class BreadcrumbJournalTests: XCTestCase {
    func testRotationKeepsTwoBackupExcludedSegments() throws {
        let directory = try makeTemporaryDirectory()
        let segmentLimit = 512
        let journal = BreadcrumbJournal(
            directory: directory,
            segmentByteLimit: segmentLimit,
            isEnabled: { true }
        )

        for index in 0..<20 {
            XCTAssertTrue(journal.append(
                category: .lifecycle,
                tag: "Lifecycle\(index)",
                message: "state changed",
                attrs: ["state": .string("state-\(index)")],
                captureSessionID: "run-rotation"
            ))
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isExcludedFromBackupKey]
        )
        .filter { $0.pathExtension == "jsonl" }

        XCTAssertLessThanOrEqual(files.count, 2)
        for file in files {
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            XCTAssertLessThanOrEqual(values.fileSize ?? 0, segmentLimit)
        }

        let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(directoryValues.isExcludedFromBackup, true)

        let lines = journal.readAll()
        XCTAssertFalse(lines.isEmpty)
        XCTAssertLessThan(lines.count, 20)
        XCTAssertTrue(lines.contains { $0.tag == "Lifecycle19" })
        XCTAssertTrue(lines.allSatisfy { $0.run == "run-rotation" })
        XCTAssertTrue(lines.allSatisfy { $0.cat == .lifecycle })
    }

    func testCorruptTailDoesNotBreakReadAll() throws {
        let directory = try makeTemporaryDirectory()
        let journal = BreadcrumbJournal(directory: directory, segmentByteLimit: 4096, isEnabled: { true })

        XCTAssertTrue(journal.append(category: .lifecycle, tag: "One", message: "started", captureSessionID: "run-corrupt"))
        XCTAssertTrue(journal.append(category: .playback, tag: "Two", message: "started", captureSessionID: "run-corrupt"))

        let segment = directory.appendingPathComponent("breadcrumbs-0.jsonl")
        let handle = try FileHandle(forWritingTo: segment)
        try handle.seekToEnd()
        handle.write(Data(#"{"ts":"torn""#.utf8))
        try handle.close()

        let lines = journal.readAll()
        XCTAssertEqual(lines.map(\.tag), ["One", "Two"])
        XCTAssertEqual(lines.map(\.run), ["run-corrupt", "run-corrupt"])
    }

    func testDisabledConsentDoesNotCreatePersistentBreadcrumbs() throws {
        let directory = try makeTemporaryDirectory()
        let journal = BreadcrumbJournal(directory: directory, isEnabled: { false })

        XCTAssertFalse(journal.append(category: .lifecycle, tag: "Lifecycle", message: "state changed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testScreenChangeBreadcrumbIsPersisted() throws {
        let directory = try makeTemporaryDirectory()
        let journal = BreadcrumbJournal(directory: directory, isEnabled: { true })

        XCTAssertTrue(journal.append(
            category: .focus,
            tag: "Navigation",
            message: "screen changed",
            attrs: ["target": .string("settings")],
            captureSessionID: "run-navigation"
        ))

        let line = try XCTUnwrap(journal.readAll().first)
        XCTAssertEqual(line.cat, .focus)
        XCTAssertEqual(line.tag, "Navigation")
        XCTAssertEqual(line.run, "run-navigation")
        XCTAssertEqual(line.attrs?["target"], .string("settings"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BreadcrumbJournalTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

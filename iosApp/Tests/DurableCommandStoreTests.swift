import Foundation
import XCTest
@testable import Silo

/// The one durable command store every write surface builds on: each
/// transition, the 7-day reaping boundary inside `persist`, the unchanged-file
/// short circuit, and the corrupt-file path.
final class DurableCommandStoreTests: XCTestCase {
    private struct Authority: Codable, Equatable, Sendable {
        let owner: String
    }

    private struct Command: DurableCommandRecord, Equatable {
        let id: UUID
        let authority: Authority
        var state: DurableCommandState
        var updatedAt: Date
        let payload: String

        init(owner: String = "a", payload: String = "p", state: DurableCommandState = .prepared,
             updatedAt: Date = .distantPast) {
            id = UUID()
            authority = Authority(owner: owner)
            self.state = state
            self.updatedAt = updatedAt
            self.payload = payload
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
        func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var fileURL: URL!
    private var clock: Clock!

    override func setUp() {
        super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableCommandStoreTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("commands.json")
        clock = Clock(start)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() -> DurableCommandStore<Command> {
        let clock = clock!
        return DurableCommandStore<Command>(fileURL: fileURL, now: { clock.now })
    }

    // MARK: append

    func testAppendStoresPreparedRecordStampedNow() async throws {
        let store = makeStore()
        let command = Command(state: .applied, updatedAt: .distantFuture)

        try await store.append(command)

        let storedValue = await store.record(id: command.id)

        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(stored.state, .prepared, "append forces the prepared state")
        XCTAssertEqual(stored.updatedAt, start, "append stamps updatedAt with the injected clock")
        XCTAssertEqual(stored.payload, "p")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAppendRejectsDuplicateID() async throws {
        let store = makeStore()
        let command = Command()
        try await store.append(command)

        do {
            try await store.append(command)
            XCTFail("duplicate id must be refused")
        } catch DurableCommandStoreError.duplicateID(let id) {
            XCTAssertEqual(id, command.id)
        }
        let count = await store.all().count
        XCTAssertEqual(count, 1)
    }

    // MARK: claim

    func testClaimMovesPreparedToUncertainAndStampsNow() async throws {
        let store = makeStore()
        let command = Command()
        try await store.append(command)
        clock.advance(by: 30)

        let claimed = try await store.claim(id: command.id)

        XCTAssertEqual(claimed.state, .uncertain)
        XCTAssertEqual(claimed.updatedAt, start.addingTimeInterval(30))
        let stored = await store.record(id: command.id)
        XCTAssertEqual(stored, claimed)
    }

    func testClaimRefusesAnythingButPrepared() async throws {
        let store = makeStore()
        let command = Command()
        try await store.append(command)
        try await store.claim(id: command.id)

        do {
            try await store.claim(id: command.id)
            XCTFail("a claimed command cannot be claimed again; that would be an automatic replay")
        } catch DurableCommandStoreError.invalidTransition(let id, let from) {
            XCTAssertEqual(id, command.id)
            XCTAssertEqual(from, .uncertain)
        }

        try await store.resolve(id: command.id, .applied)
        do {
            try await store.claim(id: command.id)
            XCTFail("a terminal command cannot be claimed")
        } catch DurableCommandStoreError.invalidTransition(_, let from) {
            XCTAssertEqual(from, .applied)
        }
    }

    func testClaimUnknownIDThrows() async throws {
        let store = makeStore()
        let missing = UUID()
        do {
            try await store.claim(id: missing)
            XCTFail("unknown id must throw")
        } catch DurableCommandStoreError.unknownID(let id) {
            XCTAssertEqual(id, missing)
        }
    }

    // MARK: resolve

    func testResolveAppliedAndFailedAreTerminal() async throws {
        let store = makeStore()
        let applied = Command(payload: "applied")
        let failed = Command(payload: "failed")
        try await store.append(applied)
        try await store.append(failed)
        try await store.claim(id: applied.id)
        try await store.claim(id: failed.id)
        clock.advance(by: 5)

        let appliedRecord = try await store.resolve(id: applied.id, .applied)
        let failedRecord = try await store.resolve(id: failed.id, .failed)

        XCTAssertEqual(appliedRecord.state, .applied)
        XCTAssertEqual(failedRecord.state, .failed)
        XCTAssertEqual(appliedRecord.updatedAt, start.addingTimeInterval(5))
        XCTAssertTrue(appliedRecord.state.isTerminal)
        XCTAssertTrue(failedRecord.state.isTerminal)

        let reversals: [(UUID, DurableCommandResolution)] = [(applied.id, .failed), (failed.id, .applied)]
        for (id, resolution) in reversals {
            do {
                try await store.resolve(id: id, resolution)
                XCTFail("a terminal record cannot be resolved again")
            } catch DurableCommandStoreError.invalidTransition(let thrownID, let from) {
                XCTAssertEqual(thrownID, id)
                XCTAssertTrue(from.isTerminal)
            }
        }
    }

    func testResolveFailedFromPreparedIsAllowedButAppliedIsNot() async throws {
        let store = makeStore()
        let refused = Command(payload: "refused before dispatch")
        let never = Command(payload: "never claimed")
        try await store.append(refused)
        try await store.append(never)

        let record = try await store.resolve(id: refused.id, .failed)
        XCTAssertEqual(record.state, .failed, "a pre-dispatch guard refusal is a definite failure")

        do {
            try await store.resolve(id: never.id, .applied)
            XCTFail("success without a claim is not a possible outcome")
        } catch DurableCommandStoreError.invalidTransition(_, let from) {
            XCTAssertEqual(from, .prepared)
        }
    }

    func testResolveUnknownIDThrows() async throws {
        let store = makeStore()
        let missing = UUID()
        do {
            try await store.resolve(id: missing, .applied)
            XCTFail("unknown id must throw")
        } catch DurableCommandStoreError.unknownID(let id) {
            XCTAssertEqual(id, missing)
        }
    }

    // MARK: discard

    func testDiscardRemovesRecordInAnyState() async throws {
        let store = makeStore()
        let prepared = Command(payload: "prepared")
        let uncertain = Command(payload: "uncertain")
        let applied = Command(payload: "applied")
        for command in [prepared, uncertain, applied] { try await store.append(command) }
        try await store.claim(id: uncertain.id)
        try await store.claim(id: applied.id)
        try await store.resolve(id: applied.id, .applied)

        try await store.discard(id: uncertain.id)
        try await store.discard(id: prepared.id)
        try await store.discard(id: applied.id)

        let remaining = await store.all()
        XCTAssertTrue(remaining.isEmpty)

        do {
            try await store.discard(id: uncertain.id)
            XCTFail("discarding twice must throw")
        } catch DurableCommandStoreError.unknownID(let id) {
            XCTAssertEqual(id, uncertain.id)
        }
    }

    func testDiscardAllRemovesOnlyMatchingRecords() async throws {
        let store = makeStore()
        let mine = Command(owner: "a")
        let theirs = Command(owner: "b")
        try await store.append(mine)
        try await store.append(theirs)

        try await store.discardAll { $0.authority.owner == "a" }

        let remaining = await store.all().map(\.id)
        XCTAssertEqual(remaining, [theirs.id])
    }

    // MARK: snapshot

    func testSnapshotFiltersByCallerSuppliedOwnerPredicate() async throws {
        let store = makeStore()
        let first = Command(owner: "a", payload: "1")
        let second = Command(owner: "a", payload: "2")
        let other = Command(owner: "b", payload: "3")
        for command in [first, second, other] { try await store.append(command) }

        let mine = await store.snapshot { $0.owner == "a" }
        let nobody = await store.snapshot { _ in false }

        XCTAssertEqual(mine.map(\.id), [first.id, second.id], "insertion order is preserved")
        XCTAssertTrue(nobody.isEmpty)
    }

    // MARK: persistence

    func testRecordsSurviveAFreshStoreOnTheSameFile() async throws {
        let store = makeStore()
        let command = Command(payload: "durable")
        try await store.append(command)
        try await store.claim(id: command.id)

        let reopened = makeStore()
        let storedValue = await reopened.record(id: command.id)
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(stored.state, .uncertain, "an in-flight command is still held after a relaunch")
        XCTAssertEqual(stored.payload, "durable")
        XCTAssertEqual(stored.authority, Authority(owner: "a"))
    }

    func testPersistSkipsTheWriteWhenNothingChanged() async throws {
        let store = makeStore()
        try await store.append(Command())
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let before = try Data(contentsOf: fileURL)

        let wrote = try await store.persist()

        XCTAssertFalse(wrote, "an identical document is not rewritten")
        XCTAssertEqual(try Data(contentsOf: fileURL), before)
        let after = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
    }

    func testPersistWritesWhenARecordChanged() async throws {
        let store = makeStore()
        let command = Command()
        try await store.append(command)
        let before = try Data(contentsOf: fileURL)

        try await store.claim(id: command.id)

        XCTAssertNotEqual(try Data(contentsOf: fileURL), before)
    }

    // MARK: reaping

    func testPersistReapsTerminalRecordsOlderThanSevenDays() async throws {
        let store = makeStore()
        let applied = Command(payload: "applied")
        let failed = Command(payload: "failed")
        let uncertain = Command(payload: "uncertain")
        let prepared = Command(payload: "prepared")
        for command in [applied, failed, uncertain, prepared] { try await store.append(command) }
        try await store.claim(id: applied.id)
        try await store.claim(id: failed.id)
        try await store.claim(id: uncertain.id)
        try await store.resolve(id: applied.id, .applied)
        try await store.resolve(id: failed.id, .failed)

        clock.advance(by: DurableCommandStore<Command>.expiryInterval + 1)
        try await store.persist()

        let remaining = await store.all().map(\.id)
        XCTAssertEqual(Set(remaining), [uncertain.id, prepared.id],
                       "terminal records are reaped; an uncertain hold and a prepared command are never reaped")
        let reopened = makeStore()
        let onDisk = await reopened.all().map(\.id)
        XCTAssertEqual(Set(onDisk), [uncertain.id, prepared.id], "the reaped file was written")
    }

    func testReapingBoundaryIsExactlySevenDays() async throws {
        let store = makeStore()
        let atBoundary = Command(payload: "exactly 7 days")
        let pastBoundary = Command(payload: "7 days and one second")
        try await store.append(atBoundary)
        try await store.append(pastBoundary)
        try await store.claim(id: atBoundary.id)
        try await store.claim(id: pastBoundary.id)
        // `pastBoundary` resolves one second before `atBoundary`, so at the
        // moment of the check it is one second older than the window.
        try await store.resolve(id: pastBoundary.id, .applied)
        clock.advance(by: 1)
        try await store.resolve(id: atBoundary.id, .applied)

        clock.advance(by: DurableCommandStore<Command>.expiryInterval)
        try await store.persist()

        let remaining = await store.all().map(\.id)
        XCTAssertEqual(remaining, [atBoundary.id],
                       "a record updated exactly expiryInterval ago is kept; one second older is dropped")
    }

    func testExpiredRecordsAreInvisibleImmediatelyAfterLoad() async throws {
        let store = makeStore()
        let stale = Command(payload: "stale")
        let live = Command(payload: "live")
        try await store.append(stale)
        try await store.append(live)
        try await store.claim(id: stale.id)
        try await store.resolve(id: stale.id, .failed)

        clock.advance(by: DurableCommandStore<Command>.expiryInterval + 60)
        let reopened = makeStore()

        let visible = await reopened.all().map(\.id)
        XCTAssertEqual(visible, [live.id], "a reader never sees a record that persist would drop")
        let staleRecord = await reopened.record(id: stale.id)
        XCTAssertNil(staleRecord)
    }

    // MARK: corrupt file

    func testCorruptFileStartsEmptyAndIsReplacedOnNextPersist() async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: fileURL)
        let store = makeStore()

        let loaded = await store.all()
        XCTAssertTrue(loaded.isEmpty, "an unreadable file is not trusted and does not crash")

        let command = Command(payload: "fresh")
        try await store.append(command)

        let reopened = makeStore()
        let storedValue = await reopened.record(id: command.id)
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(stored.payload, "fresh")
        let count = await reopened.all().count
        XCTAssertEqual(count, 1)
    }

    func testForeignDocumentShapeStartsEmpty() async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"records":[{"id":"not-a-uuid"}]}"#.utf8).write(to: fileURL)
        let store = makeStore()

        let loaded = await store.all()

        XCTAssertTrue(loaded.isEmpty)
        let wrote = try await store.persist()
        XCTAssertTrue(wrote, "the unreadable document is replaced by an empty one")
        let reopened = makeStore()
        let reopenedRecords = await reopened.all()
        XCTAssertTrue(reopenedRecords.isEmpty)
    }

    // MARK: file layout

    func testDocumentIsVersionedSortedJSONWithISO8601Dates() async throws {
        let store = makeStore()
        try await store.append(Command(payload: "layout"))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["state"] as? String, "prepared")
        XCTAssertEqual(records[0]["updatedAt"] as? String, "2023-11-14T22:13:20Z")
    }
}

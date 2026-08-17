//
//  AIJobPollerTests.swift
//  SiloTests
//
//  Behavioral tests for `AIJobPoller` using an injected fake `fetch` closure
//  (no live `SiloAI`, no network): terminal-state stop on each terminal
//  status, progress passthrough across snapshots, and cancellation.
//

import XCTest
import Foundation
@testable import Silo

final class AIJobPollerTests: XCTestCase {

    /// Collect every snapshot the poller emits for a scripted `fetch`, with a
    /// hard timeout so a logic bug can't hang the suite.
    private func collect(
        timeout: TimeInterval = 10,
        fetch: @escaping @Sendable (String) async throws -> SubtitleJob
    ) async -> [SubtitleJob] {
        let poller = AIJobPoller()
        let stream = await poller.poll(jobId: "job", fetch: fetch)

        let result = await withTaskGroup(of: [SubtitleJob]?.self) { group -> [SubtitleJob] in
            group.addTask {
                var collected: [SubtitleJob] = []
                for await snapshot in stream {
                    collected.append(snapshot)
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            await poller.cancel()
            return first ?? []
        }
        return result
    }

    // MARK: - Terminal stop

    func testStopsOnCompleted() async {
        // running, running, completed → exactly 3 snapshots, then finish.
        let statuses = ["running", "running", "completed"]
        let counter = Counter()
        let snapshots = await collect { _ in
            let i = await counter.next()
            return aiTestJob(id: "job", status: statuses[min(i, statuses.count - 1)], 0, i == 2 ? 7 : nil)
        }
        XCTAssertTrue(snapshots.count == 3, "expected 3 snapshots, got \(snapshots.count)")
        XCTAssertTrue(snapshots.last?.status == .completed)
        XCTAssertTrue(snapshots.last?.resultSubtitleId == 7)
    }

    func testStopsOnFailed() async {
        let counter = Counter()
        let snapshots = await collect { _ in
            let i = await counter.next()
            return aiTestJob(id: "job", status: i == 0 ? "running" : "failed", 0, nil)
        }
        XCTAssertTrue(snapshots.count == 2, "expected 2 snapshots, got \(snapshots.count)")
        XCTAssertTrue(snapshots.last?.status == .failed)
    }

    func testStopsOnCancelledStatus() async {
        let snapshots = await collect { _ in
            aiTestJob(id: "job", status: "cancelled", 0, nil)
        }
        // First fetch is already terminal → exactly one snapshot.
        XCTAssertTrue(snapshots.count == 1, "expected 1 snapshot, got \(snapshots.count)")
        XCTAssertTrue(snapshots.last?.status == .cancelled)
    }

    func testImmediateTerminalEmitsOnce() async {
        let snapshots = await collect { _ in
            aiTestJob(id: "job", status: "completed", 1.0, 11)
        }
        XCTAssertTrue(snapshots.count == 1)
        XCTAssertTrue(snapshots.first?.resultSubtitleId == 11)
    }

    // MARK: - Progress passthrough

    func testProgressPassthrough() async {
        let progresses: [Double] = [0.0, 0.25, 0.5, 1.0]
        let statuses = ["running", "running", "running", "completed"]
        let counter = Counter()
        let snapshots = await collect { _ in
            let i = await counter.next()
            let idx = min(i, progresses.count - 1)
            return aiTestJob(id: "job", status: statuses[idx], progresses[idx], idx == 3 ? 1 : nil)
        }
        XCTAssertTrue(snapshots.count == 4)
        XCTAssertTrue(snapshots.map { $0.progress } == progresses,
                      "progress sequence not passed through verbatim: \(snapshots.map { $0.progress })")
    }

    // MARK: - Cancellation

    func testCancellationStopsStream() async {
        // `fetch` always returns running; the poller would never stop on its
        // own. Cancelling the draining Task must finish the stream promptly.
        let started = expectation(description: "first snapshot delivered")
        let poller = AIJobPoller()
        let stream = await poller.poll(jobId: "job") { _ in
            aiTestJob(id: "job", status: "running", 0.1, nil)
        }

        var count = 0
        let drain = Task {
            for await _ in stream {
                count += 1
                if count == 1 { started.fulfill() }
            }
            return count
        }

        await fulfillment(of: [started], timeout: 5)
        drain.cancel()

        // The stream must finish (drain Task returns) within a bounded window
        // after cancellation rather than running forever.
        let finished = Task {
            _ = await drain.value
            return true
        }
        let didFinish = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await finished.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        XCTAssertTrue(didFinish, "stream did not finish after cancellation")
    }

    func testPollerCancelStopsStream() async {
        // Same as above but using the poller's own `cancel()` rather than
        // cancelling the consumer.
        let started = expectation(description: "first snapshot delivered")
        let poller = AIJobPoller()
        let stream = await poller.poll(jobId: "job") { _ in
            aiTestJob(id: "job", status: "running", 0.1, nil)
        }

        let drain = Task {
            var n = 0
            for await _ in stream {
                n += 1
                if n == 1 { started.fulfill() }
            }
            return n
        }

        await fulfillment(of: [started], timeout: 5)
        await poller.cancel()

        let didFinish = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                _ = await drain.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        XCTAssertTrue(didFinish, "poller.cancel() did not finish the stream")
    }
}

/// Build a `SubtitleJob` from scripted fields by decoding JSON — `SubtitleJob`
/// has only a custom `init(from:)`, no memberwise initializer. Free function
/// (not a method) so it can be called from the `@Sendable` `fetch` closures
/// without capturing `self`. Returns a `Sendable` value.
private func aiTestJob(
    id: String,
    status: String,
    _ progress: Double,
    _ resultSubtitleId: Int?
) -> SubtitleJob {
    let resultField = resultSubtitleId.map { "\"result_subtitle_id\": \($0)," } ?? ""
    let json = """
    {
      "id": "\(id)",
      "media_file_id": 1,
      "kind": "translate",
      "source_index": 0,
      \(resultField)
      "status": "\(status)",
      "progress": \(progress)
    }
    """
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try! d.decode(SubtitleJob.self, from: Data(json.utf8))
}

/// Simple async call counter so a scripted `fetch` can advance through a
/// snapshot sequence without data races.
private actor Counter {
    private var value = 0
    func next() -> Int {
        defer { value += 1 }
        return value
    }
}

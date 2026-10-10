import XCTest
@testable import Silo

@MainActor
final class SharedFetchTests: XCTestCase {
    func testConcurrentCallersShareOneRequest() async throws {
        let fetch = SharedFetch<Int>()
        let counter = RequestCounter()
        let gate = AsyncGate()

        let first = fetch.join {
            await counter.increment()
            await gate.wait()
            return 7
        }
        let second = fetch.join { await counter.increment(); return 8 }
        XCTAssertTrue(fetch.isInFlight)
        await gate.open()

        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, 7)
        XCTAssertEqual(secondValue, 7)
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testOnlyTheFirstCallerToResumeClearsTheSlot() async throws {
        let fetch = SharedFetch<Int>()
        let task = fetch.join { 1 }
        _ = try await task.value

        XCTAssertTrue(fetch.finish(task, value: 1))
        XCTAssertFalse(fetch.finish(task, value: 1))
        XCTAssertFalse(fetch.isInFlight)
    }

    func testRecentResultIsReusedOnlyWithinItsWindow() async throws {
        let reusing = SharedFetch<Int>(reuseWindow: .seconds(60))
        let task = reusing.join { 3 }
        reusing.finish(task, value: try await task.value)
        XCTAssertEqual(reusing.recentValue(), 3)

        let notReusing = SharedFetch<Int>()
        let other = notReusing.join { 4 }
        notReusing.finish(other, value: try await other.value)
        XCTAssertNil(notReusing.recentValue())
    }

    func testResetCancelsAndForgets() async throws {
        let fetch = SharedFetch<Int>(reuseWindow: .seconds(60))
        let landed = fetch.join { 5 }
        fetch.finish(landed, value: try await landed.value)

        let pending = fetch.join {
            try await Task.sleep(for: .seconds(30))
            return 6
        }
        fetch.reset()

        XCTAssertNil(fetch.recentValue())
        XCTAssertFalse(fetch.isInFlight)
        do {
            _ = try await pending.value
            XCTFail("A reset request must not deliver a value")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(fetch.finish(pending, value: nil))
    }
}

private actor RequestCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

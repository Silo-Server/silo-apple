import Foundation
import XCTest
@testable import Silo

/// The shared stub's `Gate` must not strand a waiter whose task is cancelled:
/// `stopLoading()` cancels a gated reply, and a test that never opens the
/// gate afterward would otherwise leak a suspended task per cancellation.
final class StubURLProtocolGateTests: XCTestCase {
    func testCancelledWaiterIsReleasedWithoutOpen() async {
        let gate = StubURLProtocol.Gate()
        let waiter = Task { await gate.wait() }
        await waitForWaiter(on: gate)
        waiter.cancel()
        let released = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await waiter.value; return true }
            group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(released, "a cancelled waiter must return without the gate opening")
    }

    func testOpenStillReleasesLiveWaiters() async {
        let gate = StubURLProtocol.Gate()
        let waiter = Task { await gate.wait() }
        await waitForWaiter(on: gate)
        await gate.open()
        await waiter.value
        // A wait after open returns immediately.
        await gate.wait()
    }

    /// Returns once a waiter is suspended inside the gate, so the step under
    /// test acts on a registered continuation rather than racing it.
    private func waitForWaiter(on gate: StubURLProtocol.Gate, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while await gate.waiterCount == 0 {
            if Date() > deadline { return XCTFail("the waiter never registered", file: file, line: line) }
            await Task.yield()
        }
    }
}

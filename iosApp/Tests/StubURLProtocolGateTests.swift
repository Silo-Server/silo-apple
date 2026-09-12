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
        // Give the waiter a chance to suspend inside the gate before cancelling.
        try? await Task.sleep(nanoseconds: 50_000_000)
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
        try? await Task.sleep(nanoseconds: 50_000_000)
        await gate.open()
        await waiter.value
        // A wait after open returns immediately.
        await gate.wait()
    }
}

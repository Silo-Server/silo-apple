import Foundation
import XCTest

/// Poll until `condition` holds, so a test never depends on a fixed sleep
/// being long enough on a loaded machine.
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    _ condition: @escaping () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("timed out waiting for \(description)", file: file, line: line)
}

/// Bounded spin that reports whether the predicate ever held, for tests that
/// want to assert on the outcome instead of failing inside the wait.
@discardableResult
func waitUntil(
    timeout: TimeInterval = 2,
    _ predicate: () async -> Bool
) async -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
        if await predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await predicate()
}

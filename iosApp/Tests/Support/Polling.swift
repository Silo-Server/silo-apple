import XCTest

/// Polls `condition` every 10 ms until it holds or `timeout` passes, and
/// returns whether it held. For a state the test can name; a fixed sleep
/// either wastes time or is too short on a loaded machine.
func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        do {
            try await Task.sleep(for: .milliseconds(10))
        } catch {
            break
        }
    }
    return await condition()
}

/// ``eventually(timeout:_:)`` that fails the test on timeout.
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    try Task.checkCancellation()
    if await eventually(timeout: timeout, condition) { return }
    XCTFail("timed out waiting for \(description)", file: file, line: line)
}

/// ``waitUntil(_:timeout:_:file:line:)`` for a test that does not throw.
func expectEventually(
    _ description: String,
    timeout: Duration = .seconds(5),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async {
    if await eventually(timeout: timeout, condition) { return }
    XCTFail("timed out waiting for: \(description)", file: file, line: line)
}

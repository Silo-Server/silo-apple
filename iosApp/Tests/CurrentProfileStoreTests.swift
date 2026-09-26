import XCTest
@testable import Silo

@MainActor
final class CurrentProfileStoreTests: XCTestCase {
    func testStaleRefreshAfterResetDoesNotBreakDeduplicationOfTheNewRefresh() async throws {
        let gate = FetchGate(gatedCalls: 2)
        gate.activeProfileId = "p-old"
        let store = makeStore(gate)

        let a = Task { await store.refresh() }
        try await gate.waitUntilParked(call: 1)

        // Profile switch: the old fetch is still on the wire.
        store.reset()
        gate.activeProfileId = "p-new"

        let b = Task { await store.refresh() }
        try await gate.waitUntilParked(call: 2)

        // The stale response lands after the new fetch started. It matches the
        // profile A was loading, so only the generation check keeps it out.
        gate.release(call: 1, with: [profile("p-old")])
        await a.value
        XCTAssertNil(store.profile)

        // C must reach its in-flight check while B is still parked.
        let c = Task { await store.refresh() }
        for _ in 0..<5 { await Task.yield() }

        gate.release(call: 2, with: [profile("p-new")])
        await b.value
        await c.value

        XCTAssertEqual(gate.callCount, 2, "C should join B's fetch, not start another")
        XCTAssertEqual(store.profile?.id, "p-new")
    }

    func testConcurrentRefreshesShareOneFetch() async throws {
        let gate = FetchGate(gatedCalls: 1)
        let store = makeStore(gate)

        let first = Task { await store.refresh() }
        try await gate.waitUntilParked(call: 1)
        let second = Task { await store.refresh() }
        for _ in 0..<5 { await Task.yield() }

        gate.release(call: 1, with: [profile("p-new")])
        await first.value
        await second.value

        XCTAssertEqual(gate.callCount, 1)
        XCTAssertEqual(store.profile?.id, "p-new")
    }

    private func makeStore(_ gate: FetchGate) -> CurrentProfileStore {
        CurrentProfileStore(
            activeProfileId: { gate.activeProfileId },
            fetchProfiles: { await gate.fetch() }
        )
    }
}

private func profile(_ id: String) -> UserProfile {
    UserProfile(id: id, name: id, avatarEmoji: nil, hasPin: false, isChild: false)
}

private struct FetchNeverStarted: Error {
    let call: Int
}

/// Holds the first `gatedCalls` fetches until the test releases them; later
/// calls answer immediately, so a duplicate fetch shows up in `callCount`
/// instead of hanging the test. Ignores cancellation on purpose to model a
/// response already on the wire when `reset()` cancels its task.
@MainActor
private final class FetchGate {
    var activeProfileId: String? = "p-new"
    private(set) var callCount = 0

    private let gatedCalls: Int
    private var parked: [Int: CheckedContinuation<[UserProfile], Never>] = [:]

    init(gatedCalls: Int) {
        self.gatedCalls = gatedCalls
    }

    func fetch() async -> [UserProfile] {
        callCount += 1
        let call = callCount
        guard call <= gatedCalls else { return [profile("p-new")] }
        return await withCheckedContinuation { parked[call] = $0 }
    }

    /// Yields until fetch `call` is parked. Bounded so a broken sequence
    /// fails the test instead of spinning forever.
    func waitUntilParked(call: Int) async throws {
        for _ in 0..<10_000 {
            if parked[call] != nil { return }
            await Task.yield()
        }
        throw FetchNeverStarted(call: call)
    }

    func release(call: Int, with profiles: [UserProfile]) {
        parked.removeValue(forKey: call)?.resume(returning: profiles)
    }
}

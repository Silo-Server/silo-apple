import XCTest
@testable import Silo

final class MetadataSingleFlightTests: XCTestCase {
    func testCoalescesOnlyConcurrentMatchingKeys() async throws {
        let flights = MetadataSingleFlight<String, String>()
        let probe = MetadataSingleFlightProbe()

        // The first request stays open until both callers share its flight.
        async let first = flights.value(for: "same") {
            await probe.gatedValue(for: "same")
        }
        async let second = flights.value(for: "same") {
            await probe.gatedValue(for: "same")
        }
        let joined = await eventually { await flights.waiterCount(for: "same") == 2 }
        XCTAssertTrue(joined, "both callers must join one flight")
        await probe.open()
        let matchingValues = try await (first, second)

        XCTAssertEqual(matchingValues.0, "same")
        XCTAssertEqual(matchingValues.1, "same")
        let matchingCallCount = await probe.count(for: "same")
        XCTAssertEqual(matchingCallCount, 1)

        // Different keys each start their own request while both are open.
        let distinct = MetadataSingleFlightProbe()
        async let alpha = flights.value(for: "alpha") {
            await distinct.gatedValue(for: "alpha")
        }
        async let beta = flights.value(for: "beta") {
            await distinct.gatedValue(for: "beta")
        }
        let bothStarted = await eventually {
            let alphaCalls = await distinct.count(for: "alpha")
            let betaCalls = await distinct.count(for: "beta")
            return alphaCalls == 1 && betaCalls == 1
        }
        XCTAssertTrue(bothStarted, "different keys must not share a flight")
        await distinct.open()
        let distinctValues = try await (alpha, beta)
        XCTAssertEqual(distinctValues.0, "alpha")
        XCTAssertEqual(distinctValues.1, "beta")

        _ = try await flights.value(for: "completed") {
            await probe.immediateValue(for: "completed")
        }
        _ = try await flights.value(for: "completed") {
            await probe.immediateValue(for: "completed")
        }

        let completedCallCount = await probe.count(for: "completed")
        XCTAssertEqual(completedCallCount, 2)
    }
}

private actor MetadataSingleFlightProbe {
    private var counts: [String: Int] = [:]
    private var isOpen = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    /// Counts the call, then waits for ``open()``.
    func gatedValue(for key: String) async -> String {
        counts[key, default: 0] += 1
        if !isOpen {
            await withCheckedContinuation { gateWaiters.append($0) }
        }
        return key
    }

    func open() {
        isOpen = true
        let waiters = gateWaiters
        gateWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func immediateValue(for key: String) -> String {
        counts[key, default: 0] += 1
        return key
    }

    func count(for key: String) -> Int {
        counts[key, default: 0]
    }
}

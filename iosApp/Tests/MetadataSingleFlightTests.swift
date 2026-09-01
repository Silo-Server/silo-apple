import XCTest
@testable import Silo

final class MetadataSingleFlightTests: XCTestCase {
    func testCoalescesOnlyConcurrentMatchingKeys() async throws {
        let flights = MetadataSingleFlight<String, String>()
        let probe = MetadataSingleFlightProbe()

        async let first = flights.value(for: "same") {
            try await probe.value(for: "same", delay: .milliseconds(100))
        }
        async let second = flights.value(for: "same") {
            try await probe.value(for: "same", delay: .milliseconds(100))
        }
        let matchingValues = try await (first, second)

        XCTAssertEqual(matchingValues.0, "same")
        XCTAssertEqual(matchingValues.1, "same")
        let matchingCallCount = await probe.count(for: "same")
        XCTAssertEqual(matchingCallCount, 1)

        async let alpha = flights.value(for: "alpha") {
            try await probe.value(for: "alpha", delay: .milliseconds(20))
        }
        async let beta = flights.value(for: "beta") {
            try await probe.value(for: "beta", delay: .milliseconds(20))
        }
        _ = try await (alpha, beta)

        let alphaCallCount = await probe.count(for: "alpha")
        let betaCallCount = await probe.count(for: "beta")
        XCTAssertEqual(alphaCallCount, 1)
        XCTAssertEqual(betaCallCount, 1)

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

    func value(for key: String, delay: Duration) async throws -> String {
        counts[key, default: 0] += 1
        try await Task.sleep(for: delay)
        return key
    }

    func immediateValue(for key: String) -> String {
        counts[key, default: 0] += 1
        return key
    }

    func count(for key: String) -> Int {
        counts[key, default: 0]
    }
}

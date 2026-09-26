import Foundation
import XCTest
@testable import Silo

/// The "server needs setup" screen re-probes the active server on demand. It
/// must leave the screen only when the same server reports it is ready, and a
/// cancelled or superseded check must never surface a late result.
@MainActor
final class ServerNeedsSetupRetryModelTests: XCTestCase {
    private static let serverURL = "https://silo.example"

    func testReadyServerCallsOnReadyOnce() async throws {
        let harness = RetryHarness(outcome: .ready)
        let model = harness.makeModel()

        let task = try XCTUnwrap(model.retry { harness.readyCount += 1 })
        await task.value

        XCTAssertEqual(harness.readyCount, 1)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isChecking)
        XCTAssertEqual(harness.checkedURLs, [Self.serverURL])
    }

    func testServerStillNeedingSetupShowsErrorAndStays() async throws {
        let harness = RetryHarness(outcome: .needsSetup)
        let model = harness.makeModel()

        let task = try XCTUnwrap(model.retry { harness.readyCount += 1 })
        await task.value

        XCTAssertEqual(harness.readyCount, 0)
        XCTAssertEqual(model.error, ServerNeedsSetupRetryModel.stillNeedsSetupMessage)
        XCTAssertFalse(model.isChecking)
    }

    func testUnreachableServerShowsUnreachableError() async throws {
        let harness = RetryHarness(outcome: .unreachable)
        let model = harness.makeModel()

        let task = try XCTUnwrap(model.retry { harness.readyCount += 1 })
        await task.value

        XCTAssertEqual(harness.readyCount, 0)
        XCTAssertEqual(model.error, ServerNeedsSetupRetryModel.unreachableMessage)
        XCTAssertFalse(model.isChecking)
    }

    func testResultIgnoredWhenActiveServerChangedDuringCheck() async throws {
        let harness = RetryHarness(outcome: .switchServerThenReady)
        let model = harness.makeModel()

        let task = try XCTUnwrap(model.retry { harness.readyCount += 1 })
        await task.value

        XCTAssertEqual(harness.checkedURLs, [Self.serverURL])
        XCTAssertEqual(harness.readyCount, 0)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isChecking)
    }

    func testCancelSuppressesResultAndClearsChecking() async throws {
        let harness = RetryHarness(outcome: .hang)
        let model = harness.makeModel()

        let task = try XCTUnwrap(model.retry { harness.readyCount += 1 })
        XCTAssertTrue(model.isChecking)
        model.cancel()
        await task.value

        XCTAssertFalse(model.isChecking)
        XCTAssertNil(model.error)
        XCTAssertEqual(harness.readyCount, 0)
    }

    /// A probe that still answers "ready" after the screen cancelled it (the
    /// user chose "Change server" or left) must not navigate.
    func testCancelSuppressesLateReadyAnswer() async throws {
        let harness = RetryHarness(outcome: .ready)
        let model = harness.makeModel()

        let task = try XCTUnwrap(model.retry { harness.readyCount += 1 })
        model.cancel()
        await task.value

        XCTAssertEqual(harness.checkedURLs, [Self.serverURL])
        XCTAssertEqual(harness.readyCount, 0)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isChecking)
    }

    func testRetryWhileCheckingIsIgnored() async throws {
        let harness = RetryHarness(outcome: .hang)
        let model = harness.makeModel()

        let first = try XCTUnwrap(model.retry { harness.readyCount += 1 })
        XCTAssertNil(model.retry { harness.readyCount += 1 })
        XCTAssertTrue(model.isChecking)

        model.cancel()
        await first.value

        XCTAssertEqual(harness.checkedURLs.count, 1)
        XCTAssertEqual(harness.readyCount, 0)
    }

    func testRetryClearsPreviousError() async throws {
        let harness = RetryHarness(outcome: .unreachable)
        let model = harness.makeModel()

        let failing = try XCTUnwrap(model.retry { harness.readyCount += 1 })
        await failing.value
        XCTAssertEqual(model.error, ServerNeedsSetupRetryModel.unreachableMessage)

        harness.outcome = .ready
        let succeeding = try XCTUnwrap(model.retry { harness.readyCount += 1 })
        XCTAssertNil(model.error)
        XCTAssertTrue(model.isChecking)
        await succeeding.value

        XCTAssertNil(model.error)
        XCTAssertEqual(harness.readyCount, 1)
    }
}

/// Stands in for `AuthService`: records each probe, answers with the chosen
/// outcome, and holds the "active server" the model compares against.
@MainActor
private final class RetryHarness {
    enum Outcome {
        case ready
        case needsSetup
        case unreachable
        /// The user switches servers while the probe is in flight.
        case switchServerThenReady
        /// Never answers on its own; only cancellation ends it.
        case hang
    }

    var outcome: Outcome
    var currentURL = "https://silo.example"
    var readyCount = 0
    private(set) var checkedURLs: [String] = []

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func makeModel() -> ServerNeedsSetupRetryModel {
        ServerNeedsSetupRetryModel(
            checkServer: { [self] url in try await self.check(url) },
            currentServerURL: { [self] in self.currentURL }
        )
    }

    private func check(_ url: String) async throws -> APIv2SetupStatus {
        checkedURLs.append(url)
        switch outcome {
        case .ready:
            return APIv2SetupStatus(needsSetup: false)
        case .needsSetup:
            return APIv2SetupStatus(needsSetup: true)
        case .unreachable:
            throw URLError(.cannotConnectToHost)
        case .switchServerThenReady:
            currentURL = "https://other.example"
            return APIv2SetupStatus(needsSetup: false)
        case .hang:
            try await Task.sleep(for: .seconds(30))
            return APIv2SetupStatus(needsSetup: false)
        }
    }
}

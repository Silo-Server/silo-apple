import UIKit
import XCTest
@testable import Silo

/// The sections below a detail page's fold wait for the first frame's
/// commit, and must never wait longer than the fallback.
@MainActor
final class DetailFrameCommitTests: XCTestCase {
    func testWithoutASceneTheWorkRunsAtOnce() {
        var runs = 0
        let request = DetailFrameCommit.afterNextCommit(in: nil) { runs += 1 }
        XCTAssertNil(request)
        XCTAssertEqual(runs, 1)
    }

    func testEachRequestRunsOnceAndACancelledOneNever() async throws {
        let scene = try foregroundScene()
        var runs = 0
        var cancelledRuns = 0
        let waitingBefore = DetailFrameCommit.waitingCount
        DetailFrameCommit.afterNextCommit(in: scene) { runs += 1 }
        let cancelled = try XCTUnwrap(DetailFrameCommit.afterNextCommit(in: scene) { cancelledRuns += 1 })
        DetailFrameCommit.cancel(cancelled)

        // By a commit or, failing that, the fallback.
        try await waitUntil { runs == 1 }
        try await waitUntil { DetailFrameCommit.waitingCount == waitingBefore }
        // Past the fallback, nothing runs twice.
        try await Task.sleep(for: DetailFrameCommit.fallback * 2)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(cancelledRuns, 0)
        XCTAssertLessThanOrEqual(DetailFrameCommit.linkedSceneCount, UIApplication.shared.connectedScenes.count)
    }

    private func foregroundScene() throws -> UIWindowScene {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .background && $0.activationState != .unattached })
        else { throw XCTSkip("The test host has no foreground window scene.") }
        return scene
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not met in time")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

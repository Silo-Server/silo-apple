import Foundation
import Observation
import XCTest
@testable import Silo

/// SwiftUI observes every piece of `AppRouter` state, so view models that
/// change routes after a network await must make those changes on the main
/// thread, not wherever their await resumed.
@MainActor
final class AppRouterIsolationTests: XCTestCase {
    func testServerSetupCommitsRouteChangesOnTheMainThread() async {
        let router = AppRouter()
        let viewModel = ServerSetupViewModel(checkServer: { _ in APIv2SetupStatus(needsSetup: true) })
        viewModel.host = "silo.example"
        let mutationThreads = ThreadRecord()
        // `onChange` runs synchronously on the thread that makes the first
        // observed mutation, whichever of the two properties that is.
        withObservationTracking {
            _ = router.path
            _ = router.authState
        } onChange: {
            mutationThreads.append(Thread.isMainThread)
        }

        await viewModel.connect(router: router)

        XCTAssertEqual(router.authState, .needsLogin)
        XCTAssertEqual(router.path.count, 1, "A server that needs setup pushes .serverNeedsSetup")
        XCTAssertEqual(mutationThreads.values, [true], "The route commit must happen on the main thread")
    }
}

private final class ThreadRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []

    func append(_ isMainThread: Bool) {
        lock.lock()
        recorded.append(isMainThread)
        lock.unlock()
    }

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

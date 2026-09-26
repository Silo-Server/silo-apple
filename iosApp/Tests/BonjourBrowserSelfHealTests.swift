#if os(iOS)
import XCTest
import Network
@testable import Silo

/// The Remote Control and pairing browsers restart after their `NWBrowser`
/// fails (for example after a post-suspension network-stack reset), and stay
/// stopped once their owner calls `stop()`. Failures are injected through
/// `handleStateUpdate`; the real browser's own non-failure updates are ignored.
@MainActor
final class BonjourBrowserSelfHealTests: XCTestCase {
    private var failure: NWBrowser.State { .failed(NWError.posix(.ENETDOWN)) }

    func testSiloControlBrowserRestartsAfterFailure() async {
        let heal = BonjourSelfHeal(delay: .zero)
        let browser = SiloControlBrowser(selfHeal: heal)
        browser.start()
        defer { browser.stop() }
        let gen = heal.generation

        browser.handleStateUpdate(failure, generation: gen)
        XCTAssertNotNil(heal.pendingRestart)
        await heal.pendingRestart?.value

        XCTAssertEqual(heal.generation, gen + 1)
        XCTAssertTrue(heal.isActive)
    }

    func testSiloControlBrowserStaysStoppedAfterStop() {
        let heal = BonjourSelfHeal(delay: .zero)
        let browser = SiloControlBrowser(selfHeal: heal)
        browser.start()
        let gen = heal.generation
        browser.stop()
        let stoppedGeneration = heal.generation

        browser.handleStateUpdate(failure, generation: gen)

        XCTAssertNil(heal.pendingRestart)
        XCTAssertFalse(heal.isActive)
        XCTAssertEqual(heal.generation, stoppedGeneration)
    }

    func testSiloControlBrowserStopCancelsPendingRestart() async {
        let heal = BonjourSelfHeal(delay: .seconds(60))
        let browser = SiloControlBrowser(selfHeal: heal)
        browser.start()
        defer { browser.stop() }
        let gen = heal.generation

        browser.handleStateUpdate(failure, generation: gen)
        let task = heal.pendingRestart
        XCTAssertNotNil(task)
        browser.stop()
        await task?.value

        XCTAssertEqual(heal.generation, gen + 1)
        XCTAssertFalse(heal.isActive)
    }

    func testSiloControlBrowserStartWhileRestartPendingStartsOnce() async {
        let heal = BonjourSelfHeal(delay: .seconds(60))
        let browser = SiloControlBrowser(selfHeal: heal)
        browser.start()
        defer { browser.stop() }
        let gen = heal.generation

        browser.handleStateUpdate(failure, generation: gen)
        let task = heal.pendingRestart
        XCTAssertNotNil(task)
        browser.start()
        await task?.value

        XCTAssertEqual(heal.generation, gen + 1)
        XCTAssertNil(heal.pendingRestart)
        XCTAssertTrue(heal.isActive)
    }

    func testSiloControlBrowserIgnoresStaleGenerationFailure() {
        let heal = BonjourSelfHeal(delay: .zero)
        let browser = SiloControlBrowser(selfHeal: heal)
        browser.start()
        defer { browser.stop() }
        let gen = heal.generation

        browser.handleStateUpdate(failure, generation: gen - 1)

        XCTAssertNil(heal.pendingRestart)
        XCTAssertEqual(heal.generation, gen)
    }

    func testPairingBrowserStillRestartsAfterFailure() async {
        let heal = BonjourSelfHeal(delay: .zero)
        let browser = TVPairingBrowser(selfHeal: heal)
        browser.start()
        defer { browser.stop() }
        let gen = heal.generation

        browser.handleStateUpdate(failure, generation: gen)
        XCTAssertNotNil(heal.pendingRestart)
        await heal.pendingRestart?.value

        XCTAssertEqual(heal.generation, gen + 1)
        XCTAssertTrue(heal.isActive)
    }

    func testPairingBrowserStopCancelsPendingRestart() async {
        let heal = BonjourSelfHeal(delay: .seconds(60))
        let browser = TVPairingBrowser(selfHeal: heal)
        browser.start()
        defer { browser.stop() }
        let gen = heal.generation

        browser.handleStateUpdate(failure, generation: gen)
        let task = heal.pendingRestart
        XCTAssertNotNil(task)
        browser.stop()
        await task?.value

        XCTAssertEqual(heal.generation, gen + 1)
        XCTAssertFalse(heal.isActive)
    }
}
#endif

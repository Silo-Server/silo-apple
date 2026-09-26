import Observation
import XCTest
@testable import Silo

/// `PlayerView` keeps its view model in a `LazyModelSlot` because SwiftUI runs
/// `View.init` on every presenter re-render and keeps only the first `@State`
/// value. These pin what that relies on: a discarded slot builds nothing, an
/// installed slot builds once, and only `replace(with:)` notifies the view.
@MainActor
final class LazyModelSlotTests: XCTestCase {
    private final class Probe {}

    private final class Factory {
        private(set) var count = 0

        func make() -> Probe {
            count += 1
            return Probe()
        }
    }

    func testFactoryDoesNotRunUntilFirstRead() {
        let factory = Factory()
        let slot = LazyModelSlot { factory.make() }
        XCTAssertEqual(factory.count, 0)

        let first = slot.model
        let second = slot.model

        XCTAssertEqual(factory.count, 1)
        XCTAssertTrue(first === second)
    }

    /// Every later `body` pass reads the built model again; that must not
    /// invalidate the reader. (Observation installs tracking only after the
    /// tracked closure returns, so no test can see a write made during the
    /// building read itself.)
    func testReadsAfterTheBuildDoNotNotifyObservers() {
        let slot = LazyModelSlot { Probe() }
        let changed = expectation(description: "Re-reading the built model must not invalidate its reader")
        changed.isInverted = true

        withObservationTracking {
            _ = slot.model
        } onChange: {
            changed.fulfill()
        }
        _ = slot.model

        wait(for: [changed], timeout: 0.05)
    }

    func testReplaceNotifiesObserversAndDoesNotRebuild() {
        let factory = Factory()
        let slot = LazyModelSlot { factory.make() }
        _ = slot.model
        let other = Probe()
        let changed = expectation(description: "Replacing the model re-renders its reader")

        withObservationTracking {
            _ = slot.model
        } onChange: {
            changed.fulfill()
        }
        slot.replace(with: other)

        wait(for: [changed], timeout: 1)
        XCTAssertTrue(slot.model === other)
        XCTAssertEqual(factory.count, 1)
    }

    /// The PiP adopt path replaces the slot with the instance it already holds.
    func testReplaceWithSameInstanceIsSilent() {
        let slot = LazyModelSlot { Probe() }
        let current = slot.model
        let changed = expectation(description: "Re-adopting the held model must not re-render")
        changed.isInverted = true

        withObservationTracking {
            _ = slot.model
        } onChange: {
            changed.fulfill()
        }
        slot.replace(with: current)

        wait(for: [changed], timeout: 0.05)
        XCTAssertTrue(slot.model === current)
    }
}

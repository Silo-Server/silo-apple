import XCTest
@testable import Silo

/// Pins `PlayerTaskRegistry`'s scope table.
///
/// The hand-maintained cancel lists this table replaced had drifted apart (see
/// the type's header), and the failure mode of a wrong entry — a task swept by
/// the wrong teardown, or never swept at all — is invisible until a user hits a
/// teardown race. So the membership is asserted key by key: a new key that
/// silently joins or misses a sweep fails here.
final class PlayerTaskRegistryTests: XCTestCase {

    /// Transient UI affordances. The only keys `.interaction` may sweep.
    private static let interactionKeys: Set<PlayerTaskRegistry.Key> = [
        .hideControls, .noticeDismiss, .remoteDismiss, .skipDebounce,
        .seekFilterTimeout, .holdSeek, .holdSeekAutoRamp,
    ]

    /// The two keys whose task *is* a teardown, so no sweep may cancel them.
    private static let neverSweptKeys: Set<PlayerTaskRegistry.Key> = [
        .cleanupCompletion, .suspendStopSession,
    ]

    private func keys(in scope: PlayerTaskRegistry.Scope) -> Set<PlayerTaskRegistry.Key> {
        Set(PlayerTaskRegistry.Key.allCases.filter { $0.scopes.contains(scope) })
    }

    func testInteractionSweepsExactlyTheUITimers() {
        XCTAssertEqual(keys(in: .interaction), Self.interactionKeys)
    }

    func testTeardownSweepsEveryKeyExceptTheTwoTeardownsThemselves() {
        XCTAssertEqual(
            keys(in: .teardown),
            Set(PlayerTaskRegistry.Key.allCases).subtracting(Self.neverSweptKeys)
        )
    }

    func testNeverSweptKeysBelongToNoScope() {
        for key in Self.neverSweptKeys {
            XCTAssertTrue(key.scopes.isEmpty, "\(key) must not be swept by any scope")
        }
    }

    func testCancelAllCancelsAndDropsExactlyItsScope() {
        let registry = PlayerTaskRegistry()
        var installed: [PlayerTaskRegistry.Key: Task<Void, Never>] = [:]
        for key in PlayerTaskRegistry.Key.allCases {
            let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 60_000_000_000) }
            installed[key] = task
            registry[key] = task
        }

        registry.cancelAll(in: .interaction)

        for key in PlayerTaskRegistry.Key.allCases {
            let swept = Self.interactionKeys.contains(key)
            XCTAssertEqual(installed[key]?.isCancelled, swept, "\(key) cancellation")
            XCTAssertEqual(registry[key] == nil, swept, "\(key) storage")
        }

        registry.cancelAll(in: .teardown)

        for key in PlayerTaskRegistry.Key.allCases {
            let survives = Self.neverSweptKeys.contains(key)
            XCTAssertEqual(installed[key]?.isCancelled, !survives, "\(key) after teardown")
            XCTAssertEqual(registry[key] != nil, survives, "\(key) storage after teardown")
        }

        for task in installed.values { task.cancel() }
    }
}

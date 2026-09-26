import SwiftUI
import XCTest
@testable import Silo

/// Presenters rebuild `PlayerView(...)` whenever they re-render, and SwiftUI
/// keeps only the first `@State` value. A `PlayerViewModel` built in
/// `PlayerView.init` (an Aether engine, an audio-session claim, a realtime
/// client, observers and a settings fetch) is therefore thrown away on every
/// re-render after the first.
@MainActor
final class PlayerViewModelOwnershipTests: XCTestCase {
    /// The pre-fix shape: `@State` handed a model that `init` already built.
    private struct EagerStateHolder {
        @State var model: PlayerViewModel
    }

    func testInitDoesNotBuildAPlayerViewModel() {
        // Control: the search reaches a model held in `@State` storage, so the
        // assertion below cannot pass just because reflection sees nothing.
        let control = PlayerViewModel()
        defer { control.cleanup() }
        XCTAssertTrue(Self.storesPlayerViewModel(EagerStateHolder(model: control), depth: 3))

        let views = (0..<3).map { _ in PlayerView(contentId: "ownership", libraryId: 7) }

        for view in views {
            XCTAssertFalse(Self.storesPlayerViewModel(view, depth: 3))
        }
    }

    func testMakeViewModelBuildsAFreshScopedModel() {
        let first = PlayerView.makeViewModel(contentId: "x", libraryId: 7, adoptsStagedRestore: true)
        let second = PlayerView.makeViewModel(contentId: "x", libraryId: 7, adoptsStagedRestore: true)
        defer {
            first.cleanup()
            second.cleanup()
        }

        XCTAssertEqual(first.libraryId, 7)
        XCTAssertFalse(first === second)
    }

    #if os(iOS)
    func testMakeViewModelAdoptsTheStagedRestoreWithoutConsumingIt() throws {
        let router = AppRouter()
        router.presentPlayer(contentId: "pip")
        PlayerPresentationRestoration.presenter = router
        let staged = PlayerViewModel()
        var built: [PlayerViewModel] = []
        defer {
            PlayerPresentationRestoration.discardAdoption(for: staged)
            PlayerPresentationRestoration.presenter = nil
            staged.cleanup()
            built.forEach { $0.cleanup() }
        }
        PlayerPresentationRestoration.recordPresentation(try XCTUnwrap(router.presentedPlayer))
        XCTAssertTrue(PlayerPresentationRestoration.reopen(staged))

        XCTAssertTrue(
            PlayerView.makeViewModel(contentId: "pip", libraryId: nil, adoptsStagedRestore: true) === staged
        )
        let otherContent = PlayerView.makeViewModel(
            contentId: "other", libraryId: nil, adoptsStagedRestore: true
        )
        // Watch-party playback: `onAppear` never adopts, so the factory must not.
        let watchParty = PlayerView.makeViewModel(
            contentId: "pip", libraryId: nil, adoptsStagedRestore: false
        )
        built = [otherContent, watchParty]
        XCTAssertFalse(otherContent === staged)
        XCTAssertFalse(watchParty === staged)

        XCTAssertTrue(PlayerPresentationRestoration.consumeAdoption(matching: "pip") === staged)
    }
    #endif

    /// Whether `value` stores a `PlayerViewModel`, directly or through `@State`
    /// storage, optionals and the objects it holds, up to `depth` levels down.
    private static func storesPlayerViewModel(_ value: Any, depth: Int) -> Bool {
        if value is PlayerViewModel { return true }
        guard depth > 0 else { return false }
        return Mirror(reflecting: value).children.contains {
            storesPlayerViewModel($0.value, depth: depth - 1)
        }
    }
}

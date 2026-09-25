import AVFoundation
import XCTest
@testable import Silo

@MainActor
final class ExternalPlaybackPolicyGuardTests: XCTestCase {
    func testWriterAfterAnAwaitCannotReopenForbiddenExternalPlayback() async throws {
        let player = AVPlayer()
        let desired: Bool? = false
        let policyGuard = ExternalPlaybackPolicyGuard { _ in desired }
        policyGuard.bind(to: player)
        XCTAssertFalse(player.allowsExternalPlayback)

        // A single post-publication yield cannot catch a writer this late.
        try await Task.sleep(for: .milliseconds(50))
        player.allowsExternalPlayback = true

        await waitUntil { !player.allowsExternalPlayback }
        XCTAssertFalse(player.allowsExternalPlayback)
    }

    func testImmediateWriterCannotReopenForbiddenExternalPlayback() async {
        let player = AVPlayer()
        let desired: Bool? = false
        let policyGuard = ExternalPlaybackPolicyGuard { _ in desired }
        policyGuard.bind(to: player)

        player.allowsExternalPlayback = true

        await waitUntil { !player.allowsExternalPlayback }
        XCTAssertFalse(player.allowsExternalPlayback)
    }

    func testBackgroundThreadWriterCannotReopenForbiddenExternalPlayback() async {
        let player = AVPlayer()
        let desired: Bool? = false
        let policyGuard = ExternalPlaybackPolicyGuard { _ in desired }
        policyGuard.bind(to: player)

        // KVO runs on the writer's thread, so the correction must hop to the main actor.
        await Task.detached {
            player.allowsExternalPlayback = true
        }.value

        await waitUntil { !player.allowsExternalPlayback }
        XCTAssertFalse(player.allowsExternalPlayback)
    }

    func testExternalScreenFlagIsAlsoEnforced() async throws {
        #if os(iOS)
        let player = AVPlayer()
        let desired: Bool? = false
        let policyGuard = ExternalPlaybackPolicyGuard { _ in desired }
        policyGuard.bind(to: player)
        XCTAssertFalse(player.usesExternalPlaybackWhileExternalScreenIsActive)

        try await Task.sleep(for: .milliseconds(50))
        player.usesExternalPlaybackWhileExternalScreenIsActive = true

        await waitUntil { !player.usesExternalPlaybackWhileExternalScreenIsActive }
        XCTAssertFalse(player.usesExternalPlaybackWhileExternalScreenIsActive)
        #else
        throw XCTSkip("usesExternalPlaybackWhileExternalScreenIsActive is managed on iOS only")
        #endif
    }

    func testDisablingWriterIsNotFoughtWhileAllowed() async throws {
        let player = AVPlayer()
        let desired: Bool? = true
        let policyGuard = ExternalPlaybackPolicyGuard { _ in desired }
        policyGuard.bind(to: player)
        XCTAssertTrue(player.allowsExternalPlayback)

        player.allowsExternalPlayback = false
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(player.allowsExternalPlayback)

        policyGuard.apply()
        XCTAssertTrue(player.allowsExternalPlayback)
    }

    func testPolicyDecliningThePlayerLeavesItUntouched() async throws {
        let player = AVPlayer()
        player.allowsExternalPlayback = false
        let desired: Bool? = nil
        let policyGuard = ExternalPlaybackPolicyGuard { _ in desired }
        policyGuard.bind(to: player)
        XCTAssertFalse(player.allowsExternalPlayback)

        player.allowsExternalPlayback = true
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(player.allowsExternalPlayback)
    }

    func testRebindStopsGuardingThePreviousPlayer() async throws {
        let first = AVPlayer()
        let second = AVPlayer()
        let desired: Bool? = false
        let policyGuard = ExternalPlaybackPolicyGuard { _ in desired }
        policyGuard.bind(to: first)
        XCTAssertFalse(first.allowsExternalPlayback)

        policyGuard.bind(to: second)
        first.allowsExternalPlayback = true
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(first.allowsExternalPlayback)
        XCTAssertFalse(second.allowsExternalPlayback)
    }

    /// Polls `condition` every 10 ms, in case AVPlayer delivers KVO off the
    /// writer's call stack. Returns at once when the condition already holds.
    private func waitUntil(timeout: TimeInterval = 1, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

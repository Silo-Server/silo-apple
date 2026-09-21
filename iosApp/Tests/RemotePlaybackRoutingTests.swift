#if os(iOS)
import XCTest
@testable import Silo

/// Every streaming play on iOS funnels through `AppRouter.presentPlayer`,
/// where one interceptor decides between the engaged TV and the local
/// player. These guard the funnel: an engaged TV takes the request and the
/// local cover never appears; with no TV the cover appears as before; a
/// second Play during the decision cannot slip past it; offline plays
/// prompt instead of silently starting a second player.
@MainActor
final class RemotePlaybackRoutingTests: XCTestCase {
    private func expectEventually(_ label: String, timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for: \(label)")
    }

    func testEngagedTVTakesTheRequestAndNoLocalPlayerAppears() async {
        let router = AppRouter()
        var received: [SiloControlPlaybackRequest] = []
        router.remotePlaybackInterceptor = { request in
            received.append(request)
            return true
        }

        router.presentPlayer(contentId: "c1", fileId: 7, startFromBeginning: false, resumePosition: 120)

        await expectEventually("interceptor called") { received.count == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(router.presentedPlayer)
        XCTAssertEqual(received.first?.contentId, "c1")
        XCTAssertEqual(received.first?.fileId, 7)
        XCTAssertEqual(received.first?.resumePosition, 120)
    }

    func testNoEngagedTVOpensTheLocalPlayer() async {
        let router = AppRouter()
        router.remotePlaybackInterceptor = { _ in false }

        router.presentPlayer(contentId: "c1")

        await expectEventually("local player presented") { router.presentedPlayer?.contentId == "c1" }
    }

    func testWithoutAnInterceptorTheLocalPlayerOpensSynchronously() {
        let router = AppRouter()
        router.presentPlayer(contentId: "c1")
        XCTAssertEqual(router.presentedPlayer?.contentId, "c1")
    }

    func testSecondPlayDuringTheDecisionIsDropped() async {
        let router = AppRouter()
        var calls = 0
        let gate = AsyncGate()
        router.remotePlaybackInterceptor = { _ in
            calls += 1
            await gate.wait()
            return true
        }

        router.presentPlayer(contentId: "first")
        router.presentPlayer(contentId: "second")
        await expectEventually("first decision started") { calls == 1 }
        gate.open()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(calls, 1, "the second tap must not reach the interceptor or the local player")
        XCTAssertNil(router.presentedPlayer)
    }

    func testOfflinePlayPromptsWhileATVIsEngagedAndHonoursTheChoice() async {
        let router = AppRouter()
        var sentToTV: [SiloControlPlaybackRequest] = []
        router.isRemotePlaybackEngaged = { true }
        router.remotePlaybackInterceptor = { request in
            sentToTV.append(request)
            return true
        }

        router.presentOfflinePlayer(downloadId: "d1", contentId: "c1", resumePosition: 30)
        XCTAssertNil(router.presentedPlayer)
        XCTAssertEqual(router.pendingOfflinePlayChoice?.presentation.offlineDownloadId, "d1")

        router.confirmOfflinePlayHere()
        XCTAssertEqual(router.presentedPlayer?.offlineDownloadId, "d1")
        XCTAssertNil(router.pendingOfflinePlayChoice)

        router.presentedPlayer = nil
        router.presentOfflinePlayer(downloadId: "d1", contentId: "c1", resumePosition: 30)
        router.sendPendingOfflinePlayToTV()
        await expectEventually("streamed to TV") { sentToTV.count == 1 }
        XCTAssertEqual(sentToTV.first?.contentId, "c1")
        XCTAssertEqual(sentToTV.first?.resumePosition, 30)
        XCTAssertNil(router.presentedPlayer)
    }

    func testOfflinePlayWithoutATVOpensLocallyWithoutPrompting() {
        let router = AppRouter()
        router.isRemotePlaybackEngaged = { false }
        router.presentOfflinePlayer(downloadId: "d1", contentId: "c1")
        XCTAssertNil(router.pendingOfflinePlayChoice)
        XCTAssertEqual(router.presentedPlayer?.offlineDownloadId, "d1")
    }

    func testPlayingADifferentTitleAsksBeforeReplacingWhatTheTVIsPlaying() async {
        let router = AppRouter()
        var sent: [String] = []
        router.remotePlaybackInterceptor = { request in sent.append(request.contentId); return true }
        router.remotePlaybackCurrentTitle = { (title: "Oak Street", contentId: "oak", targetName: "Living Room") }

        router.presentPlayer(contentId: "miasma")
        XCTAssertEqual(router.pendingReplaceRemotePlayback?.currentTitle, "Oak Street")
        XCTAssertEqual(router.pendingReplaceRemotePlayback?.targetName, "Living Room")
        XCTAssertNil(router.presentedPlayer, "the local player must never open behind the prompt")
        XCTAssertTrue(sent.isEmpty)

        router.confirmReplaceRemotePlayback()
        await expectEventually("sent after confirmation") { sent == ["miasma"] }
        XCTAssertNil(router.pendingReplaceRemotePlayback)
    }

    func testResumingTheSameTitleDoesNotAsk() async {
        let router = AppRouter()
        var sent: [String] = []
        router.remotePlaybackInterceptor = { request in sent.append(request.contentId); return true }
        router.remotePlaybackCurrentTitle = { (title: "Oak Street", contentId: "oak", targetName: "Living Room") }

        router.presentPlayer(contentId: "oak", resumePosition: 90)
        await expectEventually("sent without a prompt") { sent == ["oak"] }
        XCTAssertNil(router.pendingReplaceRemotePlayback)
    }

    func testIdleTVDoesNotAsk() async {
        let router = AppRouter()
        var sent: [String] = []
        router.remotePlaybackInterceptor = { request in sent.append(request.contentId); return true }
        router.remotePlaybackCurrentTitle = { nil }

        router.presentPlayer(contentId: "miasma")
        await expectEventually("sent without a prompt") { sent == ["miasma"] }
        XCTAssertNil(router.pendingReplaceRemotePlayback)
    }

    // MARK: - Engaged predicate

    /// The mode button, mini-bar, and routing all read one predicate. A
    /// fresh client has nothing engaged, and the predicate is what the
    /// legacy per-site `hasActiveSession` checks were replaced with.
    func testFreshClientIsNotEngagedAndLaunchOnEngagedTVDeclines() async {
        let client = SiloControlClient()
        XCTAssertFalse(client.remotePlaybackEngaged)
        let taken = await client.launchOnEngagedTV(SiloControlPlaybackRequest(
            contentId: "c1", fileId: nil, audioTrackIndex: nil, subtitleTrackIndex: nil,
            startFromBeginning: true, resumePosition: nil
        ))
        XCTAssertFalse(taken, "no TV engaged ⇒ the caller may play locally")
        XCTAssertFalse(client.isShowingRemoteControl)
    }
}

@MainActor
private final class AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}
#endif

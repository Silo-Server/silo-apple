import XCTest
@testable import Silo

/// Which quality pair playback asks for on the current connection, and the
/// replan that follows a connection change.
@MainActor
final class PlaybackNetworkQualityTests: XCTestCase {
    private let mainPair = AppleQualityAxes(resolution: "2160p", bitrateKbps: nil)
    private let cellularPair = AppleQualityAxes(resolution: "720p", bitrateKbps: 2_000)

    /// The connection and the player the controller drives.
    private final class FakePlayer {
        var metered = false
        var pairs: [Bool: AppleQualityAxes]
        var outcomes: [PlaybackNetworkQualityController.ReplanOutcome] = []
        private(set) var replans: [AppleQualityAxes] = []

        init(main: AppleQualityAxes, cellular: AppleQualityAxes) {
            pairs = [false: main, true: cellular]
        }

        func replan(_ axes: AppleQualityAxes) -> PlaybackNetworkQualityController.ReplanOutcome {
            replans.append(axes)
            return outcomes.isEmpty ? .issued : outcomes.removeFirst()
        }
    }

    private func makeController(
        debounce: Duration = .milliseconds(20)
    ) -> (PlaybackNetworkQualityController, FakePlayer) {
        let player = FakePlayer(main: mainPair, cellular: cellularPair)
        let controller = PlaybackNetworkQualityController(
            debounce: debounce,
            isMetered: { player.metered },
            pair: { player.pairs[$0]! },
            replan: { player.replan($0) }
        )
        return (controller, player)
    }

    // MARK: - Which pair

    func testMobileDataHotspotsAndLowDataModeUseTheCellularPair() async throws {
        let harness = try PlayerSettingsHarness()
        // A refresh tells the flusher the server's revision, which the
        // cellular keys' writes wait for; the values apply locally at once.
        await harness.settings.refreshFromServer()
        harness.settings.setQualityPreset(try XCTUnwrap(SiloQualityPresets.preset(id: "2160p")))
        harness.settings.setCellularQualityPreset(try XCTUnwrap(SiloQualityPresets.preset(id: "720p")))

        let paths: [(name: String, cellular: Bool, expensive: Bool, constrained: Bool, metered: Bool)] = [
            ("Wi-Fi", false, false, false, false),
            ("mobile data", true, false, false, true),
            ("phone hotspot", false, true, false, true),
            ("Low Data Mode", false, false, true, true),
        ]
        for path in paths {
            let metered = PlaybackNetworkPath.isMetered(
                usesCellular: path.cellular,
                isExpensive: path.expensive,
                isConstrained: path.constrained
            )
            XCTAssertEqual(metered, path.metered, path.name)

            let axes = harness.settings.playbackQualityAxes(onMeteredNetwork: metered)
            #if os(iOS)
            XCTAssertEqual(axes, metered ? cellularPair : mainPair, path.name)
            #else
            // Apple TV and Mac are never on mobile data.
            XCTAssertEqual(axes, mainPair, path.name)
            #endif

            // Sent as stored: the resolution as the preference, the cap as
            // `bandwidth_cap_kbps`.
            let selection = ApplePlaybackQuality.protocolV3Selection(axes: axes)
            XCTAssertEqual(selection.serverPreference, axes.resolution, path.name)
            XCTAssertEqual(selection.bandwidthCapKbps, axes.bitrateKbps, path.name)
            XCTAssertFalse(selection.isServerOwned, path.name)
        }
    }

    func testASettingsPairIsSentExactly() {
        // 1080p at 6 Mbps sits below every 1080p rung of the in-player
        // ladder. The resolution and the cap still go out unchanged.
        let selection = ApplePlaybackQuality.protocolV3Selection(
            axes: AppleQualityAxes(resolution: "1080p", bitrateKbps: 6_000)
        )
        XCTAssertEqual(selection.serverPreference, "1080p")
        XCTAssertEqual(selection.bandwidthCapKbps, 6_000)

        let auto = ApplePlaybackQuality.protocolV3Selection(axes: .auto)
        XCTAssertEqual(auto.serverPreference, "auto")
        XCTAssertNil(auto.bandwidthCapKbps)
        XCTAssertEqual(auto.clientQualityId, ApplePlaybackQuality.autoId)
    }

    // MARK: - In-player Auto and the next episode

    /// Picking Auto in the player hands the choice back to the server and
    /// keeps the saved cap for the connection, or none for "No limit".
    func testAutoPickedInThePlayerKeepsTheSavedCapForTheConnection() async throws {
        let harness = try PlayerSettingsHarness()
        await harness.settings.refreshFromServer()
        harness.settings.setQualityPreset(try XCTUnwrap(SiloQualityPresets.preset(id: "1080p-high")))
        harness.settings.setCellularQualityPreset(try XCTUnwrap(SiloQualityPresets.preset(id: "720p")))

        func autoPick(metered: Bool) -> ApplePlaybackV3QualitySelection {
            ApplePlaybackQuality.protocolV3Selection(
                requestedQualityId: ApplePlaybackQuality.autoId,
                availableQualities: [],
                autoBandwidthCapKbps: harness.settings.playbackQualityAxes(onMeteredNetwork: metered).bitrateKbps
            )
        }

        let wifi = autoPick(metered: false)
        XCTAssertEqual(wifi.serverPreference, "auto")
        XCTAssertEqual(wifi.bandwidthCapKbps, 10_000, "the main pair's cap on Wi-Fi")
        #if os(iOS)
        XCTAssertEqual(autoPick(metered: true).bandwidthCapKbps, 2_000, "the cellular pair's cap on mobile data")
        #endif

        harness.settings.setMaxBitrateKbps(nil)
        XCTAssertNil(autoPick(metered: false).bandwidthCapKbps, "\"No limit\" sends no cap")
    }

    /// A fixed in-player pick applies to its title, reloads included, and
    /// never to the next episode, which starts on the saved settings for the
    /// connection. Picking Auto is not such a pick.
    func testAnInPlayerPickAppliesToItsTitleOnly() {
        let model = PlayerViewModel()
        defer { model.cleanup() }

        model.recordViewerQualityPick("720p", forContentId: "episode-1")
        XCTAssertTrue(model.viewerQualityPickApplies(toContentId: "episode-1"), "a reload keeps it")
        XCTAssertFalse(model.viewerQualityPickApplies(toContentId: "episode-2"), "the next episode does not")

        // With no override, the next episode asks for the saved pair as
        // stored: no cap fabricated from the played source.
        var start = PlaybackSessionBridge.startQuality(
            preferredQualityOverride: nil,
            lastUsedResolution: nil,
            settingsQuality: .auto
        )
        XCTAssertNil(start.preferredQuality, "Auto")
        XCTAssertNil(start.bandwidthCapKbps)
        start = PlaybackSessionBridge.startQuality(
            preferredQualityOverride: nil,
            lastUsedResolution: nil,
            settingsQuality: cellularPair
        )
        XCTAssertEqual(start.preferredQuality, "720p")
        XCTAssertEqual(start.bandwidthCapKbps, 2_000)

        // A reload of the picked title keeps the rung and its own cap.
        start = PlaybackSessionBridge.startQuality(
            preferredQualityOverride: "720p",
            lastUsedResolution: nil,
            settingsQuality: .auto
        )
        XCTAssertEqual(start.preferredQuality, "720p")
        XCTAssertEqual(start.bandwidthCapKbps, 2_000)

        model.recordViewerQualityPick(ApplePlaybackQuality.autoId, forContentId: "episode-1")
        XCTAssertFalse(model.viewerQualityPickApplies(toContentId: "episode-1"), "Auto follows the saved settings")
        // A reload after an Auto pick keeps Auto with the saved cap.
        start = PlaybackSessionBridge.startQuality(
            preferredQualityOverride: ApplePlaybackQuality.autoId,
            lastUsedResolution: nil,
            settingsQuality: AppleQualityAxes(resolution: "1080p", bitrateKbps: 20_000)
        )
        XCTAssertEqual(start.preferredQuality, ApplePlaybackQuality.autoId)
        XCTAssertEqual(start.bandwidthCapKbps, 20_000)
    }

    /// Auto lights only while the session's preference is auto, a fixed rung
    /// only when the viewer picked it, and a fixed saved resolution lights
    /// nothing, even beside a rung of the same name, so Auto stays a choice.
    func testTheMenuLightsAutoOnlyForAnAutoPreference() {
        let model = PlayerViewModel()
        defer { model.cleanup() }

        model.activeQualityId = ApplePlaybackQuality.autoId
        XCTAssertEqual(model.highlightedQualityOptionId, ApplePlaybackQuality.autoId)

        // Saved 1080p, source plays as-is: the session's id is the saved rung.
        model.activeQualityId = "1080p-high"
        XCTAssertNil(model.highlightedQualityOptionId)
        model.activeQualityId = "720p"
        XCTAssertNil(model.highlightedQualityOptionId, "a saved 720p does not light the plan's 720p row")

        model.recordViewerQualityPick("720p", forContentId: "episode-1")
        XCTAssertEqual(model.highlightedQualityOptionId, "720p", "the rung the viewer picked lights")
    }

    // MARK: - Replanning on a connection change    // MARK: - Replanning on a connection change

    func testMovingOntoAndOffMobileDataReplansWithThatSidesPair() {
        let (controller, player) = makeController()
        controller.sessionStarted(onMeteredNetwork: false, keepsViewerPick: false)

        player.metered = true
        controller.checkConnection()
        XCTAssertEqual(player.replans, [cellularPair])
        XCTAssertEqual(controller.sessionUsesMeteredPair, true)

        // The same connection again changes nothing.
        controller.checkConnection()
        XCTAssertEqual(player.replans, [cellularPair])

        player.metered = false
        controller.checkConnection()
        XCTAssertEqual(player.replans, [cellularPair, mainPair])
        XCTAssertEqual(controller.sessionUsesMeteredPair, false)
    }

    func testAFixedRungTheViewerPickedHoldsForItsTitle() {
        let (controller, player) = makeController()
        controller.sessionStarted(onMeteredNetwork: false, keepsViewerPick: false)
        controller.viewerDidPickQuality()

        player.metered = true
        controller.connectionDidChange()
        XCTAssertFalse(controller.hasPendingCheck, "nothing waits to override the viewer's choice")
        controller.checkConnection()
        XCTAssertTrue(player.replans.isEmpty)

        // A reload of the same title keeps the pick.
        controller.sessionStarted(onMeteredNetwork: false, keepsViewerPick: true)
        controller.checkConnection()
        XCTAssertTrue(player.replans.isEmpty)

        // The next title starts on the saved settings and follows the
        // connection again.
        controller.sessionStarted(onMeteredNetwork: false, keepsViewerPick: false)
        controller.checkConnection()
        XCTAssertEqual(player.replans, [cellularPair])
    }

    func testPickingAutoKeepsFollowingTheConnection() {
        let (controller, player) = makeController()
        controller.sessionStarted(onMeteredNetwork: false, keepsViewerPick: false)
        controller.viewerDidPickQuality()
        controller.viewerDidPickAuto(onMeteredNetwork: false)
        XCTAssertFalse(controller.viewerPickedQuality)

        player.metered = true
        controller.checkConnection()
        XCTAssertEqual(player.replans, [cellularPair])

        // Auto picked after moving onto mobile data already uses that side's
        // cap, so the pending change has nothing left to reload.
        let (other, otherPlayer) = makeController()
        other.sessionStarted(onMeteredNetwork: false, keepsViewerPick: false)
        otherPlayer.metered = true
        other.viewerDidPickAuto(onMeteredNetwork: true)
        other.checkConnection()
        XCTAssertTrue(otherPlayer.replans.isEmpty)
        XCTAssertEqual(other.sessionUsesMeteredPair, true)
    }

    func testAChangeIsFollowedOnlyOnceItHolds() async throws {
        let (controller, player) = makeController()
        controller.sessionStarted(onMeteredNetwork: false, keepsViewerPick: false)

        // A flap that comes back inside the wait reloads nothing.
        player.metered = true
        controller.connectionDidChange()
        player.metered = false
        controller.connectionDidChange()
        try await waitUntil("the flap's check runs") { !controller.hasPendingCheck }
        XCTAssertTrue(player.replans.isEmpty)

        // Two reports of one change reload once.
        player.metered = true
        controller.connectionDidChange()
        controller.connectionDidChange()
        try await waitUntil("the change's check runs") { !controller.hasPendingCheck }
        XCTAssertEqual(player.replans, [cellularPair])
    }

    func testPairsThatMatchNeedNoReplan() {
        let (controller, player) = makeController()
        player.pairs[true] = mainPair
        controller.sessionStarted(onMeteredNetwork: false, keepsViewerPick: false)

        player.metered = true
        controller.checkConnection()

        XCTAssertTrue(player.replans.isEmpty)
        XCTAssertEqual(controller.sessionUsesMeteredPair, true)
    }

    func testABusyPlayerIsAskedAgainAfterTheWait() async throws {
        let (controller, player) = makeController()
        controller.sessionStarted(onMeteredNetwork: false, keepsViewerPick: false)
        player.outcomes = [.busy]

        player.metered = true
        controller.checkConnection()
        XCTAssertEqual(controller.sessionUsesMeteredPair, false, "nothing was replanned yet")

        try await waitUntil("the retry replans") { player.replans.count == 2 }
        XCTAssertEqual(player.replans, [cellularPair, cellularPair])
        XCTAssertEqual(controller.sessionUsesMeteredPair, true)
    }

    func testWithNoSessionNothingIsReplanned() {
        let (controller, player) = makeController()
        player.metered = true
        controller.connectionDidChange()
        controller.checkConnection()
        XCTAssertFalse(controller.hasPendingCheck)
        XCTAssertTrue(player.replans.isEmpty)

        // A Watch Party stops the controller for its session.
        controller.sessionStarted(onMeteredNetwork: false, keepsViewerPick: false)
        controller.stop()
        controller.checkConnection()
        XCTAssertTrue(player.replans.isEmpty)
    }
}

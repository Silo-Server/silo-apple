import XCTest
@testable import Silo

/// Which quality pair playback asks for on the current connection, and the
/// replan that follows a connection change.
@MainActor
final class PlaybackNetworkQualityTests: XCTestCase {
    private let mainPair = AppleQualityAxes(resolution: "2160p", bitrateKbps: nil)
    private let cellularPair = AppleQualityAxes(resolution: "auto", bitrateKbps: 10_000)
    private let lowDataPair = AppleQualityAxes(resolution: "auto", bitrateKbps: 2_000)

    /// The connection and the player the controller drives.
    private final class FakePlayer {
        var tier: PlaybackNetworkTier = .unmetered
        var pairs: [PlaybackNetworkTier: AppleQualityAxes]
        var outcomes: [PlaybackNetworkQualityController.ReplanOutcome] = []
        private(set) var replans: [AppleQualityAxes] = []

        init(main: AppleQualityAxes, cellular: AppleQualityAxes, lowData: AppleQualityAxes) {
            pairs = [.unmetered: main, .metered: cellular, .lowData: lowData]
        }

        func replan(_ axes: AppleQualityAxes) -> PlaybackNetworkQualityController.ReplanOutcome {
            replans.append(axes)
            return outcomes.isEmpty ? .issued : outcomes.removeFirst()
        }
    }

    private func makeController(
        debounce: Duration = .milliseconds(20)
    ) -> (PlaybackNetworkQualityController, FakePlayer) {
        let player = FakePlayer(main: mainPair, cellular: cellularPair, lowData: lowDataPair)
        let controller = PlaybackNetworkQualityController(
            debounce: debounce,
            tier: { player.tier },
            pair: { player.pairs[$0]! },
            replan: { player.replan($0) }
        )
        return (controller, player)
    }

    // MARK: - Which pair

    func testMobileDataHotspotsAndLowDataModeUseTheRightTierAndCeiling() async throws {
        let harness = try PlayerSettingsHarness()
        // A refresh tells the flusher the server's revision, which the
        // cellular keys' writes wait for; the values apply locally at once.
        await harness.settings.refreshFromServer()
        harness.settings.setQualityPreset(try XCTUnwrap(SiloQualityPresets.preset(id: "2160p")))
        harness.settings.setCellularQualityPreset(try XCTUnwrap(SiloQualityPresets.preset(id: "auto-10mbps")))

        let paths: [(name: String, cellular: Bool, expensive: Bool, constrained: Bool, tier: PlaybackNetworkTier, expected: AppleQualityAxes)] = [
            ("Wi-Fi", false, false, false, .unmetered, mainPair),
            ("mobile data", true, false, false, .metered, cellularPair),
            ("phone hotspot", false, true, false, .metered, cellularPair),
            ("Low Data Mode on Wi-Fi", false, false, true, .lowData, lowDataPair),
            ("Low Data Mode on cellular", true, true, true, .lowData, lowDataPair),
        ]
        for path in paths {
            let tier = PlaybackNetworkPath.tier(
                usesCellular: path.cellular,
                isExpensive: path.expensive,
                isConstrained: path.constrained
            )
            XCTAssertEqual(tier, path.tier, path.name)
            XCTAssertEqual(
                PlaybackNetworkPath.isMetered(usesCellular: path.cellular, isExpensive: path.expensive, isConstrained: path.constrained),
                path.tier.isMetered,
                path.name
            )

            let axes = harness.settings.playbackQualityAxes(for: tier)
            #if os(iOS)
            XCTAssertEqual(axes, path.expected, path.name)
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

        #if os(iOS)
        // Low Data Mode caps an uncapped cellular override to 2 Mbps without changing resolution.
        harness.settings.setCellularQualityPreset(try XCTUnwrap(SiloQualityPresets.preset(id: "auto")))
        XCTAssertEqual(harness.settings.playbackQualityAxes(for: .metered), .auto)
        XCTAssertEqual(harness.settings.playbackQualityAxes(for: .lowData), AppleQualityAxes(resolution: "auto", bitrateKbps: 2_000))

        // A stricter cellular override (480p / 1.5 Mbps) is never raised by Low Data Mode.
        harness.settings.setCellularQualityPreset(try XCTUnwrap(SiloQualityPresets.preset(id: "480p")))
        XCTAssertEqual(harness.settings.playbackQualityAxes(for: .lowData), AppleQualityAxes(resolution: "480p", bitrateKbps: 1_500))
        #endif
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
        harness.settings.setCellularQualityPreset(try XCTUnwrap(SiloQualityPresets.preset(id: "auto-10mbps")))

        func autoPick(tier: PlaybackNetworkTier) -> ApplePlaybackV3QualitySelection {
            ApplePlaybackQuality.protocolV3Selection(
                requestedQualityId: ApplePlaybackQuality.autoId,
                availableQualities: [],
                autoBandwidthCapKbps: harness.settings.playbackQualityAxes(for: tier).bitrateKbps
            )
        }

        let wifi = autoPick(tier: .unmetered)
        XCTAssertEqual(wifi.serverPreference, "auto")
        XCTAssertEqual(wifi.bandwidthCapKbps, 10_000, "the main pair's cap on Wi-Fi")
        #if os(iOS)
        XCTAssertEqual(autoPick(tier: .metered).bandwidthCapKbps, 10_000, "the cellular pair's cap on mobile data")
        XCTAssertEqual(autoPick(tier: .lowData).bandwidthCapKbps, 2_000, "Low Data Mode ceiling")
        #endif

        harness.settings.setMaxBitrateKbps(nil)
        XCTAssertNil(autoPick(tier: .unmetered).bandwidthCapKbps, "\"No limit\" sends no cap")
    }

    /// A fixed in-player pick applies to its title, reloads included, and
    /// never to the next episode, which starts on the saved settings for the
    /// connection. Picking Auto is not such a pick.
    func testAnInPlayerPickAppliesToItsTitleOnly() {
        let model = PlayerViewModel()
        defer { model.cleanup() }

        model.recordViewerQualityPick("720p", forContentId: "episode-1", networkTier: .unmetered)
        XCTAssertTrue(model.viewerQualityPickApplies(toContentId: "episode-1"), "a reload keeps it")
        XCTAssertFalse(model.viewerQualityPickApplies(toContentId: "episode-2"), "the next episode does not")

        // With no override, the next episode asks for the saved pair as
        // stored: no cap fabricated from the played source.
        var start = PlaybackSessionBridge.startQuality(
            preferredQualityOverride: nil,
            settingsQuality: .auto
        )
        XCTAssertNil(start.preferredQuality, "Auto")
        XCTAssertNil(start.bandwidthCapKbps)
        start = PlaybackSessionBridge.startQuality(
            preferredQualityOverride: nil,
            settingsQuality: AppleQualityAxes(resolution: "720p", bitrateKbps: 2_000)
        )
        XCTAssertEqual(start.preferredQuality, "720p")
        XCTAssertEqual(start.bandwidthCapKbps, 2_000)

        // A reload of the picked title keeps the rung and its own cap.
        start = PlaybackSessionBridge.startQuality(
            preferredQualityOverride: "720p",
            settingsQuality: .auto
        )
        XCTAssertEqual(start.preferredQuality, "720p")
        XCTAssertEqual(start.bandwidthCapKbps, 2_000)

        model.recordViewerQualityPick(ApplePlaybackQuality.autoId, forContentId: "episode-1", networkTier: .unmetered)
        XCTAssertFalse(model.viewerQualityPickApplies(toContentId: "episode-1"), "Auto follows the saved settings")
        // A reload after an Auto pick keeps Auto with the saved cap.
        start = PlaybackSessionBridge.startQuality(
            preferredQualityOverride: ApplePlaybackQuality.autoId,
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
        model.qualityOptions = ApplePlaybackQuality.playbackOptions(serverQualities: [
            PlaybackV3AvailableQuality(label: "1080p-high", displayName: "1080p High", height: 1080, bitrateKbps: 10_000, preservesSource: false),
            PlaybackV3AvailableQuality(label: "720p", displayName: "720p", height: 720, bitrateKbps: 2_000, preservesSource: false),
        ])

        model.activeQualityId = ApplePlaybackQuality.autoId
        XCTAssertEqual(model.highlightedQualityOptionId, ApplePlaybackQuality.autoId)

        // Saved 1080p, source plays as-is: the session's id is the saved rung.
        model.activeQualityId = "1080p-high"
        XCTAssertNil(model.highlightedQualityOptionId)
        model.activeQualityId = "720p"
        XCTAssertNil(model.highlightedQualityOptionId, "a saved 720p does not light the plan's 720p row")

        model.recordViewerQualityPick("720p", forContentId: "episode-1", networkTier: .unmetered)
        XCTAssertEqual(model.highlightedQualityOptionId, "720p", "the rung the viewer picked lights")
    }

    /// With `plan_active_quality_v1` the server names the row: a saved
    /// setting lights the rung the plan delivers, Auto still lights only for
    /// an auto preference, and a local id that shares a server rung's name
    /// lights nothing when the server names no row.
    func testTheServerNamesTheLitRow() {
        let options = ApplePlaybackQuality.playbackOptions(serverQualities: [
            PlaybackV3AvailableQuality(label: "1080p-medium", displayName: "1080p Medium", height: 1080, bitrateKbps: 6_000, preservesSource: false),
            PlaybackV3AvailableQuality(label: "1080p-low", displayName: "1080p Low", height: 1080, bitrateKbps: 3_000, preservesSource: false),
            PlaybackV3AvailableQuality(label: "720p-medium", displayName: "720p Medium", height: 720, bitrateKbps: 2_000, preservesSource: false),
        ])
        func lit(_ session: String, server: String?, reports: Bool = true, pick: String? = nil) -> String? {
            ApplePlaybackQuality.highlightedOptionId(
                sessionQualityId: session,
                viewerPickId: pick,
                planActiveQuality: server,
                planReportsActiveQuality: reports,
                options: options
            )
        }

        // Saved 1080p at 3 Mbps joins as the local 8 Mbps rung.
        XCTAssertEqual(lit("1080p-8", server: "1080p-low"), "1080p-low")
        XCTAssertEqual(lit("1080p-8", server: "720p-medium"), "720p-medium", "a cap the server held to 720p")
        XCTAssertNil(lit("1080p-8", server: nil), "the source plays, or an encode between rungs")
        XCTAssertNil(lit("1080p-medium", server: nil), "Apple's 12 Mbps 1080p-medium is not the server's")
        XCTAssertNil(lit("1080p-8", server: "480p"), "a row the menu doesn't list")
        XCTAssertEqual(lit(ApplePlaybackQuality.autoId, server: "720p-medium"), ApplePlaybackQuality.autoId)

        // An older server says nothing: only the viewer's own pick lights.
        XCTAssertNil(lit("1080p-medium", server: nil, reports: false))
        XCTAssertEqual(lit("720p-medium", server: nil, reports: false, pick: "720p-medium"), "720p-medium")
    }

    func testThePlanDecodesItsActiveQuality() throws {
        var object = try PlaybackV3FixtureTestSupport.v2DecisionObject(bundleClass: Self.self)
        var plan = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        XCTAssertNil(try PlaybackV3FixtureTestSupport.v2Plan(plan).activeQuality)
        plan["active_quality"] = "1080p-low"
        object["playback_plan"] = plan
        XCTAssertEqual(try PlaybackV3FixtureTestSupport.v2Decision(object).playbackPlan?.activeQuality, "1080p-low")
    }

    /// One quality switch at a time: a pick while one is in flight is ignored
    /// rather than racing it and clearing its state. (Without the guard this
    /// model, with no session, would end the switch with an error.)
    func testAPickDuringAnInFlightSwitchIsIgnored() {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        model.isQualitySwitching = true
        model.switchQuality("720p")
        XCTAssertTrue(model.isQualitySwitching, "the first switch still owns the state")
        XCTAssertNil(model.qualitySwitchError)
    }

    // MARK: - Resume and hand-picked versions

    private static let versions = [version(1, "2160p"), version(2, "1080p")]

    private static func version(_ fileId: Int, _ resolution: String) -> FileVersion {
        FileVersion(
            fileId: fileId,
            fileName: "version-\(fileId).mkv",
            resolution: resolution,
            codecVideo: "h264",
            codecAudio: "aac",
            hdr: false,
            container: "mkv",
            fileSize: 1_000,
            duration: 120,
            bitrate: 8_000_000,
            videoTracks: nil,
            audioTracks: nil,
            subtitleTracks: nil,
            chapters: nil,
            effectiveAudioTrackIndex: nil,
            effectiveAudioLanguage: nil
        )
    }

    private func start(
        requestedFileId: Int? = nil,
        pinsVersion: Bool = false,
        lastFileId: Int? = 2,
        resuming: Bool,
        override: String? = nil,
        settings: AppleQualityAxes
    ) -> PlaybackSessionBridge.StartSelection {
        PlaybackSessionBridge.startSelection(
            versions: Self.versions,
            requestedFileId: requestedFileId,
            lastFileId: lastFileId,
            lastFileInProgress: false,
            prefersLastUsedVersion: resuming,
            pinsRequestedVersion: pinsVersion,
            startsAtFirstPart: false,
            preferredQualityOverride: override,
            settingsQuality: settings
        )
    }

    /// Resuming from Continue Watching plays the last-played file but asks
    /// for the saved quality, not that file's resolution, so Auto still
    /// follows the connection and the menu lights Auto.
    func testAResumePlaysTheLastFileAtTheSavedQuality() {
        var resumed = start(resuming: true, settings: .auto)
        XCTAssertEqual(resumed.version.fileId, 2)
        XCTAssertEqual(resumed.source, .lastUsed)
        XCTAssertNil(resumed.qualityPreference, "Auto, not the file's 1080p")
        XCTAssertNil(resumed.bandwidthCapKbps)

        let model = PlayerViewModel()
        defer { model.cleanup() }
        model.activeQualityId = ApplePlaybackQuality.protocolV3QualityId(resumed.qualityPreference)
        XCTAssertEqual(model.highlightedQualityOptionId, ApplePlaybackQuality.autoId)

        // On mobile data the resume asks for the cellular pair.
        resumed = start(resuming: true, settings: cellularPair)
        XCTAssertEqual(resumed.version.fileId, 2)
        XCTAssertNil(resumed.qualityPreference, "Auto")
        XCTAssertEqual(resumed.bandwidthCapKbps, 10_000)
    }

    /// A version picked by hand plays that file; the saved quality still
    /// caps it, and an in-player pick carried to a reload still wins.
    func testAHandPickedVersionPlaysAtTheSavedQuality() {
        var picked = start(requestedFileId: 1, resuming: false, settings: .auto)
        XCTAssertEqual(picked.version.fileId, 1)
        XCTAssertEqual(picked.source, .requested)
        XCTAssertNil(picked.qualityPreference, "Auto, not the file's 2160p")

        picked = start(requestedFileId: 1, resuming: false, settings: cellularPair)
        XCTAssertEqual(picked.version.fileId, 1)
        XCTAssertNil(picked.qualityPreference)
        XCTAssertEqual(picked.bandwidthCapKbps, 10_000)

        picked = start(requestedFileId: 1, resuming: true, override: "1080p", settings: .auto)
        XCTAssertEqual(picked.version.fileId, 1, "the requested file wins over the last-played one")
        XCTAssertEqual(picked.qualityPreference, "1080p")
    }

    /// Only a version the viewer picked, while it is the file starting,
    /// keeps that file for the attempt (`allow_alternate_versions` false), so
    /// the server cannot swap in a lower version for Auto's budget. Any other
    /// start leaves the server free to.
    func testOnlyAPickedVersionKeepsItsFile() {
        let rows: [(name: String, requested: Int?, picked: Bool, resuming: Bool, keeps: Bool)] = [
            ("picked version", 1, true, false, true),
            ("picked version on a resume", 1, true, true, true),
            ("picked file is gone, a ranked one starts", 99, true, false, false),
            ("file sent only for a track pick", 1, false, false, false),
            ("default play", nil, false, false, false),
            ("Continue Watching's last-played file", nil, false, true, false),
        ]
        for row in rows {
            let selection = start(
                requestedFileId: row.requested,
                pinsVersion: row.picked,
                resuming: row.resuming,
                settings: .auto
            )
            XCTAssertEqual(selection.keepsVersion, row.keeps, row.name)
        }
    }

    /// When the last-played file is gone, a resume falls back to Auto for
    /// the saved quality, as a fresh start does, not to the resolution it
    /// last played.
    func testAResumeWhoseFileIsGoneFallsBackToAuto() {
        let resumed = start(lastFileId: 99, resuming: true, settings: .auto)
        XCTAssertEqual(resumed.version.fileId, 1)
        XCTAssertEqual(resumed.source, .ranked)
        XCTAssertNil(resumed.qualityPreference)
    }

    // MARK: - Replanning on a connection change

    func testMovingOntoAndOffMobileDataAndLowDataModeReplansWithThatTiersPair() {
        let (controller, player) = makeController()
        controller.sessionStarted(tier: .unmetered, keepsViewerPick: false)

        player.tier = .metered
        controller.checkConnection()
        XCTAssertEqual(player.replans, [cellularPair])
        XCTAssertEqual(controller.sessionTier, .metered)

        // The same connection again changes nothing.
        controller.checkConnection()
        XCTAssertEqual(player.replans, [cellularPair])

        // Enabling Low Data Mode tightens to 2 Mbps.
        player.tier = .lowData
        controller.checkConnection()
        XCTAssertEqual(player.replans, [cellularPair, lowDataPair])
        XCTAssertEqual(controller.sessionTier, .lowData)

        // Turning Low Data Mode off returns to 10 Mbps cellular.
        player.tier = .metered
        controller.checkConnection()
        XCTAssertEqual(player.replans, [cellularPair, lowDataPair, cellularPair])
        XCTAssertEqual(controller.sessionTier, .metered)

        player.tier = .unmetered
        controller.checkConnection()
        XCTAssertEqual(player.replans, [cellularPair, lowDataPair, cellularPair, mainPair])
        XCTAssertEqual(controller.sessionTier, .unmetered)
    }

    func testAFixedRungTheViewerPickedHoldsForItsTitle() {
        let (controller, player) = makeController()
        controller.sessionStarted(tier: .unmetered, keepsViewerPick: false)
        controller.viewerDidPickQuality()

        player.tier = .metered
        controller.connectionDidChange()
        XCTAssertFalse(controller.hasPendingCheck, "nothing waits to override the viewer's choice")
        controller.checkConnection()
        XCTAssertTrue(player.replans.isEmpty)

        // A reload of the same title keeps the pick.
        controller.sessionStarted(tier: .unmetered, keepsViewerPick: true)
        controller.checkConnection()
        XCTAssertTrue(player.replans.isEmpty)

        // The next title starts on the saved settings and follows the
        // connection again.
        controller.sessionStarted(tier: .unmetered, keepsViewerPick: false)
        controller.checkConnection()
        XCTAssertEqual(player.replans, [cellularPair])
    }

    /// An Auto pick records the tier of the connection its request was built
    /// for, not the live one, so a change while the request was out is still
    /// corrected by the next check.
    func testAnAutoPickRecordsTheConnectionItsRequestWasBuiltFor() throws {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        let modelController = try XCTUnwrap(model.networkQuality)
        modelController.sessionStarted(tier: .unmetered, keepsViewerPick: false)
        model.recordViewerQualityPick(ApplePlaybackQuality.autoId, forContentId: "movie", networkTier: .metered)
        XCTAssertEqual(modelController.sessionTier, .metered)
        model.recordViewerQualityPick(ApplePlaybackQuality.autoId, forContentId: "movie", networkTier: .lowData)
        XCTAssertEqual(modelController.sessionTier, .lowData)
        model.recordViewerQualityPick(ApplePlaybackQuality.autoId, forContentId: "movie", networkTier: .unmetered)
        XCTAssertEqual(modelController.sessionTier, .unmetered)

        // Wi-Fi when the request was built, mobile data when it committed.
        let (controller, player) = makeController()
        controller.sessionStarted(tier: .unmetered, keepsViewerPick: false)
        player.tier = .metered
        controller.viewerDidPickAuto(tier: .unmetered)
        controller.checkConnection()
        XCTAssertEqual(player.replans, [cellularPair])
    }

    /// A change that lands while the first load is still starting waits and
    /// is checked again rather than being dropped.
    func testAConnectionChangeDuringStartupWaits() {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        model.isLoading = true
        XCTAssertEqual(model.replanForConnectionChange(cellularPair), .busy)
        model.isLoading = false
        XCTAssertEqual(model.replanForConnectionChange(cellularPair), .unavailable, "no session to replan")
    }

    func testPickingAutoKeepsFollowingTheConnection() {
        let (controller, player) = makeController()
        controller.sessionStarted(tier: .unmetered, keepsViewerPick: false)
        controller.viewerDidPickQuality()
        controller.viewerDidPickAuto(tier: .unmetered)
        XCTAssertFalse(controller.viewerPickedQuality)

        player.tier = .metered
        controller.checkConnection()
        XCTAssertEqual(player.replans, [cellularPair])

        // Auto picked after moving onto mobile data already uses that tier's
        // cap, so the pending change has nothing left to reload.
        let (other, otherPlayer) = makeController()
        other.sessionStarted(tier: .unmetered, keepsViewerPick: false)
        otherPlayer.tier = .metered
        other.viewerDidPickAuto(tier: .metered)
        other.checkConnection()
        XCTAssertTrue(otherPlayer.replans.isEmpty)
        XCTAssertEqual(other.sessionTier, .metered)
    }

    func testAChangeIsFollowedOnlyOnceItHolds() async throws {
        let (controller, player) = makeController()
        controller.sessionStarted(tier: .unmetered, keepsViewerPick: false)

        // A flap that comes back inside the wait reloads nothing.
        player.tier = .metered
        controller.connectionDidChange()
        player.tier = .unmetered
        controller.connectionDidChange()
        try await waitUntil("the flap's check runs") { !controller.hasPendingCheck }
        XCTAssertTrue(player.replans.isEmpty)

        // Two reports of one change reload once.
        player.tier = .metered
        controller.connectionDidChange()
        controller.connectionDidChange()
        try await waitUntil("the change's check runs") { !controller.hasPendingCheck }
        XCTAssertEqual(player.replans, [cellularPair])
    }

    /// Wi-Fi Assist or a roam between access points can put the phone's path
    /// on cellular for several seconds while Wi-Fi stays connected. Each
    /// follow is a full reload, so a blip of that length must reload nothing.
    func testABlipOfSeveralSecondsReloadsNothing() async throws {
        let player = FakePlayer(main: mainPair, cellular: cellularPair, lowData: lowDataPair)
        let controller = PlaybackNetworkQualityController(
            tier: { player.tier },
            pair: { player.pairs[$0]! },
            replan: { player.replan($0) }
        )
        defer { controller.stop() }
        controller.sessionStarted(tier: .unmetered, keepsViewerPick: false)

        player.tier = .metered
        controller.connectionDidChange()
        try await Task.sleep(for: .seconds(5))
        XCTAssertTrue(player.replans.isEmpty, "a five-second blip did not hold long enough to follow")
        XCTAssertTrue(controller.hasPendingCheck)

        player.tier = .unmetered
        controller.connectionDidChange()
        XCTAssertTrue(player.replans.isEmpty)
    }

    func testPairsThatMatchNeedNoReplan() {
        let (controller, player) = makeController()
        player.pairs[.metered] = mainPair
        controller.sessionStarted(tier: .unmetered, keepsViewerPick: false)

        player.tier = .metered
        controller.checkConnection()

        XCTAssertTrue(player.replans.isEmpty)
        XCTAssertEqual(controller.sessionTier, .metered)
    }

    func testABusyPlayerIsAskedAgainAfterTheWait() async throws {
        let (controller, player) = makeController()
        controller.sessionStarted(tier: .unmetered, keepsViewerPick: false)
        player.outcomes = [.busy]

        player.tier = .metered
        controller.checkConnection()
        XCTAssertEqual(controller.sessionTier, .unmetered, "nothing was replanned yet")

        try await waitUntil("the retry replans") { player.replans.count == 2 }
        XCTAssertEqual(player.replans, [cellularPair, cellularPair])
        XCTAssertEqual(controller.sessionTier, .metered)
    }

    func testWithNoSessionNothingIsReplanned() {
        let (controller, player) = makeController()
        player.tier = .metered
        controller.connectionDidChange()
        controller.checkConnection()
        XCTAssertFalse(controller.hasPendingCheck)
        XCTAssertTrue(player.replans.isEmpty)

        // A Watch Party stops the controller for its session.
        controller.sessionStarted(tier: .unmetered, keepsViewerPick: false)
        controller.stop()
        controller.checkConnection()
        XCTAssertTrue(player.replans.isEmpty)
    }
}

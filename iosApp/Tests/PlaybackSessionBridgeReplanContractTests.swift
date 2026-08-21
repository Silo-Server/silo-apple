import Foundation
import XCTest
@testable import Silo

/// Stage-0 characterization: the three pure predicates `PlaybackSessionBridge`
/// uses to decide what a replan *is* — which protocol operation it carries,
/// whether a renewed direct session may be swapped in underneath the running
/// player, and whether an output-route notification is material at all.
///
/// All three are `static` and side-effect free, so they can be pinned without
/// standing up the bridge actor. The plan pairs are built by mutating the
/// vendored golden `decision_response.json`, so the shapes stay the server's.
final class PlaybackSessionBridgeReplanContractTests: XCTestCase {

    // MARK: - replanOperation totality

    /// Every classification any call site can produce, in one place: the five
    /// the string classifier emits, the three local route-failure tokens, the
    /// output-route token, the seek token, and the three intent tokens.
    private static let everyClassification: [String] = [
        // PlayerViewModel.protocolV3FailureClassification outputs
        "decoder_error",
        "unsupported_stream",
        "network_degraded",
        "source_unavailable",
        "playback_error",
        // Local route-failure classifications (PlayerViewModel)
        "native_direct_avplayer_failed",
        "silo_loopback_failed",
        "direct_source_unplayable",
        // Lifecycle classifications
        "output_route_changed",
        "seek_reanchor",
        // Intents
        "audio_track_changed",
        "subtitle_track_changed",
        "quality_changed"
    ]

    func testReplanOperationIsTotalAndOnlyIntentsLeaveFailureRecovery() {
        let intents: [String: String] = [
            "audio_track_changed": PlaybackProtocolV3.ReplanOperation.trackChange,
            "subtitle_track_changed": PlaybackProtocolV3.ReplanOperation.trackChange,
            "quality_changed": PlaybackProtocolV3.ReplanOperation.qualityChange
        ]
        let known: Set<String> = [
            PlaybackProtocolV3.ReplanOperation.failureRecovery,
            PlaybackProtocolV3.ReplanOperation.seekReanchor,
            PlaybackProtocolV3.ReplanOperation.seekFailureRecovery,
            PlaybackProtocolV3.ReplanOperation.trackChange,
            PlaybackProtocolV3.ReplanOperation.qualityChange
        ]

        for classification in Self.everyClassification {
            let operation = PlaybackSessionBridge.replanOperation(
                forClassification: classification
            )
            XCTAssertTrue(
                known.contains(operation),
                "\(classification) produced an unknown operation \(operation)"
            )
            XCTAssertEqual(
                operation,
                intents[classification] ?? PlaybackProtocolV3.ReplanOperation.failureRecovery,
                "classification=\(classification)"
            )
        }
    }

    /// PIN: current behavior. The mapping is a default-to-failure switch, so
    /// one operation the protocol defines is unreachable through it — a seek
    /// reanchor only becomes `seek_reanchor` because the call site passes the
    /// operation explicitly. `output_route_changed` files as failure recovery
    /// whenever the server has not advertised `output_change_v1`, which is what
    /// the default (empty) feature list here models.
    func testSeekAndOutputRouteFileAsFailureRecoveryThroughTheMappingAlone() {
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(forClassification: "seek_reanchor"),
            PlaybackProtocolV3.ReplanOperation.failureRecovery
        )
        XCTAssertNotEqual(
            PlaybackSessionBridge.replanOperation(forClassification: "seek_reanchor"),
            PlaybackProtocolV3.ReplanOperation.seekReanchor
        )
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(forClassification: "output_route_changed"),
            PlaybackProtocolV3.ReplanOperation.failureRecovery
        )
        // An unrecognized classification is never rejected — it is a failure.
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(forClassification: "totally_unknown"),
            PlaybackProtocolV3.ReplanOperation.failureRecovery
        )
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(forClassification: ""),
            PlaybackProtocolV3.ReplanOperation.failureRecovery
        )
    }

    // MARK: - canRetargetDirectSession

    func testIdenticalPlansMayBeRetargeted() throws {
        let current = try goldenPlan()
        XCTAssertTrue(
            PlaybackSessionBridge.canRetargetDirectSession(from: current, to: current)
        )
    }

    /// The whole point of the predicate: renewal mints a brand-new session and
    /// a brand-new signed URL, and neither is allowed to block the swap. Only
    /// what the player is *rendering* has to be unchanged.
    func testRenewalIdentityAndTransportURLDoNotBlockTheSwap() throws {
        let current = try goldenPlan()
        let tolerated: [(String, [String], Any)] = [
            ("stream url", ["stream", "url"], "/stream/22222222-2222-4222-8222-222222222222"),
            ("session id", ["session_id"], "22222222-2222-4222-8222-222222222222"),
            ("plan id", ["plan_id"], "plan:renewed"),
            ("plan attempt key", ["plan_attempt_key"], "v3:renewed"),
            ("expiry", ["expires_at"], "2031-01-01T00:00:00Z"),
            ("player start", ["timeline", "player_start_seconds"], 900.0),
            ("source start", ["timeline", "source_start_seconds"], 900.0),
            ("decision reason", ["decision_reason"], "renewed_original_playback")
        ]
        for (label, path, value) in tolerated {
            let replacement = try goldenPlan(setting: path, to: value)
            XCTAssertTrue(
                PlaybackSessionBridge.canRetargetDirectSession(from: current, to: replacement),
                "changing \(label) must not block a silent renewal"
            )
        }
    }

    func testAnyRenderingRelevantChangeRefusesTheSwap() throws {
        let current = try goldenPlan()
        let refused: [(String, [String], Any)] = [
            ("effective file", ["effective_media_file_id"], 43),
            ("requested file", ["requested_media_file_id"], 43),
            ("container", ["stream", "container"], "mkv"),
            ("mime type", ["stream", "mime_type"], "video/x-matroska"),
            ("header refresh", ["stream", "header_refresh"], "session"),
            ("stream origin", ["timeline", "stream_origin_seconds"], 30.0),
            ("timeline offset", ["timeline", "timeline_offset_seconds"], 30.0),
            ("seekability", ["timeline", "can_seek_anywhere"], false),
            ("seek restoration", ["timeline", "seek_restoration"], "stream_origin"),
            ("selected audio", ["selected_tracks", "audio", "index"], 1),
            ("audio recipe", ["effective_recipe", "audio_codec"], "eac3"),
            ("video recipe", ["effective_recipe", "video_codec"], "hevc"),
            ("audio claim", ["claims", "audio", "passthrough"], true),
            ("video claim", ["claims", "video", "hdr10"], true),
            ("subtitle mode", ["subtitle", "mode"], "render"),
            ("source duration", ["source", "duration_seconds"], 3600.0),
            ("source codec", ["source", "video_codec"], "hevc"),
            ("fidelity policy", ["subtitle_fidelity_policy"], "require_exact")
        ]
        for (label, path, value) in refused {
            let replacement = try goldenPlan(setting: path, to: value)
            XCTAssertFalse(
                PlaybackSessionBridge.canRetargetDirectSession(from: current, to: replacement),
                "changing \(label) must refuse a silent renewal"
            )
        }
    }

    /// Only `original_http` can be retargeted at all: a server-produced
    /// delivery has its own session lifetime, so there is nothing to swap
    /// underneath.
    func testOnlyOriginalHTTPPlansAreRetargetable() throws {
        let hlsPlan = try goldenPlan(
            mutations: [
                (["delivery"], "server_remux_hls"),
                (["stream", "protocol"], "hls")
            ]
        )
        XCTAssertFalse(
            PlaybackSessionBridge.canRetargetDirectSession(from: hlsPlan, to: hlsPlan),
            "a server HLS plan is not a direct session"
        )

        let direct = try goldenPlan()
        XCTAssertFalse(
            PlaybackSessionBridge.canRetargetDirectSession(from: direct, to: hlsPlan)
        )
        XCTAssertFalse(
            PlaybackSessionBridge.canRetargetDirectSession(from: hlsPlan, to: direct)
        )
    }

    // MARK: - isMaterialOutputRouteChange

    func testMaterialOutputRouteChangeIsAnOpaqueIdentityCompare() {
        let cases: [(active: String?, observed: String?, material: Bool, label: String)] = [
            (nil, nil, false, "no identity either side"),
            ("hdmi:7", "hdmi:7", false, "same HDMI sink re-reported"),
            ("hdmi:7", "airplay:living-room", true, "HDMI → AirPlay"),
            ("airplay:living-room", "hdmi:7", true, "AirPlay → HDMI"),
            ("hdmi:7", "hdmi:8", true, "HDMI sink swapped"),
            (nil, "hdmi:7", true, "identity appeared"),
            ("hdmi:7", nil, true, "identity disappeared"),
            ("hdmi:7", "hdmi:7 ", true, "opaque compare — whitespace is a change"),
            ("HDMI:7", "hdmi:7", true, "opaque compare — case is a change"),
            ("", "", false, "two empty identities")
        ]
        for testCase in cases {
            XCTAssertEqual(
                PlaybackSessionBridge.isMaterialOutputRouteChange(
                    activeOutputContextId: testCase.active,
                    observedOutputContextId: testCase.observed
                ),
                testCase.material,
                testCase.label
            )
        }
    }

    /// A PiP transition, a lock/unlock, or the player selecting its own
    /// preferred multichannel layout all re-fire the AVAudioSession route
    /// notification without changing the sink. None of them replan.
    func testSelfInflictedRouteNotificationsAreNotMaterial() {
        for identity in ["hdmi:7", "airplay:living-room", "builtin:speaker"] {
            XCTAssertFalse(
                PlaybackSessionBridge.isMaterialOutputRouteChange(
                    activeOutputContextId: identity,
                    observedOutputContextId: identity
                ),
                identity
            )
        }
    }

    // MARK: - Auto version selection agrees with the detail label

    /// `PlaybackSessionBridge.selectVersion` and
    /// `DetailVersionSelection.displayVersion` must resolve to the same file
    /// for the same inputs — otherwise the detail screen labels one version's
    /// tracks and format while Play starts another, and picking a labelled
    /// track pins the version that was never going to play.
    ///
    /// The sweep covers every rung: no history / a remembered file at each
    /// resolution / a remembered file that is gone, crossed with Auto, an
    /// explicit ceiling above and below the available files, Original, and the
    /// 4K rung.
    func testAutoVersionAgreesBetweenTheDetailLabelAndPlaybackStart() {
        let versions = Self.decodedVersions("""
        [
          { "file_id": 1, "resolution": "720p" },
          { "file_id": 2, "resolution": "1080p", "hdr": true },
          { "file_id": 3, "resolution": "2160p", "hdr": true,
            "video_tracks": [ { "index": 0, "codec": "hevc", "dolby_vision": "profile 8" } ] },
          { "file_id": 4, "resolution": null }
        ]
        """)
        let contexts: [VersionDynamicRangePreference.Context] = [
            .init(supportsDolbyVision: false, supportsHDR: false, dolbyVisionEnabled: false),
            .init(supportsDolbyVision: true, supportsHDR: true, dolbyVisionEnabled: true)
        ]
        let storedQualityIds: [String?] = [
            nil, "", "auto", "original", "2160p", "4K", "1080p-high", "1080p", "720p", "480p", "328p"
        ]

        for context in contexts {
            for storedQualityId in storedQualityIds {
                for lastFileId in [nil, 1, 2, 3, 4, 99] as [Int?] {
                    let detail = DetailVersionSelection.displayVersion(
                        versions: versions,
                        selectedFileId: nil,
                        lastFileId: lastFileId,
                        preferredQualityId: storedQualityId,
                        dynamicRange: context
                    )
                    let bridge = PlaybackSessionBridge.selectVersion(
                        from: versions,
                        lastFileId: lastFileId,
                        // What `PlaybackSessionBridge.prepare` hands its own
                        // selector: the stored id through the closed catalog,
                        // with Auto collapsed to nil.
                        preferredQuality: Self.bridgeQualityPreference(storedQualityId),
                        dynamicRange: context
                    )
                    XCTAssertEqual(
                        detail?.fileId,
                        bridge.fileId,
                        "quality=\(storedQualityId ?? "nil") lastFileId=\(lastFileId?.description ?? "nil") dv=\(context.supportsDolbyVision)"
                    )
                }
            }
        }
    }

    /// The bridge never asks its selector for a version the detail screen
    /// could not have labelled: an explicit Version pick is resolved before
    /// the selector runs, on both sides.
    func testAnExplicitVersionPickBypassesTheSharedSelectorOnBothSides() {
        let versions = Self.decodedVersions("""
        [
          { "file_id": 1, "resolution": "720p" },
          { "file_id": 2, "resolution": "2160p" }
        ]
        """)
        let context = VersionDynamicRangePreference.Context(
            supportsDolbyVision: false, supportsHDR: false, dolbyVisionEnabled: false
        )

        XCTAssertEqual(
            DetailVersionSelection.displayVersion(
                versions: versions,
                selectedFileId: 1,
                lastFileId: 2,
                preferredQualityId: "original",
                dynamicRange: context
            )?.fileId,
            1
        )
        XCTAssertEqual(
            DetailVersionSelection.autoVersion(
                versions: versions,
                selectedFileId: 1,
                lastFileId: 2,
                preferredQuality: ApplePlaybackQuality.originalId,
                dynamicRange: context
            )?.fileId,
            1
        )
    }

    private static func bridgeQualityPreference(_ storedQualityId: String?) -> String? {
        let normalized = ApplePlaybackQuality.normalizeStoredId(storedQualityId)
        return normalized == ApplePlaybackQuality.autoId ? nil : normalized
    }

    private static func decodedVersions(_ json: String) -> [FileVersion] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode([FileVersion].self, from: Data(json.utf8))
    }

    // MARK: - Fixture plumbing

    private func goldenPlan(
        setting path: [String],
        to value: Any
    ) throws -> PlaybackV3Plan {
        try goldenPlan(mutations: [(path, value)])
    }

    private func goldenPlan(
        mutations: [([String], Any)] = []
    ) throws -> PlaybackV3Plan {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var planObject = try XCTUnwrap(root["playback_plan"] as? [String: Any])
        for (path, value) in mutations {
            planObject = Self.setting(path: path, to: value, in: planObject)
        }
        return try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3Plan.self,
            from: try JSONSerialization.data(withJSONObject: planObject)
        )
    }

    private static func setting(
        path: [String],
        to value: Any,
        in object: [String: Any]
    ) -> [String: Any] {
        guard let head = path.first else { return object }
        var copy = object
        if path.count == 1 {
            copy[head] = value
            return copy
        }
        let child = (copy[head] as? [String: Any]) ?? [:]
        copy[head] = setting(path: Array(path.dropFirst()), to: value, in: child)
        return copy
    }
}

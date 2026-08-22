import AetherEngine
import Foundation
import XCTest
@testable import Silo

@MainActor
final class AetherPlaybackBoundaryTests: XCTestCase {
    private struct LiveStreamFixture: Decodable {
        let url: URL
        let headers: [String: String]
    }

    func testHeaderAuthenticatedStreamResolutionStaysOnAPIMediaOrigin() throws {
        let request = try XCTUnwrap(StreamRequest.resolve(
            rawURL: "/playback/transcode/session-1/master.m3u8?seek=12",
            serverURL: "https://dev.example.test/",
            additionalHeaders: [
                "authorization": "Bearer stale-wire-token",
                "X-Transport": "preserved",
            ],
            accessToken: "current-token",
            requiresHeaderAuthenticatedMedia: true
        ))

        XCTAssertEqual(
            request.url.absoluteString,
            "https://dev.example.test/api/v1/playback/transcode/session-1/master.m3u8?seek=12"
        )
        XCTAssertEqual(request.headers["Authorization"], "Bearer current-token")
        XCTAssertNil(request.headers["authorization"])
        XCTAssertEqual(request.headers["X-Transport"], "preserved")
    }

    func testHeaderAuthenticatedStreamRejectsAbsoluteAndNonMediaRoutes() {
        for raw in [
            "https://dev.example.test/api/v1/stream/session-1",
            "https://cdn.example.test/stream/session-1",
            "//cdn.example.test/stream/session-1",
            "/admin/settings",
            "/api/v1/stream/session-1",
            "/stream/../admin/settings",
            "/stream/%2e%2e/admin/settings",
            "/stream/session-1?st=legacy-secret",
            "/stream/session-1?token=legacy-secret",
            "/stream/session-1?access_token=legacy-secret",
            "/stream/session-1?credential=legacy-secret",
            "/stream/session-1?seek=not-a-number",
            "/stream/session-1?seek=-1",
            "/stream/session-1?seek=12&seek=13",
            "/stream/session-1#token=legacy-secret",
            "file:///private/movie.mkv",
        ] {
            XCTAssertNil(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "private-token",
                requiresHeaderAuthenticatedMedia: true
            ), "unexpectedly accepted \(raw)")
        }
    }

    func testLegacyResolutionStillNeverForwardsBearerAcrossOrigins() {
        XCTAssertNil(StreamRequest.resolve(
            rawURL: "https://cdn.example.test/movie.mkv",
            serverURL: "https://dev.example.test",
            additionalHeaders: ["Authorization": "Bearer private-token"],
            accessToken: "private-token",
            requiresHeaderAuthenticatedMedia: false
        ))

        let offline = StreamRequest.resolve(
            rawURL: "file:///private/movie.mkv",
            serverURL: "https://dev.example.test",
            additionalHeaders: ["Authorization": "Bearer private-token"],
            accessToken: "private-token",
            requiresHeaderAuthenticatedMedia: false
        )
        XCTAssertEqual(offline?.url.absoluteString, "file:///private/movie.mkv")
        XCTAssertEqual(offline?.headers, [:])
    }

    func testV3FixtureMapsToAuthenticatedAetherLoad() throws {
        let response = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3DecisionResponse.self,
            named: "decision_response",
            bundleClass: Self.self
        )
        guard case .playable(let plan, let sessionID) = response.validatedForApple() else {
            return XCTFail("Expected a playable fixture")
        }
        let resolvedSource = try XCTUnwrap(URL(string: "https://dev.example.test/media/file"))
        let spec = try AetherLoadSpec(
            validating: plan,
            sessionID: sessionID,
            matchContentEnabled: true,
            sourceURLOverride: resolvedSource,
            requestHeaders: [
                "X-Plan-Header": "preserved",
                "Authorization": "Bearer current-token",
            ],
            resolveURL: { URL(string: $0, relativeTo: URL(string: "https://dev.example.test")) },
            preferredAudioLanguages: ["eng"],
            preferredSubtitleLanguages: ["eng"]
        )

        XCTAssertEqual(spec.sourceURL, resolvedSource)
        XCTAssertEqual(spec.timeline.aetherStartPosition, 12.5)
        XCTAssertEqual(spec.options.httpHeaders, [
            "X-Plan-Header": "preserved",
            "Authorization": "Bearer current-token",
        ])
        XCTAssertEqual(spec.options.preferredAudioLanguages, ["eng"])
        XCTAssertEqual(spec.options.preferredSubtitleLanguages, ["eng"])
        XCTAssertNil(spec.audioSourceStreamIndex)
        XCTAssertFalse(spec.options.audioOnly)
        XCTAssertFalse(spec.options.autoplay)
        XCTAssertFalse(spec.options.nativeRemoteHLS)
    }

    func testServerHLSUsesAetherAuthenticatedRemoteBypass() throws {
        let fixtureURL = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        var planObject = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        planObject["delivery"] = PlaybackProtocolV3.PlanDelivery.transcodeHLS
        var streamObject = try XCTUnwrap(planObject["stream"] as? [String: Any])
        streamObject["protocol"] = "hls"
        streamObject["container"] = "mpegts"
        streamObject["mime_type"] = "application/vnd.apple.mpegurl"
        streamObject["headers"] = ["Authorization": "Bearer test"]
        planObject["stream"] = streamObject
        object["playback_plan"] = planObject
        let response = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        guard case .playable(let plan, let sessionID) = response.validatedForApple() else {
            return XCTFail("Expected a playable HLS fixture")
        }

        let spec = try AetherLoadSpec(
            validating: plan,
            sessionID: sessionID,
            matchContentEnabled: true,
            resolveURL: { URL(string: $0, relativeTo: URL(string: "https://dev.example.test")) }
        )

        XCTAssertTrue(spec.options.nativeRemoteHLS)
        XCTAssertEqual(spec.options.httpHeaders["Authorization"], "Bearer test")
    }

    func testV3SubtitleArtifactUsesMergedCurrentRequestHeaders() throws {
        let fixtureURL = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        var planObject = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        var selectedTracks = try XCTUnwrap(planObject["selected_tracks"] as? [String: Any])
        selectedTracks["subtitle"] = [
            "id": "file:42:subtitle:0",
            "index": 0,
        ]
        planObject["selected_tracks"] = selectedTracks
        var subtitle = try XCTUnwrap(planObject["subtitle"] as? [String: Any])
        subtitle["mode"] = "render"
        subtitle["track_id"] = "file:42:subtitle:0"
        subtitle["artifact"] = [
            "url": "/stream/session/subtitles/0.vtt",
            "mime_type": "text/vtt",
            "format": "vtt",
            "timing_origin_seconds": 0,
        ]
        planObject["subtitle"] = subtitle
        object["playback_plan"] = planObject

        let response = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        guard case .playable(let plan, let sessionID) = response.validatedForApple() else {
            return XCTFail("Expected a playable subtitle fixture")
        }
        let currentHeaders = [
            "X-Plan-Header": "preserved",
            "Authorization": "Bearer refreshed-token",
        ]
        let spec = try AetherLoadSpec(
            validating: plan,
            sessionID: sessionID,
            matchContentEnabled: true,
            sourceURLOverride: URL(string: "https://dev.example.test/media")!,
            requestHeaders: currentHeaders,
            resolveURL: {
                StreamRequest.resolve(
                    rawURL: $0,
                    serverURL: "https://dev.example.test",
                    additionalHeaders: [:],
                    accessToken: nil,
                    requiresHeaderAuthenticatedMedia: true
                )?.url
            }
        )

        XCTAssertEqual(spec.options.httpHeaders, currentHeaders)
        XCTAssertEqual(spec.options.externalSubtitles.first?.httpHeaders, currentHeaders)
    }

    func testV3SubtitleArtifactRejectsOffOriginAndNonMediaURLs() throws {
        let fixtureURL = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        let fixtureObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )

        for artifactURL in [
            "https://subtitles.example.net/movie.vtt",
            "/admin/settings",
            "/stream/session/../admin/settings",
            "/stream/session/subtitle.vtt?st=legacy-secret",
            "/stream/session/subtitle.vtt?credential=legacy-secret",
        ] {
            var object = fixtureObject
            var planObject = try XCTUnwrap(object["playback_plan"] as? [String: Any])
            var selectedTracks = try XCTUnwrap(planObject["selected_tracks"] as? [String: Any])
            selectedTracks["subtitle"] = ["id": "file:42:subtitle:0", "index": 0]
            planObject["selected_tracks"] = selectedTracks
            var subtitle = try XCTUnwrap(planObject["subtitle"] as? [String: Any])
            subtitle["mode"] = "render"
            subtitle["track_id"] = "file:42:subtitle:0"
            subtitle["artifact"] = [
                "url": artifactURL,
                "mime_type": "text/vtt",
                "format": "vtt",
                "timing_origin_seconds": 0,
            ]
            planObject["subtitle"] = subtitle
            object["playback_plan"] = planObject
            let response = try PlaybackV3FixtureTestSupport.decoder.decode(
                PlaybackV3DecisionResponse.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            guard case .playable(let plan, let sessionID) = response.validatedForApple() else {
                return XCTFail("Expected a playable subtitle fixture")
            }

            XCTAssertThrowsError(try AetherLoadSpec(
                validating: plan,
                sessionID: sessionID,
                matchContentEnabled: true,
                sourceURLOverride: URL(string: "https://dev.example.test/api/v1/stream/session")!,
                requestHeaders: ["Authorization": "Bearer current-token"],
                resolveURL: {
                    StreamRequest.resolve(
                        rawURL: $0,
                        serverURL: "https://dev.example.test",
                        additionalHeaders: [:],
                        accessToken: nil,
                        requiresHeaderAuthenticatedMedia: true
                    )?.url
                }
            ), "unexpectedly accepted subtitle artifact \(artifactURL)")
        }
    }

    func testOfflineLoadAcceptsOnlyLocalMediaAndSidecars() throws {
        let media = URL(fileURLWithPath: "/tmp/silo-offline/movie.mkv")
        let subtitle = SubtitleUrl(
            index: 3,
            language: "eng",
            codec: "srt",
            label: "English",
            source: "download",
            forced: false,
            url: URL(fileURLWithPath: "/tmp/silo-offline/movie.en.srt").absoluteString
        )
        let spec = try AetherLoadSpec(
            offlineURL: media,
            startPosition: 91,
            audioOnly: false,
            audioSourceStreamIndex: 7,
            sidecars: [subtitle],
            preferredAudioLanguages: ["eng"],
            forwardBufferSegments: Int.max
        )

        XCTAssertEqual(spec.sourceURL, media)
        XCTAssertEqual(spec.timeline.aetherStartPosition, 91)
        XCTAssertEqual(spec.audioSourceStreamIndex, 7)
        XCTAssertEqual(spec.options.preferredAudioLanguages, ["eng"])
        XCTAssertEqual(spec.options.forwardBufferSegments, Int.max)
        XCTAssertEqual(spec.options.externalSubtitles.count, 1)
        XCTAssertEqual(
            spec.externalSubtitleAppTrackIDs,
            [SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3)]
        )
        XCTAssertThrowsError(try AetherLoadSpec(
            offlineURL: URL(string: "https://example.test/movie.mkv")!,
            startPosition: 0,
            audioOnly: false
        ))
    }

    func testDirectLoadResolvesRelativeSubtitleBesideRemoteMedia() throws {
        let media = try XCTUnwrap(URL(string: "https://dev.example.test/media/movie.mkv"))
        let subtitle = SubtitleUrl(
            index: 3,
            language: "eng",
            codec: "srt",
            label: "English",
            source: "server",
            forced: false,
            url: "subtitles/movie.en.srt"
        )
        let spec = try AetherLoadSpec(
            directURL: media,
            headers: ["Authorization": "Bearer test"],
            startPosition: 0,
            audioOnly: false,
            sidecars: [subtitle]
        )

        XCTAssertEqual(
            spec.options.externalSubtitles.first?.url.absoluteString,
            "https://dev.example.test/media/subtitles/movie.en.srt"
        )
        XCTAssertEqual(
            spec.options.externalSubtitles.first?.httpHeaders,
            ["Authorization": "Bearer test"]
        )
        XCTAssertEqual(
            spec.externalSubtitleAppTrackIDs,
            [SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3)]
        )
    }

    func testDirectLoadDoesNotForwardBearerToCrossOriginSubtitle() throws {
        let media = try XCTUnwrap(URL(string: "https://dev.example.test/media/movie.mkv"))
        let subtitle = SubtitleUrl(
            index: 4,
            language: "eng",
            codec: "vtt",
            label: "External English",
            source: "provider",
            forced: false,
            url: "https://subtitles.example.net/movie.vtt"
        )
        let spec = try AetherLoadSpec(
            directURL: media,
            headers: ["Authorization": "Bearer silo-token"],
            startPosition: 0,
            audioOnly: false,
            sidecars: [subtitle]
        )

        XCTAssertEqual(spec.options.httpHeaders["Authorization"], "Bearer silo-token")
        XCTAssertEqual(spec.options.externalSubtitles.first?.httpHeaders, [:])
    }

    func testControllerConstructsOnlyAetherEngine() throws {
        let controller = try AetherPlaybackController()
        XCTAssertEqual(controller.engine.state, .idle)
        controller.setVolume(0.4)
        controller.setMuted(true)
        controller.setVolume(0.7)
        XCTAssertTrue(controller.isMuted)
        XCTAssertEqual(controller.volume, 0.7, accuracy: 0.001)
        XCTAssertEqual(controller.engine.volume, 0, accuracy: 0.001)
        controller.setMuted(false)
        XCTAssertEqual(controller.engine.volume, 0.7, accuracy: 0.001)

        let appTrackID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 42)
        controller.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(fileURLWithPath: "/tmp/subtitle.srt")),
            appTrackID: appTrackID
        )
        XCTAssertTrue(controller.containsSubtitle(appTrackID: appTrackID))
        XCTAssertEqual(
            controller.appSubtitleID(forAetherID: AetherEngine.externalSubtitleTrackIDBase),
            appTrackID
        )
        controller.stop()
    }

    /// Opt-in shared-dev proof for the complete server -> StreamRequest ->
    /// Aether boundary. The fixture stays outside the repository because it
    /// contains a short-lived bearer credential. Normal test runs skip this;
    /// validation supplies only its mode-0600 path through the test process
    /// environment.
    func testLiveHeaderAuthenticatedStreamLoadsAndAdvancesInAether() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["SILO_AETHER_LIVE_FIXTURE_PATH"],
              !fixturePath.isEmpty else {
            throw XCTSkip("Set SILO_AETHER_LIVE_FIXTURE_PATH for shared-dev playback proof")
        }

        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let fixture = try JSONDecoder().decode(
            LiveStreamFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        guard let scheme = fixture.url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              fixture.url.host != nil else {
            return XCTFail("Live fixture URL must be an absolute HTTP(S) URL")
        }
        XCTAssertNotNil(
            fixture.headers.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame },
            "Live fixture must exercise Aether's authenticated HTTP transport"
        )

        let controller = try AetherPlaybackController()
        defer { controller.stop() }
        let spec = try AetherLoadSpec(
            directURL: fixture.url,
            headers: fixture.headers,
            startPosition: 0,
            audioOnly: false
        )
        let epoch = controller.beginLoad(spec)
        try await controller.finishLoad(epoch)

        XCTAssertNotEqual(controller.engine.playbackBackend, .none)
        XCTAssertGreaterThan(controller.engine.duration, 0)
        XCTAssertFalse(controller.engine.audioTracks.isEmpty)

        controller.play()
        let deadline = Date().addingTimeInterval(15)
        while controller.engine.clock.currentTime <= 0.25, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(
            controller.engine.clock.currentTime,
            0.25,
            "Aether loaded the authenticated source but its playback clock never advanced"
        )
    }
}

import AetherEngine
import Foundation
import XCTest
@testable import Silo

@MainActor
final class AetherPlaybackBoundaryTests: XCTestCase {
    private struct LiveStreamFixture: Decodable {
        let label: String?
        let url: URL
        let headers: [String: String]
    }

    private struct LiveStreamFixtureEnvelope: Decodable {
        let streams: [LiveStreamFixture]
    }

    func testExplicitV3AudioSelectionOverridesProfileLanguageForInitialLoad() {
        let languages = AetherInitialAudioPreference.languages(
            selectedOrdinal: 0,
            tracks: [
                makeAudioTrack(language: "pt", isDefault: true),
                makeAudioTrack(language: "en", isDefault: false),
            ],
            fallbackLanguage: "en"
        )

        XCTAssertEqual(languages, ["pt"])
    }

    func testUnlabeledExplicitAudioSelectionDoesNotFallBackToProfileLanguage() {
        let languages = AetherInitialAudioPreference.languages(
            selectedOrdinal: 0,
            tracks: [makeAudioTrack(language: nil, isDefault: false)],
            fallbackLanguage: "en"
        )

        XCTAssertEqual(languages, [])
    }

    func testUnavailableExplicitAudioInventoryDoesNotResurrectProfileLanguage() {
        for tracks in [
            [AudioTrack](),
            [makeAudioTrack(language: "pt", isDefault: true)],
        ] {
            let languages = AetherInitialAudioPreference.languages(
                selectedOrdinal: 1,
                tracks: tracks,
                fallbackLanguage: "en"
            )

            XCTAssertEqual(languages, [])
        }
    }

    func testWhitespaceOnlyExplicitAudioLanguageDoesNotBecomeAnAetherHint() {
        let languages = AetherInitialAudioPreference.languages(
            selectedOrdinal: 0,
            tracks: [makeAudioTrack(language: "  ", isDefault: false)],
            fallbackLanguage: "en"
        )

        XCTAssertEqual(languages, [])
    }

    func testProfileAudioLanguageRemainsFallbackWithoutExplicitSelection() {
        let languages = AetherInitialAudioPreference.languages(
            selectedOrdinal: nil,
            tracks: [makeAudioTrack(language: "pt", isDefault: true)],
            fallbackLanguage: " en "
        )

        XCTAssertEqual(languages, ["en"])
    }

    private func makeAudioTrack(language: String?, isDefault: Bool) -> AudioTrack {
        AudioTrack(
            index: nil,
            codec: "eac3",
            channels: 6,
            channelLayout: "5.1(side)",
            bitrate: 640,
            sampleRate: 48_000,
            language: language,
            title: nil,
            embeddedTitle: nil,
            isDefault: isDefault
        )
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

    func testHeaderAuthenticatedStreamAcceptsSubtitleArtifactIdentifiers() throws {
        for raw in [
            "/stream/session-1/subtitles/2.vtt?file_id=631745",
            "/stream/session-1/subtitles/2.vtt?file_id=631745&downloaded_subtitle_id=8",
            "/stream/session-1/subtitles/2/fonts?file_id=631745",
        ] {
            let request = try XCTUnwrap(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "current-token",
                requiresHeaderAuthenticatedMedia: true
            ), "unexpectedly rejected \(raw)")
            XCTAssertEqual(
                request.url.absoluteString,
                "https://dev.example.test/api/v1" + raw
            )
            XCTAssertEqual(request.headers["Authorization"], "Bearer current-token")
        }
    }

    func testHeaderAuthenticatedStreamRejectsSubtitleIdentifiersOnMediaAndMalformedValues() {
        for raw in [
            // Media routes keep the seek-only rule.
            "/stream/session-1?file_id=631745",
            "/stream/session-1/master.m3u8?file_id=631745",
            "/playback/transcode/session-1/master.m3u8?downloaded_subtitle_id=8",
            // Unknown names stay rejected on the subtitle artifact family.
            "/stream/session-1/subtitles/2.vtt?st=legacy-secret",
            "/stream/session-1/subtitles/2.vtt?file_id=631745&token=legacy-secret",
            // Non-negative integers only, and no duplicates.
            "/stream/session-1/subtitles/2.vtt?file_id=-1",
            "/stream/session-1/subtitles/2.vtt?file_id=abc",
            "/stream/session-1/subtitles/2.vtt?file_id=1.5",
            "/stream/session-1/subtitles/2.vtt?file_id=",
            "/stream/session-1/subtitles/2.vtt?downloaded_subtitle_id=-8",
            "/stream/session-1/subtitles/2.vtt?file_id=1&file_id=2",
            "/stream/session-1/subtitles/2.vtt?file_id=1#token=legacy-secret",
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

    // MARK: - authorized_media_origins_v1

    private static let proxyOrigin = "https://proxy.example.test:8443"

    func testAuthorizedOriginsStillAcceptRelativeAPIMediaURLs() throws {
        for raw in [
            "/stream/v3/session-1",
            "/stream/v3/session-1/master.m3u8?seek=12",
            "/playback/transcode/session-1/master.m3u8",
            "/stream/session-1/subtitles/2.vtt?file_id=631745",
        ] {
            let request = try XCTUnwrap(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "current-token",
                requiresHeaderAuthenticatedMedia: true,
                authorizedMediaOriginSessionId: "session-1"
            ), "unexpectedly rejected \(raw)")
            XCTAssertEqual(request.url.absoluteString, "https://dev.example.test/api/v1" + raw)
            XCTAssertEqual(request.headers["Authorization"], "Bearer current-token")
        }
    }

    func testAuthorizedOriginsAcceptProxyMediaFamilyVerbatim() throws {
        for raw in [
            "\(Self.proxyOrigin)/stream/v3/session-1",
            "\(Self.proxyOrigin)/stream/v3/session-1?seek=12.5",
            "\(Self.proxyOrigin)/stream/v3/session-1/master.m3u8",
            "\(Self.proxyOrigin)/stream/v3/session-1/master.m3u8?seek=0",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment/seg-00042.m4s",
        ] {
            let request = try XCTUnwrap(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: ["X-Transport": "preserved"],
                accessToken: "current-token",
                requiresHeaderAuthenticatedMedia: true,
                authorizedMediaOriginSessionId: "session-1"
            ), "unexpectedly rejected \(raw)")
            // Used exactly as handed: no `/api/v1` prefix, no rewriting.
            XCTAssertEqual(request.url.absoluteString, raw)
            XCTAssertEqual(request.headers["Authorization"], "Bearer current-token")
            XCTAssertEqual(request.headers["X-Transport"], "preserved")
            XCTAssertEqual(request.serverUrl, "https://dev.example.test")
        }
    }

    func testAuthorizedOriginsAcceptHTTPProxyWhenServerIsHTTP() throws {
        let raw = "http://proxy.example.test:8080/stream/v3/session-1"
        let request = try XCTUnwrap(StreamRequest.resolve(
            rawURL: raw,
            serverURL: "http://dev.example.test",
            additionalHeaders: ["X-Transport": "preserved"],
            accessToken: "current-token",
            requiresHeaderAuthenticatedMedia: true,
            authorizedMediaOriginSessionId: "session-1"
        ), "unexpectedly rejected \(raw) with an http server")
        XCTAssertEqual(request.url.absoluteString, raw)
        XCTAssertEqual(request.headers["Authorization"], "Bearer current-token")
        XCTAssertEqual(request.headers["X-Transport"], "preserved")
    }

    func testAuthorizedOriginsRejectHTTPProxyWhenServerIsHTTPS() {
        let raw = "http://proxy.example.test:8080/stream/v3/session-1"
        XCTAssertNil(StreamRequest.resolve(
            rawURL: raw,
            serverURL: "https://dev.example.test",
            additionalHeaders: [:],
            accessToken: "current-token",
            requiresHeaderAuthenticatedMedia: true,
            authorizedMediaOriginSessionId: "session-1"
        ), "an https deployment must never downgrade the bearer to an http proxy origin")
    }

    func testProxyMediaURLsAreRejectedWithoutNegotiatedOrigins() {
        for raw in [
            "\(Self.proxyOrigin)/stream/v3/session-1",
            "\(Self.proxyOrigin)/stream/v3/session-1/master.m3u8",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment/seg-1.m4s",
        ] {
            XCTAssertNil(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "private-token",
                requiresHeaderAuthenticatedMedia: true
            ), "unexpectedly accepted \(raw) without negotiated origins")

            XCTAssertNil(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "private-token",
                requiresHeaderAuthenticatedMedia: false
            ), "unexpectedly accepted \(raw) in legacy mode")
        }
    }

    func testAuthorizedOriginsRejectEverythingOutsideTheProxyMediaFamily() {
        for raw in [
            // Wrong route family, or the API family spelled absolutely.
            "\(Self.proxyOrigin)/stream/session-1",
            "\(Self.proxyOrigin)/api/v1/stream/v3/session-1",
            "\(Self.proxyOrigin)/playback/transcode/session-1/master.m3u8",
            "\(Self.proxyOrigin)/stream/v3",
            "\(Self.proxyOrigin)/stream/v3/",
            "\(Self.proxyOrigin)/stream/v3/session-1/",
            "\(Self.proxyOrigin)/stream/v3/session-1/index.m3u8",
            "\(Self.proxyOrigin)/stream/v3/session-1/master.m3u8/extra",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment/seg-1/extra",
            "\(Self.proxyOrigin)/stream/v3/session-1/subtitles/0.vtt",
            // Traversal and encoded separators.
            "\(Self.proxyOrigin)/stream/v3/session-1/../../admin/settings",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment/%2e%2e",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment/a%2fb",
            "\(Self.proxyOrigin)/stream/v3/session-1/segment/a%5cb",
            // Credentials, fragments, foreign schemes, scheme-relative.
            "https://user:pass@proxy.example.test/stream/v3/session-1",
            "\(Self.proxyOrigin)/stream/v3/session-1#token=legacy-secret",
            "ftp://proxy.example.test/stream/v3/session-1",
            "//proxy.example.test/stream/v3/session-1",
            // Query allowlist: `seek` only, and subtitle identifiers never
            // travel on an absolute URL.
            "\(Self.proxyOrigin)/stream/v3/session-1?st=legacy-secret",
            "\(Self.proxyOrigin)/stream/v3/session-1?token=legacy-secret",
            "\(Self.proxyOrigin)/stream/v3/session-1?access_token=legacy-secret",
            "\(Self.proxyOrigin)/stream/v3/session-1?file_id=631745",
            "\(Self.proxyOrigin)/stream/v3/session-1?downloaded_subtitle_id=8",
            "\(Self.proxyOrigin)/stream/v3/session-1?seek=12&token=legacy-secret",
            "\(Self.proxyOrigin)/stream/v3/session-1?seek=12&seek=13",
            "\(Self.proxyOrigin)/stream/v3/session-1?seek=not-a-number",
            "\(Self.proxyOrigin)/stream/v3/session-1?seek=-1",
            "\(Self.proxyOrigin)/stream/v3/session-1?seek",
        ] {
            XCTAssertNil(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "private-token",
                requiresHeaderAuthenticatedMedia: true,
                authorizedMediaOriginSessionId: "session-1"
            ), "unexpectedly accepted \(raw)")
        }
    }

    func testAuthorizedOriginsRejectAnotherSessionsGrant() throws {
        let foreign = "\(Self.proxyOrigin)/stream/v3/session-2/master.m3u8"
        XCTAssertNil(StreamRequest.resolve(
            rawURL: foreign,
            serverURL: "https://dev.example.test",
            additionalHeaders: [:],
            accessToken: "current-token",
            requiresHeaderAuthenticatedMedia: true,
            authorizedMediaOriginSessionId: "session-1"
        ))
    }

    func testAuthorizedOriginsRejectEmptySessionId() {
        let raw = "\(Self.proxyOrigin)/stream/v3/session-1/master.m3u8"
        XCTAssertNil(StreamRequest.resolve(
            rawURL: raw,
            serverURL: "https://dev.example.test",
            additionalHeaders: [:],
            accessToken: "current-token",
            requiresHeaderAuthenticatedMedia: true,
            authorizedMediaOriginSessionId: ""
        ), "empty session id must not enable absolute proxy URLs")
    }

    func testAuthorizedOriginsRejectWhitespaceOnlySessionId() {
        let raw = "\(Self.proxyOrigin)/stream/v3/session-1/master.m3u8"
        XCTAssertNil(StreamRequest.resolve(
            rawURL: raw,
            serverURL: "https://dev.example.test",
            additionalHeaders: [:],
            accessToken: "current-token",
            requiresHeaderAuthenticatedMedia: true,
            authorizedMediaOriginSessionId: " "
        ), "whitespace-only session id must not enable absolute proxy URLs")
    }

    func testAuthorizedOriginsDoNotRelaxTheRelativeMediaContract() {
        for raw in [
            "/admin/settings",
            "/api/v1/stream/v3/session-1",
            "/stream/../admin/settings",
            "/stream/v3/session-1?st=legacy-secret",
            "/stream/v3/session-1#token=legacy-secret",
            "file:///private/movie.mkv",
        ] {
            XCTAssertNil(StreamRequest.resolve(
                rawURL: raw,
                serverURL: "https://dev.example.test",
                additionalHeaders: [:],
                accessToken: "private-token",
                requiresHeaderAuthenticatedMedia: true,
                authorizedMediaOriginSessionId: "session-1"
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

    func testV3SubtitleSidecarKeepsBearerWhenMediaIsOnAProxyOrigin() throws {
        let fixtureURL = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        var planObject = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        var selectedTracks = try XCTUnwrap(planObject["selected_tracks"] as? [String: Any])
        selectedTracks["subtitle"] = ["id": "file:42:subtitle:0", "index": 0]
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
        let currentHeaders = ["Authorization": "Bearer current-token"]
        let proxySource = try XCTUnwrap(
            URL(string: "\(Self.proxyOrigin)/stream/v3/\(sessionID)")
        )
        let spec = try AetherLoadSpec(
            validating: plan,
            sessionID: sessionID,
            matchContentEnabled: true,
            sourceURLOverride: proxySource,
            requestHeaders: currentHeaders,
            resolveURL: {
                StreamRequest.resolve(
                    rawURL: $0,
                    serverURL: "https://dev.example.test",
                    additionalHeaders: [:],
                    accessToken: nil,
                    requiresHeaderAuthenticatedMedia: true
                )?.url
            },
            apiOriginURL: URL(string: "https://dev.example.test")
        )

        let sidecar = try XCTUnwrap(spec.options.externalSubtitles.first)
        XCTAssertEqual(sidecar.url.host, "dev.example.test")
        XCTAssertEqual(sidecar.httpHeaders, currentHeaders)
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

    /// The reproduction for the ordering mismatch: a plan whose subtitle mode
    /// is `off` declares no external track to Aether, so it must publish no
    /// alias either — even when a stale artifact and `track_id` survive on the
    /// decision. An alias here would claim Aether id `base + 0`, which belongs
    /// to whichever sidecar is registered first afterwards (Arabic), so picking
    /// English would render Arabic.
    func testSubtitlesOffPublishesNoDeclaredAliasDespiteStaleArtifact() throws {
        let plan = try sidecarInventoryPlan(
            mode: "off",
            selectedTrackId: "file:42:subtitle:2",
            includeArtifact: true
        )
        let spec = try Self.loadSpec(for: plan.plan, sessionID: plan.sessionID)

        XCTAssertTrue(spec.options.externalSubtitles.isEmpty)
        XCTAssertEqual(spec.externalSubtitleAppTrackIDs.count, spec.options.externalSubtitles.count)
        XCTAssertTrue(spec.externalSubtitleAppTrackIDs.isEmpty)
    }

    /// End-to-end translation over the reported inventory (ar, da, en, es at
    /// combined indices 0...3, sidecars registered after the load because
    /// playback started with subtitles off): the English app id must resolve to
    /// the Aether id English was registered under, and every id must round-trip.
    func testPostLoadSidecarRegistrationKeepsAppAndAetherSubtitleIDsPaired() throws {
        let plan = try sidecarInventoryPlan(
            mode: "off",
            selectedTrackId: "file:42:subtitle:2",
            includeArtifact: true
        )
        let spec = try Self.loadSpec(for: plan.plan, sessionID: plan.sessionID)
        let controller = try AetherPlaybackController()
        defer { controller.stop() }
        controller.beginLoad(spec)

        // Registration order is the plan's inventory order, exactly as the
        // post-load path in `PlayerViewModel.loadPendingExternalSubtitles`
        // walks it.
        var appTrackIDsByLanguage: [String: Int64] = [:]
        for item in plan.plan.subtitle.inventory where item.delivery == "sidecar" {
            let appTrackID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: item.combinedIndex)
            appTrackIDsByLanguage[item.language ?? ""] = appTrackID
            controller.addExternalSubtitleTrack(
                ExternalSubtitleTrack(
                    url: URL(fileURLWithPath: "/tmp/movie.\(item.language ?? "und").srt"),
                    name: item.label,
                    language: item.language
                ),
                appTrackID: appTrackID
            )
        }

        let englishAppID = try XCTUnwrap(appTrackIDsByLanguage["eng"])
        let englishAetherID = try XCTUnwrap(
            controller.engine.subtitleTracks.first(where: { $0.language == "eng" })?.id
        )
        XCTAssertEqual(controller.aetherSubtitleID(forAppID: englishAppID), englishAetherID)
        XCTAssertEqual(controller.appSubtitleID(forAetherID: englishAetherID), englishAppID)
        // The Arabic sidecar owns `base + 0`; nothing else may translate to it.
        XCTAssertEqual(
            controller.aetherSubtitleID(forAppID: try XCTUnwrap(appTrackIDsByLanguage["ara"])),
            AetherEngine.externalSubtitleTrackIDBase
        )
        for (_, appTrackID) in appTrackIDsByLanguage {
            let aetherID = try XCTUnwrap(controller.aetherSubtitleID(forAppID: appTrackID))
            XCTAssertEqual(controller.appSubtitleID(forAetherID: aetherID), appTrackID)
        }
    }

    /// The same inventory on the path where the server *did* render the pick:
    /// the declared artifact is the only external track, so exactly one alias
    /// is published and it names the selected track — the ordinal Aether will
    /// assign that declared track during `load`.
    func testDeclaredArtifactPublishesExactlyOneAliasForTheSelectedTrack() throws {
        let plan = try sidecarInventoryPlan(
            mode: "render",
            selectedTrackId: "file:42:subtitle:2",
            includeArtifact: true
        )
        let spec = try Self.loadSpec(for: plan.plan, sessionID: plan.sessionID)
        let englishAppID = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 2)

        XCTAssertEqual(spec.options.externalSubtitles.count, 1)
        XCTAssertEqual(spec.externalSubtitleAppTrackIDs, [englishAppID])

        let controller = try AetherPlaybackController()
        defer { controller.stop() }
        controller.beginLoad(spec)
        XCTAssertEqual(
            controller.aetherSubtitleID(forAppID: englishAppID),
            AetherEngine.externalSubtitleTrackIDBase
        )
        XCTAssertTrue(controller.containsSubtitle(appTrackID: englishAppID))
        XCTAssertEqual(
            controller.appSubtitleID(forAetherID: AetherEngine.externalSubtitleTrackIDBase),
            englishAppID
        )
        // No other inventory entry may claim a declared alias.
        for combinedIndex in [0, 1, 3] {
            XCTAssertFalse(controller.containsSubtitle(
                appTrackID: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: combinedIndex)
            ))
        }
    }

    /// The four-sidecar inventory from the reported file: ar, da, en, es at
    /// combined indices 0...3 plus an embedded PGS track at 4.
    private func sidecarInventoryPlan(
        mode: String,
        selectedTrackId: String,
        includeArtifact: Bool
    ) throws -> (plan: PlaybackV3Plan, sessionID: String) {
        let fixtureURL = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        var planObject = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        var inventory: [[String: Any]] = [
            ("ara", "Arabic"), ("dan", "Danish"), ("eng", "English"), ("spa", "Spanish"),
        ].enumerated().map { combinedIndex, entry in
            [
                "track_id": "file:42:subtitle:\(combinedIndex)",
                "combined_index": combinedIndex,
                "source": "external",
                "codec": "srt",
                "language": entry.0,
                "label": entry.1,
                "forced": false,
                "default": false,
                "hearing_impaired": false,
                "delivery": "sidecar",
                "url": "/stream/session/subtitles/\(combinedIndex).srt?file_id=42",
            ]
        }
        inventory.append([
            "track_id": "file:42:subtitle:4",
            "combined_index": 4,
            "source": "embedded",
            "codec": "pgs",
            "language": "jpn",
            "label": "Japanese",
            "forced": false,
            "default": false,
            "hearing_impaired": false,
            "delivery": "burn_in_only",
        ])
        var subtitle: [String: Any] = [
            "mode": mode,
            "track_id": selectedTrackId,
            "inventory": inventory,
        ]
        if includeArtifact {
            subtitle["artifact"] = [
                "url": "/stream/session/subtitles/2.srt?file_id=42",
                "mime_type": "application/x-subrip",
                "format": "srt",
                "timing_origin_seconds": 0,
            ]
        }
        planObject["subtitle"] = subtitle
        var selectedTracks = try XCTUnwrap(planObject["selected_tracks"] as? [String: Any])
        selectedTracks["subtitle"] = ["id": selectedTrackId, "index": 2]
        planObject["selected_tracks"] = selectedTracks
        object["playback_plan"] = planObject

        let response = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        guard case .playable(let plan, let sessionID) = response.validatedForApple() else {
            throw XCTSkip("Expected a playable sidecar-inventory fixture")
        }
        return (plan, sessionID)
    }

    private static func loadSpec(
        for plan: PlaybackV3Plan,
        sessionID: String
    ) throws -> AetherLoadSpec {
        try AetherLoadSpec(
            validating: plan,
            sessionID: sessionID,
            matchContentEnabled: false,
            sourceURLOverride: URL(string: "https://dev.example.test/api/v1/stream/session"),
            requestHeaders: ["Authorization": "Bearer current-token"],
            resolveURL: {
                StreamRequest.resolve(
                    rawURL: $0,
                    serverURL: "https://dev.example.test",
                    additionalHeaders: [:],
                    accessToken: nil,
                    requiresHeaderAuthenticatedMedia: true
                )?.url
            },
            panelIsInHDRMode: false
        )
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
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        let fixtures: [LiveStreamFixture]
        if let envelope = try? decoder.decode(LiveStreamFixtureEnvelope.self, from: data) {
            fixtures = envelope.streams
        } else {
            fixtures = [try decoder.decode(LiveStreamFixture.self, from: data)]
        }
        XCTAssertFalse(fixtures.isEmpty, "Live fixture envelope must contain at least one stream")

        for fixture in fixtures {
            try await assertLiveFixtureLoadsAndAdvances(fixture)
        }
    }

    private func assertLiveFixtureLoadsAndAdvances(_ fixture: LiveStreamFixture) async throws {
        let label = fixture.label ?? "live stream"
        guard let scheme = fixture.url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              fixture.url.host != nil else {
            return XCTFail("\(label): URL must be an absolute HTTP(S) URL")
        }
        XCTAssertNotNil(
            fixture.headers.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame },
            "\(label): fixture must exercise Aether's authenticated HTTP transport"
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
            "\(label): Aether loaded the authenticated source but its playback clock never advanced"
        )
    }

    // MARK: - Deferred track selection

    // Aether publishes its track inventory during startup, before it has
    // dispatched the source onto a decode backend. A deferred pick applied
    // there makes the engine rebuild its pipeline on a route it has not chosen
    // yet, which on a software-decode source (VC-1) is rejected for the codec
    // and takes the in-flight load down with it — the player then sits on the
    // spinner forever. The gate is what keeps that pick held.

    func testDeferredTrackSelectionIsHeldUntilTheLoadIsEstablished() {
        XCTAssertEqual(
            DeferredTrackSelectionGate.outcome(
                isLoadEstablished: false,
                engineAlreadyMatches: false
            ),
            .deferUntilEstablished
        )
        XCTAssertEqual(
            DeferredTrackSelectionGate.outcome(
                isLoadEstablished: false,
                engineAlreadyMatches: true
            ),
            .deferUntilEstablished,
            "an unestablished load must not consume the pending pick even when it looks satisfied"
        )
    }

    func testEstablishedLoadSkipsTheEngineCallWhenTheTrackAlreadyMatches() {
        XCTAssertEqual(
            DeferredTrackSelectionGate.outcome(
                isLoadEstablished: true,
                engineAlreadyMatches: true
            ),
            .adoptWithoutEngineCall
        )
    }

    func testEstablishedLoadDrivesTheEngineWhenTheTrackDiffers() {
        XCTAssertEqual(
            DeferredTrackSelectionGate.outcome(
                isLoadEstablished: true,
                engineAlreadyMatches: false
            ),
            .applyToEngine
        )
    }

    // MARK: - Play during in-flight load

    // `beginLoad` installs spec/epoch before `engine.load` returns. That
    // window looks like a background teardown (route `.none`, session not
    // ready). Play in that window must not call `reloadAtCurrentPosition()`,
    // which starts a second `load` and cancels startup.

    func testPlayDuringUncommittedLoadDoesNotRestore() {
        XCTAssertEqual(
            AetherPlayIntent.action(
                hasCommittedActiveLoad: false,
                sessionRequiresRestore: true
            ),
            .ignore
        )
        XCTAssertEqual(
            AetherPlayIntent.action(
                hasCommittedActiveLoad: false,
                sessionRequiresRestore: false
            ),
            .ignore,
            "an uncommitted load must not start transport even when the route looks live"
        )
    }

    func testPlayAfterCommitRestoresATornDownSession() {
        XCTAssertEqual(
            AetherPlayIntent.action(
                hasCommittedActiveLoad: true,
                sessionRequiresRestore: true
            ),
            .restoreThenPlay
        )
    }

    func testPlayAfterCommitStartsTransportWhenTheSessionIsLive() {
        XCTAssertEqual(
            AetherPlayIntent.action(
                hasCommittedActiveLoad: true,
                sessionRequiresRestore: false
            ),
            .play
        )
    }
}

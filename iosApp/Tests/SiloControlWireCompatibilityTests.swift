import XCTest
@testable import Silo

/// v2 wire compatibility guards.
///
/// The AetherEngine migration removed the HDR toggle from this build but left
/// `SiloControlProtocol.version` at 2 and kept advertising `[1, 2]`, so a
/// rolling phone/TV update still negotiates v2 against peers that predate the
/// removal. Those peers require the `supportsHDRToggle` state key (Android's
/// `SiloCastPlaybackState.supportsHDRToggle` is a non-null `Boolean` with no
/// kotlinx default) and can still send `set_hdr_enabled`. Either mismatch is a
/// hard decode error, and `FramedJSONSession` tears the whole connection down
/// on decode errors — so these are session-fatal, not cosmetic.
///
/// NOTE: as with `SiloControlTests`, this project has no unit-test target
/// wired into `project.yml` yet, so these are not currently compiled or
/// executed.
final class SiloControlWireCompatibilityTests: XCTestCase {

    // MARK: - State: encoding for old peers

    /// The key an old v2 peer requires must be on the wire, and false, because
    /// this build genuinely has no HDR toggle to offer.
    func testEncodedStateCarriesSupportsHDRToggleForOldPeers() throws {
        let data = try JSONEncoder().encode(SiloControlMessage.state(.compatFixture()))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let state = try XCTUnwrap(json["state"] as? [String: Any])

        XCTAssertEqual(state["supportsHDRToggle"] as? Bool, false,
                       "old v2 peers decode supportsHDRToggle as a required non-optional Bool")
    }

    /// Guards the whole set of state keys an old v2 peer declares without a
    /// default. Losing any one of them breaks the same way `supportsHDRToggle`
    /// did, silently, at rolling-update time.
    func testEncodedStateCarriesEveryFieldOldPeersRequire() throws {
        let data = try JSONEncoder().encode(SiloControlMessage.state(.compatFixture()))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let state = try XCTUnwrap(json["state"] as? [String: Any])

        let required = [
            "title", "isPlaying", "isLoading", "isBuffering", "currentTime", "duration",
            "audioTracks", "subtitleTracks", "qualityOptions", "activeQualityId",
            "isQualitySwitching", "playbackSpeed", "videoGravity", "hdrEnabled",
            "supportsVideoGravity", "supportsHDRToggle", "volume", "isMuted",
            "hasNextEpisode",
        ]
        for key in required {
            XCTAssertNotNil(state[key], "v2 peers require the '\(key)' state key")
        }
    }

    // MARK: - State: decoding from old peers

    /// The mirror case: an old TV that never learned the field is not what
    /// breaks — but a peer that omits it must still decode here, so the
    /// tolerance is genuinely two-way and this build never regresses into
    /// requiring a field it doesn't use.
    func testStateDecodesWhenSupportsHDRToggleIsAbsent() throws {
        let message = try JSONDecoder().decode(
            SiloControlMessage.self,
            from: Data(Self.stateJSON(extraKeys: "").utf8)
        )
        guard case .state(let state) = message else {
            return XCTFail("Expected a state message")
        }
        XCTAssertEqual(state.title, "Movie")
        XCTAssertNil(state.supportsHDRToggle)
    }

    /// An old TV that still advertises the toggle must decode too — the value
    /// is carried, not rejected, even though nothing on this side reads it.
    func testStateDecodesWhenOldPeerAdvertisesTheToggle() throws {
        let message = try JSONDecoder().decode(
            SiloControlMessage.self,
            from: Data(Self.stateJSON(extraKeys: #""supportsHDRToggle":true,"#).utf8)
        )
        guard case .state(let state) = message else {
            return XCTFail("Expected a state message")
        }
        XCTAssertEqual(state.supportsHDRToggle, true)
    }

    // MARK: - Commands: retired names from old peers

    /// The exact frame an old v2 phone sends when the user hits its HDR
    /// toggle. Before the fix this threw, which killed the connection.
    func testRetiredSetHDREnabledCommandDecodesAsUnsupportedInsteadOfThrowing() throws {
        let data = Data(
            #"{"type":"control","v":2,"control":{"name":"set_hdr_enabled","enabled":true}}"#.utf8
        )
        let message = try JSONDecoder().decode(SiloControlMessage.self, from: data)
        XCTAssertEqual(message, .unsupportedControl(name: "set_hdr_enabled"))
    }

    /// Any future-or-past name degrades the same way rather than being a
    /// special case for this one command.
    func testUnknownCommandNameDecodesAsUnsupported() throws {
        let data = Data(
            #"{"type":"control","v":2,"control":{"name":"set_something_new","value":"x"}}"#.utf8
        )
        let message = try JSONDecoder().decode(SiloControlMessage.self, from: data)
        XCTAssertEqual(message, .unsupportedControl(name: "set_something_new"))
    }

    func testUnsupportedControlRoundTrips() throws {
        let message = SiloControlMessage.unsupportedControl(name: "set_hdr_enabled")
        let data = try JSONEncoder().encode(message)
        XCTAssertEqual(try JSONDecoder().decode(SiloControlMessage.self, from: data), message)
    }

    /// A malformed command — no `name` at all — is still a real decode error.
    /// Tolerance is scoped to unknown names, not to junk.
    func testCommandWithoutNameStillFailsToDecode() {
        let data = Data(#"{"type":"control","v":2,"control":{"enabled":true}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SiloControlMessage.self, from: data))
    }

    // MARK: - Commands: no regression from the hand-written decoder

    /// `SiloControlCommand` now decodes by hand, so every argument field has
    /// to survive the round trip exactly as the synthesized decoder did.
    func testKnownCommandsRoundTripEveryArgument() throws {
        let commands: [SiloControlCommand] = [
            .play,
            .pause,
            .playPause,
            .stop,
            .playNext,
            .seek(seconds: 42.5),
            .selectAudioTrack(7),
            .selectSubtitleTrack(nil),
            .selectSubtitleTrack(3),
            .setPlaybackSpeed(1.75),
            .setQuality("1080p"),
            .setVideoGravity("fill"),
            .setSubtitleSyncMs(-250),
            .setSubtitlePosition("bottom"),
            .setVolume(0.6),
            .setMuted(true),
        ]
        for command in commands {
            let data = try JSONEncoder().encode(SiloControlMessage.control(command))
            let decoded = try JSONDecoder().decode(SiloControlMessage.self, from: data)
            XCTAssertEqual(decoded, .control(command), "round trip failed for \(command.name)")
        }
    }

    /// The wire names old peers match on are part of the contract, not an
    /// implementation detail.
    func testCommandWireNamesAreUnchanged() throws {
        let data = try JSONEncoder().encode(SiloControlMessage.control(.setVideoGravity("fill")))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let control = try XCTUnwrap(json["control"] as? [String: Any])
        XCTAssertEqual(control["name"] as? String, "set_video_gravity")
        XCTAssertEqual(control["value"] as? String, "fill")
    }

    // MARK: - Fixtures

    private static func stateJSON(extraKeys: String) -> String {
        """
        {"type":"state","v":2,"state":{
        "contentId":"c1","title":"Movie","isPlaying":true,"isLoading":false,
        "isBuffering":false,"currentTime":10.0,"duration":100.0,
        "audioTracks":[],"subtitleTracks":[],"qualityOptions":[],
        "activeQualityId":"auto","isQualitySwitching":false,"playbackSpeed":1.0,
        "videoGravity":"fit","hdrEnabled":false,"supportsVideoGravity":true,
        \(extraKeys)
        "volume":1.0,"isMuted":false,"hasNextEpisode":false}}
        """
    }
}

private extension SiloControlPlaybackState {
    static func compatFixture() -> SiloControlPlaybackState {
        SiloControlPlaybackState(
            contentId: "c1", sessionId: "s1", title: "Movie", subtitle: nil,
            isPlaying: true, isLoading: false, isBuffering: false,
            currentTime: 10, duration: 100,
            audioTracks: [], subtitleTracks: [],
            selectedAudioTrackId: nil, selectedSubtitleTrackId: nil,
            qualityOptions: [], activeQualityId: "auto", isQualitySwitching: false,
            playbackSpeed: 1.0, videoGravity: "fit", hdrEnabled: false,
            supportsVideoGravity: true,
            volume: 1.0, isMuted: false, hasNextEpisode: false, nextEpisodeTitle: nil,
            error: nil)
    }
}

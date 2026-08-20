import Foundation
import XCTest
@testable import Silo

enum PlaybackV3FixtureTestSupport {
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func fixtureURL(named name: String, bundleClass: AnyClass) throws -> URL {
        try XCTUnwrap(
            Bundle(for: bundleClass).url(forResource: name, withExtension: "json"),
            "Missing vendored Playback V3 fixture \(name).json"
        )
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        named name: String,
        bundleClass: AnyClass
    ) throws -> T {
        try decoder.decode(
            type,
            from: Data(contentsOf: fixtureURL(named: name, bundleClass: bundleClass))
        )
    }
}

/// Builds a planner execution plan from the fields the tests actually vary.
/// `selectedAudioTrackId`, `planAudioSelectionIndex` and
/// `selectedSecondarySubtitleTrackId` are `nil` at every call site.
func makeTestExecutionPlan(
    session: PlaybackSessionResponse,
    version: FileVersion,
    streamRequest: StreamRequest,
    routeRequirements: PlaybackRouteRequirements = .baseline,
    preferredAudioTrackIndex: Int? = nil,
    selectedPrimarySubtitleTrackId: Int64? = nil,
    dolbyVisionPolicy: DolbyVisionPolicy.Snapshot = .default
) -> PlaybackExecutionPlan {
    ApplePlaybackRoutePlanner().makeExecutionPlan(
        input: ApplePlaybackPlannerInput(
            session: session,
            selectedVersion: version,
            streamRequest: streamRequest,
            routeRequirements: routeRequirements,
            selectedAudioTrackId: nil,
            planAudioSelectionIndex: nil,
            preferredAudioTrackIndex: preferredAudioTrackIndex,
            selectedPrimarySubtitleTrackId: selectedPrimarySubtitleTrackId,
            selectedSecondarySubtitleTrackId: nil,
            dolbyVisionPolicy: dolbyVisionPolicy
        )
    )
}

// MARK: - Planner model fixtures

/// The stream URL every planner fixture is built around.
let testStreamURL = URL(string: "https://example.invalid/stream")!

func makeTestSession(
    playMethod: String = "direct",
    position: Double = 0,
    audioTrackIndex: Int? = 0
) -> PlaybackSessionResponse {
    PlaybackSessionResponse(
        sessionId: "test-session",
        userId: nil,
        profileId: nil,
        mediaFileId: 1,
        playMethod: playMethod,
        position: position,
        isPaused: false,
        streamUrl: testStreamURL.absoluteString,
        audioTrackIndex: audioTrackIndex,
        durationSeconds: 120,
        subtitleUrls: nil,
        playbackInfo: nil
    )
}

func makeTestAudioTrack(
    index: Int = 1,
    codec: String,
    channels: Int = 2,
    layout: String? = "stereo",
    language: String = "eng",
    title: String? = nil,
    isDefault: Bool = true
) -> AudioTrack {
    AudioTrack(
        index: index,
        codec: codec,
        channels: channels,
        channelLayout: layout,
        bitrate: 128_000,
        sampleRate: 48_000,
        language: language,
        title: title,
        embeddedTitle: title,
        isDefault: isDefault
    )
}

func makeTestVideoTrack(
    codec: String = "hevc",
    width: Int = 3840,
    height: Int = 2160,
    colorTransfer: String? = nil,
    videoRange: String? = nil,
    dolbyVision: String? = nil
) -> VideoTrack {
    VideoTrack(
        index: 0,
        codec: codec,
        width: width,
        height: height,
        frameRate: "23.976",
        bitrate: 20_000,
        profile: "Main 10",
        level: 153,
        bitDepth: 10,
        colorRange: "tv",
        colorTransfer: colorTransfer,
        videoRange: videoRange,
        dolbyVision: dolbyVision,
        title: nil,
        language: nil
    )
}

func makeTestSubtitleTrack(
    index: Int = 2,
    codec: String,
    isDefault: Bool = true,
    forced: Bool = false
) -> SubtitleTrack {
    SubtitleTrack(
        index: index,
        codec: codec,
        language: "eng",
        title: "English",
        embeddedTitle: "English",
        forced: forced,
        hearingImpaired: false,
        isDefault: isDefault,
        external: false,
        externalPath: nil
    )
}

func makeTestVersion(
    container: String,
    codecVideo: String?,
    codecAudio: String?,
    resolution: String = "2160p",
    bitrate: Int? = 20_000,
    videoTracks: [VideoTrack]? = nil,
    audioTracks: [AudioTrack]? = nil,
    subtitleTracks: [SubtitleTrack]? = nil
) -> FileVersion {
    FileVersion(
        fileId: 1,
        fileName: "fixture.\(container)",
        resolution: resolution,
        codecVideo: codecVideo,
        codecAudio: codecAudio,
        hdr: false,
        container: container,
        fileSize: 1_000_000,
        duration: 120,
        bitrate: bitrate,
        videoTracks: videoTracks,
        audioTracks: audioTracks,
        subtitleTracks: subtitleTracks,
        chapters: nil,
        effectiveAudioTrackIndex: 0
    )
}

#if os(iOS)
import XCTest
@testable import Silo

/// The phone remote's menus are built from `RemoteMenuModel` so the TV's
/// twice-a-second state frames don't rebuild an open menu. These guard the
/// split: per-frame fields must stay out of the model, and every value a menu
/// shows must stay in it.
final class RemoteMenuModelTests: XCTestCase {
    func testPerFrameFieldsDoNotChangeTheMenuModel() {
        let before = RemoteMenuModel(state: .menuFixture())
        let after = RemoteMenuModel(state: .menuFixture(
            isPlaying: false,
            isBuffering: true,
            currentTime: 1_234,
            volume: 0.2,
            isMuted: true
        ))

        XCTAssertEqual(before, after)
    }

    func testMenuValuesChangeTheMenuModel() {
        let base = RemoteMenuModel(state: .menuFixture())
        let changes: [(String, SiloControlPlaybackState)] = [
            ("subtitle tracks", .menuFixture(subtitleTracks: [.english, .spanish, .french])),
            ("selected subtitle", .menuFixture(selectedSubtitleTrackId: 11)),
            ("selected audio", .menuFixture(selectedAudioTrackId: 2)),
            ("active quality", .menuFixture(activeQualityId: "1080")),
            ("quality switching", .menuFixture(isQualitySwitching: true)),
            ("speed", .menuFixture(playbackSpeed: 1.5)),
            ("subtitle delay", .menuFixture(subtitleSyncMs: 500)),
            ("subtitle position", .menuFixture(subtitlePosition: "top")),
        ]

        for (name, state) in changes {
            XCTAssertNotEqual(base, RemoteMenuModel(state: state), name)
        }
    }
}

private extension SiloControlTrack {
    static let english = SiloControlTrack(kind: "sub", trackId: 10, title: "English", detail: nil)
    static let spanish = SiloControlTrack(kind: "sub", trackId: 11, title: "Spanish", detail: nil)
    static let french = SiloControlTrack(kind: "sub", trackId: 12, title: "French", detail: nil)
}

private extension SiloControlPlaybackState {
    static func menuFixture(
        isPlaying: Bool = true,
        isBuffering: Bool = false,
        currentTime: Double = 600,
        volume: Double = 0.8,
        isMuted: Bool = false,
        subtitleTracks: [SiloControlTrack] = [.english, .spanish],
        selectedAudioTrackId: Int64? = 1,
        selectedSubtitleTrackId: Int64? = 10,
        activeQualityId: String = "auto",
        isQualitySwitching: Bool = false,
        playbackSpeed: Double = 1.0,
        subtitleSyncMs: Int? = 0,
        subtitlePosition: String? = "bottom"
    ) -> SiloControlPlaybackState {
        var state = SiloControlPlaybackState(
            contentId: "c", sessionId: "s", title: "T", subtitle: nil,
            isPlaying: isPlaying, isLoading: false, isBuffering: isBuffering,
            currentTime: currentTime, duration: 3_600,
            audioTracks: [
                SiloControlTrack(kind: "audio", trackId: 1, title: "English", detail: "TrueHD"),
                SiloControlTrack(kind: "audio", trackId: 2, title: "Commentary", detail: "AC3"),
            ],
            subtitleTracks: subtitleTracks,
            selectedAudioTrackId: selectedAudioTrackId,
            selectedSubtitleTrackId: selectedSubtitleTrackId,
            qualityOptions: [
                SiloControlOption(id: "auto", label: "Auto", detail: nil),
                SiloControlOption(id: "1080", label: "1080p", detail: nil),
            ],
            activeQualityId: activeQualityId,
            isQualitySwitching: isQualitySwitching,
            playbackSpeed: playbackSpeed, videoGravity: "fit", hdrEnabled: false,
            supportsVideoGravity: true,
            volume: volume, isMuted: isMuted, hasNextEpisode: false, nextEpisodeTitle: nil,
            error: nil
        )
        state.subtitleSyncMs = subtitleSyncMs
        state.subtitlePosition = subtitlePosition
        state.supportsSubtitleDelay = true
        state.supportsSubtitlePosition = true
        return state
    }
}
#endif

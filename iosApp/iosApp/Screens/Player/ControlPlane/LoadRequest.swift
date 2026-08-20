import Foundation

/// What a load asks for: the content, the user's (or the server's) track and
/// quality preferences, and — for a local download — the offline record it must
/// be prepared from.
///
/// It used to be nested on `PlayerViewModel` and referenced as
/// `PlayerViewModel.LoadRequest`. Wave 3 moves it here because the control
/// plane, not the view model, is what carries it now: it rides
/// `PlayerIntent.load`, `Effect.startSession`, `Preparing.request`,
/// `Playing.request` and `SuspendedContext.request`, and it is the replay
/// intent every recovery rebuilds a fresh load from.
///
/// **It is adopted, not frozen.** `Preparing.request`/`Playing.request` are
/// rewritten at every `.prepared`, `.replanned` and `.renewed` through
/// `adoptingProtocolV3Intent` — see that method — so a replay carries the plan
/// the server last authorised rather than the one the load started with.
struct LoadRequest: Equatable {
    let contentId: String
    let preferredFileId: Int?
    let preferredAudioTrackIndex: Int?
    let preferredSubtitleTrackIndex: Int?
    let preferredSidecarSubtitleTrackId: Int64?
    let startFromBeginning: Bool
    /// Authoritative protocol-v3 combined ordinal. Unlike
    /// `preferredSubtitleTrackIndex`, this also represents external,
    /// downloaded, and server-extracted subtitle rows.
    var preferredProtocolV3SubtitleIndex: Int? = nil
    /// Set for local playback of a completed download. Routes the
    /// prepare through `OfflinePlaybackBuilder` instead of a server
    /// session, so retry after an error stays on the offline path.
    var offlineDownloadId: String? = nil
    /// Explicit quality for this load (mid-stream quality-change replan);
    /// wins over `PlayerSettings.preferredQuality` in the bridge.
    var preferredQualityOverride: String? = nil

    /// Rebuild a request for the same playback session while retaining the
    /// user's temporary quality choice. Recovery must not fall back to the
    /// persisted preference merely because tracks or the file id changed.
    func copyForRecovery(
        preferredFileId: Int?,
        preferredAudioTrackIndex: Int?,
        preferredSubtitleTrackIndex: Int?,
        preferredSidecarSubtitleTrackId: Int64?,
        offlineDownloadId: String?
    ) -> LoadRequest {
        var request = LoadRequest(
            contentId: contentId,
            preferredFileId: preferredFileId,
            preferredAudioTrackIndex: preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
            preferredSidecarSubtitleTrackId: preferredSidecarSubtitleTrackId,
            startFromBeginning: false,
            offlineDownloadId: offlineDownloadId,
            preferredQualityOverride: preferredQualityOverride
        )
        request.preferredProtocolV3SubtitleIndex = preferredProtocolV3SubtitleIndex
        return request
    }

    /// Refresh the inputs used by session renewal from an adopted V3 plan.
    /// Player track lists are transient and may already be empty when a
    /// failed transport reports that its server session disappeared.
    func adoptingProtocolV3Intent(
        plan: PlaybackV3Plan,
        selectedVersion: FileVersion,
        activeQualityId: String
    ) -> LoadRequest {
        let selectedSubtitleIndex = plan.selectedTracks.subtitle?.index
        let selectedSubtitle = selectedSubtitleIndex.flatMap { selectedIndex in
            plan.subtitle.inventory.first(where: { $0.combinedIndex == selectedIndex })
        }
        let embeddedFFmpegIndex: Int? = selectedSubtitle.flatMap { item in
            // A sidecar is the server-selected artifact even when it was
            // extracted from an embedded stream. Arming both identities
            // would publish and select the same subtitle twice.
            guard item.source == "embedded", item.delivery != "sidecar" else { return nil }
            return ApplePlaybackV3PlanAdapter.ffmpegSubtitleStreamIndex(
                serverCombinedIndex: item.combinedIndex,
                in: selectedVersion
            )
        }
        let sidecarTrackId: Int64? = selectedSubtitle.flatMap { item in
            guard item.delivery == "sidecar" else { return nil }
            return SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: item.combinedIndex)
        }
        var request = copyForRecovery(
            preferredFileId: plan.effectiveMediaFileId,
            preferredAudioTrackIndex: plan.selectedTracks.audio?.index,
            preferredSubtitleTrackIndex: embeddedFFmpegIndex,
            preferredSidecarSubtitleTrackId: sidecarTrackId,
            offlineDownloadId: offlineDownloadId
        )
        request.preferredProtocolV3SubtitleIndex = selectedSubtitleIndex
        request.preferredQualityOverride = activeQualityId
        return request
    }

    /// Every stored property, compared. `PlaybackReducerTests`'
    /// `testLoadRequestEqualityCoversEveryStoredProperty` fails if one is added
    /// without being listed here.
    ///
    /// Written out rather than synthesised because the reducer's structural
    /// guards compare requests, and a silently-synthesised conformance would
    /// grow a new field without the test noticing.
    static func == (lhs: LoadRequest, rhs: LoadRequest) -> Bool {
        lhs.contentId == rhs.contentId
            && lhs.preferredFileId == rhs.preferredFileId
            && lhs.preferredAudioTrackIndex == rhs.preferredAudioTrackIndex
            && lhs.preferredSubtitleTrackIndex == rhs.preferredSubtitleTrackIndex
            && lhs.preferredSidecarSubtitleTrackId == rhs.preferredSidecarSubtitleTrackId
            && lhs.startFromBeginning == rhs.startFromBeginning
            && lhs.preferredProtocolV3SubtitleIndex == rhs.preferredProtocolV3SubtitleIndex
            && lhs.offlineDownloadId == rhs.offlineDownloadId
            && lhs.preferredQualityOverride == rhs.preferredQualityOverride
    }
}

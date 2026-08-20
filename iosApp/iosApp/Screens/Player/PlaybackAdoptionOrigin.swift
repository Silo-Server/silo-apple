import Foundation

/// Origin-specific inputs for `adoptPreparedPlayback`.
///
/// The three pipelines that adopt a prepared playback (`beginFreshLoad`,
/// `attemptProtocolV3Replan`, `restartCurrentTranscodeHLS`) publish the
/// same session/track/quality state and then run the identical
/// `makeStreamRequest` → `makeExecutionPlan` → `logExecutionPlan` →
/// `loadStream` tail. Everything they genuinely disagree about is spelled
/// out here rather than being silently unified.
///
/// Top-level rather than nested in `PlayerViewModel`: both halves of the adopt
/// take it — the shell's `adoptPrepared` and the track half's
/// `TrackSelectionCoordinator.adopt(prepared:origin:)`.
enum PlaybackAdoptionOrigin {
    /// A brand-new item. Owns the fields nothing else republishes — title,
    /// metadata, chapters, marker ranges, the subtitle-policy snapshot —
    /// and binds realtime unconditionally because there is no prior
    /// session to keep.
    case freshLoad(FreshLoad)
    /// An in-place V3 plan replacement (error recovery, output-route
    /// change, quality-switch completion). The only origin that keeps the
    /// outgoing backend alive across the reload.
    case protocolV3Replan(Replan)
    /// An in-place stream restart for a seek reanchor or a quality change.
    case transcodeRestart(TranscodeRestart)

    struct FreshLoad {
        /// Offline playback has no server session: no realtime channel, no
        /// catalog artwork, no Next Up lookup.
        let isOffline: Bool
        /// `resumePositionOverride`; feeds `timelineOffset(for:session:requestedStart:)`.
        let requestedStart: Double?
    }

    struct Replan {
        /// Subtitle selection captured before the replan started, used to
        /// re-establish a sidecar / server-rendered choice afterwards.
        let selectedSubtitleSnapshot: Int64?
    }

    struct TranscodeRestart {
        let target: Double
        let isQualitySwitch: Bool
        let selectedSubtitleSnapshot: Int64?
        /// The restart keeps the previous sidecar list when the replacement
        /// session omits one; the other two origins reset to empty.
        let subtitleUrlFallback: [SubtitleUrl]
        let recoveredEmbeddedSubtitleSelection: TrackSelectionSnapshot?
        let recoveredSecondarySubtitleId: Int64?
        let selectionOrigin: SelectionOrigin
    }

    var subtitleUrlFallback: [SubtitleUrl] {
        if case .transcodeRestart(let restart) = self { return restart.subtitleUrlFallback }
        return []
    }

    /// Only a live protocol replan has a known-good outgoing backend worth
    /// preserving across the reload.
    var reusesActiveEngine: Bool {
        if case .protocolV3Replan = self { return true }
        return false
    }

    var invalidStreamURLMessage: String {
        if case .protocolV3Replan = self {
            return "The replacement V3 plan returned an invalid stream URL."
        }
        return "Invalid stream URL"
    }
}

import Foundation

/// A renderer choice made after the server issued the current video plan.
/// Keep the server identity so another file cannot reuse the same ordinal.
/// `nil` at the call site means the plan still owns selection.
enum ProtocolV3SubtitleSelection: Equatable {
    case off
    case track(String)

    init?(track: PlayerTrack?, plan: PlaybackV3Plan) {
        guard let track else {
            self = .off
            return
        }
        guard let item = plan.subtitle.inventory.first(where: {
            SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: $0.combinedIndex) == track.trackId
        }) else { return nil }
        self = .track(item.trackId)
    }

    func inventoryItem(in plan: PlaybackV3Plan) -> PlaybackV3SubtitleInventoryItem? {
        guard case .track(let id) = self else { return nil }
        return plan.subtitle.inventory.first { $0.trackId == id }
    }

    func appTrackID(in plan: PlaybackV3Plan) -> Int64? {
        inventoryItem(in: plan).map {
            SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: $0.combinedIndex)
        }
    }

    /// Nil means no known override; -1 explicitly clears a server selection.
    func replanIndex(in plan: PlaybackV3Plan) -> Int? {
        self == .off ? -1 : inventoryItem(in: plan)?.combinedIndex
    }

    /// Original-file playback already demuxes every embedded subtitle. The
    /// inventory's combined ordinal is a menu identity; only an FFmpeg index
    /// can identify a stream in that opened file: the row's own, else the
    /// picker row's catalog-derived one.
    func embeddedStreamIndex(for track: PlayerTrack, in plan: PlaybackV3Plan) -> Int? {
        guard plan.delivery == PlaybackProtocolV3.PlanDelivery.originalHTTP,
              plan.subtitle.mode != PlaybackProtocolV3.SubtitleMode.burnIn,
              appTrackID(in: plan) == track.trackId,
              let item = inventoryItem(in: plan), item.source == "embedded",
              let codec = item.codec, let container = plan.stream.container,
              let streamIndex = item.embeddedStreamIndex ?? track.ffIndex, streamIndex >= 0,
              ApplePlaybackV3Capabilities.nativeEmbeddedSubtitleCapabilities(containers: [container])
                .contains(where: { $0.codecs.contains(ApplePlaybackV3Capabilities.normalizedSubtitleCodec(codec)) })
        else { return nil }
        return streamIndex
    }

    /// `serverCarriesSubtitleRenditions`: the attempt's server negotiated
    /// `hls_subtitle_renditions_v1`, so it can carry an embedded text track in
    /// a transcode's own stream. `serverCarriesRemuxSubtitleRenditions`: it
    /// also negotiated `hls_remux_subtitle_renditions_v1`, so a copy remux can
    /// carry one too.
    func canApplyLocally(
        to plan: PlaybackV3Plan,
        isMounted: Bool,
        serverCarriesSubtitleRenditions: Bool = false,
        serverCarriesRemuxSubtitleRenditions: Bool = false
    ) -> Bool {
        guard plan.subtitle.mode != PlaybackProtocolV3.SubtitleMode.burnIn else { return false }
        if self == .off { return true }
        guard let item = inventoryItem(in: plan) else { return false }
        if isMounted { return true }
        // Server HLS carries an embedded text track inside its own stream.
        // Mounting the inventory sidecar instead would demux the whole source
        // file before the first cue, so the pick goes to the server; a server
        // that cannot emit the rendition this time answers with a sidecar plan
        // on the same transport.
        let streamCarriesRendition = plan.delivery == PlaybackProtocolV3.PlanDelivery.transcodeHLS
            || plan.delivery == PlaybackProtocolV3.PlanDelivery.remuxHLS && serverCarriesRemuxSubtitleRenditions
        if serverCarriesSubtitleRenditions,
           streamCarriesRendition,
           item.source == "embedded",
           !SubtitleCodecClassifier.isBitmap(item.codec) {
            return false
        }
        return (item.delivery == "sidecar"
            && item.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
}

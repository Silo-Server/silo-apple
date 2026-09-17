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

    /// Original-file playback already demuxes every embedded subtitle. The
    /// inventory's combined ordinal is a menu identity; only the catalog's
    /// FFmpeg index can identify a stream in that opened file.
    func embeddedStreamIndex(for track: PlayerTrack, in plan: PlaybackV3Plan) -> Int? {
        guard plan.delivery == PlaybackProtocolV3.PlanDelivery.originalHTTP,
              plan.subtitle.mode != PlaybackProtocolV3.SubtitleMode.burnIn,
              appTrackID(in: plan) == track.trackId,
              let item = inventoryItem(in: plan), item.source == "embedded",
              let codec = item.codec, let container = plan.stream.container,
              let streamIndex = track.ffIndex, streamIndex >= 0,
              ApplePlaybackV3Capabilities.nativeEmbeddedSubtitleCapabilities(containers: [container])
                .contains(where: { $0.codecs.contains(ApplePlaybackV3Capabilities.normalizedSubtitleCodec(codec)) })
        else { return nil }
        return streamIndex
    }

    func canApplyLocally(to plan: PlaybackV3Plan, isMounted: Bool) -> Bool {
        guard plan.subtitle.mode != PlaybackProtocolV3.SubtitleMode.burnIn else { return false }
        if self == .off { return true }
        guard let item = inventoryItem(in: plan) else { return false }
        return isMounted || (item.delivery == "sidecar"
            && item.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }
}

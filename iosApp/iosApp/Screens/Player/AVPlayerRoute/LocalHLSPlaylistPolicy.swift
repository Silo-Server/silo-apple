import Foundation

enum LocalHLSPlaylistPolicy {
    enum PlaylistType: Equatable {
        case liveSliding
        case vod

        var hlsTag: String? {
            switch self {
            case .liveSliding: return nil
            case .vod: return "#EXT-X-PLAYLIST-TYPE:VOD"
            }
        }
    }

    /// When the store retires (deletes) old segment bytes to stay under the
    /// spill budget, the manifest MUST drop those segments too. The manifest
    /// is sliding-live from the first publish, so retiring bytes only advances
    /// `firstMediaSequence`; it does not change playlist type mid-session.
    static let shouldRemoveRetiredSegmentsFromPlaylist = true

    static func shouldEmitStartTag(firstMediaSequence: Int) -> Bool {
        firstMediaSequence <= 0
    }

    static func playlistType(isFinal: Bool) -> PlaylistType {
        isFinal ? .vod : .liveSliding
    }

    /// HLS `BANDWIDTH` declares the variant's peak segment bitrate; declaring
    /// less makes AVFoundation log a -12318 "Segment exceeds specified
    /// bandwidth" errorLog entry for every oversized segment. The true peak
    /// is unknown when the master playlist is written, so declare the source
    /// average with 2x headroom (remux copies the video through, so generated
    /// bitrate tracks the source; FLAC audio bridging can locally exceed the
    /// average). Overstating is harmless on a single-variant playlist — there
    /// is no ABR decision to skew. Sources with no reported bitrate keep the
    /// legacy 18 Mbps declaration.
    static let fallbackMasterBandwidthBps = 18_000_000

    static func masterPlaylistBandwidth(
        sourceBitrateBps: Double?
    ) -> (peak: Int, average: Int?) {
        guard let sourceBitrateBps,
              sourceBitrateBps.isFinite,
              sourceBitrateBps > 0 else {
            return (fallbackMasterBandwidthBps, nil)
        }
        let average = Int(min(sourceBitrateBps, 1_000_000_000))
        return (max(fallbackMasterBandwidthBps, average * 2), average)
    }
}

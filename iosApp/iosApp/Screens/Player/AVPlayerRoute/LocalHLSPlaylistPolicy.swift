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

    static func shouldEmitStartTag(firstMediaSequence: Int) -> Bool {
        firstMediaSequence <= 0
    }

    static func playlistType(isFinal: Bool) -> PlaylistType {
        isFinal ? .vod : .liveSliding
    }

    /// Legacy declaration, kept for sources with no reported bitrate.
    static let fallbackMasterBandwidthBps = 18_000_000

    /// Bridging a lossy source track to lossless FLAC can push the served
    /// variant's average above the source container average (multichannel
    /// FLAC runs ~2-4 Mbps vs ~768 kbps DTS), and RFC 8216 forbids
    /// understating AVERAGE-BANDWIDTH; budget a conservative allowance.
    static let bridgedLosslessAudioAllowanceBps: Double = 4_000_000

    /// HLS `BANDWIDTH` declares the variant's peak segment bitrate; declaring
    /// less makes AVFoundation log a -12318 "Segment exceeds specified
    /// bandwidth" errorLog entry for every oversized segment. The true peak
    /// is unknown when the master playlist is written, so declare the source
    /// average with 2x headroom (remux copies the video through, so generated
    /// bitrate tracks the source; FLAC audio bridging can locally exceed the
    /// average). Overstating is harmless on a single-variant playlist — there
    /// is no ABR decision to skew. Sources with no reported bitrate keep the
    /// legacy 18 Mbps declaration.
    static func masterPlaylistBandwidth(
        sourceBitrateBps: Double?,
        isAudioBridgedToLossless: Bool
    ) -> (peak: Int, average: Int?) {
        guard let sourceBitrateBps,
              sourceBitrateBps.isFinite,
              sourceBitrateBps > 0 else {
            return (fallbackMasterBandwidthBps, nil)
        }
        let servedBitrateBps = sourceBitrateBps
            + (isAudioBridgedToLossless ? bridgedLosslessAudioAllowanceBps : 0)
        let average = Int(min(servedBitrateBps, 1_000_000_000))
        return (max(fallbackMasterBandwidthBps, average * 2), average)
    }
}

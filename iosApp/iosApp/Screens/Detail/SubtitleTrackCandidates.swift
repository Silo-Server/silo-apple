import Foundation

/// Maps the catalog payload's `SubtitleTrack` metadata onto the `PlayerTrack`
/// shape `SubtitleAutoResolver` consumes, so anything that needs to know what
/// the player will auto-select runs the real resolver instead of restating its
/// policy.
///
/// The body is the mapping `PlaybackSessionBridge.initialProtocolV3SubtitleIntent`
/// builds before it calls the resolver, which is the one caller of
/// `playerTracks(from:)`.
enum SubtitleTrackCandidates {
    /// Resolver candidates paired with the ordinal of the `SubtitleTrack` each
    /// came from, so a resolved pick can be mapped back to the payload entry.
    /// Embedded tracks with no ffmpeg stream index are dropped — nothing can
    /// address them; external sidecars keep their synthetic sidecar id.
    static func indexedPlayerTracks(
        from tracks: [SubtitleTrack]
    ) -> [(ordinal: Int, track: PlayerTrack)] {
        var externalOrdinal = 0
        return tracks.enumerated().compactMap { ordinal, track in
            let isExternal = track.external == true
            let trackId: Int64
            let sourceIndex: Int?
            if isExternal {
                sourceIndex = externalOrdinal
                trackId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: externalOrdinal)
                externalOrdinal += 1
            } else {
                guard let index = track.index else { return nil }
                sourceIndex = nil
                trackId = Int64(index)
            }
            return (
                ordinal,
                PlayerTrack(
                    trackId: trackId,
                    kind: .sub,
                    title: track.title ?? track.embeddedTitle,
                    lang: track.language,
                    codec: track.codec,
                    audioChannelsLayout: nil,
                    audioChannelCount: nil,
                    bitrate: nil,
                    isDefault: track.isDefault ?? false,
                    isForced: track.forced ?? false,
                    isHearingImpaired: track.hearingImpaired ?? false,
                    isVisualImpaired: false,
                    isExternal: isExternal,
                    isSelected: false,
                    ffIndex: isExternal ? nil : track.index,
                    srcId: sourceIndex
                )
            )
        }
    }

    /// The candidate list alone — the shape `SubtitleAutoResolver.Inputs` takes.
    static func playerTracks(from tracks: [SubtitleTrack]) -> [PlayerTrack] {
        indexedPlayerTracks(from: tracks).map(\.track)
    }
}

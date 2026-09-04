import Foundation

/// Maps detail payload subtitle metadata into the exact candidate shape the
/// player's auto resolver consumes.
///
/// Candidates are ordered external-first to match the Protocol V3 combined
/// ordinal space (externals, then embedded, then downloaded). The watch detail
/// lists embedded tracks before externals, and the resolver is first-match
/// within a track class, so resolving in catalog order picks a different
/// track than the post-load resolver does over the plan inventory. That
/// disagreement forced a `subtitle_track_changed` replan, and a full engine
/// reload, on every episode start.
enum SubtitleTrackCandidates {
    /// `ordinal` is the position in the returned combined order, not the
    /// catalog offset the track came from.
    static func indexedPlayerTracks(
        from tracks: [SubtitleTrack]
    ) -> [(ordinal: Int, track: PlayerTrack)] {
        var externalOrdinal = 0
        let combinedOrder = tracks.filter { $0.external == true }
            + tracks.filter { $0.external != true }
        return combinedOrder.enumerated().compactMap { ordinal, track in
            let isExternal = track.external == true
            let trackId: Int64
            let sourceIndex: Int?
            if isExternal {
                sourceIndex = externalOrdinal
                trackId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: externalOrdinal)
                externalOrdinal += 1
            } else {
                // Embedded tracks always resolve: `selectionIndex` reads a
                // missing wire index (`index,omitempty`) as FFmpeg stream 0.
                let index = track.selectionIndex ?? 0
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
                    audioChannelCount: nil,
                    bitrate: nil,
                    isDefault: track.isDefault ?? false,
                    isForced: track.forced ?? false,
                    isHearingImpaired: track.hearingImpaired ?? false,
                    isExternal: isExternal,
                    isSelected: false,
                    ffIndex: isExternal ? nil : track.selectionIndex,
                    srcId: sourceIndex
                )
            )
        }
    }

    static func playerTracks(from tracks: [SubtitleTrack]) -> [PlayerTrack] {
        indexedPlayerTracks(from: tracks).map(\.track)
    }
}

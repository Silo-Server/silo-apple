import Foundation

/// Local-playback corrections to the track inventory AetherEngine probes.
///
/// A server-prepared download (remux or transcode) is an MP4 the server muxed
/// itself, and its container metadata is not the source's:
///   - MP4 stores a track title only as its handler name, which FFmpeg does not
///     read back as `title`, so Aether falls back to a synthesized
///     "ENG (aac)" / "Track 2 (mov_text)" name;
///   - the MP4 muxer marks the first timed-text track default whatever the
///     source said, so that flag carries no authoring intent.
/// The manifest's `audio_tracks` list the delivered file's audio streams in
/// order, so it restores the audio titles. Original-quality downloads play the
/// source file itself and are left exactly as probed.
enum OfflinePreparedTrackInventory {

    /// Replace Aether's synthesized audio names with the manifest's titles.
    /// When the counts disagree the file is not the one the manifest
    /// describes, so ordinals cannot be trusted and the tracks stay as probed.
    static func audioTracks(_ tracks: [PlayerTrack], manifestTracks: [AudioTrack]?) -> [PlayerTrack] {
        let described = manifestTracks ?? []
        guard described.count == tracks.count else {
            return tracks.map { track in
                track.replacing(title: hasSynthesizedName(track) ? nil : track.title)
            }
        }
        return zip(tracks, described).map { track, manifestTrack in
            guard hasSynthesizedName(track) else { return track }
            return track.replacing(
                title: PlayerTrack.normalizedText(manifestTrack.title),
                lang: track.normalizedLanguageCode ?? PlayerTrack.normalizedText(manifestTrack.language)
            )
        }
    }

    /// Drop the muxer's default flag and synthesized names from the timed-text
    /// tracks inside the file. Sidecars keep the manifest's own metadata.
    static func subtitleTracks(_ tracks: [PlayerTrack]) -> [PlayerTrack] {
        tracks.map { track in
            guard !track.isExternal else { return track }
            return track.replacing(
                title: hasSynthesizedName(track) ? nil : track.title,
                isDefault: false
            )
        }
    }

    /// Aether names an untitled stream "<LANG> (<codec>)", or
    /// "Track <id> (<codec>)" without a language (`Demuxer.trackInfo`).
    static func hasSynthesizedName(_ track: PlayerTrack) -> Bool {
        guard let title = track.title, let codec = track.codec else { return false }
        if let lang = track.lang, title == "\(lang.uppercased()) (\(codec))" {
            return true
        }
        if let ffIndex = track.ffIndex, title == "Track \(ffIndex) (\(codec))" {
            return true
        }
        return false
    }
}

private extension PlayerTrack {
    func replacing(title: String?, lang: String? = nil, isDefault: Bool? = nil) -> PlayerTrack {
        PlayerTrack(
            trackId: trackId,
            kind: kind,
            title: title,
            lang: lang ?? self.lang,
            codec: codec,
            audioChannelCount: audioChannelCount,
            bitrate: bitrate,
            isDefault: isDefault ?? self.isDefault,
            isForced: isForced,
            isHearingImpaired: isHearingImpaired,
            isExternal: isExternal,
            isSelected: isSelected,
            ffIndex: ffIndex,
            srcId: srcId,
            isDownloaded: isDownloaded
        )
    }
}

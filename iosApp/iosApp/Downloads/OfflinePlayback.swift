import Foundation

/// Synthesizes the same `PreparedPlayback` the online path produces, but
/// from a stored offline manifest + local media file, so the player loads
/// with no server session. The local file plays via the existing engines
/// (FFmpeg `PlayerCore` for MKV/etc., `AVPlayer` for MP4) and the manifest
/// drives chapters, intro/credits markers, and subtitles unchanged.
enum OfflinePlaybackBuilder {
    static func makePreparedPlayback(
        leafContentId: String,
        manifest: OfflineManifest,
        mediaURL: URL,
        subtitleURLs: [SubtitleUrl],
        resumePosition: Double?
    ) -> PreparedPlayback {
        let version = FileVersion(
            fileId: manifest.mediaFileId,
            fileName: nil,
            resolution: manifest.resolution,
            codecVideo: manifest.codecVideo,
            codecAudio: manifest.codecAudio,
            hdr: manifest.hdr,
            container: manifest.container,
            fileSize: manifest.fileSize,
            duration: manifest.durationSeconds,
            bitrate: nil,
            videoTracks: nil,
            audioTracks: nil,
            subtitleTracks: nil,
            chapters: manifest.chapters,
            intro: manifest.intro,
            credits: manifest.credits
        )

        let watchDetail = WatchDetail(
            offlineLeafContentId: leafContentId,
            manifest: manifest,
            version: version
        )

        let session = PlaybackSessionResponse(
            sessionId: "offline-\(manifest.downloadId)",
            userId: nil,
            profileId: nil,
            mediaFileId: manifest.mediaFileId,
            playMethod: "direct",
            position: resumePosition ?? 0,
            isPaused: false,
            streamUrl: mediaURL.absoluteString,
            audioTrackIndex: nil,
            durationSeconds: manifest.durationSeconds,
            timelineOffsetSeconds: 0,
            subtitleUrls: subtitleURLs.isEmpty ? nil : subtitleURLs,
            playbackInfo: nil
        )

        return PreparedPlayback(
            watchDetail: watchDetail,
            selectedVersion: version,
            session: session
        )
    }
}

extension WatchDetail {
    /// Build a `WatchDetail` from a stored offline manifest. `WatchDetail`
    /// has only a decoding initializer, so this sets every stored property
    /// directly. `userData` is nil — the offline resume point is carried on
    /// the synthetic session's `position` instead.
    init(offlineLeafContentId: String, manifest: OfflineManifest, version: FileVersion) {
        contentId = offlineLeafContentId
        type = manifest.type
        title = manifest.title
        year = manifest.year
        overview = manifest.overview
        versions = [version]
        subtitles = nil
        intro = manifest.intro
        credits = manifest.credits
        userData = nil
        seriesId = manifest.seriesId
        seriesTitle = manifest.seriesTitle
        seasonNumber = manifest.seasonNumber
        episodeNumber = manifest.episodeNumber
        effectiveSubtitleLanguage = nil
        effectiveSubtitleMode = nil
        effectiveShowForcedSubtitles = nil
        effectiveSubtitleTrackSignature = nil
    }
}

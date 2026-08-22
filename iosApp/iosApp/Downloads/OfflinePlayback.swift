import Foundation

/// Failure modes for the local offline prepare. Terminal — there is no
/// server to fall back to, so these surface through the player's standard
/// error wall via `errorDescription`.
enum OfflinePlaybackError: LocalizedError {
    case downloadNotFound
    case manifestUnavailable
    case mediaFileMissing

    var errorDescription: String? {
        switch self {
        case .downloadNotFound:
            return "This download is no longer on this device."
        case .manifestUnavailable:
            return "The offline playback data for this download is missing. Delete and re-download it."
        case .mediaFileMissing:
            return "The downloaded video file is missing. Delete and re-download it."
        }
    }
}

/// A locally-synthesized playback bundle plus the identity the player needs
/// to route watch progress into the offline queue instead of a server
/// session.
struct OfflinePreparedPlayback {
    let prepared: PreparedPlayback
    let downloadId: String
    /// Leaf media item id progress is keyed by — the episode id for an
    /// episode download, otherwise the movie content id.
    let mediaItemId: String
    /// Cached poster on disk, so the Now Playing widget gets artwork
    /// without a catalog fetch.
    let posterFileURL: URL?
}

/// Synthesizes the same `PreparedPlayback` the online path produces, but
/// from a stored offline manifest + local media file, so AetherEngine loads
/// with no server session. Aether probes the delivered file itself; the
/// manifest remains authoritative for catalog metadata, chapters,
/// intro/credits markers, track preferences, and downloaded subtitles.
enum OfflinePlaybackBuilder {
    /// Near-end resume points restart from zero, mirroring the session
    /// bridge's suppression window so offline resume feels identical to
    /// the online path.
    private static let nearEndResumeSuppressionSeconds: Double = 5

    /// Assemble a fully local `OfflinePreparedPlayback` for a completed
    /// download. Reads only the on-device record/manifest/media — never
    /// the network — so it works in airplane mode.
    @MainActor
    static func loadPreparedPlayback(
        downloadId: String,
        startFromBeginning: Bool,
        resumePositionOverride: Double?
    ) async throws -> OfflinePreparedPlayback {
        let manager = DownloadManager.shared
        guard let record = manager.record(id: downloadId), record.isPlayableOffline else {
            throw OfflinePlaybackError.downloadNotFound
        }
        guard let manifest = await manager.loadManifest(for: record) else {
            throw OfflinePlaybackError.manifestUnavailable
        }
        guard let mediaURL = manager.absoluteMediaURL(for: record),
              FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw OfflinePlaybackError.mediaFileMissing
        }

        let leafId = record.leafMediaItemId
        let prepared = makePreparedPlayback(
            leafContentId: leafId,
            manifest: manifest,
            mediaURL: mediaURL,
            subtitleURLs: localSubtitleUrls(record: record, manifest: manifest, manager: manager),
            resumePosition: resolvedResumePosition(
                startFromBeginning: startFromBeginning,
                explicitPosition: resumePositionOverride,
                storedPosition: manager.localProgress(forMediaItemId: leafId)?.position,
                duration: manifest.durationSeconds
            )
        )
        let posterFileURL = record.posterFilename.flatMap {
            manager.absoluteFileURL(for: record, filename: $0)
        }
        return OfflinePreparedPlayback(
            prepared: prepared,
            downloadId: record.id,
            mediaItemId: leafId,
            posterFileURL: posterFileURL
        )
    }

    /// Map the manifest's sidecar subtitles to their cached on-disk files.
    /// Entries whose fetch never completed are skipped rather than surfaced
    /// as broken tracks.
    @MainActor
    private static func localSubtitleUrls(
        record: DownloadRecord,
        manifest: OfflineManifest,
        manager: DownloadManager
    ) -> [SubtitleUrl] {
        var urls: [SubtitleUrl] = []
        for (index, subtitle) in (manifest.subtitles ?? []).enumerated() {
            guard let filename = record.subtitleFilenames[subtitle.fetchUrl],
                  let fileURL = manager.absoluteFileURL(for: record, filename: filename),
                  FileManager.default.fileExists(atPath: fileURL.path) else {
                continue
            }
            urls.append(SubtitleUrl(
                index: index,
                language: subtitle.language,
                codec: subtitle.format,
                label: nil,
                // Manifest subtitles are always sidecar files
                // (`external:{i}` / `downloaded:{id}`), never embedded, so
                // they must survive Aether's embedded-track inventory merge.
                source: "external",
                forced: subtitle.forced,
                url: fileURL.absoluteString
            ))
        }
        return urls
    }

    /// Offline mirror of the session bridge's resume resolution: explicit
    /// "start over" wins, then the caller's position, then the stored local
    /// resume point — with near-end positions restarting from zero.
    private static func resolvedResumePosition(
        startFromBeginning: Bool,
        explicitPosition: Double?,
        storedPosition: Double?,
        duration: Double?
    ) -> Double? {
        if startFromBeginning { return 0 }
        let candidate = [explicitPosition, storedPosition]
            .compactMap { value -> Double? in
                guard let value, value.isFinite, value >= 0 else { return nil }
                return value
            }
            .first
        guard let candidate else { return nil }
        guard let duration, duration.isFinite, duration > 0 else { return candidate }
        return candidate >= max(0, duration - nearEndResumeSuppressionSeconds) ? 0 : candidate
    }

    /// Map the manifest's audio tracks into the catalog `AudioTrack` shape the
    /// player and detail views read.
    ///
    /// `index` is deliberately dropped rather than forwarded. `AudioTrack.index`
    /// means the source stream index, while the manifest's `index` is only the
    /// ordinal within this list. Aether's probe maps that ordinal to the real
    /// source stream identifier immediately before the offline load.
    ///
    /// `embeddedTitle` stays nil because the server already collapsed the
    /// cleaned and embedded titles into one field; echoing the same string back
    /// as both would corrupt the audio-pref signature that compares them
    /// separately.
    private static func audioTracks(from manifest: OfflineManifest) -> [AudioTrack]? {
        manifest.audioTracks.map { tracks in
            tracks.map { track in
                AudioTrack(
                    index: nil,
                    codec: track.codec,
                    channels: track.channels,
                    channelLayout: track.layout,
                    bitrate: track.bitrate,
                    sampleRate: track.sampleRate,
                    language: track.language,
                    title: track.title,
                    embeddedTitle: nil,
                    isDefault: track.isDefault
                )
            }
        }
    }

    /// Overall bitrate in kbps, matching the probed value the server puts on an
    /// online `FileVersion` and keeping offline metadata consistent with the
    /// same file streamed.
    ///
    /// The manifest carries no probed bitrate, so derive the real average from
    /// the delivered file. `targetBitrateKbps` is only a transcode target and
    /// is absent for original downloads, so it is the fallback, not the source.
    /// A sub-second duration would be a corrupt manifest, not real content, and
    /// dividing by it produces a value `Int(_:)` traps on. Both bounds below
    /// keep a bad manifest falling back rather than crashing playback.
    private static func averageBitrateKbps(from manifest: OfflineManifest) -> Int? {
        guard let fileSize = manifest.fileSize, fileSize > 0,
              let duration = manifest.durationSeconds, duration >= 1 else {
            return manifest.targetBitrateKbps
        }
        let kbps = Double(fileSize) * 8 / duration / 1_000
        guard kbps.isFinite, kbps >= 1, kbps < Double(Int32.max) else {
            return manifest.targetBitrateKbps
        }
        return Int(kbps)
    }

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
            bitrate: averageBitrateKbps(from: manifest),
            // AetherEngine probes the actual downloaded file. The manifest
            // intentionally does not pretend to describe delivered streams.
            videoTracks: nil,
            audioTracks: audioTracks(from: manifest),
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
            audioTrackIndex: manifest.selectedAudioTrackIndex,
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

import Foundation

/// One audio part of a book. Active playback uses server-issued offsets and durations.
struct AudioPlaybackTrack: Identifiable, Hashable {
    let index: Int
    let fileId: Int
    let fileName: String?
    let version: FileVersion
    let durationSeconds: Double
    let startOffsetSeconds: Double
    var id: Int { index }
}

/// Chapter mapped onto the whole-book timeline (file-local chapter starts
/// shifted by the owning track's start offset).
struct AudioPlaybackChapter: Identifiable, Hashable {
    let index: Int
    let title: String?
    let startSeconds: Double
    let endSeconds: Double?
    let trackIndex: Int?
    var id: String { "\(trackIndex ?? -1)-\(index)-\(startSeconds)" }
}

/// Everything the audio player needs to drive a whole book through the
/// standard per-file playback API: the ordered file list stitched into one
/// timeline, merged chapters, and the book-level resume point.
struct AudiobookPlaybackContext {
    let contentId: String
    let title: String
    let subtitle: String?
    let posterUrl: String?
    let totalDurationSeconds: Double
    let resumePositionSeconds: Double
    let tracks: [AudioPlaybackTrack]
    let chapters: [AudioPlaybackChapter]

    init(detail: ItemDetail, manifest: APIv2PlaybackManifest) throws {
        guard manifest.mediaItemId == detail.contentId else { throw PlaybackSequencedError.invalidResponse }
        var tracks: [AudioPlaybackTrack] = []
        var chapters: [AudioPlaybackChapter] = []
        for (index, part) in manifest.parts.enumerated() {
            guard let fileID = Int(part.fileId) else { throw PlaybackSequencedError.invalidResponse }
            let metadata = detail.versions?.first { $0.fileId == fileID }
                ?? FileVersion(fileId: fileID, fileName: nil, resolution: nil, codecVideo: nil,
                    codecAudio: nil, hdr: nil, container: nil, fileSize: nil, duration: nil,
                    bitrate: nil, videoTracks: nil, audioTracks: nil, subtitleTracks: nil, chapters: nil)
            tracks.append(AudioPlaybackTrack(index: index, fileId: fileID, fileName: metadata.fileName,
                version: metadata, durationSeconds: part.durationSeconds, startOffsetSeconds: part.offsetSeconds))
            for chapter in metadata.chapters ?? [] where chapter.startSeconds.isFinite
                && chapter.startSeconds >= 0 && chapter.startSeconds < part.durationSeconds {
                chapters.append(AudioPlaybackChapter(index: chapter.index, title: chapter.title,
                    startSeconds: part.offsetSeconds + chapter.startSeconds,
                    endSeconds: chapter.endSeconds.flatMap {
                        $0.isFinite && $0 >= chapter.startSeconds && $0 <= part.durationSeconds ? part.offsetSeconds + $0 : nil
                    }, trackIndex: index))
            }
        }
        contentId = detail.contentId
        title = detail.title
        subtitle = detail.audiobook?.authors.map(\.name).filter { !$0.isEmpty }.joined(separator: ", ").nonEmpty
        posterUrl = detail.posterUrl
        totalDurationSeconds = manifest.durationSeconds
        let resume = detail.userData?.positionSeconds ?? 0
        resumePositionSeconds = resume.isFinite ? min(max(0, resume), manifest.durationSeconds) : 0
        self.tracks = tracks
        self.chapters = chapters.sorted { $0.startSeconds < $1.startSeconds }
    }

    init?(detail: ItemDetail) {
        let parts = Self.audioParts(of: detail)
        guard !parts.isEmpty else { return nil }

        var tracks: [AudioPlaybackTrack] = []
        var chapters: [AudioPlaybackChapter] = []
        var offset = 0.0
        for (index, part) in parts.enumerated() {
            let duration = Self.partDuration(part)
            tracks.append(AudioPlaybackTrack(
                index: index,
                fileId: part.fileId,
                fileName: part.fileName,
                version: part,
                durationSeconds: duration,
                startOffsetSeconds: offset
            ))
            for chapter in part.chapters ?? [] {
                chapters.append(AudioPlaybackChapter(
                    index: chapter.index,
                    title: chapter.title,
                    startSeconds: offset + chapter.startSeconds,
                    endSeconds: chapter.endSeconds.map { offset + $0 },
                    trackIndex: index
                ))
            }
            offset += duration
        }

        let total = detail.audiobook?.totalDurationSeconds.map(Double.init) ?? offset

        contentId = detail.contentId
        title = detail.title
        subtitle = detail.audiobook?.authors
            .map(\.name)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
            .nonEmpty
        posterUrl = detail.posterUrl
        totalDurationSeconds = max(total, offset)
        resumePositionSeconds = min(
            max(0, detail.userData?.positionSeconds ?? 0),
            max(0, totalDurationSeconds)
        )
        self.tracks = tracks
        self.chapters = chapters.sorted { $0.startSeconds < $1.startSeconds }
    }

    /// Detail presentation and the edition anchor for discovery. This ordering
    /// does not authorize active playback offsets or part transitions.
    static func audioParts(of detail: ItemDetail) -> [FileVersion] {
        (detail.versions ?? [])
            .filter { version in
                if version.presentationKind == "audiobook_part" { return true }
                return version.codecAudio != nil || version.duration != nil
            }
            .sorted { lhs, rhs in
                let leftIndex = lhs.presentationPartIndex ?? Int.max
                let rightIndex = rhs.presentationPartIndex ?? Int.max
                if leftIndex != rightIndex { return leftIndex < rightIndex }
                return lhs.fileId < rhs.fileId
            }
    }

    /// Probe duration when present, otherwise the furthest chapter edge —
    /// some scanned parts carry chapters but no container duration.
    static func partDuration(_ part: FileVersion) -> Double {
        if let duration = part.duration, duration.isFinite, duration > 0 {
            return duration
        }
        let chapterEnd = (part.chapters ?? [])
            .compactMap { $0.endSeconds ?? $0.startSeconds }
            .max() ?? 0
        return max(0, chapterEnd)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

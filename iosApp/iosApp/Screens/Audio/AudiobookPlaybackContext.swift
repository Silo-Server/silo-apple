import Foundation

/// One audio part of a book on the whole-book timeline. Built client-side
/// from `ItemDetail.versions`; the server's playback API only knows about
/// individual files, so the global offsets exist purely in the client.
struct AudioPlaybackTrack: Identifiable, Hashable {
    let index: Int
    let fileId: Int
    let fileName: String?
    /// The catalog version a streamed part plays; nil for a downloaded
    /// file opened without the server.
    let version: FileVersion?
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

    /// The chapter's own title, or "Chapter N" in the language `locale`
    /// shows. A view passes its `\.locale` so the label follows a switch.
    func displayTitle(locale: Locale) -> String {
        title ?? AppLanguage.string(.optionsChapterNumbered(LocaleFormat.integer(index + 1, locale: locale)), locale: locale)
    }
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
    private(set) var resumePositionSeconds: Double
    let tracks: [AudioPlaybackTrack]
    let chapters: [AudioPlaybackChapter]

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
        // Same cleaned title as the detail page, so the player, mini player,
        // and lock screen don't repeat the series prefix and "(N of M)".
        title = AudiobookDetailFormatting.cleanTitle(detail.title, seriesName: detail.audiobook?.series?.name)
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

    /// A downloaded single-file book, opened from its record and stored
    /// manifest with no server: one track at the start of the book, whose
    /// chapters are the file's. Nil when the manifest names neither a
    /// duration nor chapters to measure the file by.
    init?(download record: DownloadRecord, manifest: OfflineManifest, posterUrl: String?, resumePositionSeconds: Double) {
        guard let fileId = Int(record.mediaFileId) else { return nil }
        let fileChapters = manifest.chapters ?? []
        let chapterEnd = fileChapters.compactMap { $0.endSeconds ?? $0.startSeconds }.max() ?? 0
        let duration: Double
        if let probed = manifest.durationSeconds, probed.isFinite, probed > 0 {
            duration = probed
        } else {
            duration = chapterEnd
        }
        guard duration > 0 else { return nil }

        contentId = record.contentId
        title = record.title ?? manifest.title
        subtitle = record.subtitle?.nonEmpty
        self.posterUrl = posterUrl
        totalDurationSeconds = duration
        self.resumePositionSeconds = min(max(0, resumePositionSeconds), duration)
        tracks = [AudioPlaybackTrack(
            index: 0,
            fileId: fileId,
            fileName: nil,
            version: nil,
            durationSeconds: duration,
            startOffsetSeconds: 0
        )]
        chapters = fileChapters
            .map {
                AudioPlaybackChapter(
                    index: $0.index,
                    title: $0.title,
                    startSeconds: $0.startSeconds,
                    endSeconds: $0.endSeconds,
                    trackIndex: 0
                )
            }
            .sorted { $0.startSeconds < $1.startSeconds }
    }

    /// Resumes from `position` instead of the server's resume point, for
    /// listening on this device the server has not received yet.
    func resuming(at position: Double) -> AudiobookPlaybackContext {
        var copy = self
        copy.resumePositionSeconds = min(max(0, position), max(0, totalDurationSeconds))
        return copy
    }

    /// The playable audio parts of an audiobook detail, in book order.
    /// Shared with the detail screen so the "Parts"/"Chapters" lists there
    /// match the player's timeline exactly.
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

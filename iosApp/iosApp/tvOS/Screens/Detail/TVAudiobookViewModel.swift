#if os(tvOS)
import SwiftUI

/// Shared visual tokens for the tvOS "Lounge" audiobook screens.
enum TVAudiobookStyle {
    /// Warm gold used for the series locator, matching the mockup's
    /// `rgba(233,213,162,.8)`.
    static let gold = Color(red: 0.913, green: 0.835, blue: 0.635).opacity(0.8)
}

/// Derives everything the Lounge screen, chapter picker, and info screen need
/// from an `ItemDetail`, in one place. It reuses `AudiobookPlaybackContext`
/// for the stitched timeline and `AudiobookProgress` for the pure decisions,
/// so the three views stay consistent and carry no timeline math of their own.
struct TVAudiobookViewModel {
    let detail: ItemDetail

    /// Stitched once at init: `AudiobookPlaybackContext(detail:)` walks every
    /// part and chapter, so computing it per property access would make nearly
    /// the whole surface O(parts + chapters) on each body evaluation.
    private let context: AudiobookPlaybackContext?

    // MARK: - Timeline

    let parts: [FileVersion]

    init(detail: ItemDetail) {
        self.detail = detail
        self.context = AudiobookPlaybackContext(detail: detail)
        self.parts = AudiobookPlaybackContext.audioParts(of: detail)
    }

    var chapters: [AudioPlaybackChapter] { context?.chapters ?? [] }
    var tracks: [AudioPlaybackTrack] { context?.tracks ?? [] }

    var totalDuration: Double {
        if let context, context.totalDurationSeconds > 0 { return context.totalDurationSeconds }
        if let total = detail.audiobook?.totalDurationSeconds, total > 0 { return Double(total) }
        if let duration = detail.userData?.durationSeconds, duration > 0 { return duration }
        return parts.reduce(0) { $0 + AudiobookPlaybackContext.partDuration($1) }
    }

    var position: Double { max(0, detail.userData?.positionSeconds ?? 0) }

    var resumePosition: Double? {
        AudiobookProgress.resumePosition(
            position: detail.userData?.positionSeconds,
            totalDuration: totalDuration
        )
    }

    var isFinished: Bool {
        AudiobookProgress.isFinished(
            played: detail.userData?.played ?? false,
            position: position,
            totalDuration: totalDuration
        )
    }

    var currentChapterIndex: Int? {
        AudiobookProgress.currentChapterIndex(chapters: chapters, position: position)
    }

    var percentComplete: Int {
        guard totalDuration > 0 else { return 0 }
        return Int(min(1, max(0, position / totalDuration)) * 100 + 0.5)
    }

    var fraction: Double {
        guard totalDuration > 0 else { return 0 }
        return min(1, max(0, position / totalDuration))
    }

    // MARK: - Identity

    var title: String {
        AudiobookDetailFormatting.cleanTitle(detail.title, seriesName: detail.audiobook?.series?.name)
    }

    var eyebrow: String {
        if let genre = detail.genres?.first, !genre.isEmpty {
            return "AUDIOBOOK · \(genre.uppercased())"
        }
        return "AUDIOBOOK"
    }

    var seriesLine: String? {
        let volume = AudiobookDetailFormatting.volume(in: detail.title)
        let index = detail.audiobook?.series?.entries
            .first(where: { $0.contentId == detail.contentId })?
            .seriesIndex ?? volume.index
        return AudiobookDetailFormatting.seriesLine(
            name: detail.audiobook?.series?.name,
            index: index,
            total: volume.total
        )
    }

    struct Credits { let author: String?; let narrator: String? }

    var credits: Credits? {
        let author = AudiobookDetailFormatting.peopleSummary(
            detail.audiobook?.authors.map(\.name) ?? [], visible: 2
        )
        let narrator = AudiobookDetailFormatting.peopleSummary(
            detail.audiobook?.narrators.map(\.name) ?? [], visible: 2
        )
        if author == nil && narrator == nil { return nil }
        return Credits(author: author, narrator: narrator)
    }

    // MARK: - State cluster

    enum State {
        case inProgress(fraction: Double, percent: Int, line1: String, line2: String?)
        case notStarted(line1: String, line2: String?)
        case finished(line1: String, line2: String?)
    }

    var state: State {
        if resumePosition != nil {
            return .inProgress(
                fraction: fraction,
                percent: percentComplete,
                line1: inProgressLine1,
                line2: inProgressLine2
            )
        }
        if isFinished {
            return .finished(line1: "Finished", line2: runtimeLabel.nonEmptyOrNil)
        }
        return .notStarted(line1: "Not started", line2: notStartedLine2)
    }

    /// "Chapter 24 · What the Tide Owes", or a listened-time line when the
    /// book carries no chapters.
    private var inProgressLine1: String {
        guard let index = currentChapterIndex, chapters.indices.contains(index) else {
            let listened = PlayerTimeFormatter.formatRuntime(position)
            return listened.isEmpty ? "In progress" : "\(listened) listened"
        }
        return "Chapter \(index + 1) · \(chapterTitle(index))"
    }

    /// "8:12 into the chapter · 5h 28m left in the book".
    private var inProgressLine2: String? {
        var pieces: [String] = []
        if let index = currentChapterIndex, chapters.indices.contains(index) {
            let intoChapter = max(0, position - chapters[index].startSeconds)
            pieces.append("\(PlayerTimeFormatter.formatHMS(intoChapter)) into the chapter")
        }
        let left = max(0, totalDuration - position)
        let leftLabel = PlayerTimeFormatter.formatRuntime(left)
        if !leftLabel.isEmpty {
            pieces.append("\(leftLabel) left in the book")
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    /// "14h 22m · 38 chapters" (chapter count omitted when none).
    private var notStartedLine2: String? {
        var pieces: [String] = []
        let runtime = runtimeLabel
        if !runtime.isEmpty { pieces.append(runtime) }
        if !chapters.isEmpty { pieces.append("\(chapters.count) chapters") }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    var runtimeLabel: String { PlayerTimeFormatter.formatRuntime(totalDuration) }

    func chapterTitle(_ index: Int) -> String {
        guard chapters.indices.contains(index) else { return "Chapter \(index + 1)" }
        if let title = chapters[index].title, !title.isEmpty { return title }
        return "Chapter \(index + 1)"
    }

    // MARK: - Actions

    /// Chapters is only worth a button when there's something to pick — real
    /// chapters, or more than one part to jump between.
    var showsChapters: Bool { !chapters.isEmpty || parts.count > 1 }

    var primaryIcon: String {
        resumePosition == nil && isFinished ? "arrow.counterclockwise" : "play.fill"
    }

    var primaryLabel: String {
        if resumePosition != nil { return "Resume" }
        if isFinished { return "Play Again" }
        return "Play"
    }

    @MainActor
    func performPrimary(_ store: AudioPlaybackStore, libraryId: Int? = nil) {
        if let resumePosition {
            store.play(contentId: detail.contentId, restart: false, startPosition: resumePosition, libraryId: libraryId)
        } else if isFinished {
            store.play(contentId: detail.contentId, restart: true, libraryId: libraryId)
        } else {
            store.play(contentId: detail.contentId, restart: false, libraryId: libraryId)
        }
    }
}

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
#endif

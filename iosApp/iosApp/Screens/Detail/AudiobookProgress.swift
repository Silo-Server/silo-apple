import Foundation

/// Pure, SwiftUI-free progress/timeline decisions for the audiobook detail
/// screens. `AudiobookPlaybackContext` already stitches parts and chapters
/// onto one whole-book timeline; this enum layers the pure "where am I"
/// rules on top so they can be unit tested without an `ItemDetail` fixture.
///
/// Both the tvOS page (`TVAudiobookViewModel`) and the phone/iPad/Mac page
/// (`BookDetailPresentation`) route Resume / Play Again through these rules.
enum AudiobookProgress {

    /// The meaningful resume point, or nil when Resume should be suppressed.
    /// nil unless the stored position is finite and past the 30s intro grace;
    /// nil again within 5s of the end (a book that far in is "finished", not
    /// "resumable"). The end guard only applies when we know the duration.
    static func resumePosition(position: Double?, totalDuration: Double) -> Double? {
        guard let position, position.isFinite, position > 30 else { return nil }
        if totalDuration.isFinite, totalDuration > 0, position >= totalDuration - 5 {
            return nil
        }
        return position
    }

    /// Whether the book is effectively finished — the played flag, or a
    /// position within 5s of the (known, positive) end.
    static func isFinished(played: Bool, position: Double, totalDuration: Double) -> Bool {
        if played { return true }
        guard totalDuration > 0, position > 0 else { return false }
        return position >= totalDuration - 5
    }

    /// Index of the chapter currently playing: the last chapter whose start
    /// is at or before `position`. Returns nil only for an empty list. A
    /// position before the first chapter's start still resolves to chapter 0
    /// (the book opens on its first chapter), so the ring/label always have a
    /// chapter to name once any chapters exist.
    static func currentChapterIndex(chapters: [AudioPlaybackChapter], position: Double) -> Int? {
        guard !chapters.isEmpty else { return nil }
        var current = 0
        for (index, chapter) in chapters.enumerated() where chapter.startSeconds <= position {
            current = index
        }
        return current
    }

    /// Duration of the chapter at `index`: the next chapter's start minus
    /// this one's, or (for the last chapter) the book total minus this start.
    /// Clamped at ≥ 0 so a stale/short total can't produce a negative length.
    static func chapterDuration(
        chapters: [AudioPlaybackChapter],
        at index: Int,
        totalDuration: Double
    ) -> Double {
        guard chapters.indices.contains(index) else { return 0 }
        let start = chapters[index].startSeconds
        let end: Double
        if index + 1 < chapters.count {
            end = chapters[index + 1].startSeconds
        } else {
            end = totalDuration
        }
        return max(0, end - start)
    }

    /// Whether the chapter at `index` has been fully listened — its computed
    /// end (start + `chapterDuration`) is at or before `position`.
    static func isChapterFinished(
        chapters: [AudioPlaybackChapter],
        at index: Int,
        position: Double,
        totalDuration: Double
    ) -> Bool {
        guard chapters.indices.contains(index) else { return false }
        let end = chapters[index].startSeconds
            + chapterDuration(chapters: chapters, at: index, totalDuration: totalDuration)
        return end <= position
    }
}

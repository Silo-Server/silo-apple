import Foundation

/// The book formats the shared detail page can present. Everything that
/// differs between formats — wording, cover shape, placeholder art — lives
/// here, so supporting ebooks later is one new case rather than a new page.
enum BookDetailKind {
    case audiobook

    /// Width ÷ height of the format's cover art.
    var coverAspectRatio: CGFloat {
        switch self {
        case .audiobook: 1
        }
    }

    var placeholderSymbol: String {
        switch self {
        case .audiobook: "headphones"
        }
    }

    /// Short label above the title in the wide (iPad/Mac) hero.
    var eyebrow: String {
        switch self {
        case .audiobook: "Audiobook"
        }
    }

    /// The watchlist action, in the format's own verb.
    var queueLabel: String {
        switch self {
        case .audiobook: "Want to Listen"
        }
    }

    /// The watched action. Books are finished, not watched.
    var finishedLabel: String { "Finished" }
}

/// Pure, SwiftUI-free projection of an audiobook `ItemDetail` into the
/// strings and decisions the shared detail hero needs. Kept separate from the
/// view so the rules can be unit tested on every platform.
struct BookDetailPresentation {
    let detail: ItemDetail
    let kind: BookDetailKind
    /// The live "Finished" state from the detail view model. It wins over the
    /// payload's `played` flag so toggling Finished updates the Play label
    /// before the next detail reload.
    let isMarkedFinished: Bool

    init(detail: ItemDetail, kind: BookDetailKind = .audiobook, isMarkedFinished: Bool) {
        self.detail = detail
        self.kind = kind
        self.isMarkedFinished = isMarkedFinished
    }

    // MARK: - Identity

    var title: String {
        AudiobookDetailFormatting.cleanTitle(detail.title, seriesName: detail.audiobook?.series?.name)
    }

    /// "The Stormlight Archive · Book 5 of 5". The total comes from the
    /// title's "(N of M)" locator rather than the series entry count, which
    /// can include alternate editions and narrations.
    var seriesLine: String? {
        let volume = AudiobookDetailFormatting.volume(in: detail.title)
        let currentIndex = detail.audiobook?.series?.entries
            .first(where: { $0.contentId == detail.contentId })?
            .seriesIndex
        return AudiobookDetailFormatting.seriesLine(
            name: detail.audiobook?.series?.name,
            index: currentIndex ?? volume.index,
            total: volume.total
        )
    }

    /// "By A & B · Narrated by N". Nil when neither list has a name.
    var creditText: String? {
        var pieces: [String] = []
        if let authors = AudiobookDetailFormatting.peopleSummary(
            detail.audiobook?.authors.map(\.name) ?? [], visible: 3
        ) {
            pieces.append("By \(authors)")
        }
        if let narrators = AudiobookDetailFormatting.peopleSummary(
            detail.audiobook?.narrators.map(\.name) ?? [], visible: 2
        ) {
            pieces.append("Narrated by \(narrators)")
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    /// The author line the player shows under the title. Matches
    /// `AudiobookPlaybackContext.subtitle` so the line doesn't change when
    /// the session's own context replaces the preview.
    var playerSubtitle: String? {
        let authors = (detail.audiobook?.authors ?? []).map(\.name).filter { !$0.isEmpty }
        return authors.isEmpty ? nil : authors.joined(separator: ", ")
    }

    // MARK: - Hero metadata

    /// Year and length, in the same leading slots movies use for year and
    /// runtime.
    var factsTokens: [String] {
        var tokens: [String] = []
        if let year = detail.year, year > 0 { tokens.append(String(year)) }
        let runtime = PlayerTimeFormatter.formatRuntime(totalDurationSeconds)
        if !runtime.isEmpty { tokens.append(runtime) }
        return tokens
    }

    /// Series position — the book equivalent of an episode's "Season ·
    /// Episode" source token — or, for a standalone book, its lead genre.
    /// Showing both usually wraps the hero line onto a stray second row.
    var sourceTokens: [String] {
        if let seriesLine { return [seriesLine] }
        if let genre = detail.genres?.first?.trimmingCharacters(in: .whitespaces), !genre.isEmpty {
            return [genre]
        }
        return []
    }

    // MARK: - Timeline

    var parts: [FileVersion] {
        AudiobookPlaybackContext.audioParts(of: detail)
    }

    /// Total book length, preferring the server's authoritative value and
    /// falling back to the stitched part durations.
    var totalDurationSeconds: Double {
        Self.totalDurationSeconds(of: detail)
    }

    static func totalDurationSeconds(of detail: ItemDetail) -> Double {
        if let total = detail.audiobook?.totalDurationSeconds, total > 0 {
            return Double(total)
        }
        if let duration = detail.userData?.durationSeconds, duration > 0 {
            return duration
        }
        return AudiobookPlaybackContext.audioParts(of: detail)
            .reduce(0) { $0 + AudiobookPlaybackContext.partDuration($1) }
    }

    var positionSeconds: Double {
        max(0, detail.userData?.positionSeconds ?? 0)
    }

    var resumePosition: Double? {
        AudiobookProgress.resumePosition(
            position: detail.userData?.positionSeconds,
            totalDuration: totalDurationSeconds
        )
    }

    var isFinished: Bool {
        AudiobookProgress.isFinished(
            played: isMarkedFinished,
            position: positionSeconds,
            totalDuration: totalDurationSeconds
        )
    }

    /// Listening progress 0...1, only when there is a meaningful resume point.
    var resumeFraction: Double? {
        guard resumePosition != nil, totalDurationSeconds > 0 else { return nil }
        return min(1, max(0, positionSeconds / totalDurationSeconds))
    }

    // MARK: - Primary action

    enum PrimaryAction: Equatable {
        case resume(at: Double)
        case playAgain
        case play
    }

    var primaryAction: PrimaryAction {
        if let resumePosition { return .resume(at: resumePosition) }
        if isFinished { return .playAgain }
        return .play
    }

    var primaryLabel: String {
        switch primaryAction {
        case .resume:
            let left = PlayerTimeFormatter.formatRuntime(
                max(0, totalDurationSeconds - positionSeconds)
            )
            return left.isEmpty ? "Resume" : "Resume · \(left) left"
        case .playAgain:
            return "Play Again"
        case .play:
            return "Play"
        }
    }

    var primaryIcon: String {
        primaryAction == .playAgain ? "arrow.counterclockwise" : "play.fill"
    }
}

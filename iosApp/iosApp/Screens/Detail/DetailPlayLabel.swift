import Foundation

/// Titles for the detail pages' primary Play button. The title uses the
/// same `PlaybackResumePoint` rule as the resume prompt (more than 30
/// seconds in and not within 5 seconds of the end), applied to the page's
/// saved watch state. The tap re-reads the server, so after another device
/// moved on the prompt can offer a newer position than the title implies.
enum DetailPlayLabel {
    static func resumePosition(_ userData: LeafItemUserData?) -> Double? {
        PlaybackResumePoint.position(userData?.positionSeconds, duration: userData?.durationSeconds)
    }

    /// "Resume" or "Play" for a movie or a single episode's own page.
    static func item(_ userData: LeafItemUserData?) -> String {
        resumePosition(userData) == nil ? "Play" : "Resume"
    }

    /// "Resume S1·E2" or "Play S1·E2" for the series page's next-up episode.
    static func episode(_ episode: EpisodeListItem) -> String {
        "\(item(episode.userData)) S\(episode.seasonNumber)·E\(episode.episodeNumber)"
    }
}

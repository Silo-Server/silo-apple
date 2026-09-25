import Foundation

/// The Series episode the player was showing when it closed, and whether it
/// crossed the completion boundary. A Series page uses it to land on the next
/// episode after a finished one, or on the same episode so it can be resumed.
///
/// The decision needs only episode order and the player's completion flag, so
/// the page can apply it before the post-playback catalog refresh arrives.
struct SeriesPlaybackReturn: Equatable {
    let episodeContentId: String
    let seriesContentId: String
    let seasonNumber: Int?
    let completed: Bool

    /// The episode to select among `episodes`, which must be in play order.
    /// `nil` when the played episode is not in the list, or when it finished
    /// and its successor is not loaded.
    func episodeToSelect(in episodes: [EpisodeListItem]) -> String? {
        guard let index = episodes.firstIndex(where: { $0.contentId == episodeContentId }) else {
            return nil
        }
        guard completed else { return episodeContentId }
        let nextIndex = index + 1
        guard episodes.indices.contains(nextIndex) else { return nil }
        let next = episodes[nextIndex]
        // Specials sort after the last regular season. Finishing a regular
        // episode never continues into them.
        if next.seasonNumber == 0, episodes[index].seasonNumber != 0 { return nil }
        return next.contentId
    }
}

extension Notification.Name {
    /// Posted when a player closes. The object is the `SeriesPlaybackReturn`,
    /// or `nil` when the player was not showing a Series episode.
    static let seriesPlaybackDidReturn = Notification.Name("seriesPlaybackDidReturn")
}

/// Holds the latest player return until its Series page consumes it. The page
/// can reappear before or after the player finishes tearing down, so it takes
/// the return both when it reappears and when the notification arrives.
@MainActor
enum SeriesPlaybackReturnInbox {
    private static var pending: SeriesPlaybackReturn?

    static func publish(_ playback: SeriesPlaybackReturn?) {
        pending = playback
        NotificationCenter.default.post(name: .seriesPlaybackDidReturn, object: playback)
    }

    /// Drop a return from an earlier player. A Series page calls this when it
    /// starts playback, so it only takes the return that playback produces.
    static func discardPending() {
        pending = nil
    }

    /// Consume the pending return when it belongs to `seriesContentId`.
    static func take(seriesContentId: String) -> SeriesPlaybackReturn? {
        guard let playback = pending, playback.seriesContentId == seriesContentId else { return nil }
        pending = nil
        return playback
    }
}

import Foundation

/// Whether a return to the foreground on iOS reloads Home.
///
/// Five minutes away skips the quick trips a phone app sees all the time
/// (answering a message, copying a code, checking a link), where Home cannot
/// have changed in a way worth a refetch. Anything longer may follow playback
/// on another device or new additions, and the refetch also replaces artwork
/// URLs whose signatures may have expired while away.
enum HomeForegroundRefreshPolicy {
    static let minimumTimeAway: TimeInterval = 5 * 60

    static func shouldRefresh(backgroundedAt: Date?, now: Date = .now) -> Bool {
        guard let backgroundedAt else { return false }
        return now.timeIntervalSince(backgroundedAt) >= minimumTimeAway
    }
}

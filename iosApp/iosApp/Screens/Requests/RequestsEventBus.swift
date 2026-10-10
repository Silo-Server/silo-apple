import Foundation

/// Broadcast of the most recent request mutation (create/cancel result) so
/// every mounted requests surface can patch its own items in place instead
/// of refetching. A broadcast value, not a queue — a screen that mounts
/// after the event fired does its normal fetch and already sees current
/// state.
@MainActor
@Observable
final class RequestsEventBus {
    static let shared = RequestsEventBus()

    private(set) var lastUpdate: MediaRequest?
    /// The most recent admin decision (approve/decline/retry) on anyone's
    /// request. Kept apart from `lastUpdate`, whose consumers treat every
    /// record as the signed-in user's own.
    private(set) var lastModeration: MediaRequest?

    func publish(_ request: MediaRequest) {
        RequestDetailCache.shared.storeOwnRecord(request)
        lastUpdate = request
    }

    func publishModeration(_ request: MediaRequest) {
        let cache = RequestDetailCache.shared
        cache.unpinModeration(request)
        // An admin deciding on their own request: their own lists update too.
        let key = RequestDetailCache.Key(mediaType: request.mediaType, tmdbId: request.tmdbId)
        if cache.ownRecord(key)?.id == request.id {
            publish(request)
        }
        lastModeration = request
    }

    /// Sign-out / profile switch: don't leak one account's last mutation
    /// into the next session's `.onChange` observers.
    func reset() {
        lastUpdate = nil
        lastModeration = nil
        RequestDetailCache.shared.clear()
    }
}

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
    /// The most recent follow toggle. Kept apart from `lastUpdate`: no
    /// record of the user's own changed, only their state on the title.
    private(set) var lastTitleState: RequestTitleStateUpdate?

    func publish(_ request: MediaRequest) {
        RequestDetailCache.shared.storeOwnRecord(request)
        lastUpdate = request
    }

    func publishTitleState(_ update: RequestTitleStateUpdate) {
        RequestDetailCache.shared.applyTitleState(update)
        lastTitleState = update
    }

    /// Sign-out / profile switch: don't leak one account's last mutation
    /// into the next session's `.onChange` observers.
    func reset() {
        lastUpdate = nil
        lastTitleState = nil
        RequestDetailCache.shared.clear()
    }
}

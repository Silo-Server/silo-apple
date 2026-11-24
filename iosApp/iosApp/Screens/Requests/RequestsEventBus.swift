import Foundation

/// Broadcast of the most recent request mutation (create/cancel result, or
/// a removed request) so
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
    /// The most recent request the user removed. Kept apart from
    /// `lastUpdate`: the record no longer exists, so lists drop it.
    private(set) var lastRemoval: MediaRequest?

    func publish(_ request: MediaRequest) {
        RequestDetailCache.shared.storeOwnRecord(request)
        lastUpdate = request
    }

    /// Lists drop the row, and the record no longer seeds the title's page.
    /// The title's own request state is left to the next read: another
    /// request for it may exist, so a removal says nothing about it.
    func publishRemoval(_ request: MediaRequest) {
        RequestDetailCache.shared.forgetOwnRecord(request)
        lastRemoval = request
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
        lastRemoval = nil
        RequestDetailCache.shared.clear()
    }
}

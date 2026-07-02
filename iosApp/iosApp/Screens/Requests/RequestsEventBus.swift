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

    func publish(_ request: MediaRequest) {
        lastUpdate = request
    }

    /// Sign-out / profile switch: don't leak one account's last mutation
    /// into the next session's `.onChange` observers.
    func reset() {
        lastUpdate = nil
    }
}

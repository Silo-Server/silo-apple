import Foundation

/// The three My Requests sections, derived purely from
/// `RequestDisplayState` so bucketing and chip color can never disagree.
/// Cancelled requests (`.unavailable`) drop off the list entirely —
/// cancelling is a terminal user action, not a state worth surfacing.
enum MyRequestsBucket: CaseIterable {
    case inMotion
    case landed
    case needsAttention

    var title: String {
        switch self {
        case .inMotion: "In motion"
        case .landed: "Landed in your library"
        case .needsAttention: "Needs attention"
        }
    }

    init?(_ state: RequestDisplayState) {
        switch state {
        case .pending, .onTheWay: self = .inMotion
        case .inLibrary: self = .landed
        case .needsAttention: self = .needsAttention
        case .unavailable: return nil
        }
    }

    /// Groups requests into the ordered buckets, newest-first within each,
    /// omitting empty buckets.
    static func bucket(_ requests: [MediaRequest]) -> [(bucket: MyRequestsBucket, requests: [MediaRequest])] {
        var grouped: [MyRequestsBucket: [MediaRequest]] = [:]
        for request in requests {
            let state = RequestDisplayState(
                status: request.status,
                outcome: request.outcome,
                reason: request.lastError
            )
            guard let bucket = MyRequestsBucket(state) else { continue }
            grouped[bucket, default: []].append(request)
        }
        return MyRequestsBucket.allCases.compactMap { bucket in
            guard let items = grouped[bucket], !items.isEmpty else { return nil }
            return (bucket, items.sorted { $0.createdAt > $1.createdAt })
        }
    }
}

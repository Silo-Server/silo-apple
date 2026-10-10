import Foundation

/// The three My Requests sections (and filters), derived purely from
/// `RequestDisplayState` so bucketing and chip color can never disagree.
/// Requests that need the user sit above finished ones.
/// Cancelled requests (`.unavailable`) drop off the list entirely —
/// cancelling is a terminal user action, not a state worth surfacing.
enum MyRequestsBucket: CaseIterable {
    case inMotion
    case needsAttention
    case landed

    var title: String {
        switch self {
        case .inMotion: "In progress"
        case .needsAttention: "Needs you"
        case .landed: "Available"
        }
    }

    var systemImage: String {
        switch self {
        case .inMotion: "arrow.down.circle"
        case .needsAttention: "exclamationmark.circle"
        case .landed: "checkmark.circle"
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
            guard let bucket = MyRequestsBucket(RequestDisplayState(record: request)) else { continue }
            grouped[bucket, default: []].append(request)
        }
        return MyRequestsBucket.allCases.compactMap { bucket in
            guard let items = grouped[bucket], !items.isEmpty else { return nil }
            return (bucket, items.sorted { $0.createdAt > $1.createdAt })
        }
    }
}

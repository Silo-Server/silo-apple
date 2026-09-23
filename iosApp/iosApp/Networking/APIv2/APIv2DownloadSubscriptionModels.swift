import Foundation

// Wire models for the v2 series monitors: listDownloadSubscriptions,
// getDownloadSubscription, createDownloadSubscription,
// updateDownloadSubscription, deleteDownloadSubscription and
// syncDownloadSubscription. The monitor itself decodes into
// `ServerSubscription`.

/// `CollectionDownloadSubscription`: one page of listDownloadSubscriptions.
struct APIv2DownloadSubscriptionPage: Decodable, Sendable {
    let items: [ServerSubscription]
    let page: APIv2Page?
}

/// `DownloadSubscriptionSyncInputBody`. Every page of one sync repeats the
/// validator captured before its first page.
struct APIv2DownloadSubscriptionSyncBody: Encodable, Hashable, Sendable {
    let subscriptionId: String
    let etag: String

    private enum CodingKeys: String, CodingKey {
        case subscriptionId = "subscription_id"
        case etag
    }
}

/// `DownloadSubscriptionSync`: the answer for one sync page.
struct APIv2DownloadSubscriptionSync: Decodable, Sendable {
    let subscriptionId: String
    /// Episodes this page registered. A repeated page may report zero.
    let registered: Int
    let examined: Int
    let page: APIv2Page
}

/// How one monitor's sync ended.
struct DownloadSubscriptionSyncOutcome: Sendable {
    /// Episodes the server registered across every page of this sync.
    let registered: Int
    /// The monitor as last read, when a 409 made the sync read it again.
    let reloaded: ServerSubscription?
    /// The server no longer has the monitor.
    let removed: Bool
}

/// A monitor answer the client cannot use. Nothing from it is applied.
enum DownloadSubscriptionError: LocalizedError, Equatable, Sendable {
    /// A request the server would refuse; it was not sent.
    case invalidRequest
    /// The monitor list ended early, repeated a cursor or a monitor, or held
    /// a monitor without an id, series or validator.
    case incompleteList
    /// A monitor or sync answer that does not describe the request.
    case unexpectedReceipt
    /// A sync that did not finish within its page and restart bounds.
    case incompleteSync

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "The monitoring request is not valid."
        case .incompleteList: return "The server returned an incomplete list of monitored series. Try again."
        case .unexpectedReceipt: return "The server returned an unexpected monitoring answer."
        case .incompleteSync: return "The server did not finish checking a monitored series for new episodes."
        }
    }
}

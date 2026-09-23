import Foundation

/// `GET /api/v2/collections`: the acting profile's collections and the
/// account's groups. Both arrays are always present. The list is bounded, so
/// a `page` that says more follows is refused rather than shown cut off.
struct APIv2PersonalCollections: Decodable {
    let items: [UserCollection]
    let groups: [CollectionGroup]
    let page: APIv2Page?
}

/// `GET /api/v2/collections/capabilities`, reduced to what this client uses.
/// `groups` is false on stores without group support (SQLite user stores),
/// where every group operation answers 501 `capability_unsupported`.
struct APIv2CollectionCapabilities: Decodable {
    let revision: String
    let state: String
    let allowed: Bool
    let groups: Bool

    var supportsGroups: Bool { allowed && state == "available" && groups }
}

/// The version a collection or group edit is based on: the strong `ETag` of
/// the canonical editor read and the owner that read was fenced on. The write
/// sends the tag as `If-Match` under that same owner, never a list row's
/// state and never a wildcard.
struct CollectionEditVersion: Sendable {
    let path: String
    let etag: String
    let auth: CapturedOrdinaryRequestAuth
}

struct CollectionEditor<Value> {
    let value: Value
    let version: CollectionEditVersion
}

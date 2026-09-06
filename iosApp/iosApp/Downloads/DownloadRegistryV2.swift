import Foundation

struct APIv2DownloadCapability: Decodable {
    let revision: String
    let state: String
    let enabled: Bool
    let downloadAllowed: Bool
    let proxyDelivery: Bool
    let orderedStatus: Bool
    let subscriptionMutations: Bool?
    let boundedSubscriptionSync: Bool?
    let subscriptionReads: Bool?
    let qualityPresets: [String]
    let transcodeEnabled: Bool
    let transcodeUserAllowed: Bool
    let seasonDownload: Bool
    let seriesMonitoring: Bool
    let monitoringModes: [String]

    var localValue: DownloadCapability {
        var value = DownloadCapability(enabled: state == "available" && !revision.isEmpty && enabled,
            downloadAllowed: downloadAllowed, qualityPresets: qualityPresets,
            transcodeEnabled: transcodeEnabled, transcodeUserAllowed: transcodeUserAllowed,
            seasonDownload: seasonDownload, seriesMonitoring: seriesMonitoring, monitoringModes: monitoringModes)
        value.registryRevision = revision
        value.registryState = state
        value.proxyDelivery = proxyDelivery
        value.orderedStatus = orderedStatus
        value.subscriptionMutations = subscriptionMutations
        value.boundedSubscriptionSync = boundedSubscriptionSync
        value.subscriptionReads = subscriptionReads
        return value
    }
}

struct APIv2DownloadEntry: Decodable, Sendable {
    let id: String
    let contentId: String
    let episodeId: String?
    let batchId: String?
    let deviceId: String?
    let mediaFileId: String
    let fileSize: Int64
    let bytesSent: Int64
    let kind: String
    let status: String
    let quality: String
    let effectiveQuality: String
    let deliveryFormat: String
    let targetBitrateKbps: Int
    let revision: Int
    let createdAt: Date
    let completedAt: Date?
    let statusEventAt: Date?
}

struct APIv2DownloadPage: Decodable, Sendable {
    let items: [APIv2DownloadEntry]
    let page: APIv2Page
}

/// No rows escape until the complete device-bound registry has been collected.
/// In particular, callers must not run absence reconciliation on a partial page.
enum DownloadRegistryV2 {
    static func collect(deviceID: String,
                        fetch: (String?) async throws -> APIv2DownloadPage) async throws -> [ServerDownloadRow] {
        guard !deviceID.isEmpty else { throw DownloadOwnershipError.wrongAuthority }
        var cursor: String?
        var cursors = Set<String>()
        var ids = Set<String>()
        var rows: [ServerDownloadRow] = []
        for _ in 0..<100 {
            let response = try await fetch(cursor)
            guard response.items.count <= 100 else { throw DownloadOwnershipError.incompleteAction }
            for entry in response.items {
                guard entry.deviceId == deviceID, ids.insert(entry.id).inserted else {
                    throw DownloadOwnershipError.wrongAuthority
                }
                rows.append(try ServerDownloadRow(v2: entry))
            }
            if !response.page.hasMore {
                guard response.page.nextCursor?.isEmpty != false else { throw DownloadOwnershipError.incompleteAction }
                return rows
            }
            guard !response.items.isEmpty, let next = response.page.nextCursor, !next.isEmpty,
                  cursors.insert(next).inserted else { throw DownloadOwnershipError.incompleteAction }
            cursor = next
        }
        throw DownloadOwnershipError.incompleteAction
    }

    static func path(id: String) throws -> String {
        guard !id.isEmpty, id != ".", id != "..",
              let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) else {
            throw DownloadOwnershipError.incompleteAction
        }
        return "/api/v2/downloads/" + encoded
    }
}

/// Persisted with the local transition, scoped by its enclosing record/store.
/// Completion supersedes a queued start event for the same registry revision.
struct DownloadStatusEvent: Codable, Hashable, Sendable {
    let id: UUID
    let status: String
    let updatedAt: String
    let revision: Int
    let deviceID: String
    let leaseGeneration: UUID

    struct Body: Encodable {
        let status: String
        let updatedAt: String
        let revision: Int
    }
    var body: Body { Body(status: status, updatedAt: updatedAt, revision: revision) }

    static func make(status: String, record: DownloadRecord, lease: DownloadAssetLease,
                     now: Date = Date()) -> DownloadStatusEvent? {
        guard let revision = record.revision, revision > 0 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var time = now
        // Retain this fence after acknowledgment: two transitions can occur in
        // one wire-format millisecond even when the start response arrived.
        for raw in [record.lastStatusEventAt, record.pendingStatusEvent?.updatedAt].compactMap({ $0 }) {
            if let prior = formatter.date(from: raw) {
                time = max(time, prior.addingTimeInterval(0.001))
            }
        }
        return DownloadStatusEvent(id: UUID(), status: status, updatedAt: formatter.string(from: time),
            revision: revision, deviceID: AppleDeviceIdentity.current.id, leaseGeneration: lease.generation)
    }
}

struct DownloadSubscriptionPage: Decodable {
    let items: [ServerSubscription]
    let page: APIv2Page
}
struct DownloadSubscriptionSyncBody: Encodable {
    let subscriptionId: String
    let etag: String
}
struct DownloadSubscriptionSyncPage: Decodable {
    let subscriptionId: String
    let registered: Int
    let examined: Int
    let page: APIv2Page
}

enum DownloadSubscriptionV2 {
    static func path(_ id: String) throws -> String {
        let registryPath = try DownloadRegistryV2.path(id: id)
        return registryPath.replacingOccurrences(of: "/api/v2/downloads/", with: "/api/v2/downloads/subscriptions/")
    }

    static func validator(_ tag: String?) throws -> String {
        guard let tag, tag.count > 2, tag.first == "\"", tag.last == "\"",
              !tag.contains("\r"), !tag.contains("\n") else { throw DownloadOwnershipError.incompleteAction }
        return tag
    }

    static func validate(_ row: ServerSubscription, seriesID: String? = nil, id: String? = nil) throws {
        guard !row.id.isEmpty, !row.seriesId.isEmpty, row.maxStorageBytes >= 0,
              SubscriptionMode(rawValue: row.mode) != nil,
              row.seasonNumbers?.allSatisfy({ $0 >= 0 }) != false,
              seriesID == nil || seriesID == row.seriesId, id == nil || id == row.id else {
            throw DownloadOwnershipError.incompleteAction
        }
        _ = try validator(row.etag)
    }

    static func collect(fetch: (String?) async throws -> DownloadSubscriptionPage) async throws -> [ServerSubscription] {
        var rows: [ServerSubscription] = []
        var ids = Set<String>()
        var cursors = Set<String>()
        var cursor: String?
        for _ in 0..<100 {
            let result = try await fetch(cursor)
            guard result.items.count <= 100 else { throw DownloadOwnershipError.incompleteAction }
            for row in result.items {
                try validate(row)
                guard ids.insert(row.id).inserted else { throw DownloadOwnershipError.incompleteAction }
                rows.append(row)
            }
            guard result.page.hasMore else {
                guard result.page.nextCursor?.isEmpty != false else { throw DownloadOwnershipError.incompleteAction }
                return rows
            }
            guard let next = result.page.nextCursor, !next.isEmpty, cursors.insert(next).inserted else {
                throw DownloadOwnershipError.incompleteAction
            }
            cursor = next
        }
        throw DownloadOwnershipError.incompleteAction
    }

    static func sync(id: String, fetch: (String?) async throws -> DownloadSubscriptionSyncPage) async throws {
        var cursor: String?
        var cursors = Set<String>()
        for _ in 0..<1000 {
            let result = try await fetch(cursor)
            guard result.subscriptionId == id, result.registered >= 0, result.examined >= 0,
                  result.examined <= 100, result.registered <= result.examined else { throw DownloadOwnershipError.incompleteAction }
            guard result.page.hasMore else {
                guard result.page.nextCursor?.isEmpty != false else { throw DownloadOwnershipError.incompleteAction }
                return
            }
            guard let next = result.page.nextCursor, !next.isEmpty, cursors.insert(next).inserted else {
                throw DownloadOwnershipError.incompleteAction
            }
            cursor = next
        }
        throw DownloadOwnershipError.incompleteAction
    }
}

struct DownloadCreateV2Body: Encodable, Sendable {
    let contentId: String
    let episodeId: String?
    let mediaFileId: String?
    let quality: String
    let series: Bool
    let seasonNumber: Int?
    let caps: DownloadCaps?
    let expectedRevision: Int?
    let expectedDownloadId: String?
    let batchId: String?

    init(_ request: CreateDownloadRequest, existing: DownloadRecord?, batchID: String?) throws {
        guard request.fileId == nil || request.fileId! > 0 else { throw DownloadOwnershipError.incompleteAction }
        contentId = request.contentId; episodeId = request.episodeId
        mediaFileId = request.fileId.map(String.init); quality = request.quality
        series = request.series == true; seasonNumber = request.seasonNumber; caps = request.caps
        batchId = series ? batchID : nil
        if series {
            guard batchID?.isEmpty == false else { throw DownloadOwnershipError.incompleteAction }
            expectedRevision = nil; expectedDownloadId = nil
        } else if let existing {
            guard existing.contentId == contentId, existing.episodeId == episodeId,
                  let revision = existing.revision, revision > 0 else { throw DownloadOwnershipError.incompleteAction }
            expectedRevision = revision; expectedDownloadId = existing.id
        } else {
            expectedRevision = 0; expectedDownloadId = nil
        }
    }
}
struct DownloadCreateSkipped: Decodable, Sendable {
    let episodeId: String
    let reason: String
}
struct DownloadCreateV2Page: Decodable, Sendable {
    let items: [APIv2DownloadEntry]
    let skipped: [DownloadCreateSkipped]
    let page: APIv2Page
    let batchId: String?
}
struct DownloadCreateV2Result {
    let rows: [ServerDownloadRow]
    let skipped: [DownloadCreateSkipped]
}
enum DownloadCreationV2 {
    static func collect(body: DownloadCreateV2Body, deviceID: String,
                        fetch: (String?) async throws -> DownloadCreateV2Page) async throws -> DownloadCreateV2Result {
        var cursor: String?
        var cursors = Set<String>()
        var ids = Set<String>()
        var rows: [ServerDownloadRow] = []
        var skipped: [DownloadCreateSkipped] = []
        for _ in 0..<1000 {
            let response = try await fetch(cursor)
            guard response.items.count <= 100, response.skipped.count <= 100,
                  response.batchId == body.batchId else { throw DownloadOwnershipError.incompleteAction }
            for item in response.items {
                guard item.deviceId == deviceID, item.contentId == body.contentId,
                      body.series || item.episodeId == body.episodeId,
                      body.mediaFileId == nil || item.mediaFileId == body.mediaFileId,
                      ids.insert(item.id).inserted else { throw DownloadOwnershipError.wrongAuthority }
                rows.append(try ServerDownloadRow(v2: item))
            }
            skipped.append(contentsOf: response.skipped)
            if !body.series {
                guard response.items.count == 1, response.skipped.isEmpty, !response.page.hasMore else {
                    throw DownloadOwnershipError.incompleteAction
                }
            }
            guard response.page.hasMore else {
                guard response.page.nextCursor?.isEmpty != false else { throw DownloadOwnershipError.incompleteAction }
                return DownloadCreateV2Result(rows: rows, skipped: skipped)
            }
            guard let next = response.page.nextCursor, !next.isEmpty, cursors.insert(next).inserted else {
                throw DownloadOwnershipError.incompleteAction
            }
            cursor = next
        }
        throw DownloadOwnershipError.incompleteAction
    }
}

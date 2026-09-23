import Foundation

// MARK: Series monitors (profile_scoped)
//
// A monitor belongs to (account, profile, device). The server never syncs one
// on its own: the client lists its monitors, then pages each active one
// through syncDownloadSubscription, which registers the episodes in scope.
// PATCH and DELETE are guarded by the monitor's validator (`If-Match`).

extension APIv2Client {
    /// Monitors per list page and sync episodes per page. Both reads stop
    /// after `downloadRegistryMaxPages` pages.
    static let downloadSubscriptionPageLimit = 100
    /// Times one sync reads the monitor again after a 409 and starts over.
    static let downloadSubscriptionSyncRestarts = 2
    /// Times one sync page is sent again after an uncertain outcome, with the
    /// same validator and cursor.
    static let downloadSubscriptionSyncPageRetries = 2

    // MARK: listDownloadSubscriptions

    /// Reads every monitor of this device. A read that ends early, repeats a
    /// cursor or a monitor, or holds an unusable monitor throws: the caller
    /// treats a monitor missing from the list as removed on the server.
    func listDownloadSubscriptions(auth: CapturedOrdinaryRequestAuth) async throws -> [ServerSubscription] {
        var monitors: [ServerSubscription] = []
        var ids: Set<String> = []
        var cursors: Set<String> = []
        var cursor: String?
        for _ in 0..<Self.downloadRegistryMaxPages {
            var query = ["limit": String(Self.downloadSubscriptionPageLimit)]
            if let cursor { query["cursor"] = cursor }
            let response = try await downloadRegistryRequest(method: "GET", path: "/api/v2/downloads/subscriptions",
                query: query, auth: auth)
            guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
            let page = try HTTPClient.makeJSONDecoder().decode(APIv2DownloadSubscriptionPage.self, from: response.data)
            guard page.items.count <= Self.downloadSubscriptionPageLimit else {
                throw DownloadSubscriptionError.incompleteList
            }
            for monitor in page.items {
                guard monitor.isUsable, ids.insert(monitor.id).inserted else {
                    throw DownloadSubscriptionError.incompleteList
                }
                monitors.append(monitor)
            }
            guard let info = page.page, info.hasMore else {
                guard page.page?.nextCursor?.isEmpty ?? true else { throw DownloadSubscriptionError.incompleteList }
                return monitors
            }
            guard let next = info.nextCursor, !next.isEmpty, !page.items.isEmpty, cursors.insert(next).inserted else {
                throw DownloadSubscriptionError.incompleteList
            }
            cursor = next
        }
        throw DownloadSubscriptionError.incompleteList
    }

    // MARK: getDownloadSubscription

    func downloadSubscription(id: String, auth: CapturedOrdinaryRequestAuth) async throws -> ServerSubscription {
        let path = try Self.downloadSubscriptionPath(id)
        let response = try await downloadRegistryRequest(method: "GET", path: path, auth: auth)
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        return try Self.decodeMonitor(response, id: id, seriesId: nil)
    }

    // MARK: createDownloadSubscription (non_retryable)

    /// Sends one create, exactly once. The server answers with the new
    /// monitor, or with the monitor this device already has for the series,
    /// unchanged. After an uncertain outcome the caller reads the monitor
    /// list instead of sending again.
    func createDownloadSubscription(
        _ request: CreateSubscriptionRequest,
        auth: CapturedOrdinaryRequestAuth
    ) async throws -> ServerSubscription {
        guard !request.seriesId.isEmpty, request.maxStorageBytes >= 0,
              SubscriptionMode(rawValue: request.mode) != nil else {
            throw DownloadSubscriptionError.invalidRequest
        }
        let response = try await downloadRegistryRequest(method: "POST", path: "/api/v2/downloads/subscriptions",
            body: try Self.snakeCaseBody(request), auth: auth)
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        return try Self.decodeMonitor(response, id: nil, seriesId: request.seriesId)
    }

    // MARK: updateDownloadSubscription (natural_idempotent, If-Match)

    /// Applies `patch` under the monitor's validator. A 412 (or the 409 of a
    /// concurrent edit) means the monitor changed since `etag` was read: the
    /// monitor is read again and the same fields are applied once more under
    /// its new validator. A monitor without a stored validator is read first.
    /// A 428 is a client bug and is never retried.
    func updateDownloadSubscription(
        id: String,
        etag: String?,
        patch: UpdateSubscriptionRequest,
        auth: CapturedOrdinaryRequestAuth
    ) async throws -> ServerSubscription {
        let path = try Self.downloadSubscriptionPath(id)
        let body = try Self.snakeCaseBody(patch)
        var validator = etag
        var reapplied = false
        while true {
            let current = try await monitorValidator(id: id, stored: validator, auth: auth)
            do {
                let response = try await downloadRegistryRequest(method: "PATCH", path: path, body: body,
                    headers: ["If-Match": current], auth: auth)
                guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
                return try Self.decodeMonitor(response, id: id, seriesId: nil)
            } catch where !reapplied && Self.monitorChanged(error) {
                reapplied = true
                validator = nil
            }
        }
    }

    // MARK: deleteDownloadSubscription (natural_idempotent, If-Match)

    /// Stops a monitor under its validator. A 404 means it is already gone.
    /// A 412 (or 409) reads the monitor again and deletes it once more under
    /// its new validator; a 428 is a client bug and is never retried.
    func deleteDownloadSubscription(id: String, etag: String?, auth: CapturedOrdinaryRequestAuth) async throws {
        let path = try Self.downloadSubscriptionPath(id)
        var validator = etag
        var reapplied = false
        while true {
            do {
                let current = try await monitorValidator(id: id, stored: validator, auth: auth)
                let response = try await downloadRegistryRequest(method: "DELETE", path: path,
                    headers: ["If-Match": current], auth: auth)
                guard response.statusCode == 204 else { throw APIv2Error.httpStatus(response.statusCode) }
                return
            } catch where Self.downloadStatus(of: error) == 404 {
                return
            } catch where !reapplied && Self.monitorChanged(error) {
                reapplied = true
                validator = nil
            }
        }
    }

    // MARK: syncDownloadSubscription (natural_idempotent)

    /// Registers the episodes one monitor puts in scope, one page at a time.
    /// Every page names the validator captured before the first page; a page
    /// without an answer is sent again with the same validator and cursor.
    /// A 409 means the monitor changed: it is read again and the sync starts
    /// over under its new validator. A 404 on either read, or on a page
    /// when the monitor read then answers 404 too, means the server no
    /// longer has the monitor. A paused monitor is not synced.
    ///
    /// Throws when a page is refused, when the server or network asks to
    /// wait, or when the sync does not finish within its bounds.
    func syncDownloadSubscription(
        id: String,
        etag: String?,
        auth: CapturedOrdinaryRequestAuth,
        retryDelay: TimeInterval = 1
    ) async throws -> DownloadSubscriptionSyncOutcome {
        var reloaded: ServerSubscription?
        var validator = etag ?? ""
        if validator.isEmpty {
            do {
                let monitor = try await downloadSubscription(id: id, auth: auth)
                reloaded = monitor
                validator = monitor.etag
            } catch where Self.downloadStatus(of: error) == 404 {
                return DownloadSubscriptionSyncOutcome(registered: 0, reloaded: nil, removed: true)
            }
        }
        var registered = 0
        var restarts = 0
        var retries = 0
        var pages = 0
        var cursor: String?
        var cursors: Set<String> = []
        while true {
            if let reloaded, !reloaded.active {
                return DownloadSubscriptionSyncOutcome(registered: registered, reloaded: reloaded, removed: false)
            }
            guard pages < Self.downloadRegistryMaxPages else { throw DownloadSubscriptionError.incompleteSync }
            do {
                let page = try await syncDownloadSubscriptionPage(id: id, etag: validator, cursor: cursor, auth: auth)
                pages += 1
                retries = 0
                registered += page.registered
                guard page.page.hasMore else {
                    return DownloadSubscriptionSyncOutcome(registered: registered, reloaded: reloaded, removed: false)
                }
                guard let next = page.page.nextCursor, !next.isEmpty, cursors.insert(next).inserted else {
                    throw DownloadSubscriptionError.incompleteSync
                }
                cursor = next
            } catch let pageError where Self.downloadStatus(of: pageError) == 404 {
                // The monitor was deleted, or its series is no longer
                // accessible; both answer 404, so only a read tells which.
                do {
                    _ = try await downloadSubscription(id: id, auth: auth)
                } catch where Self.downloadStatus(of: error) == 404 {
                    return DownloadSubscriptionSyncOutcome(registered: registered, reloaded: nil, removed: true)
                } catch {}
                throw pageError
            } catch where Self.downloadStatus(of: error) == 409 {
                guard restarts < Self.downloadSubscriptionSyncRestarts else { throw error }
                restarts += 1
                do {
                    let monitor = try await downloadSubscription(id: id, auth: auth)
                    reloaded = monitor
                    validator = monitor.etag
                } catch where Self.downloadStatus(of: error) == 404 {
                    return DownloadSubscriptionSyncOutcome(registered: registered, reloaded: nil, removed: true)
                }
                cursor = nil
                cursors.removeAll()
                pages = 0
                retries = 0
            } catch where retries < Self.downloadSubscriptionSyncPageRetries && Self.isTransportUncertain(error) {
                retries += 1
                if retryDelay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * Double(retries) * 1_000_000_000))
                }
            }
        }
    }

    /// One sync page. The answer must name the monitor it was asked about.
    private func syncDownloadSubscriptionPage(
        id: String,
        etag: String,
        cursor: String?,
        auth: CapturedOrdinaryRequestAuth
    ) async throws -> APIv2DownloadSubscriptionSync {
        guard !id.isEmpty, !etag.isEmpty else { throw DownloadSubscriptionError.invalidRequest }
        var query = ["limit": String(Self.downloadSubscriptionPageLimit)]
        if let cursor { query["cursor"] = cursor }
        // Sorted keys keep a retried page's body byte-identical to the first.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let body = try encoder.encode(APIv2DownloadSubscriptionSyncBody(subscriptionId: id, etag: etag))
        let response = try await downloadRegistryRequest(method: "POST", path: "/api/v2/downloads/subscriptions/sync",
            query: query, body: body, auth: auth)
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        guard let page = try? HTTPClient.makeJSONDecoder().decode(APIv2DownloadSubscriptionSync.self, from: response.data),
              page.subscriptionId == id, page.registered >= 0 else {
            throw DownloadSubscriptionError.unexpectedReceipt
        }
        return page
    }

    // MARK: Helpers

    /// The validator a write sends as `If-Match`: `stored` when it is set,
    /// otherwise the monitor's current one, read from the server.
    private func monitorValidator(id: String, stored: String?, auth: CapturedOrdinaryRequestAuth) async throws -> String {
        if let stored, !stored.isEmpty { return stored }
        return try await downloadSubscription(id: id, auth: auth).etag
    }

    /// The HTTP status of a failed monitor or registry call, if it has one.
    static func downloadStatus(of error: Error) -> Int? {
        switch error {
        case APIv2Error.problem(let problem): return problem.status
        case APIv2Error.httpStatus(let status): return status
        default: return nil
        }
    }

    /// A page that was sent and got no usable answer from the transport or
    /// the server. An answer the client could not use is not sent again.
    private static func isTransportUncertain(_ error: Error) -> Bool {
        guard !(error is DownloadSubscriptionError), !(error is CancellationError) else { return false }
        return downloadRegistryFailure(error) == .uncertain
    }

    /// 412: the validator is stale. 409: the monitor changed while the server
    /// applied the write.
    private static func monitorChanged(_ error: Error) -> Bool {
        let status = downloadStatus(of: error)
        return status == 412 || status == 409
    }

    private static func downloadSubscriptionPath(_ id: String) throws -> String {
        guard let segment = CatalogPathSegment.encode(id) else { throw DownloadSubscriptionError.invalidRequest }
        return "/api/v2/downloads/subscriptions/\(segment)"
    }

    private static func snakeCaseBody<Body: Encodable>(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(body)
    }

    /// Decodes a monitor answer and checks that it describes the monitor or
    /// series the request named. An answer that does not throws
    /// `unexpectedReceipt`, which counts as uncertain.
    private static func decodeMonitor(_ response: HTTPRawResponse, id: String?, seriesId: String?) throws -> ServerSubscription {
        guard let monitor = try? HTTPClient.makeJSONDecoder().decode(ServerSubscription.self, from: response.data),
              monitor.isUsable, id.map({ $0 == monitor.id }) ?? true,
              seriesId.map({ $0 == monitor.seriesId }) ?? true else {
            throw DownloadSubscriptionError.unexpectedReceipt
        }
        return monitor
    }
}

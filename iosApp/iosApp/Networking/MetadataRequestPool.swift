import Foundation

/// Coalesces only callers that are concurrently waiting for the same value.
///
/// This is intentionally not a response cache. A completed flight is removed,
/// failures are retryable, and mutation/polling code can keep using
/// `SiloAPI` directly when it requires a new server read.
actor MetadataSingleFlight<Key: Hashable & Sendable, Value> {
    private struct Flight {
        let task: Task<Value, Error>
        var waiters: Set<UUID>
    }

    private var flights: [Key: Flight] = [:]

    func value(
        for key: Key,
        operation: @escaping () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()

        let waiterID = UUID()
        let task: Task<Value, Error>
        if var flight = flights[key] {
            flight.waiters.insert(waiterID)
            flights[key] = flight
            task = flight.task
        } else {
            let newTask = Task { try await operation() }
            flights[key] = Flight(task: newTask, waiters: [waiterID])
            task = newTask
        }

        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, for: key) }
        }

        finishWaiter(waiterID, for: key)
        try Task.checkCancellation()
        return try result.get()
    }

    /// A shared request survives one view disappearing while another still
    /// needs it. When the final waiter goes away, stop work that no screen can
    /// consume. The waiter UUID also prevents a late completion from removing
    /// a replacement flight for the same key.
    private func cancelWaiter(_ waiterID: UUID, for key: Key) {
        guard var flight = flights[key], flight.waiters.remove(waiterID) != nil else {
            return
        }
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
            flight.task.cancel()
        } else {
            flights[key] = flight
        }
    }

    private func finishWaiter(_ waiterID: UUID, for key: Key) {
        guard var flight = flights[key], flight.waiters.remove(waiterID) != nil else {
            return
        }
        if flight.waiters.isEmpty {
            flights.removeValue(forKey: key)
        } else {
            flights[key] = flight
        }
    }
}

/// Opt-in shared flights for steady-state metadata reads.
///
/// Keys include the nonsecret account credential generation and profile so a
/// profile/server transition cannot join a request dispatched for the prior
/// identity. Callers whose freshness depends on an external revision can add
/// that revision to `itemDetail`; mutation pollers should bypass this type and
/// call `SiloAPI` directly.
final class MetadataRequestPool: @unchecked Sendable {
    static let shared = MetadataRequestPool()

    private struct RequestScope: Hashable, Sendable {
        let account: RefreshAccountIdentity?
        let profileID: String?
        let libraryID: Int?
    }

    private struct ItemDetailKey: Hashable, Sendable {
        let scope: RequestScope
        let contentID: String
        let freshnessDiscriminator: String?
    }

    private struct SeasonsKey: Hashable, Sendable {
        let scope: RequestScope
        let seriesID: String
    }

    private struct EpisodesKey: Hashable, Sendable {
        let scope: RequestScope
        let seriesID: String
        let seasonNumber: Int
    }

    private struct WatchDetailKey: Hashable, Sendable {
        let scope: RequestScope
        let contentID: String
    }

    private let itemDetailFlights = MetadataSingleFlight<ItemDetailKey, ItemDetail>()
    private let seasonsFlights = MetadataSingleFlight<SeasonsKey, SeasonsResponse>()
    private let episodesFlights = MetadataSingleFlight<EpisodesKey, EpisodesResponse>()
    private let watchDetailFlights = MetadataSingleFlight<WatchDetailKey, WatchDetail>()

    private let api: SiloAPI
    private let tokenStore: TokenStore

    init(api: SiloAPI = .shared, tokenStore: TokenStore = .shared) {
        self.api = api
        self.tokenStore = tokenStore
    }

    func itemDetail(
        contentId: String,
        libraryId: Int? = nil,
        freshnessDiscriminator: String? = nil
    ) async throws -> ItemDetail {
        let key = ItemDetailKey(
            scope: await requestScope(libraryId: libraryId),
            contentID: contentId,
            freshnessDiscriminator: freshnessDiscriminator
        )
        return try await itemDetailFlights.value(for: key) {
            try await self.api.itemDetail(contentId: contentId, libraryId: libraryId)
        }
    }

    func seasons(seriesId: String, libraryId: Int? = nil) async throws -> SeasonsResponse {
        let key = SeasonsKey(scope: await requestScope(libraryId: libraryId), seriesID: seriesId)
        return try await seasonsFlights.value(for: key) {
            try await self.api.seasons(seriesId: seriesId, libraryId: libraryId)
        }
    }

    func episodes(seriesId: String, seasonNumber: Int, libraryId: Int? = nil) async throws -> EpisodesResponse {
        let key = EpisodesKey(
            scope: await requestScope(libraryId: libraryId),
            seriesID: seriesId,
            seasonNumber: seasonNumber
        )
        return try await episodesFlights.value(for: key) {
            try await self.api.episodes(
                seriesId: seriesId,
                seasonNumber: seasonNumber,
                libraryId: libraryId
            )
        }
    }

    func watchDetail(contentId: String, libraryId: Int? = nil) async throws -> WatchDetail {
        let key = WatchDetailKey(scope: await requestScope(libraryId: libraryId), contentID: contentId)
        return try await watchDetailFlights.value(for: key) {
            try await self.api.watchDetail(contentId: contentId, libraryId: libraryId)
        }
    }

    private func requestScope(libraryId: Int?) async -> RequestScope {
        let auth = await tokenStore.captureOrdinaryRequestAuth()
        return RequestScope(account: auth?.account, profileID: auth?.profileId, libraryID: libraryId)
    }
}

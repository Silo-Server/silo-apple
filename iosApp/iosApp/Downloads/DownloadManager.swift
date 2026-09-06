import Foundation
import Observation
import OSLog

enum DownloadError: LocalizedError {
    case unavailable
    case fileURLUnavailable
    case emptyRegistrationResponse
    case registrationAlreadyInFlight
    case scopeChangedDuringRegistration

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Downloads aren't available for this profile."
        case .fileURLUnavailable: return "Could not resolve the download URL."
        case .emptyRegistrationResponse: return "The server didn't create a download."
        case .registrationAlreadyInFlight: return "This download is already being prepared."
        case .scopeChangedDuringRegistration: return "The active profile changed before the download could start."
        }
    }
}

/// Coordinates the offline-downloads feature: capability gating, the local
/// registry, the background transfer pipeline, series-monitoring sync, and
/// offline progress reconciliation.
///
/// The store actor owns durable state. This coordinator publishes only checked
/// command receipts and captures the owner before each asynchronous operation.
@Observable
@MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Downloads"
    )

    private static let maxConcurrentTransfers = 3
    private static let maxRetries = 4

    /// In-memory persisted blob. `private(set)` so the `@Observable` macro
    /// tracks reads of its derived accessors below.
    private(set) var file: DownloadStoreFile = .empty {
        didSet {
            rebuildDownloadedIndex()
            let enabled = file.capability?.isUsable == true
            if enabled != downloadsEnabled { downloadsEnabled = enabled }
            syncLiveActivity()
        }
    }

    private(set) var scopeServerId: String = ""
    private(set) var scopeProfileId: String = ""

    private struct OwnerHandle {
        let id: UUID
        let store: ProgressBootstrapStore
        let authority: DownloadLocalAuthority
        let auth: CapturedOrdinaryRequestAuth
        let generation: UUID
        let assets: DownloadAssetOwnership
    }
    // Production marker publication remains disabled until the immutable review.
    private let permitOwnershipTransfer: Bool
    private let rootOverride: URL?
    private let transferTokenStore: TokenStore
    private let captureAuthority: @Sendable () async -> CapturedDurableAccountAuth?
    private var owner: OwnerHandle?
    private var publishedRevision: UInt64 = 0
    private var activationTask: Task<Bool, Never>?
    private var activationID = UUID()
    private var pipelineTokens: [String: UUID] = [:]
    private var retryTokens: [String: UUID] = [:]
    private var pipelineTasks: [String: Task<Void, Never>] = [:]
    private var startingIDs: Set<String> = []
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var pendingPauseIDs: Set<String> = []
    private var pendingResumeIDs: Set<String> = []
    private let sessionDelegate: DownloadSessionDelegate
    private var pollTask: Task<Void, Never>?
    private var unsavedProgress: [UUID: (QueuedProgress, Bool, OwnerHandle)] = [:]
    private(set) var persistenceError: String?
    /// Local events are durable, but upload/bootstrap activation is a later checkpoint.
    let progressSynchronizationIsQueuedOnly = true
    /// Cached scope storage usage; refreshed off the MainActor (a filesystem
    /// walk) so SwiftUI bodies reading `totalBytesUsed` don't block.
    private(set) var storageBytesUsed: Int64 = 0
    /// Smoothed transfer rate (bytes/sec) per downloading record, derived
    /// from progress deltas so the UI never needs its own timer competing
    /// with the `@Observable` update path.
    private(set) var transferRates: [String: Double] = [:]
    private var rateSamples: [String: (bytes: Int64, at: Date)] = [:]
    private static let rateSampleInterval: TimeInterval = 0.5
    private static let rateSmoothing = 0.3
    /// Last time each record's byte counter was published into the
    /// `@Observable` `file` blob. Delegate callbacks arrive many times per
    /// second; UI counters should tick at a readable cadence instead.
    private var lastProgressPublish: [String: Date] = [:]
    private static let progressPublishInterval: TimeInterval = 1.0

    init(permitOwnershipTransfer: Bool = false, rootOverride: URL? = nil, tokenStore: TokenStore = .shared, sessionDelegate: DownloadSessionDelegate? = nil,
         captureAuthority: @escaping @Sendable () async -> CapturedDurableAccountAuth? = { await TokenStore.shared.captureDurableAccountAuth() }) {
        self.permitOwnershipTransfer = permitOwnershipTransfer
        self.rootOverride = rootOverride
        self.captureAuthority = captureAuthority
        self.transferTokenStore = tokenStore
        self.sessionDelegate = sessionDelegate ?? DownloadSessionDelegate(parkingRoot: rootOverride,
            identifier: rootOverride == nil ? DownloadSessionDelegate.sessionIdentifier : "com.continuum.play.downloads.test.\(UUID())")
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.sessionDelegate.events {
                await self.handleSessionEvent(event)
            }
        }
    }

    // MARK: - Observable surface

    var capability: DownloadCapability? { file.capability }
    /// Stored mirror of `capability?.isUsable`, maintained by `file`'s
    /// `didSet`, so hot per-card checks (`isDownloaded`) never register the
    /// whole `file` blob — reassigned on every transfer progress tick — as
    /// their observed state.
    private(set) var downloadsEnabled: Bool = false
    /// Leaf ids currently waiting for POST /downloads to return. This belongs
    /// to the manager (rather than one button) so a detail rebuild cannot make
    /// the preparing indicator disappear during registration.
    private(set) var pendingRegistrationContentIds: Set<String> = []
    /// Each pending id owns a unique token. An older request may finish after
    /// sign-out and reactivation, but its defer must never clear a newer
    /// request for the same content id.
    private var pendingRegistrationTokens: [String: UUID] = [:]
    /// Incremented whenever the active server/profile identity is invalidated
    /// or replaced. Network responses captured under an older generation are
    /// discarded before they can mutate the newly active scope.
    private var registrationScopeGeneration: UInt64 = 0
    var canDownloadSeason: Bool { downloadsEnabled && capability?.seasonDownload == true }
    var canMonitorSeries: Bool { downloadsEnabled && capability?.seriesMonitoring == true }

    var availableFormats: [DownloadFormat] {
        (capability?.qualityPresets ?? []).compactMap(DownloadFormat.init(rawValue:))
    }

    var monitoringModes: [SubscriptionMode] {
        (capability?.monitoringModes ?? []).compactMap(SubscriptionMode.init(rawValue:))
    }

    /// All records, newest first.
    var records: [DownloadRecord] {
        file.records.values.sorted { $0.registeredAt > $1.registeredAt }
    }

    var activeRecords: [DownloadRecord] { records.filter { $0.localStatus.isActive } }
    var subscriptions: [DownloadSubscription] { file.subscriptions }

    var totalBytesUsed: Int64 { storageBytesUsed }

    // MARK: - Lookups

    /// Leaf content ids (movie `contentId` / episode `episodeId`) whose media
    /// is on disk. Cached separately from `records` because poster cards check
    /// membership per card render — and only republished when membership
    /// actually changes, so in-flight progress ticks (which also mutate `file`)
    /// don't invalidate every visible card.
    private(set) var downloadedContentIds: Set<String> = []

    /// Single capability-aware check for the card badges: true only when the
    /// server still advertises downloads for this profile *and* the item's
    /// media is on device, so badges vanish alongside every other download
    /// affordance on servers without the capability. Membership is checked
    /// first so the (overwhelmingly common) non-downloaded card never touches
    /// the capability flag at all.
    func isDownloaded(contentId: String) -> Bool {
        downloadedContentIds.contains(contentId) && downloadsEnabled
    }

    private func rebuildDownloadedIndex() {
        // Revoked downloads keep their on-device file (playable offline),
        // so they badge the same as completed ones.
        let ids = Set(
            file.records.values
                .filter { $0.localStatus == .completed || $0.localStatus == .revoked }
                .map { $0.episodeId ?? $0.contentId }
        )
        if ids != downloadedContentIds {
            downloadedContentIds = ids
        }
    }

    /// The download record for a leaf content id (movie or episode), if any.
    func record(forContentId contentId: String) -> DownloadRecord? {
        file.records.values.first { $0.contentId == contentId || $0.episodeId == contentId }
    }

    func isRegistering(contentId: String) -> Bool {
        pendingRegistrationContentIds.contains(contentId)
    }

    func record(id: String) -> DownloadRecord? { file.records[id] }

    func subscription(forSeriesId seriesId: String) -> DownloadSubscription? {
        file.subscriptions.first { $0.seriesId == seriesId }
    }

    func absoluteMediaURL(for record: DownloadRecord) -> URL? {
        guard let filename = record.mediaFilename, !scopeServerId.isEmpty else { return nil }
        return DownloadFilePaths.fileURL(
            serverId: scopeServerId,
            profileId: scopeProfileId,
            downloadId: record.id,
            filename: filename
        )
    }

    func absoluteFileURL(for record: DownloadRecord, filename: String) -> URL? {
        guard !scopeServerId.isEmpty else { return nil }
        return DownloadFilePaths.fileURL(
            serverId: scopeServerId,
            profileId: scopeProfileId,
            downloadId: record.id,
            filename: filename
        )
    }

    func localProgress(forMediaItemId mediaItemId: String) -> LocalProgressEntry? {
        file.localProgress[mediaItemId]
    }

    /// On-disk poster image for a record — present once the asset pipeline
    /// has fetched artwork, which runs before the media transfer starts, so
    /// in-progress rows can show real art rather than a placeholder.
    func posterImageURL(for record: DownloadRecord) -> URL? {
        record.posterFilename.flatMap { absoluteFileURL(for: record, filename: $0) }
    }

    func transferRate(id: String) -> Double? {
        transferRates[id]
    }

    /// Decode the on-disk offline manifest for a completed download. The file
    /// read + decode happens on the `DownloadStore` actor, off the MainActor.
    func loadManifest(for record: DownloadRecord) async -> OfflineManifest? {
        guard let filename = record.manifestFilename,
              let url = absoluteFileURL(for: record, filename: filename) else {
            return nil
        }
        return await DownloadStore.shared.loadManifest(at: url)
    }

    // MARK: - Grouped surface (Downloads redesign)

    /// Whether this download's leaf item has been watched to completion —
    /// drives the reclaim suggestion and the "watched" episode dimming.
    func isWatched(_ record: DownloadRecord) -> Bool {
        file.localProgress[record.leafMediaItemId]?.completed == true
    }

    /// Completed/revoked records that physically occupy storage and can be
    /// browsed offline. Excludes failed and in-flight records.
    var onDeviceRecords: [DownloadRecord] {
        records.filter { $0.localStatus == .completed || $0.localStatus == .revoked }
    }

    /// Standalone downloaded movies (no parent series).
    var movieRecords: [DownloadRecord] {
        onDeviceRecords.filter { $0.seriesId == nil }
    }

    /// Downloaded episodes grouped by series, then season — the spine of the
    /// redesigned Downloads list and the offline series-browse screen.
    var seriesGroups: [DownloadSeriesGroup] {
        DownloadGroupBuilder.seriesGroups(
            from: onDeviceRecords,
            isWatched: { isWatched($0) },
            seriesTitle: { subscription(forSeriesId: $0)?.seriesTitle },
            isMonitored: { subscription(forSeriesId: $0) != nil }
        )
    }

    /// Records downloaded *and* watched to completion — the set the
    /// "Free up space" suggestion offers to delete.
    var reclaimableRecords: [DownloadRecord] {
        onDeviceRecords.filter { $0.localStatus == .completed && isWatched($0) }
    }

    var reclaimableBytes: Int64 {
        reclaimableRecords.reduce(0) { $0 + $1.fileSize }
    }

    /// Storage split for the hero bar: series vs movies (summed from record
    /// sizes), in-flight transfer bytes (from active records' progress —
    /// invisible to the on-disk walk while the media sits in the session's
    /// staging area), plus an "other" remainder (artwork/manifests/
    /// subtitles) derived from the true on-disk total.
    var storageBreakdown: DownloadStorageBreakdown {
        var series: Int64 = 0
        var movies: Int64 = 0
        for record in onDeviceRecords {
            if record.seriesId == nil { movies += record.fileSize }
            else { series += record.fileSize }
        }
        let inProgress = records.reduce(Int64(0)) {
            $0 + ($1.localStatus.isActive ? $1.bytesDownloaded : 0)
        }
        let other = max(0, storageBytesUsed - series - movies)
        return DownloadStorageBreakdown(
            series: series,
            movies: movies,
            inProgress: inProgress,
            other: other
        )
    }

    /// The unified, sorted list the Manager renders: one entry per series
    /// group and one per standalone movie.
    func downloadListItems(sortedBy option: DownloadSortOption) -> [DownloadListItem] {
        var items = seriesGroups.map(DownloadListItem.series)
        items += movieRecords.map(DownloadListItem.movie)
        return DownloadGroupBuilder.sorted(items, by: option)
    }

    private func verified(_ handle: OwnerHandle) async throws -> CapturedOrdinaryRequestAuth {
        guard owner?.id == handle.id,
              let current = await captureAuthority(),
              try DownloadLocalAuthority(current) == handle.authority,
              current.request.account == handle.auth.account,
              current.request.profileToken == handle.auth.profileToken,
              owner?.id == handle.id else { throw DownloadOwnershipError.wrongAuthority }
        return current.request
    }

    private func publish(_ state: DownloadLocalState, owner handle: OwnerHandle) async throws {
        _ = try await verified(handle)
        guard state.authority == handle.authority, state.ownerGeneration == handle.generation else {
            throw DownloadOwnershipError.stale
        }
        guard state.revision >= publishedRevision else { return }
        publishedRevision = state.revision
        file = state.downloads
        persistenceError = nil
    }

    @discardableResult
    private func command(_ command: DownloadLocalCommand, owner handle: OwnerHandle, recordOperation: (String, UUID)? = nil) async throws -> DownloadLocalState {
        _ = try await verified(handle)
        let state = try await handle.store.applyLocal(command, generation: handle.generation, recordOperation: recordOperation)
        try await publish(state, owner: handle)
        return state
    }

    private func requireOwner() throws -> OwnerHandle {
        guard let owner else { throw DownloadOwnershipError.disabled }
        return owner
    }

    private func report(_ error: Error) {
        persistenceError = "The change could not be saved. Your existing downloads have been kept."
        Self.logger.error("Download command did not commit")
    }

    private func request<T: Decodable>(_ method: String, _ path: String, body: Data? = nil, query: [String: String] = [:], maxResponseBytes: Int? = nil,
                                       owner handle: OwnerHandle) async throws -> T {
        let auth = try await verified(handle)
        let identity = HTTPRequestIdentity(serverId: handle.authority.serverID, serverURL: handle.authority.origin,
            profileId: handle.authority.profileID, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let response = try await HTTPClient.shared.requestData(method: method, path: path, query: query, body: body,
            requestIdentity: identity, expectedAccount: auth.account)
        _ = try await verified(handle)
        if let maxResponseBytes, response.data.count > maxResponseBytes { throw DownloadOwnershipError.incompleteAction }
        return try HTTPClient.makeJSONDecoder().decode(T.self, from: response.data)
    }

    private func requestVoid(_ method: String, _ path: String, body: Data? = nil, owner handle: OwnerHandle) async throws {
        let auth = try await verified(handle)
        let identity = HTTPRequestIdentity(serverId: handle.authority.serverID, serverURL: handle.authority.origin,
            profileId: handle.authority.profileID, clientFamily: AppleDeviceIdentity.current.clientFamily)
        _ = try await HTTPClient.shared.requestData(method: method, path: path, body: body,
            requestIdentity: identity, expectedAccount: auth.account)
        _ = try await verified(handle)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(value)
    }

    func activateScopeIfNeeded() async -> Bool {
        if let owner, (try? await verified(owner)) != nil { return true }
        guard permitOwnershipTransfer, rootOverride != nil else { return false }
        if let activationTask { return await activationTask.value }
        let attempt = UUID()
        activationID = attempt
        let task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                guard let auth = await captureAuthority() else { throw DownloadOwnershipError.wrongAuthority }
                guard activationID == attempt else { throw DownloadOwnershipError.stale }
                try Task.checkCancellation()
                let authority = try DownloadLocalAuthority(auth)
                let root = rootOverride ?? DownloadFilePaths.scopeDirectory(serverId: authority.serverID, profileId: authority.profileID)
                let store = ProgressBootstrapStore(localRoot: root, authority: authority)
                let state = try await store.openLocal(legacyData: nil, permitMigration: permitOwnershipTransfer)
                guard let current = await captureAuthority(),
                      try DownloadLocalAuthority(current) == authority, current.request.account == auth.request.account else {
                    throw DownloadOwnershipError.wrongAuthority
                }
                guard activationID == attempt else { throw DownloadOwnershipError.stale }
                try Task.checkCancellation()
                let handle = OwnerHandle(id: UUID(), store: store, authority: authority, auth: auth.request,
                    generation: state.ownerGeneration, assets: DownloadAssetOwnership(root: root))
                owner = handle
                publishedRevision = 0
                scopeServerId = authority.serverID
                scopeProfileId = authority.profileID
                try await publish(state, owner: handle)
                refreshStorageUsage()
                return true
            } catch {
                if activationID == attempt { report(error) }
                return false
            }
        }
        activationTask = task
        let result = await task.value
        if activationID == attempt { activationTask = nil }
        return result
    }

    func onAppActive(onCapabilityRefreshed: (() -> Void)? = nil) async {
        guard await activateScopeIfNeeded() else { return }
        await recoverTransfers()
        for id in Array(unsavedProgress.keys) { await persistPendingProgress(id) }
        await refreshCapability()
        onCapabilityRefreshed?()
        await reconcileWithServer(triggerPipeline: true)
        await runMonitoringAndProgressSync()
    }

    func clearForSignOut() {
        activationID = UUID()
        owner = nil
        activationTask?.cancel()
        activationTask = nil
        pollTask?.cancel()
        pollTask = nil
        for task in pipelineTasks.values { task.cancel() }
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        pipelineTasks.removeAll()
        retryTokens.removeAll()
        pipelineTokens.removeAll()
        pendingPauseIDs.removeAll()
        pendingResumeIDs.removeAll()
        startingIDs.removeAll()
        pendingRegistrationTokens.removeAll()
        pendingRegistrationContentIds.removeAll()
        registrationScopeGeneration &+= 1
        scopeServerId = ""
        scopeProfileId = ""
        file = .empty
        publishedRevision = 0
        transferRates = [:]
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        sessionDelegate.backgroundCompletionHandler = handler
    }

    func refreshCapability() async {
        do {
            let handle = try requireOwner()
            let capability: APIv2DownloadCapability = try await request("GET", "/api/v2/capabilities/downloads", owner: handle)
            try await command(.capability(capability.localValue, Date()), owner: handle)
        } catch { report(error) }
    }
    func downloadMovie(
        contentId: String,
        displayTitle: String?,
        year: Int?,
        posterThumbhash: String?,
        fileId: Int? = nil,
        quality: String? = nil
    ) async throws {
        try await requestDownload(
            contentId: contentId,
            fileId: fileId,
            quality: quality,
            type: "movie",
            displayTitle: displayTitle,
            displaySubtitle: year.map(String.init),
            posterThumbhash: posterThumbhash
        )
    }

    func downloadEpisode(
        seriesId: String,
        episodeId: String,
        displayTitle: String?,
        displaySubtitle: String?,
        posterThumbhash: String?,
        fileId: Int? = nil,
        quality: String? = nil
    ) async throws {
        try await requestDownload(
            contentId: seriesId,
            episodeId: episodeId,
            fileId: fileId,
            quality: quality,
            type: "episode",
            seriesId: seriesId,
            displayTitle: displayTitle,
            displaySubtitle: displaySubtitle,
            posterThumbhash: posterThumbhash
        )
    }

    func downloadSeason(seriesId: String, seasonNumber: Int) async throws {
        try await requestDownload(contentId: seriesId, series: true, seasonNumber: seasonNumber, seriesId: seriesId)
    }

    func downloadSeries(seriesId: String) async throws {
        try await requestDownload(contentId: seriesId, series: true, seriesId: seriesId)
    }

    private func requestDownload(
        contentId: String,
        episodeId: String? = nil,
        fileId: Int? = nil,
        quality requestedQuality: String? = nil,
        series: Bool = false,
        seasonNumber: Int? = nil,
        type: String? = nil,
        seriesId: String? = nil,
        displayTitle: String? = nil,
        displaySubtitle: String? = nil,
        posterThumbhash: String? = nil
    ) async throws {
        guard downloadsEnabled else { throw DownloadError.unavailable }

        let registrationContentId = episodeId ?? contentId
        guard pendingRegistrationTokens[registrationContentId] == nil else {
            throw DownloadError.registrationAlreadyInFlight
        }
        let registrationToken = UUID()
        let capturedScopeGeneration = registrationScopeGeneration
        let capturedServerId = scopeServerId
        let capturedProfileId = scopeProfileId
        pendingRegistrationTokens[registrationContentId] = registrationToken
        pendingRegistrationContentIds.insert(registrationContentId)
        defer {
            finishPendingRegistration(
                contentId: registrationContentId,
                token: registrationToken
            )
        }

        // Series/season batches are original-quality only per the server
        // contract; single items may use any advertised public quality preset.
        let isBatch = series || seasonNumber != nil
        let quality = isBatch
            ? DownloadFormat.original.rawValue
            : resolvedDownloadQuality(requestedQuality)

        let request = CreateDownloadRequest(
            contentId: contentId,
            episodeId: episodeId,
            fileId: fileId,
            quality: quality,
            series: series ? true : nil,
            seasonNumber: seasonNumber,
            caps: DownloadCaps.current()
        )
        let handle = try requireOwner()
        let response: CreateDownloadResponse = try await self.request("POST", "/api/v1/downloads", body: encode(request), owner: handle)
        let rows = response.downloads
        guard capturedScopeGeneration == registrationScopeGeneration,
              capturedServerId == scopeServerId,
              capturedProfileId == scopeProfileId else {
            throw DownloadError.scopeChangedDuringRegistration
        }
        guard !rows.isEmpty else { throw DownloadError.emptyRegistrationResponse }
        try await command(.registered(rows, DownloadRegistrationDisplay(title: rows.count == 1 ? displayTitle : nil,
            subtitle: rows.count == 1 ? displaySubtitle : nil, type: type, seriesID: seriesId,
            posterThumbhash: rows.count == 1 ? posterThumbhash : nil)), owner: handle)
        processQueue()
        ensurePolling()
    }

    private func finishPendingRegistration(contentId: String, token: UUID) {
        guard pendingRegistrationTokens[contentId] == token else { return }
        pendingRegistrationTokens.removeValue(forKey: contentId)
        pendingRegistrationContentIds.remove(contentId)
    }

    private func resolvedDownloadQuality(_ requestedQuality: String?) -> String {
        let allowed = capability?.qualityPresets ?? []
        if let requestedQuality, allowed.contains(requestedQuality) {
            return requestedQuality
        }
        return DownloadSettings.shared.resolvedFormat(allowedFormats: allowed)
    }

    func deleteDownload(id: String) { deleteDownloads(ids: [id]) }
    func deleteDownload(forContentId contentId: String) {
        if let record = record(forContentId: contentId) { deleteDownload(id: record.id) }
    }

    func deleteDownloads(ids: [String]) {
        guard let handle = owner else { return }
        Task {
            do {
                for id in ids {
                    _ = try await verified(handle)
                    let lease = try await handle.store.localLease(downloadID: id)
                    let snapshot = try await handle.store.localSnapshot()
                    for binding in snapshot.transfers.values where binding.lease == lease { sessionDelegate.cancel(binding) }
                    pipelineTasks[id]?.cancel()
                    retryTasks[id]?.cancel()
                    do {
                        try await requestVoid("DELETE", DownloadRegistryV2.path(id: id), owner: handle)
                    } catch let error as HTTPError where error.statusCode == 404 {
                        // The prior DELETE may have succeeded before its response was lost.
                        _ = try await verified(handle)
                    }
                    let result = try await handle.store.deleteLocalRecord(lease, generation: handle.generation)
                    try await publish(result, owner: handle)
                }
                refreshStorageUsage()
            } catch { report(error) }
        }
    }

    func pauseDownload(id: String) {
        guard let handle = owner, let record = file.records[id] else { return }
        pendingPauseIDs.insert(id)
        Task {
            defer { if owner?.id == handle.id { pendingPauseIDs.remove(id) } }
            do {
                let snapshot = try await handle.store.localSnapshot()
                let binding = snapshot.transfers.values.first { $0.taskID == record.taskIdentifier && $0.lease.downloadID == id }
                pipelineTasks[id]?.cancel()
                retryTasks[id]?.cancel()
                let paused = try await command(.status(id, .paused, nil), owner: handle)
                if let binding, let data = await sessionDelegate.pause(binding) {
                    let lease = try await handle.store.localLease(downloadID: id)
                    try await attach(data, suffix: "resume", kind: .resume, lease: lease, owner: handle, operationID: paused.recordOperations[id])
                }
                if pendingResumeIDs.remove(id) != nil { resumeDownload(id: id) }
            } catch { report(error) }
        }
    }

    func resumeDownload(id: String) {
        if pendingPauseIDs.contains(id) { pendingResumeIDs.insert(id); return }
        guard let handle = owner else { return }
        Task {
            do { try await command(.status(id, .queued, nil), owner: handle); processQueue() }
            catch { report(error) }
        }
    }

    func retryDownload(id: String) { resumeDownload(id: id) }

    private func processQueue() {
        guard let handle = owner else { return }
        let active = records.filter { $0.localStatus == .downloading || $0.localStatus == .fetchingAssets }.count
        let available = max(0, Self.maxConcurrentTransfers - active - startingIDs.count)
        for record in records.filter({ $0.localStatus == .queued && !startingIDs.contains($0.id) && !exceedsStorageCap(for: $0) }).prefix(available) {
            startingIDs.insert(record.id)
            let token = UUID()
            pipelineTokens[record.id] = token
            pipelineTasks[record.id] = Task {
                var operation: UUID?
                defer {
                    if pipelineTokens[record.id] == token {
                        startingIDs.remove(record.id)
                        pipelineTasks.removeValue(forKey: record.id)
                        pipelineTokens.removeValue(forKey: record.id)
                    }
                }
                do {
                    let (result, operationID) = try await handle.store.beginLocalPipeline(id: record.id, generation: handle.generation)
                    operation = operationID
                    try await publish(result, owner: handle)
                    try await startMediaPipeline(recordId: record.id, operationID: operationID, owner: handle)
                } catch {
                    if let operation, (try? await verified(handle)) != nil {
                        try? await command(.status(record.id, .failed, "Download interrupted. Try again."), owner: handle, recordOperation: (record.id, operation))
                    }
                    report(error)
                    scheduleRetry(recordId: record.id, owner: handle)
                }
            }
        }
    }

    private func scheduleRetry(recordId: String, owner handle: OwnerHandle) {
        guard let record = file.records[recordId], record.localStatus == .failed,
              record.retryCount < Self.maxRetries, retryTasks[recordId] == nil else { return }
        let count = record.retryCount
        let token = UUID()
        retryTokens[recordId] = token
        retryTasks[recordId] = Task {
            defer {
                if retryTokens[recordId] == token {
                    retryTasks.removeValue(forKey: recordId)
                    retryTokens.removeValue(forKey: recordId)
                }
            }
            do {
                try await Task.sleep(for: .seconds(min(30, pow(2, Double(count)))))
                try await command(.retry(recordId, count), owner: handle)
                processQueue()
            } catch { if !Task.isCancelled { report(error) } }
        }
    }

    private func attach(_ data: Data, suffix: String, kind: DownloadAssetKind,
                        lease: DownloadAssetLease, owner handle: OwnerHandle, operationID: UUID? = nil) async throws {
        _ = try await verified(handle)
        let directory = handle.assets.root.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temporary, options: .withoutOverwriting)
        let result = try await handle.store.attachLocalAsset(source: temporary, suffix: suffix, kind: kind,
            lease: lease, generation: handle.generation, operationID: operationID)
        try await publish(result, owner: handle)
        // Successful inputs remain journal recovery material until a separately leased
        // cleanup. Failed writes never delete a valid incoming or existing asset.
    }

    private func startMediaPipeline(recordId: String, operationID: UUID, owner handle: OwnerHandle) async throws {
        let lease = try await handle.store.localLease(downloadID: recordId)
        let wire: APIv2DownloadManifest = try await request("GET", DownloadRegistryV2.path(id: recordId) + "/manifest",
            maxResponseBytes: 1 << 20, owner: handle)
        let snapshot = try await handle.store.localSnapshot()
        guard let record = snapshot.downloads.records[recordId], snapshot.recordOperations[recordId] == operationID else {
            throw DownloadOwnershipError.stale
        }
        let manifest = try wire.validated(for: record)
        try await attach(JSONEncoder().encode(manifest), suffix: "json", kind: .manifest, lease: lease, owner: handle, operationID: operationID)
        try await command(.manifest(recordId, manifest), owner: handle, recordOperation: (recordId, operationID))
        let assets: [(String?, DownloadAssetKind)] = [(manifest.artworkUrls?.poster, .poster),
            (manifest.artworkUrls?.backdrop, .backdrop), (manifest.artworkUrls?.logo, .logo)]
        for (path, kind) in assets {
            if let path { try await fetchOptionalAsset(path: path, suffix: "jpg", kind: kind, lease: lease, owner: handle, operationID: operationID) }
        }
        for subtitle in manifest.subtitles ?? [] {
            try await fetchOptionalAsset(path: subtitle.fetchUrl, suffix: subtitle.format ?? "srt", kind: .subtitle(subtitle.fetchUrl), lease: lease, owner: handle, operationID: operationID)
        }
        let auth = try await verified(handle)
        let url = try APIv2DownloadManifest.fileURL(origin: handle.authority.origin, downloadID: recordId)
        let transferID = UUID()
        let request = DownloadAuthHeaders.authorizedRequest(url: url, allowsCellular: !DownloadSettings.shared.wifiOnly, auth: auth)
        let task: URLSessionDownloadTask
        if let record = file.records[recordId], let filename = record.resumeDataFilename,
           let data = try? Data(contentsOf: handle.assets.root.appendingPathComponent(recordId).appendingPathComponent(filename)) {
            let resumed = sessionDelegate.prepare(data: data, transferID: transferID)
            if resumed.originalRequest?.url == url {
                task = resumed
            } else {
                resumed.cancel()
                task = sessionDelegate.prepare(request: request, transferID: transferID)
            }
        } else { task = sessionDelegate.prepare(request: request, transferID: transferID) }
        let binding = DownloadTaskBinding(transferID: transferID, sessionID: sessionDelegate.identifier,
            taskID: task.taskIdentifier, lease: lease, operationID: operationID)
        do {
            let result = try await handle.store.bindLocalTask(binding, generation: handle.generation)
            try await publish(result, owner: handle)
            try await handle.store.resumeLocalTask(binding, generation: handle.generation,
                tokenStore: transferTokenStore, auth: CapturedDurableAccountAuth(accountID: handle.authority.accountID,
                    accountEpoch: handle.authority.accountEpoch, request: auth)) { task.resume() }
            await flushStatus(id: recordId, owner: handle)
        } catch { task.cancel(); throw error }
    }

    private func fetchOptionalAsset(path: String, suffix: String, kind: DownloadAssetKind,
                                    lease: DownloadAssetLease, owner handle: OwnerHandle, operationID: UUID) async throws {
        do {
            try await fetchAsset(path: path, suffix: suffix, kind: kind, lease: lease, owner: handle, operationID: operationID)
        } catch HTTPError.http(let status, _) where status != 401 && status != 403 {
            // Missing optional artwork or subtitles do not prevent media playback.
        } catch HTTPError.network {
            try Task.checkCancellation()
            _ = try await verified(handle)
        }
    }

    private func fetchAsset(path: String, suffix: String, kind: DownloadAssetKind,
                            lease: DownloadAssetLease, owner handle: OwnerHandle, operationID: UUID? = nil) async throws {
        let auth = try await verified(handle)
        let identity = HTTPRequestIdentity(serverId: handle.authority.serverID, serverURL: handle.authority.origin,
            profileId: handle.authority.profileID, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let response = try await HTTPClient.shared.requestData(method: "GET", path: path,
            requestIdentity: identity, expectedAccount: auth.account)
        try await attach(response.data, suffix: suffix, kind: kind, lease: lease, owner: handle, operationID: operationID)
    }

    private func handleSessionEvent(_ event: DownloadSessionEvent) async {
        if case .allEventsDelivered = event {
            // Stream consumption awaits every preceding command. Unknown arrivals were
            // already parked synchronously; no swallowed persistence task is treated as success.
            await recoverTransfers()
            let handler = sessionDelegate.backgroundCompletionHandler
            sessionDelegate.backgroundCompletionHandler = nil
            handler?()
            return
        }
        guard await activateScopeIfNeeded(), let handle = owner else { return }
        do {
            switch event {
            case .progress(let taskID, let transferID, let bytes, let total):
                let binding = try handle.assets.binding(transferID: transferID, taskID: taskID, sessionID: sessionDelegate.identifier)
                _ = try await verified(handle)
                let id = binding.lease.downloadID
                updateTransferRate(recordId: id, bytes: bytes)
                let now = Date()
                if let prior = lastProgressPublish[id], now.timeIntervalSince(prior) < Self.progressPublishInterval { return }
                try await command(.transferProgress(binding, bytes, total), owner: handle)
                lastProgressPublish[id] = now
            case .finished(let arrival):
                let binding = try handle.assets.binding(transferID: arrival.transferID, taskID: arrival.taskID, sessionID: arrival.sessionID)
                _ = try await verified(handle)
                guard binding.lease.authority == handle.authority else { throw DownloadOwnershipError.wrongAuthority }
                let ext = file.records[binding.lease.downloadID].map(mediaExtension) ?? "bin"
                let result = try await handle.store.completeLocalTask(source: arrival.payload, suffix: ext,
                    binding: binding, generation: handle.generation)
                try await publish(result, owner: handle)
                clearTransferRate(recordId: binding.lease.downloadID)
                #if os(iOS)
                if let completed = file.records[binding.lease.downloadID] { DownloadNotifier.downloadCompleted(completed) }
                #endif
                await flushStatus(id: binding.lease.downloadID, owner: handle)
                refreshStorageUsage()
                processQueue()
            case .failed(let taskID, let transferID, let status, let data, _):
                let binding = try handle.assets.binding(transferID: transferID, taskID: taskID, sessionID: sessionDelegate.identifier)
                if file.records[binding.lease.downloadID]?.localStatus == .paused { return }
                if status == 409 {
                    try await command(.status(binding.lease.downloadID, .revoked, nil), owner: handle,
                        recordOperation: (binding.lease.downloadID, binding.operationID))
                    processQueue()
                    return
                }
                if let data { try await attach(data, suffix: "resume", kind: .resume, lease: binding.lease, owner: handle, operationID: binding.operationID) }
                if file.records[binding.lease.downloadID]?.localStatus != .paused {
                    try await command(.status(binding.lease.downloadID, .failed, "Download interrupted. Try again."), owner: handle,
                        recordOperation: (binding.lease.downloadID, binding.operationID))
                    if status != 403 && status != 404 { scheduleRetry(recordId: binding.lease.downloadID, owner: handle) }
                    #if os(iOS)
                    if let record = file.records[binding.lease.downloadID],
                       status == 403 || status == 404 || record.retryCount >= Self.maxRetries {
                        DownloadNotifier.downloadFailed(record)
                    }
                    #endif
                    processQueue()
                }
            case .allEventsDelivered: break
            }
        } catch { report(error) } // Unknown arrivals stay parked; never remove them here.
    }

    func recoverTransfers() async {
        guard let handle = owner else { return }
        do {
            _ = try await verified(handle)
            let staging = (rootOverride ?? DownloadFilePaths.rootDirectory()).appendingPathComponent("staging")
            let directories = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
            for directory in directories {
                guard let arrival = try? DownloadArrivalParking.recover(directory: directory),
                      let binding = try? handle.assets.binding(transferID: arrival.transferID,
                        taskID: arrival.taskID, sessionID: arrival.sessionID), binding.lease.authority == handle.authority else { continue }
                let ext = file.records[binding.lease.downloadID].map(mediaExtension) ?? "bin"
                if let result = try? await handle.store.completeLocalTask(source: arrival.payload, suffix: ext,
                        binding: binding, generation: handle.generation) {
                    try await publish(result, owner: handle)
                }
            }
            let active = await sessionDelegate.activeTransfers()
            _ = try await verified(handle)
            let snapshot = try await handle.store.localSnapshot()
            for record in snapshot.downloads.records.values {
                guard (record.localStatus == .fetchingAssets || record.localStatus == .downloading),
                      pipelineTasks[record.id] == nil, !pendingPauseIDs.contains(record.id),
                      let operation = snapshot.recordOperations[record.id] else { continue }
                if let binding = snapshot.transfers.values.first(where: {
                    $0.lease.downloadID == record.id && $0.operationID == operation
                }), let task = active[binding.taskID], task.transferID == binding.transferID {
                    if task.state == .suspended {
                        let auth = try await verified(handle)
                        try await handle.store.resumeLocalTask(binding, generation: handle.generation,
                            tokenStore: transferTokenStore, auth: CapturedDurableAccountAuth(accountID: handle.authority.accountID,
                                accountEpoch: handle.authority.accountEpoch, request: auth)) {
                            if task.task.state == .suspended { task.task.resume() }
                        }
                    }
                    if task.state == .running || task.state == .suspended { continue }
                }
                try await command(.status(record.id, .queued, nil), owner: handle, recordOperation: (record.id, operation))
            }
        } catch { report(error) }
    }

    private func ensurePolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                guard let self, self.owner != nil else { return }
                await self.reconcileWithServer(triggerPipeline: true)
            }
        }
    }

    private func flushStatus(id: String, owner handle: OwnerHandle) async {
        do {
            _ = try await verified(handle)
            guard let event = try await handle.store.pendingLocalStatus(id: id, generation: handle.generation) else { return }
            let row: APIv2DownloadEntry = try await request("PATCH", DownloadRegistryV2.path(id: id),
                body: encode(event.body), owner: handle)
            let result = try await handle.store.acknowledgeLocalStatus(id: id, event: event, row: row,
                generation: handle.generation)
            try await publish(result, owner: handle)
        } catch { report(error) } // Keep the exact event after uncertainty or revision conflict.
    }

    func reconcileWithServer(triggerPipeline: Bool) async {
        do {
            let handle = try requireOwner()
            let observed = try await handle.store.localSnapshot().recordOperations
            let rows = try await DownloadRegistryV2.collect(deviceID: AppleDeviceIdentity.current.id) { cursor in
                var query = ["limit": "100"]
                if let cursor { query["cursor"] = cursor }
                return try await self.request("GET", "/api/v2/downloads", query: query, owner: handle)
            }
            try await command(.registered(rows, DownloadRegistrationDisplay()), owner: handle)
            try await command(.absentServerRows(observed: observed, present: Set(rows.map(\.id))), owner: handle)
            for id in rows.map(\.id) { await flushStatus(id: id, owner: handle) }
            if triggerPipeline { processQueue() }
            ensurePolling()
        } catch { report(error) }
    }
    func createSubscription(
        seriesId: String,
        seriesTitle: String?,
        mode: SubscriptionMode,
        seasonNumbers: [Int]?,
        deleteWatched: Bool,
        maxStorageBytes: Int64
    ) async throws {
        let request = CreateSubscriptionRequest(
            seriesId: seriesId,
            mode: mode.rawValue,
            seasonNumbers: mode == .specificSeasons ? seasonNumbers : nil,
            deleteWatched: deleteWatched,
            maxStorageBytes: maxStorageBytes
        )
        let handle = try requireOwner()
        let response: CreateSubscriptionResponse = try await self.request("POST", "/api/v1/downloads/subscriptions", body: encode(request), owner: handle)
        try await command(.subscription(response.subscription, seriesTitle), owner: handle)
        await reconcileWithServer(triggerPipeline: true)
    }

    func updateSubscription(
        id: String,
        mode: SubscriptionMode? = nil,
        seasonNumbers: [Int]? = nil,
        deleteWatched: Bool? = nil,
        maxStorageBytes: Int64? = nil,
        active: Bool? = nil
    ) async throws {
        let existingTitle = file.subscriptions.first(where: { $0.id == id })?.seriesTitle
        let request = UpdateSubscriptionRequest(
            mode: mode?.rawValue,
            seasonNumbers: seasonNumbers,
            deleteWatched: deleteWatched,
            maxStorageBytes: maxStorageBytes,
            active: active
        )
        let handle = try requireOwner()
        let response: CreateSubscriptionResponse = try await self.request("PATCH", "/api/v1/downloads/subscriptions/\(id)", body: encode(request), owner: handle)
        try await command(.subscription(response.subscription, existingTitle), owner: handle)
        await reconcileWithServer(triggerPipeline: true)
    }

    func deleteSubscription(id: String) async {
        do {
            let handle = try requireOwner()
            try await requestVoid("DELETE", "/api/v1/downloads/subscriptions/\(id)", owner: handle)
            try await command(.deleteSubscription(id), owner: handle)
        } catch { report(error) }
    }

    func runMonitoringAndProgressSync() async {
        do {
            let handle = try requireOwner()
            if !file.subscriptions.isEmpty {
                let _: SubscriptionSyncResponse = try await request("POST", "/api/v1/downloads/subscriptions/sync", owner: handle)
            }
            await reconcileWithServer(triggerPipeline: true)
        } catch { report(error) }
        // Uploads, bootstrap and progress-driven retention await their protocol checkpoint.
    }

    struct OfflineProgressAuthority: Sendable {
        fileprivate let ownerID: UUID
        fileprivate let authority: DownloadLocalAuthority
    }

    func captureOfflineProgressAuthority() -> OfflineProgressAuthority? {
        owner.map { OfflineProgressAuthority(ownerID: $0.id, authority: $0.authority) }
    }

    @discardableResult
    func recordOfflineProgress(mediaItemId: String, position: Double, duration: Double, completed: Bool,
                               authority: OfflineProgressAuthority?) -> Task<Void, Never>? {
        guard let authority, let handle = owner, authority.ownerID == handle.id,
              authority.authority == handle.authority, position.isFinite, position >= 0,
              duration.isFinite, duration >= 0 else { return nil }
        let event = QueuedProgress(id: UUID(), mediaItemId: mediaItemId, position: position,
            duration: duration, updatedAt: Date(), attempts: 0)
        unsavedProgress[event.id] = (event, completed, handle)
        return Task { await persistPendingProgress(event.id) }
    }

    private func persistPendingProgress(_ id: UUID) async {
        guard let (event, completed, handle) = unsavedProgress[id] else { return }
        do {
            try await command(.progress(event, completed), owner: handle)
            unsavedProgress.removeValue(forKey: id)
        } catch { report(error) } // Keep exact UUID/time/attempts for a later checked retry.
    }

    func flushProgressQueue() async { /* Explicitly queued-only until upload review. */ }
    func pullProgressDeltas() async { /* The legacy mixed-cache writer is retired. */ }

    private func refreshStorageUsage() {
        guard let handle = owner else { storageBytesUsed = 0; return }
        Task {
            let root = handle.assets.root
            let bytes = await Task.detached(priority: .utility) {
                let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
                var bytes: Int64 = 0
                while let url = enumerator?.nextObject() as? URL {
                    if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                        bytes += Int64(values.fileSize ?? 0)
                    }
                }
                return bytes
            }.value
            guard owner?.id == handle.id else { return }
            storageBytesUsed = bytes
        }
    }
    private func syncLiveActivity() {
        #if os(iOS)
        let completedIds = Set(
            file.records.values
                .filter { $0.localStatus == .completed }
                .map(\.id)
        )
        DownloadLiveActivityController.shared.sync(
            activeRecords: activeRecords,
            completedRecordIds: completedIds,
            totalBytesPerSecond: transferRates.values.reduce(0, +)
        )
        #endif
    }

    /// Notify only for transfer/pipeline failures the user would otherwise
    /// discover much later. Reconcile-driven failures (rows revoked or
    /// removed server-side) stay silent — they can arrive in bulk during a
    /// sync and the Downloads screen already surfaces them.
    private func mediaExtension(for record: DownloadRecord) -> String {
        switch (record.container ?? "").lowercased() {
        case "mkv", "matroska": return "mkv"
        case "mov": return "mov"
        case "m4v": return "m4v"
        case "webm": return "webm"
        case "avi": return "avi"
        case "ts": return "ts"
        case "m2ts": return "m2ts"
        default: return "mp4"
        }
    }

    /// Per-subscription `max_storage_bytes` soft gate: skip starting a
    /// download that would push its series over the cap. The server only
    /// soft-gates; the client is authoritative.
    private func exceedsStorageCap(for record: DownloadRecord) -> Bool {
        guard let seriesId = capSeriesId(for: record),
              let subscription = subscription(forSeriesId: seriesId),
              subscription.maxStorageBytes > 0 else {
            return false
        }
        // Count completed bytes plus the expected size of in-flight
        // transfers — `processQueue` can start several episodes in one
        // pass, and counting only `.completed` would let each of them see
        // the same free capacity and overshoot the cap together.
        let used = file.records.values
            .filter { other in
                guard other.id != record.id, capSeriesId(for: other) == seriesId else { return false }
                switch other.localStatus {
                case .completed, .downloading, .fetchingAssets, .paused: return true
                default: return false
                }
            }
            .reduce(Int64(0)) { $0 + max($1.fileSize, $1.bytesDownloaded) }
        return used + max(record.fileSize, 0) > subscription.maxStorageBytes
    }

    /// Series identity for cap accounting. Episode rows registered by
    /// subscription sync carry the series id in `contentId` until the
    /// manifest hydrates `seriesId` — without the fallback, freshly synced
    /// episodes would bypass the cap entirely.
    private func capSeriesId(for record: DownloadRecord) -> String? {
        record.seriesId ?? (record.episodeId != nil ? record.contentId : nil)
    }

    private func updateTransferRate(recordId: String, bytes: Int64) {
        let now = Date()
        guard let sample = rateSamples[recordId] else {
            rateSamples[recordId] = (bytes, now)
            return
        }
        let elapsed = now.timeIntervalSince(sample.at)
        guard elapsed >= Self.rateSampleInterval else { return }
        // Resume-data restarts can report fewer bytes than the last sample;
        // reset the window instead of publishing a negative rate.
        guard bytes >= sample.bytes else {
            rateSamples[recordId] = (bytes, now)
            transferRates.removeValue(forKey: recordId)
            return
        }
        let instant = Double(bytes - sample.bytes) / elapsed
        if let previous = transferRates[recordId] {
            transferRates[recordId] = previous + Self.rateSmoothing * (instant - previous)
        } else {
            transferRates[recordId] = instant
        }
        rateSamples[recordId] = (bytes, now)
    }

    private func clearTransferRate(recordId: String) {
        rateSamples.removeValue(forKey: recordId)
        transferRates.removeValue(forKey: recordId)
        lastProgressPublish.removeValue(forKey: recordId)
    }
}

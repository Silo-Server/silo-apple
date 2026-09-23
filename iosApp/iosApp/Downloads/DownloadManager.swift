import Foundation
import Observation
import OSLog

enum DownloadError: LocalizedError {
    case unavailable
    case fileURLUnavailable
    case emptyRegistrationResponse
    case registrationAlreadyInFlight
    case scopeChangedDuringRegistration
    case registryChanged
    case registrationUncertain
    case monitoringScopeChanged
    case monitorChanged
    case monitorRemoved
    case monitoringUncertain

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Downloads aren't available for this profile."
        case .fileURLUnavailable: return "Could not resolve the download URL."
        case .emptyRegistrationResponse: return "The server didn't create a download."
        case .registrationAlreadyInFlight: return "This download is already being prepared."
        case .scopeChangedDuringRegistration: return "The active profile changed before the download could start."
        case .registryChanged: return "This download changed on the server. Try again."
        case .registrationUncertain: return "Silo couldn't confirm the download started. It will appear in Downloads if the server created it."
        case .monitoringScopeChanged: return "The active profile changed before monitoring could be saved."
        case .monitorChanged: return "Monitoring for this series changed on the server. Try again."
        case .monitorRemoved: return "This series is no longer monitored."
        case .monitoringUncertain: return "Silo couldn't confirm the monitoring change. Check this series again once you're back online."
        }
    }
}

/// Coordinates the offline-downloads feature: capability gating, the local
/// registry, the background transfer pipeline, series-monitoring sync, and
/// offline progress reconciliation.
///
/// Concurrency model (the chosen hybrid): this is a single `@MainActor`
/// `@Observable` coordinator the UI reads directly, with all disk I/O
/// delegated to the `DownloadStore` actor and all media transfers to the
/// `DownloadSessionDelegate`'s background `URLSession`. The in-memory
/// `file` blob is the source of truth; every mutation persists through the
/// store actor.
@Observable
@MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Downloads"
    )

    private static let maxConcurrentTransfers = 3
    nonisolated private static let maxRetries = 4
    /// Bounds one flush at 10,000 queued items (100 per batch).
    private static let maxProgressBatchesPerFlush = 100

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
    /// The scope `file` was loaded for. While a scope switch waits on its
    /// load, `scopeServerId`/`scopeProfileId` already name the new scope but
    /// `file` still holds the old one, so saves and registry owners go by
    /// this instead.
    private var fileServerId = ""
    private var fileProfileId = ""

    /// Coalesces the several legitimate app-lifecycle callers that can all ask
    /// for the same scope at launch. Without this, a late disk read can replace
    /// a newly registered in-memory download with its older empty snapshot.
    private var scopeLoadTask: Task<DownloadStoreFile, Never>?
    private var scopeLoadToken: UUID?
    private var scopeLoadServerId = ""
    private var scopeLoadProfileId = ""

    private let sessionDelegate = DownloadSessionDelegate()
    private var intentionalCancels: Set<Int> = []
    private var pollTask: Task<Void, Never>?
    private var lastProgressPersist = Date.distantPast
    /// Session events that arrive before the first scope activation loads the
    /// persisted registry (a background relaunch replays buffered delegate
    /// events the moment the session is recreated). Handling them against an
    /// empty registry would discard finished media as unmatched, so they are
    /// held here and replayed by `releaseHeldSessionEvents()`.
    private var pendingSessionEvents: [DownloadSessionEvent] = []
    private var sessionEventsHeld = true
    /// In-flight back-off timers keyed by record id, tracked so a foreground
    /// reconcile doesn't re-queue a record that already has a scheduled
    /// restart (double-starting the transfer) and so pause/delete can abort
    /// the timer instead of leaving it to fire against a dead record.
    private var retryTasks: [String: Task<Void, Never>] = [:]
    /// Records whose pause is still waiting on the resume-data capture
    /// round-trip. A resume tapped inside that window is deferred to
    /// `finishPause` (via `pendingResumeIds`) so the captured data isn't
    /// dropped and the transfer restarted from byte zero.
    private var pendingPauseIds: Set<String> = []
    private var pendingResumeIds: Set<String> = []
    /// Serializes disk saves so a rapid burst of `persist()` calls can't land
    /// out of order and overwrite a newer snapshot with an older one.
    private var saveChain: Task<Void, Never>?
    /// Offline progress entries a running flush has sent and is still
    /// waiting on. Dispatched entries outside this set are held.
    private var progressUploadsInFlight: Set<UUID> = []
    /// Claimed offline progress whose batch provably never reached the
    /// server, keyed by the scope that claimed it, when the flush lost its
    /// scope before it could resolve them. The store file is updated too;
    /// this set covers a load of that scope already in flight, and is applied
    /// and cleared when the scope's store is next installed.
    private var releasedProgressClaims: [String: Set<UUID>] = [:]
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
    /// The one-shot removal of downloads saved by earlier versions. Every
    /// scope activation waits for it, so nothing reads or writes the store
    /// before it has run.
    private var legacyStorageTask: Task<Void, Never>?
    /// True until the user dismisses the notice that this version removed
    /// downloads saved by an earlier one.
    private(set) var legacyDownloadsNoticePending = false
    /// True when this launch's removal did not finish. The next launch runs
    /// it again; until then nothing tells the earlier version's server rows
    /// from new ones, so reconcile imports no unknown row.
    private var legacyRemovalIncomplete = false
    /// The running pass over `file.pendingServerDeletes`, if any.
    private var serverDeleteTask: Task<Void, Never>?
    /// Records whose pending status event is being sent.
    private var statusReportsInFlight: Set<String> = []
    /// The running pass over `file.pendingSubscriptionDeletes`, if any.
    private var subscriptionDeleteTask: Task<Void, Never>?
    /// Monitor DELETEs and creates that landed while other monitor requests
    /// were in flight.
    private var subscriptionWrites = SubscriptionWriteLedger()

    private init() {
        // Drain background-session events for the lifetime of the app.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in self.sessionDelegate.events {
                self.handleSessionEvent(event)
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

    /// Delete several downloads in one pass: one store write, one storage
    /// recompute, and the server DELETEs fanned out in a single task.
    func deleteDownloads(ids: [String]) {
        var removedIds: [String] = []
        for id in ids {
            guard let record = file.records[id] else { continue }
            if let taskId = record.taskIdentifier {
                intentionalCancels.insert(taskId)
                sessionDelegate.cancel(taskId: taskId)
            }
            retryTasks[id]?.cancel()
            retryTasks[id] = nil
            file.records.removeValue(forKey: id)
            clearTransferRate(recordId: id)
            removedIds.append(id)
        }
        guard !removedIds.isEmpty else { return }
        // Enqueue the updated snapshot before removing assets, as for single
        // deletion. Persistence remains asynchronous through the save chain.
        persist()
        if !scopeServerId.isEmpty {
            for id in removedIds {
                DownloadFilePaths.removeDownloadDirectory(
                    serverId: scopeServerId,
                    profileId: scopeProfileId,
                    downloadId: id
                )
            }
        }
        queueServerDeletes(removedIds)
        processQueue()
        refreshStorageUsage()
    }

    /// One-time hydration of `seasonNumber`/`episodeNumber`/`seriesTitle` for
    /// episode downloads created before those fields existed. A cheap no-op
    /// once every record carries them.
    private func backfillEpisodeMetadataIfNeeded() async {
        let needing = file.records.values.filter {
            $0.seriesId != nil
                && $0.manifestFilename != nil
                && ($0.seasonNumber == nil || $0.seriesTitle == nil)
        }
        guard !needing.isEmpty else { return }
        var changed = false
        for record in needing {
            guard let manifest = await loadManifest(for: record),
                  var current = file.records[record.id] else { continue }
            if current.seasonNumber == nil { current.seasonNumber = manifest.seasonNumber }
            if current.episodeNumber == nil { current.episodeNumber = manifest.episodeNumber }
            if current.seriesTitle == nil { current.seriesTitle = manifest.seriesTitle }
            file.records[record.id] = current
            changed = true
        }
        if changed { persist() }
    }

    // MARK: - Lifecycle

    /// Re-point the manager at the active `(server, profile)` scope,
    /// loading that scope's persisted blob. Returns false when there is no
    /// signed-in scope.
    @discardableResult
    func activateScopeIfNeeded() async -> Bool {
        await removeLegacyDownloadsIfNeeded()
        let serverId = ServerRegistry.shared.activeServerId ?? ""
        let profileId = await TokenStore.shared.getProfileId() ?? ""
        guard !serverId.isEmpty, !profileId.isEmpty else {
            deactivate()
            releaseHeldSessionEvents()
            return false
        }
        if serverId == scopeServerId, profileId == scopeProfileId,
           fileServerId == serverId, fileProfileId == profileId,
           !file.records.isEmpty || file.capability != nil {
            releaseHeldSessionEvents()
            return true
        }
        if serverId != scopeServerId || profileId != scopeProfileId {
            invalidatePendingRegistrations()
            scopeServerId = serverId
            scopeProfileId = profileId
        }

        let loadTask: Task<DownloadStoreFile, Never>
        let loadToken: UUID
        if let existing = scopeLoadTask,
           scopeLoadServerId == serverId,
           scopeLoadProfileId == profileId,
           let existingToken = scopeLoadToken {
            loadTask = existing
            loadToken = existingToken
        } else {
            scopeLoadTask?.cancel()
            let token = UUID()
            let task = Task {
                await DownloadStore.shared.load(serverId: serverId, profileId: profileId)
            }
            scopeLoadTask = task
            scopeLoadToken = token
            scopeLoadServerId = serverId
            scopeLoadProfileId = profileId
            loadTask = task
            loadToken = token
        }

        let loadedFile = await loadTask.value
        guard scopeServerId == serverId, scopeProfileId == profileId else { return false }
        if scopeLoadToken == loadToken {
            // Exactly one waiter installs this snapshot. Later waiters observe
            // the already-hydrated `file` instead of assigning it a second time.
            file = loadedFile
            fileServerId = serverId
            fileProfileId = profileId
            if let released = releasedProgressClaims.removeValue(forKey: Self.progressClaimKey(serverId, profileId)),
               OfflineProgressQueue.releaseClaims(&file.progressQueue, ids: released) {
                persist()
            }
            scopeLoadTask = nil
            scopeLoadToken = nil
            scopeLoadServerId = ""
            scopeLoadProfileId = ""
        }
        releaseHeldSessionEvents()
        refreshStorageUsage()
        await backfillEpisodeMetadataIfNeeded()
        return true
    }

    private func removeLegacyDownloadsIfNeeded() async {
        let task = legacyStorageTask ?? Task { await self.runLegacyStorageRemoval() }
        legacyStorageTask = task
        await task.value
    }

    private func runLegacyStorageRemoval() async {
        let store = DownloadStore.shared
        switch await store.legacyStorageState() {
        case let .removed(noticePending):
            legacyDownloadsNoticePending = noticePending
        case .removalNeeded:
            // Transfers an earlier version started would land their media in
            // the storage removed below; stop them first.
            await sessionDelegate.cancelAllTasks()
            let removal = await store.removeLegacyStorage()
            legacyDownloadsNoticePending = removal.hadDownloads
            legacyRemovalIncomplete = !removal.completed
        }
    }

    func acknowledgeLegacyDownloadsNotice() {
        guard legacyDownloadsNoticePending else { return }
        legacyDownloadsNoticePending = false
        Task { await DownloadStore.shared.acknowledgeLegacyRemovalNotice() }
    }

    /// Called on app launch / foreground and on the first authenticated
    /// transition. Refreshes capability, reconciles with the server, and
    /// runs subscription + progress sync.
    ///
    /// `onCapabilityRefreshed` fires as soon as `downloadsEnabled` is
    /// authoritative for the active scope, before the (potentially slow)
    /// server reconciliation and sync work. Callers that only need to know
    /// whether the Downloads tab exists should not wait for the rest.
    func onAppActive(onCapabilityRefreshed: (() -> Void)? = nil) async {
        guard await activateScopeIfNeeded() else { return }
        await refreshCapability()
        onCapabilityRefreshed?()
        guard downloadsEnabled else { return }
        await reconcileWithServer(triggerPipeline: true)
        await runMonitoringAndProgressSync()
    }

    /// Sign-out: stop active transfers and drop in-memory state. On-disk
    /// files are intentionally preserved (the user may sign back in).
    func clearForSignOut() {
        cancelActiveTasks()
        deactivate()
    }

    private func deactivate() {
        pollTask?.cancel()
        pollTask = nil
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        pendingPauseIds.removeAll()
        pendingResumeIds.removeAll()
        invalidatePendingRegistrations()
        scopeLoadTask?.cancel()
        scopeLoadTask = nil
        scopeLoadToken = nil
        scopeLoadServerId = ""
        scopeLoadProfileId = ""
        scopeServerId = ""
        scopeProfileId = ""
        file = .empty
        fileServerId = ""
        fileProfileId = ""
        rateSamples.removeAll()
        transferRates.removeAll()
    }

    private func cancelActiveTasks() {
        for record in file.records.values where record.localStatus == .downloading {
            if let taskId = record.taskIdentifier {
                intentionalCancels.insert(taskId)
                sessionDelegate.cancel(taskId: taskId)
            }
        }
    }

    // MARK: - Background relaunch

    /// Store the system completion handler delivered when iOS relaunches
    /// the app to finish background events.
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        sessionDelegate.backgroundCompletionHandler = handler
    }

    // MARK: - Capability

    /// On failure the cached capability stays, so an unreachable or
    /// update-required server keeps completed downloads visible and playable.
    func refreshCapability() async {
        guard let owner = await captureScopeOwner() else { return }
        do {
            let capability = try await SiloAPI.shared.apiV2Client.downloadCapability(auth: owner.auth)
            guard isCurrent(owner) else { return }
            file.capability = capability
            file.capabilityFetchedAt = Date()
            persist()
        } catch {
            Self.logger.warning("capability refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Public download actions

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
        pendingRegistrationTokens[registrationContentId] = registrationToken
        pendingRegistrationContentIds.insert(registrationContentId)
        defer {
            finishPendingRegistration(
                contentId: registrationContentId,
                token: registrationToken
            )
        }

        guard let owner = await captureScopeOwner(), owner.generation == capturedScopeGeneration else {
            throw DownloadError.scopeChangedDuringRegistration
        }
        let isBatch = series || seasonNumber != nil
        do {
            if isBatch {
                // Series/season batches are original-quality only per the
                // server contract.
                try await createSeriesPages(seriesId: contentId, seasonNumber: seasonNumber, owner: owner)
            } else {
                let request = APIv2DownloadCreateRequest.single(
                    contentId: contentId,
                    episodeId: episodeId,
                    mediaFileId: fileId.map(String.init),
                    quality: resolvedDownloadQuality(requestedQuality),
                    caps: DownloadCaps.current(),
                    expected: createGuard(forLeafId: registrationContentId)
                )
                let created = try await SiloAPI.shared.apiV2Client.createDownloads(request, auth: owner.auth)
                guard isCurrent(owner) else { throw DownloadError.scopeChangedDuringRegistration }
                applyCreatedEntries(
                    created.items,
                    displayTitle: displayTitle,
                    displaySubtitle: displaySubtitle,
                    type: type,
                    seriesId: seriesId,
                    posterThumbhash: posterThumbhash
                )
            }
        } catch let error as DownloadError {
            // A scope change or an all-skipped batch: nothing to reconcile.
            throw error
        } catch {
            try await settleFailedCreate(error, leafId: isBatch ? nil : registrationContentId, owner: owner)
        }
    }

    /// Registers a series or season one server page at a time. Every page
    /// repeats the same client-chosen batch id, and each page's entries are
    /// stored as soon as it arrives.
    private func createSeriesPages(seriesId: String, seasonNumber: Int?, owner: ScopeOwner) async throws {
        let request = APIv2DownloadCreateRequest.seriesPage(
            seriesId: seriesId,
            seasonNumber: seasonNumber,
            batchId: UUID().uuidString.lowercased(),
            caps: DownloadCaps.current()
        )
        var cursor: String?
        var cursors: Set<String> = []
        var registered = 0
        for _ in 0..<APIv2Client.downloadRegistryMaxPages {
            let page = try await SiloAPI.shared.apiV2Client.createDownloads(request, cursor: cursor, auth: owner.auth)
            guard isCurrent(owner) else { throw DownloadError.scopeChangedDuringRegistration }
            applyCreatedEntries(page.items, displayTitle: nil, displaySubtitle: nil, type: nil,
                seriesId: seriesId, posterThumbhash: nil)
            registered += page.items.count
            guard page.page.hasMore else {
                if registered == 0 { throw DownloadError.emptyRegistrationResponse }
                return
            }
            guard let next = page.page.nextCursor, cursors.insert(next).inserted else {
                throw DownloadRegistryError.unexpectedReceipt
            }
            cursor = next
        }
        throw DownloadRegistryError.unexpectedReceipt
    }

    /// What the registry should hold for an item, according to the local
    /// record. A stale guard gets a 409, which reads the registry again.
    private func createGuard(forLeafId leafId: String) -> APIv2DownloadCreateRequest.Guard {
        guard let record = record(forContentId: leafId),
              let revision = record.revision, revision >= 1 else { return .absent }
        return .entry(id: record.id, revision: revision)
    }

    private func applyCreatedEntries(
        _ entries: [APIv2DownloadEntry],
        displayTitle: String?,
        displaySubtitle: String?,
        type: String?,
        seriesId: String?,
        posterThumbhash: String?
    ) {
        // An entry the create reused is wanted again, so an earlier local
        // delete of it no longer applies.
        if var pending = file.pendingServerDeletes, !pending.isDisjoint(with: entries.map(\.id)) {
            pending.subtract(entries.map(\.id))
            file.pendingServerDeletes = pending.isEmpty ? nil : pending
        }
        for entry in entries {
            upsertRow(
                entry,
                displayTitle: entries.count == 1 ? displayTitle : nil,
                displaySubtitle: entries.count == 1 ? displaySubtitle : nil,
                type: type,
                seriesId: seriesId,
                posterThumbhash: entries.count == 1 ? posterThumbhash : nil
            )
        }
        persist()
        processQueue()
        ensurePolling()
    }

    /// Decides what a failed create means for the user. `createDownloads` is
    /// never sent again on its own: a conflict or an uncertain outcome reads
    /// the registry instead, and when that read shows a live entry for the
    /// item, the download goes ahead from it.
    private func settleFailedCreate(_ error: Error, leafId: String?, owner: ScopeOwner) async throws {
        let failure = APIv2Client.downloadRegistryFailure(error)
        Self.logger.warning("download create failed (\(String(describing: failure), privacy: .public)): \(String(describing: error), privacy: .public)")
        guard isCurrent(owner) else { throw DownloadError.scopeChangedDuringRegistration }
        switch failure {
        case .rejected, .notApplied:
            throw error
        case .conflict, .uncertain:
            await reconcileWithServer(triggerPipeline: true)
            // A pending DELETE of this item's entry, or of one left by an
            // earlier version, makes the create conflict. Send it, even when
            // the read failed, and wait for it so a retry does not meet the
            // same entry again.
            sendPendingServerDeletes()
            await serverDeleteTask?.value
            guard isCurrent(owner) else { throw DownloadError.scopeChangedDuringRegistration }
            if let leafId, let record = record(forContentId: leafId),
               record.localStatus != .failed, record.localStatus != .revoked {
                return
            }
            throw failure == .conflict ? DownloadError.registryChanged : DownloadError.registrationUncertain
        }
    }

    private func invalidatePendingRegistrations() {
        registrationScopeGeneration &+= 1
        pendingRegistrationTokens.removeAll()
        pendingRegistrationContentIds.removeAll()
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

    func deleteDownload(id: String) {
        deleteDownloads(ids: [id])
    }

    func deleteDownload(forContentId contentId: String) {
        if let record = record(forContentId: contentId) {
            deleteDownload(id: record.id)
        }
    }

    /// Suspend an in-flight media transfer. The status flips to `.paused`
    /// synchronously (so the UI responds on the tap) and the resume data is
    /// captured asynchronously — the task identifier stays on the record
    /// until then so a transfer that finishes during the race still
    /// completes normally instead of being discarded.
    func pauseDownload(id: String) {
        guard var record = file.records[id], record.localStatus == .downloading else { return }
        guard let taskId = record.taskIdentifier else {
            // No live task: the record is waiting out a retry back-off.
            // Abort the timer and park the record so the pause control isn't
            // dead during the window; resume re-queues from scratch.
            retryTasks[id]?.cancel()
            retryTasks[id] = nil
            record.localStatus = .paused
            file.records[id] = record
            clearTransferRate(recordId: id)
            persist()
            processQueue()
            return
        }
        intentionalCancels.insert(taskId)
        pendingPauseIds.insert(id)
        record.localStatus = .paused
        file.records[id] = record
        clearTransferRate(recordId: id)
        persist()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let data = await self.sessionDelegate.pause(taskId: taskId)
            self.finishPause(recordId: id, resumeData: data)
        }
        processQueue()
    }

    /// Continue a paused transfer. Routed through the queue so resumes honor
    /// the concurrency cap — `processQueue` starts the record from its
    /// captured resume data when present, falling back to a full restart
    /// (same server registration, byte zero) when the data is missing,
    /// unreadable, or was never produced.
    func resumeDownload(id: String) {
        guard var record = file.records[id], record.localStatus == .paused else { return }
        // The pause's resume-data capture is still in flight — flag the
        // intent and let `finishPause` re-queue with the data instead of
        // discarding the partial transfer.
        if pendingPauseIds.contains(id) {
            pendingResumeIds.insert(id)
            return
        }
        record.localStatus = .queued
        file.records[id] = record
        persist()
        processQueue()
    }

    /// Lands after `pause(taskId:)` resolves. Guarded on `.paused` because
    /// the transfer may have finished (or the record been deleted) during
    /// the cancel round-trip — clobbering the newer state would orphan it.
    /// A resume requested mid-round-trip re-queues here, once the captured
    /// data is on disk, rather than restarting from byte zero.
    private func finishPause(recordId: String, resumeData: Data?) {
        pendingPauseIds.remove(recordId)
        let resumeRequested = pendingResumeIds.remove(recordId) != nil
        guard var record = file.records[recordId], record.localStatus == .paused else { return }
        record.taskIdentifier = nil
        if let resumeData,
           let url = absoluteFileURLForNewAsset(recordId: recordId, filename: "resume.bin") {
            try? resumeData.write(to: url, options: .atomic)
            record.resumeDataFilename = "resume.bin"
        }
        if resumeRequested {
            record.localStatus = .queued
        }
        file.records[recordId] = record
        persist()
        if resumeRequested { processQueue() }
    }

    func retryDownload(id: String) {
        guard var record = file.records[id], record.localStatus == .failed else { return }
        record.localStatus = .queued
        record.retryCount = 0
        record.lastError = nil
        file.records[id] = record
        persist()
        processQueue()
    }

    // MARK: - Pipeline

    private func processQueue() {
        let activeCount = file.records.values.filter {
            $0.localStatus == .downloading || $0.localStatus == .fetchingAssets
        }.count
        var slots = max(0, Self.maxConcurrentTransfers - activeCount)
        guard slots > 0 else { return }

        let queued = file.records.values
            .filter { $0.localStatus == .queued }
            .sorted { $0.registeredAt < $1.registeredAt }

        for record in queued where slots > 0 {
            // Reserve the slot synchronously so a second pass doesn't pick
            // the same record before its async pipeline flips the status.
            guard !exceedsStorageCap(for: record) else { continue }
            slots -= 1
            startQueuedRecord(record)
        }
    }

    /// Start one queued record, preferring its captured resume data (a
    /// paused transfer) so completed byte ranges aren't refetched; missing
    /// or unreadable data, or data for a retired file URL, falls back to the
    /// full pipeline restart.
    private func startQueuedRecord(_ record: DownloadRecord) {
        var record = record
        if let filename = record.resumeDataFilename,
           let url = absoluteFileURL(for: record, filename: filename) {
            let resumeData = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            record.resumeDataFilename = nil
            if let resumeData, let taskId = sessionDelegate.resume(data: resumeData) {
                record.taskIdentifier = taskId
                record.localStatus = .downloading
                file.records[record.id] = record
                persist()
                return
            }
            record.bytesDownloaded = 0
            file.records[record.id] = record
        }
        setLocalStatus(.fetchingAssets, id: record.id)
        Task { await self.startMediaPipeline(recordId: record.id) }
    }

    /// Fetches the manifest and its assets, then starts the file transfer,
    /// all under the scope owner captured here. Once that scope is gone,
    /// nothing a request returns is applied: the record belongs to a store
    /// that is no longer loaded.
    private func startMediaPipeline(recordId: String) async {
        guard file.records[recordId] != nil else { return }
        guard let owner = await captureScopeOwner() else {
            // No usable session for this scope right now. Park the record;
            // the next queue pass or reconcile starts it again.
            if file.records[recordId]?.localStatus == .fetchingAssets { setLocalStatus(.queued, id: recordId) }
            return
        }
        do {
            let manifest = try await SiloAPI.shared.apiV2Client.downloadManifest(id: recordId, auth: owner.auth)
            guard isCurrent(owner) else { return }
            await persistManifest(manifest, recordId: recordId)
            guard isCurrent(owner) else { return }
            applyManifestDisplay(manifest, recordId: recordId)
            await fetchArtwork(manifest, recordId: recordId, owner: owner)
            await fetchSubtitles(manifest, recordId: recordId, owner: owner)
            guard isCurrent(owner) else { return }
            await startMediaTransfer(recordId: recordId, owner: owner)
        } catch {
            guard isCurrent(owner) else { return }
            handlePipelineError(error, recordId: recordId)
        }
    }

    private func startMediaTransfer(recordId: String, owner: ScopeOwner) async {
        // The owner's current credentials: a token rotated since the capture
        // is used, a different owner is not.
        let auth = await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: owner.auth)
        guard isCurrent(owner), var record = file.records[recordId] else { return }
        guard let auth else {
            handlePipelineError(HTTPError.requestIdentityChanged, recordId: recordId)
            return
        }
        guard let fileURL = APIv2Client.downloadFileURL(id: recordId, serverURL: auth.account.serverURL) else {
            handlePipelineError(DownloadError.fileURLUnavailable, recordId: recordId)
            return
        }
        let request = DownloadAuthHeaders.authorizedRequest(
            url: fileURL,
            auth: auth,
            allowsCellular: !DownloadSettings.shared.wifiOnly
        )
        let taskId = sessionDelegate.start(request: request)
        record.taskIdentifier = taskId
        record.localStatus = .downloading
        record.pendingStatusEvent = Self.statusEvent(.downloading, for: record)
        file.records[recordId] = record
        persist()
        reportPendingStatusEvents()
    }

    private func persistManifest(_ manifest: OfflineManifest, recordId: String) async {
        guard let url = absoluteFileURLForNewAsset(recordId: recordId, filename: "manifest.json") else { return }
        await DownloadStore.shared.saveManifest(manifest, to: url)
        if var record = file.records[recordId] {
            record.manifestFilename = "manifest.json"
            file.records[recordId] = record
        }
    }

    private func applyManifestDisplay(_ manifest: OfflineManifest, recordId: String) {
        guard var record = file.records[recordId] else { return }
        record.title = record.title ?? manifest.title
        record.type = manifest.type
        record.format = manifest.quality
        record.effectiveQuality = manifest.effectiveQuality
        record.deliveryFormat = manifest.deliveryFormat
        record.targetBitrateKbps = manifest.targetBitrateKbps
        record.revision = manifest.revision ?? record.revision
        record.container = manifest.container
        record.posterThumbhash = record.posterThumbhash ?? manifest.posterThumbhash
        record.stableIdentity = manifest.stableIdentity
        if let seriesId = manifest.seriesId { record.seriesId = seriesId }
        record.seriesTitle = record.seriesTitle ?? manifest.seriesTitle
        record.seasonNumber = record.seasonNumber ?? manifest.seasonNumber
        record.episodeNumber = record.episodeNumber ?? manifest.episodeNumber
        if record.subtitle == nil {
            if manifest.type == "episode" {
                let season = manifest.seasonNumber.map { "S\($0)" }
                let episode = manifest.episodeNumber.map { "E\($0)" }
                record.subtitle = [season, episode].compactMap { $0 }.joined(separator: " · ")
            } else if let year = manifest.year {
                record.subtitle = String(year)
            }
        }
        if record.fileSize <= 0, let size = manifest.fileSize { record.fileSize = size }
        file.records[recordId] = record
        persist()
    }

    private func fetchArtwork(_ manifest: OfflineManifest, recordId: String, owner: ScopeOwner) async {
        let kinds: [(kind: String, path: String?, filename: String)] = [
            ("poster", manifest.artworkUrls?.poster, "poster.jpg"),
            ("backdrop", manifest.artworkUrls?.backdrop, "backdrop.jpg"),
            ("logo", manifest.artworkUrls?.logo, "logo.png"),
        ]
        for entry in kinds {
            // Only fetch artwork the manifest actually advertises. The server
            // omits artwork_urls.* (omitempty) when a title has no poster/
            // backdrop/logo, so synthesizing a path here would guarantee a 404.
            guard let path = entry.path else { continue }
            let data: Data
            do {
                data = try await SiloAPI.shared.apiV2Client.downloadAsset(path: path, downloadId: recordId,
                    auth: owner.auth)
            } catch {
                Self.logger.warning("download artwork fetch failed: \(String(describing: error), privacy: .public)")
                continue
            }
            guard isCurrent(owner) else { return }
            guard !data.isEmpty,
                  let url = absoluteFileURLForNewAsset(recordId: recordId, filename: entry.filename) else {
                continue
            }
            try? data.write(to: url, options: .atomic)
            guard var record = file.records[recordId] else { continue }
            switch entry.kind {
            case "poster": record.posterFilename = entry.filename
            case "backdrop": record.backdropFilename = entry.filename
            case "logo": record.logoFilename = entry.filename
            default: break
            }
            file.records[recordId] = record
        }
        persist()
    }

    private func fetchSubtitles(_ manifest: OfflineManifest, recordId: String, owner: ScopeOwner) async {
        guard let subtitles = manifest.subtitles, !subtitles.isEmpty else { return }
        for (index, subtitle) in subtitles.enumerated() {
            let ext = (subtitle.format ?? "srt").lowercased()
            let filename = "sub_\(index).\(ext)"
            let data: Data
            do {
                data = try await SiloAPI.shared.apiV2Client.downloadAsset(path: subtitle.fetchUrl, downloadId: recordId,
                    auth: owner.auth)
            } catch {
                Self.logger.warning("download subtitle fetch failed: \(String(describing: error), privacy: .public)")
                continue
            }
            guard isCurrent(owner) else { return }
            guard !data.isEmpty,
                  let url = absoluteFileURLForNewAsset(recordId: recordId, filename: filename) else {
                continue
            }
            try? data.write(to: url, options: .atomic)
            guard var record = file.records[recordId] else { continue }
            record.subtitleFilenames[subtitle.fetchUrl] = filename
            file.records[recordId] = record
        }
        persist()
    }

    private func handlePipelineError(_ error: Error, recordId: String) {
        guard var record = file.records[recordId] else { return }
        record.taskIdentifier = nil
        if case HTTPError.requestIdentityChanged = error {
            // The session changed under the request; nothing was applied.
            // Park the record for the next queue pass.
            record.localStatus = .queued
            file.records[recordId] = record
            persist()
            return
        }
        if let statusCode = Self.pipelineStatus(error) {
            switch statusCode {
            case 409:
                record.localStatus = .revoked
                record.serverStatus = "revoked"
            case 404:
                record.localStatus = .failed
                record.lastError = "not_found"
            case 403:
                record.localStatus = .failed
                record.lastError = "forbidden"
            case 429, 500...599:
                // Cap and back off pipeline retries (manifest/asset fetch),
                // mirroring the media-transfer retry path; otherwise a
                // persistent 429 would retry every 5s forever.
                if record.retryCount < Self.maxRetries {
                    record.retryCount += 1
                    file.records[recordId] = record
                    scheduleRetry(recordId: recordId, resumeData: nil, refreshToken: false)
                } else {
                    record.localStatus = .failed
                    record.lastError = "http_\(statusCode)"
                    file.records[recordId] = record
                    persist()
                    processQueue()
                }
                return
            default:
                record.localStatus = .failed
                record.lastError = "http_\(statusCode)"
            }
        } else {
            record.localStatus = .failed
            record.lastError = error.localizedDescription
        }
        file.records[recordId] = record
        persist()
        if record.localStatus == .failed {
            notifyTerminalFailure(record)
        }
        processQueue()
    }

    /// The HTTP status of a failed manifest request, or nil when it never got
    /// an answer. A 410 from this v2 route is the server asking for a newer
    /// app, which a retry cannot fix, so it fails the record.
    nonisolated private static func pipelineStatus(_ error: Error) -> Int? {
        switch error {
        case APIv2Error.problem(let problem): return problem.status
        case APIv2Error.httpStatus(let status): return status
        default: return nil
        }
    }

    /// Mirror the active queue into the lock-screen Live Activity. Hooked
    /// into `file`'s `didSet` so every mutation flows through — including
    /// scope deactivation (empty blob ends the activity). The controller
    /// dedupes identical content states, so burst mutations (reconcile
    /// loops, pipeline steps) cost a snapshot build and nothing more.
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
    private func notifyTerminalFailure(_ record: DownloadRecord) {
        #if os(iOS)
        DownloadNotifier.downloadFailed(record)
        #endif
    }

    // MARK: - Background session events

    private func handleSessionEvent(_ event: DownloadSessionEvent) {
        // Hold events until the first scope activation has loaded the
        // persisted registry — on a cold (background) relaunch the recreated
        // session replays its buffered events immediately, and matching them
        // against a not-yet-loaded registry would delete finished media as
        // orphaned and re-download it from scratch.
        guard !sessionEventsHeld else {
            pendingSessionEvents.append(event)
            return
        }
        switch event {
        case let .progress(taskId, written, total):
            guard var record = recordByTask(taskId) else { return }
            updateTransferRate(recordId: record.id, bytes: written)
            // Publish to the observable blob at a readable cadence — the raw
            // callbacks fire many times per second and each reassignment
            // redraws every byte counter "live". Skipped ticks lose nothing:
            // `written` is cumulative, so the next publish catches up.
            let now = Date()
            guard now.timeIntervalSince(lastProgressPublish[record.id] ?? .distantPast)
                >= Self.progressPublishInterval else { return }
            lastProgressPublish[record.id] = now
            record.bytesDownloaded = written
            if total > 0 { record.fileSize = total }
            file.records[record.id] = record
            persistProgressThrottled()

        case let .finished(taskId, stagedURL, _):
            handleMediaFinished(taskId: taskId, stagedURL: stagedURL)

        case let .failed(taskId, statusCode, resumeData, message):
            handleMediaFailure(taskId: taskId, statusCode: statusCode, resumeData: resumeData, message: message)

        case .allEventsDelivered:
            // Flush queued store writes before handing control back — iOS
            // can suspend the process as soon as the completion handler
            // runs, and the `.finished`/`.failed` records handled above are
            // still on the async save chain.
            guard let handler = sessionDelegate.backgroundCompletionHandler else { return }
            sessionDelegate.backgroundCompletionHandler = nil
            let pendingSave = saveChain
            Task { @MainActor in
                await pendingSave?.value
                handler()
            }
        }
    }

    /// Replay events held during launch, in arrival order, now that the
    /// registry reflects the active scope (or the lack of one — orphan
    /// cleanup is then correct rather than premature).
    private func releaseHeldSessionEvents() {
        guard sessionEventsHeld else { return }
        sessionEventsHeld = false
        while !pendingSessionEvents.isEmpty {
            handleSessionEvent(pendingSessionEvents.removeFirst())
        }
    }

    private func handleMediaFinished(taskId: Int, stagedURL: URL) {
        intentionalCancels.remove(taskId)
        guard var record = recordByTask(taskId) else {
            try? FileManager.default.removeItem(at: stagedURL)
            return
        }
        clearTransferRate(recordId: record.id)
        let ext = mediaExtension(for: record)
        let filename = "media.\(ext)"
        guard let destination = absoluteFileURLForNewAsset(recordId: record.id, filename: filename) else {
            try? FileManager.default.removeItem(at: stagedURL)
            return
        }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: stagedURL, to: destination)
        } catch {
            Self.logger.error("Failed to move finished media: \(String(describing: error), privacy: .private)")
            record.localStatus = .failed
            record.lastError = "move_failed"
            record.taskIdentifier = nil
            file.records[record.id] = record
            persist()
            processQueue()
            return
        }
        record.mediaFilename = filename
        record.localStatus = .completed
        record.downloadedAt = Date()
        record.taskIdentifier = nil
        record.lastError = nil
        if record.fileSize <= 0 {
            record.fileSize = fileSizeOnDisk(destination)
        }
        record.bytesDownloaded = record.fileSize
        record.pendingStatusEvent = Self.statusEvent(.completed, for: record)
        file.records[record.id] = record
        persist()
        #if os(iOS)
        DownloadNotifier.downloadCompleted(record)
        #endif
        reportPendingStatusEvents()
        processQueue()
        refreshStorageUsage()
        Task { await self.enforceRetention() }
    }

    private func handleMediaFailure(taskId: Int, statusCode: Int?, resumeData: Data?, message: String) {
        if intentionalCancels.remove(taskId) != nil { return }
        guard var record = recordByTask(taskId) else { return }
        record.taskIdentifier = nil
        clearTransferRate(recordId: record.id)

        switch Self.mediaFailureAction(statusCode: statusCode, retryCount: record.retryCount, message: message) {
        case .revoke:
            record.localStatus = .revoked
            record.serverStatus = "revoked"
            file.records[record.id] = record
            persist()
            processQueue()
        case let .fail(reason):
            record.localStatus = .failed
            record.lastError = reason
            file.records[record.id] = record
            persist()
            notifyTerminalFailure(record)
            processQueue()
        case let .retry(keepResumeData, refreshToken):
            record.retryCount += 1
            if !keepResumeData { record.bytesDownloaded = 0 }
            file.records[record.id] = record
            scheduleRetry(recordId: record.id, resumeData: keepResumeData ? resumeData : nil,
                refreshToken: refreshToken)
        }
    }

    /// What a failed file transfer does next.
    enum MediaFailureAction: Equatable {
        case revoke
        case fail(String)
        /// Send the transfer again after a back-off. Without resume data the
        /// download restarts from its manifest and a fresh file URL.
        case retry(keepResumeData: Bool, refreshToken: Bool)
    }

    /// Every retry is bounded by `maxRetries`, after which the record fails.
    nonisolated static func mediaFailureAction(statusCode: Int?, retryCount: Int, message: String) -> MediaFailureAction {
        let canRetry = retryCount < maxRetries
        switch statusCode {
        case 409:
            return .revoke
        case 404:
            return .fail("not_found")
        case 403:
            return .fail("forbidden")
        case 401:
            // Refresh the token first; a persistently expired credential
            // would otherwise retry forever with the record stuck downloading.
            return canRetry ? .retry(keepResumeData: false, refreshToken: true) : .fail("unauthorized")
        case 410, 412, 416:
            // The URL is gone (a retired route, or resume data that outlived
            // it) or the resume point no longer matches the file. Restart the
            // download instead of resuming the same request.
            return canRetry ? .retry(keepResumeData: false, refreshToken: false) : .fail("http_\(statusCode ?? 0)")
        default:
            return canRetry ? .retry(keepResumeData: true, refreshToken: false) : .fail(message)
        }
    }

    private func scheduleRetry(recordId: String, resumeData: Data?, refreshToken: Bool) {
        let attempt = file.records[recordId]?.retryCount ?? 1
        let delaySeconds = min(120, Int(pow(2.0, Double(attempt))) * 5)
        retryTasks[recordId]?.cancel()
        retryTasks[recordId] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.scopeServerId.isEmpty else { return }
            self.retryTasks[recordId] = nil
            // Fire only while the record still looks like the failure this
            // retry was scheduled for — a pause, delete, revoke, or re-queue
            // that landed during the back-off owns the record now, and
            // restarting on top of it would run two transfers of one file.
            guard let record = self.file.records[recordId],
                  record.taskIdentifier == nil,
                  record.localStatus == .downloading || record.localStatus == .fetchingAssets else { return }
            if refreshToken {
                // Any authenticated v2 read runs HTTPClient's single-flight
                // 401 refresh, so the next background request carries a
                // fresh token.
                await self.refreshCapability()
            }
            if let resumeData, let taskId = self.sessionDelegate.resume(data: resumeData) {
                guard var rec = self.file.records[recordId] else { return }
                rec.taskIdentifier = taskId
                rec.localStatus = .downloading
                self.file.records[recordId] = rec
                self.persist()
            } else {
                // Restart from the manifest step — a pipeline failure may have
                // been in the manifest/asset fetch, not the media transfer.
                self.setLocalStatus(.fetchingAssets, id: recordId)
                await self.startMediaPipeline(recordId: recordId)
            }
        }
    }

    // MARK: - Polling (preparing → ready)

    private func ensurePolling() {
        guard pollTask == nil else { return }
        guard file.records.values.contains(where: { $0.localStatus == .preparing }) else { return }
        pollTask = Task { @MainActor in
            defer { self.pollTask = nil }
            while !Task.isCancelled {
                guard self.file.records.values.contains(where: { $0.localStatus == .preparing }) else { break }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                await self.reconcileWithServer(triggerPipeline: true)
            }
        }
    }

    // MARK: - Reconcile with server

    /// Mirrors this device's registry into the store. Runs only on a
    /// complete read, because an entry missing from it counts as removed on
    /// the server.
    func reconcileWithServer(triggerPipeline: Bool) async {
        guard downloadsEnabled, let owner = await captureScopeOwner() else { return }
        let listed: [APIv2DownloadEntry]
        do {
            listed = try await SiloAPI.shared.apiV2Client.listDownloads(auth: owner.auth)
        } catch {
            Self.logger.warning("download registry read failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard isCurrent(owner) else { return }
        // A complete read that no longer lists a locally deleted entry
        // confirms its DELETE. The others stay hidden until theirs lands.
        let pendingDeletes = (file.pendingServerDeletes ?? []).intersection(listed.map(\.id))
        file.pendingServerDeletes = pendingDeletes.isEmpty ? nil : pendingDeletes
        let rows = listed.filter { !pendingDeletes.contains($0.id) }
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (id, original) in file.records {
            if let row = byId[id] {
                var record = mergeExistingRecord(original, with: row)
                switch row.status {
                case "ready":
                    if record.localStatus == .preparing || record.localStatus == .registering {
                        record.localStatus = .queued
                    }
                case "revoked":
                    if record.localStatus == .completed {
                        record.localStatus = .revoked
                    } else if record.localStatus.isActive {
                        record.localStatus = .revoked
                    }
                case "failed":
                    if record.localStatus != .completed {
                        record.localStatus = .failed
                        record.lastError = "server_failed"
                    }
                default:
                    break
                }
                file.records[id] = record
            } else if original.localStatus.isActive {
                var record = original
                record.localStatus = .failed
                record.lastError = "removed_on_server"
                file.records[id] = record
            }
        }

        // Pick up rows registered out-of-band (e.g. subscription sync).
        var legacyRowIds: [String] = []
        if legacyRemovalIncomplete {
            Self.logger.warning("Not importing unknown server downloads: removing earlier versions' downloads did not finish")
        } else {
            let unknownRows = Self.partitionUnknownRows(
                rows.filter { file.records[$0.id] == nil },
                legacyRowsPending: file.legacyRowsPending == true
            )
            for row in unknownRows.imported {
                file.records[row.id] = makeRecord(from: row, type: row.episodeId != nil ? "episode" : nil)
            }
            if !unknownRows.legacy.isEmpty {
                Self.logger.notice("Deleting \(unknownRows.legacy.count, privacy: .public) server downloads registered by an earlier version")
                legacyRowIds = unknownRows.legacy.map(\.id)
            }
            file.legacyRowsPending = nil
        }
        persist()
        // Also sends the DELETEs still pending from an earlier pass.
        queueServerDeletes(legacyRowIds)
        reportPendingStatusEvents()

        await reconnectActiveTasks()
        if triggerPipeline {
            processQueue()
            ensurePolling()
        }
    }

    /// Splits server rows the store doesn't know into rows to import and rows
    /// an earlier version registered. A store the legacy removal wrote
    /// (`legacyRowsPending`) has not seen a complete registry read yet. A
    /// download this version registers is recorded when its create answers,
    /// so every unknown row that first read lists is one of the removed
    /// downloads, and importing it would bring it back as a download nobody
    /// asked for.
    /// After that read, and in every scope the earlier version never wrote,
    /// unknown rows are imported. No server timestamp is compared with the
    /// device clock.
    nonisolated static func partitionUnknownRows(
        _ rows: [APIv2DownloadEntry],
        legacyRowsPending: Bool
    ) -> (imported: [APIv2DownloadEntry], legacy: [APIv2DownloadEntry]) {
        legacyRowsPending ? ([], rows) : (rows, [])
    }

    // MARK: - Registry writes

    /// The request owner of the active download scope, captured before a
    /// registry call so its answer is applied only to that scope.
    private struct ScopeOwner {
        let scope: ScopeKey
        let auth: CapturedOrdinaryRequestAuth

        var generation: UInt64 { scope.generation }
    }

    /// One activation of a download scope. The generation advances on every
    /// scope change, so a switch away and back gives a different key.
    private struct ScopeKey: Equatable {
        let serverId: String
        let profileId: String
        let generation: UInt64
    }

    /// The active scope, or nil when there is none or its store has not
    /// loaded into `file` yet.
    private var loadedScope: ScopeKey? {
        guard !scopeServerId.isEmpty, !scopeProfileId.isEmpty,
              fileServerId == scopeServerId, fileProfileId == scopeProfileId else { return nil }
        return ScopeKey(serverId: scopeServerId, profileId: scopeProfileId, generation: registrationScopeGeneration)
    }

    /// Captures the request owner of `expected`, or of the active scope when
    /// nil. Background work passes the scope it was started under, captured
    /// synchronously, so it never pairs a newer scope's auth with a store
    /// it did not read.
    private func captureScopeOwner(expecting expected: ScopeKey? = nil) async -> ScopeOwner? {
        guard let scope = loadedScope, expected == nil || expected == scope,
              let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              auth.account.serverId == scope.serverId, auth.profileId == scope.profileId else { return nil }
        let owner = ScopeOwner(scope: scope, auth: auth)
        return isCurrent(owner) ? owner : nil
    }

    /// Whether the scope `owner` was captured for is still active and its
    /// store is the one in `file`.
    private func isCurrent(_ owner: ScopeOwner) -> Bool {
        loadedScope == owner.scope
    }

    /// Records that these registry entries must be deleted on the server,
    /// then sends every pending DELETE, including ones an earlier pass could
    /// not send. The record persists first, so an entry whose DELETE never
    /// lands is not imported again by a later reconcile. Every complete
    /// reconcile calls this, with or without new ids.
    private func queueServerDeletes(_ ids: [String]) {
        var pending = file.pendingServerDeletes ?? []
        if !pending.isSuperset(of: ids) {
            pending.formUnion(ids)
            file.pendingServerDeletes = pending
            persist()
        }
        sendPendingServerDeletes()
    }

    /// Sends the DELETE for every pending entry, one pass at a time.
    /// `deleteDownload` is `natural_idempotent`, so an entry without a
    /// definite answer stays pending and a later pass sends it again; a 204
    /// or a 404 ends it. The pass stops when the active owner changes.
    private func sendPendingServerDeletes() {
        guard serverDeleteTask == nil, file.pendingServerDeletes?.isEmpty == false,
              let scope = loadedScope else { return }
        serverDeleteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runServerDeletePass(scope: scope)
            self.serverDeleteTask = nil
        }
    }

    private func runServerDeletePass(scope: ScopeKey) async {
        guard let owner = await captureScopeOwner(expecting: scope) else { return }
        var attempted: Set<String> = []
        while isCurrent(owner),
              let id = (file.pendingServerDeletes ?? []).subtracting(attempted).sorted().first {
            attempted.insert(id)
            do {
                try await SiloAPI.shared.apiV2Client.deleteDownload(id: id, auth: owner.auth)
            } catch where Self.isNotFound(error) {
                // Already gone.
            } catch {
                Self.logger.warning("download delete failed; kept for the next reconcile: \(String(describing: error), privacy: .public)")
                continue
            }
            guard isCurrent(owner) else { return }
            file.pendingServerDeletes?.remove(id)
            if file.pendingServerDeletes?.isEmpty == true { file.pendingServerDeletes = nil }
            persist()
        }
    }

    nonisolated private static func isNotFound(_ error: Error) -> Bool {
        switch error {
        case APIv2Error.problem(let problem): return problem.status == 404
        case APIv2Error.httpStatus(let status): return status == 404
        default: return false
        }
    }

    /// A status event for the record's current revision, stamped now, or nil
    /// when the record has no revision an event could name.
    private static func statusEvent(_ status: DownloadStatusEvent.Status, for record: DownloadRecord) -> DownloadStatusEvent? {
        guard let revision = record.revision, revision >= 1 else { return nil }
        return DownloadStatusEvent(status: status, updatedAt: Date(), revision: revision)
    }

    /// What an answer to a status report means for the stored event.
    enum StatusReportResolution: Equatable {
        /// The server holds the event, or would refuse it again: drop it.
        case settled
        /// The entry moved to a newer revision, so the event describes bytes
        /// that were replaced: drop it and read the registry.
        case reconcile
        /// No definite answer: keep the event and send the same one later.
        case retryLater
    }

    nonisolated static func statusReportResolution(_ error: Error?) -> StatusReportResolution {
        guard let error else { return .settled }
        switch APIv2Client.downloadRegistryFailure(error) {
        case .conflict: return .reconcile
        case .rejected: return .settled
        case .notApplied, .uncertain: return .retryLater
        }
    }

    /// Sends every unanswered status event of the active scope. Reconcile
    /// calls this too, so an event kept for later goes out again on the next
    /// foreground.
    private func reportPendingStatusEvents() {
        let ids = file.records.values
            .filter { $0.pendingStatusEvent != nil && !statusReportsInFlight.contains($0.id) }
            .map(\.id)
        guard !ids.isEmpty, let scope = loadedScope else { return }
        statusReportsInFlight.formUnion(ids)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let superseded = await self.sendStatusEvents(ids: ids, scope: scope)
            self.statusReportsInFlight.subtract(ids)
            // A newer event recorded while its predecessor was in flight.
            if superseded { self.reportPendingStatusEvents() }
        }
    }

    /// Returns whether any record got a newer event while its report was in
    /// flight.
    private func sendStatusEvents(ids: [String], scope: ScopeKey) async -> Bool {
        guard let owner = await captureScopeOwner(expecting: scope) else { return false }
        var superseded = false
        var needsReconcile = false
        for id in ids {
            guard isCurrent(owner), let event = file.records[id]?.pendingStatusEvent else { continue }
            var failure: Error?
            do {
                _ = try await SiloAPI.shared.apiV2Client.reportDownloadStatus(id: id, event: event, auth: owner.auth)
            } catch {
                failure = error
                Self.logger.warning("download status report failed: \(String(describing: error), privacy: .public)")
            }
            guard isCurrent(owner), var record = file.records[id] else { continue }
            guard record.pendingStatusEvent == event else {
                superseded = true
                continue
            }
            switch Self.statusReportResolution(failure) {
            case .settled:
                record.pendingStatusEvent = nil
            case .reconcile:
                record.pendingStatusEvent = nil
                needsReconcile = true
            case .retryLater:
                continue
            }
            file.records[id] = record
            persist()
        }
        if needsReconcile, isCurrent(owner) {
            await reconcileWithServer(triggerPipeline: true)
        }
        return superseded
    }

    /// After a relaunch the background session may have lost in-flight
    /// tasks (or finished them while we were dead). Re-queue records whose
    /// task is no longer live. A live task on a retired file URL is
    /// cancelled and its download re-queued, so it restarts from a fresh
    /// manifest instead of ending in a 410.
    private func reconnectActiveTasks() async {
        let (active, retired) = await sessionDelegate.liveTasks()
        for taskId in retired {
            intentionalCancels.insert(taskId)
            sessionDelegate.cancel(taskId: taskId)
        }
        for (id, record) in file.records {
            var record = record
            // Task identifiers are only unique within one URLSession
            // instance — a recreated session hands the same small integers
            // to new tasks, so a persisted id with no live task must be
            // dropped before it can match (and misroute) another record's
            // transfer. Pause round-trips keep theirs: the cancelled task
            // may still deliver a final event that must find this record.
            if let taskId = record.taskIdentifier,
               !active.contains(taskId),
               !pendingPauseIds.contains(id) {
                record.taskIdentifier = nil
                file.records[id] = record
            }
            // Records with a live back-off timer are owned by the retry;
            // re-queuing them here would double-start the transfer when it
            // fires.
            guard retryTasks[id] == nil else { continue }
            guard record.localStatus == .downloading || record.localStatus == .fetchingAssets else {
                continue
            }
            // `.fetchingAssets` records were mid-pipeline in a detached Task
            // that did not survive the relaunch; re-queue them too so they
            // aren't wedged (and don't keep occupying a concurrency slot
            // forever).
            if record.localStatus == .downloading,
               let taskId = record.taskIdentifier, active.contains(taskId) {
                continue
            }
            setLocalStatus(.queued, id: id)
        }
    }

    // MARK: - Series monitoring

    /// Starts monitoring a series, then registers the episodes it puts in
    /// scope. The server answers a create for a series this device already
    /// monitors with that monitor, unchanged, so differing options are then
    /// applied to it with a PATCH.
    ///
    /// `createDownloadSubscription` is `non_retryable`: it is sent once. After
    /// an uncertain outcome the monitor list shows whether the server
    /// created it.
    func createSubscription(
        seriesId: String,
        seriesTitle: String?,
        mode: SubscriptionMode,
        seasonNumbers: [Int]?,
        deleteWatched: Bool,
        maxStorageBytes: Int64
    ) async throws {
        guard let owner = await captureScopeOwner() else { throw DownloadError.monitoringScopeChanged }
        let request = CreateSubscriptionRequest(
            seriesId: seriesId,
            mode: mode.rawValue,
            seasonNumbers: mode == .specificSeasons ? seasonNumbers : nil,
            deleteWatched: deleteWatched,
            maxStorageBytes: maxStorageBytes
        )
        // A monitor DELETE on the wire lands first, so a create for a series
        // the user just stopped does not answer with the monitor that DELETE
        // removes.
        if let running = subscriptionDeleteTask {
            await running.value
            guard isCurrent(owner) else { throw DownloadError.monitoringScopeChanged }
        }
        try await sendCreate(request, seriesTitle: seriesTitle, owner: owner)
        if let answered = subscription(forSeriesId: seriesId), subscriptionWrites.awaitsDelete(answered.id),
           let running = subscriptionDeleteTask {
            // A delete pass that started during the create sent the DELETE
            // for the monitor the create answered with. Once it lands, that
            // monitor is gone; the create's answer was definite, so one
            // fresh create is a new request, not a resend.
            await running.value
            guard isCurrent(owner) else { throw DownloadError.monitoringScopeChanged }
            if subscriptionWrites.wasDeleted(answered.id) {
                try await sendCreate(request, seriesTitle: seriesTitle, owner: owner)
            }
        }
        guard let monitor = subscription(forSeriesId: seriesId) else { throw DownloadError.monitoringUncertain }
        if monitor.seriesTitle == nil, let seriesTitle,
           let index = file.subscriptions.firstIndex(where: { $0.id == monitor.id }) {
            file.subscriptions[index].seriesTitle = seriesTitle
            persist()
        }
        if !Self.monitorMatches(monitor, request) {
            try await updateSubscription(
                id: monitor.id,
                mode: mode,
                seasonNumbers: request.seasonNumbers,
                deleteWatched: deleteWatched,
                maxStorageBytes: maxStorageBytes,
                active: true
            )
            return
        }
        // The server removed the monitor after answering the create: the
        // user's change did not stick.
        if await syncSubscription(id: monitor.id, owner: owner).removed { throw DownloadError.monitoringUncertain }
        await reconcileWithServer(triggerPipeline: true)
    }

    /// Sends one create and stores the monitor it answers with. After an
    /// uncertain outcome the monitor list shows whether the server created
    /// it.
    private func sendCreate(_ request: CreateSubscriptionRequest, seriesTitle: String?, owner: ScopeOwner) async throws {
        do {
            let created = try await SiloAPI.shared.apiV2Client.createDownloadSubscription(request, auth: owner.auth)
            guard isCurrent(owner) else { throw DownloadError.monitoringScopeChanged }
            upsertSubscription(created, seriesTitle: seriesTitle, fromCreate: true)
            persist()
        } catch let error as DownloadError {
            throw error
        } catch {
            let failure = APIv2Client.downloadRegistryFailure(error)
            Self.logger.warning("monitor create failed (\(String(describing: failure), privacy: .public)): \(String(describing: error), privacy: .public)")
            guard failure == .uncertain || failure == .conflict else { throw error }
            let listed = await refreshSubscriptions(owner: owner)
            guard isCurrent(owner) else { throw DownloadError.monitoringScopeChanged }
            guard listed, subscription(forSeriesId: request.seriesId) != nil else { throw DownloadError.monitoringUncertain }
        }
    }

    /// Whether a stored monitor already has the options a create asked for.
    nonisolated static func monitorMatches(_ monitor: DownloadSubscription, _ request: CreateSubscriptionRequest) -> Bool {
        guard monitor.active, monitor.mode == request.mode, monitor.deleteWatched == request.deleteWatched,
              monitor.maxStorageBytes == request.maxStorageBytes else { return false }
        guard request.mode == SubscriptionMode.specificSeasons.rawValue else { return true }
        return Set(monitor.seasonNumbers ?? []) == Set(request.seasonNumbers ?? [])
    }

    /// Edits a monitor under its stored validator, then registers the
    /// episodes its new scope adds. A stale validator is refreshed once by
    /// `updateDownloadSubscription`; a failure that remains is surfaced.
    func updateSubscription(
        id: String,
        mode: SubscriptionMode? = nil,
        seasonNumbers: [Int]? = nil,
        deleteWatched: Bool? = nil,
        maxStorageBytes: Int64? = nil,
        active: Bool? = nil
    ) async throws {
        guard let owner = await captureScopeOwner() else { throw DownloadError.monitoringScopeChanged }
        guard let existing = file.subscriptions.first(where: { $0.id == id }) else { throw DownloadError.monitorRemoved }
        let patch = UpdateSubscriptionRequest(
            mode: mode?.rawValue,
            seasonNumbers: seasonNumbers,
            deleteWatched: deleteWatched,
            maxStorageBytes: maxStorageBytes,
            active: active
        )
        let updated: ServerSubscription
        do {
            updated = try await SiloAPI.shared.apiV2Client.updateDownloadSubscription(
                id: id, etag: existing.etag, patch: patch, auth: owner.auth)
        } catch {
            guard isCurrent(owner) else { throw DownloadError.monitoringScopeChanged }
            throw settleFailedMonitorWrite(error, id: id)
        }
        guard isCurrent(owner) else { throw DownloadError.monitoringScopeChanged }
        upsertSubscription(updated, seriesTitle: existing.seriesTitle)
        persist()
        if await syncSubscription(id: id, owner: owner).removed { throw DownloadError.monitorRemoved }
        await reconcileWithServer(triggerPipeline: true)
    }

    /// The error a failed monitor write shows. A monitor the server no longer
    /// has is removed locally.
    private func settleFailedMonitorWrite(_ error: Error, id: String) -> Error {
        let status = APIv2Client.downloadStatus(of: error)
        if status == 428 {
            // Every write sends If-Match, so the server not seeing one is a
            // client bug, never a condition a retry could clear.
            Self.logger.fault("monitor write reached the server without If-Match: \(String(describing: error), privacy: .public)")
            return error
        }
        Self.logger.warning("monitor write failed: \(String(describing: error), privacy: .public)")
        switch status {
        case 404:
            file.subscriptions.removeAll { $0.id == id }
            persist()
            return DownloadError.monitorRemoved
        case 409, 412:
            return DownloadError.monitorChanged
        default:
            return APIv2Client.downloadRegistryFailure(error) == .uncertain ? DownloadError.monitoringUncertain : error
        }
    }

    /// Stops monitoring a series. The monitor leaves the local list at once;
    /// its DELETE is recorded with the monitor's validator first, so a
    /// DELETE that does not land is sent again by the next sync and the
    /// monitor list never brings the monitor back meanwhile.
    func deleteSubscription(id: String) async {
        guard let index = file.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let removed = file.subscriptions.remove(at: index)
        var pending = file.pendingSubscriptionDeletes ?? [:]
        pending[id] = removed.etag ?? ""
        file.pendingSubscriptionDeletes = pending
        persist()
        await sendPendingSubscriptionDeletes()
    }

    /// Sends every pending monitor DELETE, one pass at a time.
    /// `deleteDownloadSubscription` is `natural_idempotent`: a DELETE without
    /// a definite answer stays pending for the next pass. A refusal ends it,
    /// and the next monitor list shows the monitor again, because the server
    /// still has it.
    private func sendPendingSubscriptionDeletes() async {
        if let running = subscriptionDeleteTask {
            await running.value
            return
        }
        guard file.pendingSubscriptionDeletes?.isEmpty == false, let scope = loadedScope else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSubscriptionDeletePass(scope: scope)
            self.subscriptionDeleteTask = nil
        }
        subscriptionDeleteTask = task
        await task.value
    }

    private func runSubscriptionDeletePass(scope: ScopeKey) async {
        guard let owner = await captureScopeOwner(expecting: scope) else { return }
        var attempted: Set<String> = []
        while isCurrent(owner),
              let next = (file.pendingSubscriptionDeletes ?? [:])
                .filter({ !attempted.contains($0.key) }).min(by: { $0.key < $1.key }) {
            let id = next.key
            attempted.insert(id)
            subscriptionWrites.deleteSent(id)
            var landed = true
            var keepPending = false
            do {
                try await SiloAPI.shared.apiV2Client.deleteDownloadSubscription(
                    id: id, etag: next.value.isEmpty ? nil : next.value, auth: owner.auth)
            } catch {
                landed = false
                if APIv2Client.downloadStatus(of: error) == 428 {
                    Self.logger.fault("monitor delete reached the server without If-Match: \(String(describing: error), privacy: .public)")
                } else {
                    Self.logger.warning("monitor delete failed: \(String(describing: error), privacy: .public)")
                }
                switch APIv2Client.downloadRegistryFailure(error) {
                case .notApplied, .uncertain, .conflict:
                    keepPending = true
                case .rejected:
                    break
                }
            }
            // A create that answered with this monitor meanwhile brought it
            // back locally; the DELETE removed it on the server anyway.
            let createdMonitorGone = subscriptionWrites.deleteAnswered(id, landed: landed)
            if keepPending { continue }
            guard isCurrent(owner) else { return }
            file.pendingSubscriptionDeletes?.removeValue(forKey: id)
            if file.pendingSubscriptionDeletes?.isEmpty == true { file.pendingSubscriptionDeletes = nil }
            if createdMonitorGone { file.subscriptions.removeAll { $0.id == id } }
            persist()
        }
    }

    /// Replaces the local monitor list with a complete read of the server's.
    /// Returns false when the read failed or the scope changed.
    @discardableResult
    private func refreshSubscriptions(owner: ScopeOwner) async -> Bool {
        let started = subscriptionWrites.generation
        let listed: [ServerSubscription]
        do {
            listed = try await SiloAPI.shared.apiV2Client.listDownloadSubscriptions(auth: owner.auth)
        } catch {
            Self.logger.warning("monitor list read failed: \(String(describing: error), privacy: .public)")
            return false
        }
        guard isCurrent(owner) else { return false }
        // The read shows the server as it was when it started: a DELETE that
        // landed during it may still be listed, and a create answered during
        // it may be missing.
        let landed = subscriptionWrites.landed(since: started)
        let merged = Self.mergeSubscriptions(
            local: file.subscriptions,
            listed: listed,
            stopped: Set((file.pendingSubscriptionDeletes ?? [:]).keys).union(landed.deleted),
            createdDuringRead: landed.created,
            legacyRemovalDate: legacyRemovalDate
        )
        subscriptionWrites.listCompleted(startedAt: started)
        if merged != file.subscriptions {
            file.subscriptions = merged
            persist()
        }
        return true
    }

    /// The local monitor list after a complete read of the server's. Local
    /// titles stay. A monitor the server no longer lists is dropped, unless a
    /// create answered with it during the read (`createdDuringRead`). One the
    /// user stopped (`stopped`: its DELETE is pending or landed during the
    /// read) is not brought back. An unknown monitor created before this
    /// version removed earlier versions' downloads belongs to them, so it is
    /// left out and never synced.
    nonisolated static func mergeSubscriptions(
        local: [DownloadSubscription],
        listed: [ServerSubscription],
        stopped: Set<String>,
        createdDuringRead: Set<String> = [],
        legacyRemovalDate: Date?
    ) -> [DownloadSubscription] {
        let titles = Dictionary(local.map { ($0.id, $0.seriesTitle) }, uniquingKeysWith: { first, _ in first })
        let merged: [DownloadSubscription] = listed.compactMap { monitor in
            guard !stopped.contains(monitor.id) else { return nil }
            if let title = titles[monitor.id] {
                return DownloadSubscription(from: monitor, seriesTitle: title)
            }
            if let legacyRemovalDate, monitor.createdAt < legacyRemovalDate { return nil }
            return DownloadSubscription(from: monitor, seriesTitle: nil)
        }
        let listedIds = Set(listed.map(\.id))
        let created = local.filter {
            createdDuringRead.contains($0.id) && !listedIds.contains($0.id) && !stopped.contains($0.id)
        }
        return merged + created
    }

    /// Registers new in-scope episodes for every active monitor: sends the
    /// pending monitor DELETEs, reads the monitor list, then syncs each
    /// monitor page by page. Returns how many episodes the server registered.
    private func syncSubscriptions(owner: ScopeOwner) async -> Int {
        await sendPendingSubscriptionDeletes()
        guard isCurrent(owner) else { return 0 }
        await refreshSubscriptions(owner: owner)
        var registered = 0
        for id in file.subscriptions.filter(\.active).map(\.id) {
            guard isCurrent(owner) else { break }
            let result = await syncSubscription(id: id, owner: owner)
            registered += result.registered
            // Offline, rate limited or unavailable: the other monitors would
            // meet the same answer.
            if result.stopRun { break }
        }
        return registered
    }

    /// Syncs one stored monitor and applies what the sync learned about it.
    /// `removed` means the server no longer has the monitor.
    @discardableResult
    private func syncSubscription(id: String, owner: ScopeOwner) async -> (registered: Int, stopRun: Bool, removed: Bool) {
        guard let monitor = file.subscriptions.first(where: { $0.id == id }), monitor.active else { return (0, false, false) }
        let outcome: DownloadSubscriptionSyncOutcome
        do {
            outcome = try await SiloAPI.shared.apiV2Client.syncDownloadSubscription(
                id: id, etag: monitor.etag, auth: owner.auth)
        } catch {
            Self.logger.warning("monitor sync failed: \(String(describing: error), privacy: .public)")
            return (0, APIv2Client.downloadRegistryFailure(error) == .notApplied, false)
        }
        guard isCurrent(owner) else { return (outcome.registered, true, false) }
        if outcome.removed {
            file.subscriptions.removeAll { $0.id == id }
            persist()
        } else if let reloaded = outcome.reloaded {
            upsertSubscription(reloaded, seriesTitle: monitor.seriesTitle)
            persist()
        }
        return (outcome.registered, false, outcome.removed)
    }

    /// Subscription sync + offline progress reconciliation, run on
    /// foreground and from the background refresh task. Client-driven: no
    /// server background worker.
    func runMonitoringAndProgressSync() async {
        guard downloadsEnabled else { return }
        let priorRecordIds = Set(file.records.keys)
        var registered = 0
        if canMonitorSeries, let owner = await captureScopeOwner() {
            registered = await syncSubscriptions(owner: owner)
        }
        await flushProgressQueue()
        await pullProgressDeltas()
        await reconcileWithServer(triggerPipeline: true)
        notifyMonitoringBatch(registered: registered, priorRecordIds: priorRecordIds)
        await enforceRetention()
    }

    /// One notification per sync batch when monitoring registered new
    /// episodes. The rows land locally via the reconcile that just ran; a
    /// fresh episode row's `contentId` is the series id (episode
    /// registrations are keyed by series), which is how the batch resolves
    /// the show name for the copy before the manifest hydrates `seriesId`.
    private func notifyMonitoringBatch(registered: Int, priorRecordIds: Set<String>) {
        #if os(iOS)
        guard registered > 0 else { return }
        let newEpisodes = file.records.values.filter {
            !priorRecordIds.contains($0.id) && $0.episodeId != nil
        }
        guard !newEpisodes.isEmpty else { return }
        let titles = Set(newEpisodes.compactMap {
            subscription(forSeriesId: $0.seriesId ?? $0.contentId)?.seriesTitle
        })
        DownloadNotifier.newEpisodesQueued(count: newEpisodes.count, seriesTitles: titles)
        #endif
    }

    /// Client-enforced `delete_watched`: remove completed downloads whose
    /// series is monitored with retention enabled and whose progress is
    /// completed. The server never deletes on-device files.
    private func enforceRetention() async {
        let retentionSeries = Set(
            file.subscriptions.filter { $0.deleteWatched }.map { $0.seriesId }
        )
        guard !retentionSeries.isEmpty else { return }
        let toDelete = file.records.values.filter { record in
            // Progress is keyed by the leaf item id (the episode), which for an
            // episode download is `episodeId`, not the series `contentId`.
            let leafId = record.episodeId ?? record.contentId
            return record.localStatus == .completed
                && record.seriesId.map(retentionSeries.contains) == true
                && file.localProgress[leafId]?.completed == true
        }
        for record in toDelete {
            deleteDownload(id: record.id)
        }
    }

    // MARK: - Offline progress

    /// Record a watch-progress event from offline playback: update the
    /// local resume point and queue it for the next reconnect flush.
    func recordOfflineProgress(mediaItemId: String, position: Double, duration: Double, completed: Bool) {
        guard !mediaItemId.isEmpty, position.isFinite, position >= 0 else { return }
        let now = Date()
        var entry = file.localProgress[mediaItemId]
            ?? LocalProgressEntry(position: 0, duration: duration, completed: false, updatedAt: now)
        entry.position = position
        if duration.isFinite, duration > 0 { entry.duration = duration }
        entry.completed = entry.completed || completed
        entry.updatedAt = now
        file.localProgress[mediaItemId] = entry

        var queue = file.progressQueue
        OfflineProgressQueue.record(
            &queue,
            mediaItemId: mediaItemId,
            position: position,
            duration: duration,
            at: now
        )
        file.progressQueue = queue
        persist()
    }

    /// Offline progress entries whose upload outcome is unknown. They are
    /// never re-sent; `discardHeldProgress()` is the user's exit.
    var heldProgressCount: Int {
        OfflineProgressQueue.held(file.progressQueue, inFlight: progressUploadsInFlight).count
    }

    /// "Discard held change" for offline progress with an unknown outcome.
    func discardHeldProgress() {
        guard heldProgressCount > 0 else { return }
        var queue = file.progressQueue
        OfflineProgressQueue.discardHeld(&queue, inFlight: progressUploadsInFlight)
        file.progressQueue = queue
        persist()
    }

    /// Uploads queued offline progress through `POST /api/v2/sync/progress`
    /// in batches of at most 100 distinct items, under the owner of the
    /// active download scope. Each batch is claimed durably before it is
    /// sent, so a batch whose answer never arrives, even across a crash, is
    /// held instead of sent again (see `OfflineProgressQueue`).
    func flushProgressQueue() async {
        let serverId = scopeServerId
        let profileId = scopeProfileId
        let generation = registrationScopeGeneration
        guard !serverId.isEmpty, !profileId.isEmpty,
              let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              auth.account.serverId == serverId, auth.profileId == profileId else { return }
        // The scope generation advances on every scope change, including a
        // switch away and back, so a stale flush cannot touch a newer file.
        func scopeUnchanged() -> Bool {
            generation == registrationScopeGeneration && serverId == scopeServerId && profileId == scopeProfileId
        }

        for _ in 0..<Self.maxProgressBatchesPerFlush {
            guard scopeUnchanged() else { return }
            var queue = file.progressQueue
            OfflineProgressQueue.dropUnsendable(&queue)
            let batch = OfflineProgressQueue.nextBatch(queue)
            guard !batch.isEmpty else {
                if queue.count != file.progressQueue.count {
                    file.progressQueue = queue
                    persist()
                }
                return
            }
            let ids = Set(batch.map(\.id))
            OfflineProgressQueue.claim(&queue, ids: ids)
            file.progressQueue = queue
            progressUploadsInFlight.formUnion(ids)
            persist()
            await saveChain?.value

            let outcome = await SiloAPI.shared.apiV2Client.syncProgress(batch.compactMap(\.syncItem), auth: auth)
            progressUploadsInFlight.subtract(ids)
            guard scopeUnchanged() else {
                // A batch that was sent stays dispatched in the old scope's
                // file, which is the held state it belongs in. One that never
                // reached the server (refused before dispatch, or deferred)
                // goes back to pending there.
                if OfflineProgressQueue.releasesClaims(outcome) {
                    releaseProgressClaims(ids, serverId: serverId, profileId: profileId)
                }
                return
            }
            queue = file.progressQueue
            OfflineProgressQueue.resolve(&queue, batch: batch, outcome: outcome)
            file.progressQueue = queue
            persist()
            if let failure = outcome.failureSummary {
                Self.logger.warning("offline progress upload: \(failure, privacy: .public)")
            }
            guard OfflineProgressQueue.flushContinues(after: outcome) else { return }
        }
    }

    /// Returns claimed entries of an inactive (or not yet reinstalled) scope
    /// to pending: in memory when that scope is installed again, and in its
    /// store file, ordered after every save already queued.
    private func releaseProgressClaims(_ ids: Set<UUID>, serverId: String, profileId: String) {
        if serverId == scopeServerId, profileId == scopeProfileId, scopeLoadTask == nil {
            // Switched away and back: the scope's store is installed again.
            if OfflineProgressQueue.releaseClaims(&file.progressQueue, ids: ids) { persist() }
            return
        }
        releasedProgressClaims[Self.progressClaimKey(serverId, profileId), default: []].formUnion(ids)
        let previous = saveChain
        saveChain = Task { @MainActor in
            await previous?.value
            await DownloadStore.shared.releaseProgressClaims(ids, serverId: serverId, profileId: profileId)
        }
    }

    private static func progressClaimKey(_ serverId: String, _ profileId: String) -> String {
        serverId + "\n" + profileId
    }

    func pullProgressDeltas() async {
        do {
            let response = try await SiloAPI.shared.pullProgressDeltas(since: file.progressCursor)
            for item in response.progress {
                let serverTime = item.updatedAt ?? Date()
                var entry = file.localProgress[item.mediaItemId]
                    ?? LocalProgressEntry(
                        position: item.positionSeconds,
                        duration: item.durationSeconds,
                        completed: item.completed,
                        updatedAt: serverTime
                    )
                if serverTime >= entry.updatedAt {
                    entry.position = item.positionSeconds
                    if item.durationSeconds > 0 { entry.duration = item.durationSeconds }
                    entry.completed = entry.completed || item.completed
                    entry.updatedAt = serverTime
                    file.localProgress[item.mediaItemId] = entry
                }
            }
            if let cursor = response.nextCursor, !cursor.isEmpty {
                file.progressCursor = cursor
            }
            persist()
        } catch {
            // Non-fatal; retry next foreground.
        }
    }

    // MARK: - Helpers

    private func upsertRow(
        _ row: APIv2DownloadEntry,
        displayTitle: String?,
        displaySubtitle: String?,
        type: String?,
        seriesId: String?,
        posterThumbhash: String?
    ) {
        if let existing = file.records[row.id] {
            var merged = mergeExistingRecord(existing, with: row)
            if existing.localStatus == .failed || existing.localStatus == .revoked {
                merged.localStatus = Self.mapInitialStatus(row.status)
                merged.lastError = nil
                merged.retryCount = 0
            }
            file.records[row.id] = merged
            return
        }
        var record = makeRecord(from: row, type: type)
        record.title = displayTitle
        record.subtitle = displaySubtitle
        record.seriesId = seriesId ?? record.seriesId
        record.posterThumbhash = posterThumbhash
        file.records[row.id] = record
    }

    private func mergeExistingRecord(_ existing: DownloadRecord, with row: APIv2DownloadEntry) -> DownloadRecord {
        var record = existing
        if shouldReplaceLocalAssets(record, with: row) {
            discardLocalAssets(for: record)
            resetLocalAssets(on: &record, status: row.status)
        }
        applyServerRow(row, to: &record)
        return record
    }

    private func shouldReplaceLocalAssets(_ record: DownloadRecord, with row: APIv2DownloadEntry) -> Bool {
        if let currentRevision = record.revision {
            return row.revision > currentRevision
        }
        return record.mediaFileId != row.mediaFileId || record.format != row.quality
    }

    private func discardLocalAssets(for record: DownloadRecord) {
        if let taskId = record.taskIdentifier {
            intentionalCancels.insert(taskId)
            sessionDelegate.cancel(taskId: taskId)
        }
        guard !scopeServerId.isEmpty else { return }
        DownloadFilePaths.removeDownloadDirectory(
            serverId: scopeServerId,
            profileId: scopeProfileId,
            downloadId: record.id
        )
    }

    private func resetLocalAssets(on record: inout DownloadRecord, status: String) {
        record.mediaFilename = nil
        record.manifestFilename = nil
        record.posterFilename = nil
        record.backdropFilename = nil
        record.logoFilename = nil
        record.subtitleFilenames = [:]
        record.resumeDataFilename = nil
        record.container = nil
        record.stableIdentity = nil
        record.bytesDownloaded = 0
        record.localStatus = Self.mapInitialStatus(status)
        record.downloadedAt = nil
        record.lastError = nil
        record.retryCount = 0
        record.taskIdentifier = nil
        // An unsent event describes the replaced bytes.
        record.pendingStatusEvent = nil
    }

    private func applyServerRow(_ row: APIv2DownloadEntry, to record: inout DownloadRecord) {
        record.contentId = row.contentId
        record.mediaFileId = row.mediaFileId
        record.format = row.quality
        record.effectiveQuality = row.effectiveQuality
        record.deliveryFormat = row.deliveryFormat
        record.targetBitrateKbps = row.targetBitrateKbps
        record.revision = row.revision
        record.serverStatus = row.status
        if row.fileSize > 0, record.fileSize <= 0 {
            record.fileSize = row.fileSize
        }
        if let completedAt = row.completedAt {
            record.downloadedAt = completedAt
        }
    }

    private func makeRecord(from row: APIv2DownloadEntry, type: String?) -> DownloadRecord {
        DownloadRecord(
            id: row.id,
            contentId: row.contentId,
            episodeId: row.episodeId,
            batchId: row.batchId,
            mediaFileId: row.mediaFileId,
            format: row.quality,
            effectiveQuality: row.effectiveQuality,
            deliveryFormat: row.deliveryFormat,
            targetBitrateKbps: row.targetBitrateKbps,
            revision: row.revision,
            serverStatus: row.status,
            localStatus: Self.mapInitialStatus(row.status),
            fileSize: row.fileSize,
            bytesDownloaded: 0,
            mediaFilename: nil,
            manifestFilename: nil,
            posterFilename: nil,
            backdropFilename: nil,
            logoFilename: nil,
            subtitleFilenames: [:],
            title: nil,
            subtitle: nil,
            type: type,
            seriesId: nil,
            posterThumbhash: nil,
            container: nil,
            stableIdentity: nil,
            registeredAt: row.createdAt,
            downloadedAt: row.completedAt,
            lastError: nil,
            retryCount: 0,
            taskIdentifier: nil
        )
    }

    nonisolated static func mapInitialStatus(_ serverStatus: String) -> LocalDownloadStatus {
        switch serverStatus {
        // `downloading` and `completed` only record what a device reported;
        // the server file is still fetchable, so a record without local
        // media downloads it like a `ready` row.
        case "ready", "downloading", "completed": return .queued
        case "preparing": return .preparing
        case "revoked": return .revoked
        case "failed": return .failed
        default: return .registering
        }
    }

    /// Stores a monitor the server answered with. Only a create brings back
    /// a monitor the user stopped: it can answer with a monitor whose DELETE
    /// has not landed, which is wanted again, so that DELETE no longer
    /// applies. An edit or sync answer for a stopped monitor is dropped.
    private func upsertSubscription(_ server: ServerSubscription, seriesTitle: String?, fromCreate: Bool = false) {
        if fromCreate {
            let cancelled = file.pendingSubscriptionDeletes?.removeValue(forKey: server.id) != nil
            if file.pendingSubscriptionDeletes?.isEmpty == true { file.pendingSubscriptionDeletes = nil }
            subscriptionWrites.createAnswered(server.id, cancelledPendingDelete: cancelled)
        } else if file.pendingSubscriptionDeletes?[server.id] != nil || subscriptionWrites.wasDeleted(server.id) {
            return
        }
        let mirror = DownloadSubscription(from: server, seriesTitle: seriesTitle)
        if let index = file.subscriptions.firstIndex(where: { $0.id == server.id }) {
            file.subscriptions[index] = mirror
        } else {
            file.subscriptions.append(mirror)
        }
    }

    private func setLocalStatus(_ status: LocalDownloadStatus, id: String) {
        guard var record = file.records[id] else { return }
        record.localStatus = status
        file.records[id] = record
        persist()
    }

    private func recordByTask(_ taskId: Int) -> DownloadRecord? {
        file.records.values.first { $0.taskIdentifier == taskId }
    }

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

    private func absoluteFileURLForNewAsset(recordId: String, filename: String) -> URL? {
        guard !scopeServerId.isEmpty else { return nil }
        return DownloadFilePaths.fileURL(
            serverId: scopeServerId,
            profileId: scopeProfileId,
            downloadId: recordId,
            filename: filename
        )
    }

    private func fileSizeOnDisk(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// Saves `file` to the store of the scope it was loaded for, which lags
    /// the active scope while a switch waits on its load.
    private func persist() {
        guard !fileServerId.isEmpty, !fileProfileId.isEmpty else { return }
        lastProgressPersist = Date()
        let snapshot = file
        let serverId = fileServerId
        let profileId = fileProfileId
        // Chain each save after the previous so writes land in call order.
        let previous = saveChain
        saveChain = Task { @MainActor in
            await previous?.value
            await DownloadStore.shared.save(snapshot, serverId: serverId, profileId: profileId)
        }
    }

    /// Recompute scope storage usage off the MainActor and publish it.
    private func refreshStorageUsage() {
        let serverId = scopeServerId
        let profileId = scopeProfileId
        guard !serverId.isEmpty, !profileId.isEmpty else {
            storageBytesUsed = 0
            return
        }
        Task.detached(priority: .utility) {
            let bytes = DownloadFilePaths.bytesUsed(serverId: serverId, profileId: profileId)
            await MainActor.run { [weak self] in self?.storageBytesUsed = bytes }
        }
    }

    /// Throttle disk writes during the high-frequency progress callbacks;
    /// the in-memory mutation already drives the UI.
    private func persistProgressThrottled() {
        guard Date().timeIntervalSince(lastProgressPersist) > 2 else { return }
        persist()
    }

    // MARK: - Transfer rate

    /// Exponentially-smoothed rate from progress deltas. Samples at least
    /// `rateSampleInterval` apart so the burst-y delegate callbacks don't
    /// produce jittery instantaneous rates.
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

import Foundation
import Observation
import OSLog
#if canImport(UIKit)
import UIKit
#endif

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
/// Concurrency: one `@MainActor` `@Observable` coordinator the UI reads
/// directly. Disk I/O goes through the `DownloadStore` actor and transfers
/// through `DownloadSessionDelegate`'s background `URLSession`. `file` is the
/// source of truth; `persist()` saves snapshots of it in order.
@Observable
@MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    private static let logger = Logger.downloads

    /// Records fetching their manifest at once. Running transfers are capped
    /// separately, by the Simultaneous Downloads setting.
    nonisolated private static let maxConcurrentPipelines = 3
    nonisolated private static let maxRetries = 4
    /// Bounds one flush at 10,000 queued items (100 per batch).
    private static let maxProgressBatchesPerFlush = 100

    /// In-memory store for the active scope. Read by the AutoDownload
    /// extension; written only here.
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
    /// Set when iOS relaunches the app to deliver background events; called
    /// once `allEventsDelivered` is processed.
    @ObservationIgnored private var backgroundCompletionHandler: (() -> Void)?
    /// Tasks this manager cancelled on purpose, whose failure events are
    /// ignored. Keyed by owner as well as identifier: identifiers repeat
    /// across session instances, so an identifier alone could swallow
    /// another download's real failure.
    private var intentionalCancels: Set<IntentionalCancel> = []
    private struct IntentionalCancel: Hashable {
        let taskId: Int
        let owner: DownloadTaskTag
    }
    private var pollTask: Task<Void, Never>?
    /// Identifies the loop `pollTask` holds.
    @ObservationIgnored private var pollToken: UUID?
    private var lastProgressPersist = Date.distantPast
    /// Session events that arrive before the first scope activation loads the
    /// persisted registry (a background relaunch replays buffered delegate
    /// events the moment the session is recreated). A finished file is
    /// parked on disk under its owner before its event is sent, so the hold
    /// no longer protects finished media; it keeps early progress and
    /// failure events for the first loaded scope, which would otherwise be
    /// dropped. Replayed by `releaseHeldSessionEvents()`.
    private var pendingSessionEvents: [DownloadSessionEvent] = []
    private var sessionEventsHeld = true
    /// The settle of parked finished transfers for the store most recently
    /// installed into `file`. Activation, reconnect and the background
    /// completion handler wait for it, so a finished download completes
    /// before anything could re-queue it or iOS could suspend the app.
    private var parkedSettle: (scope: ScopeKey, task: Task<Void, Never>)?
    /// In-flight back-off timers keyed by record id, tracked so pause/delete
    /// can abort the timer instead of leaving it to fire against a dead
    /// record. `restartOwners` is what keeps a reconcile off their records.
    private var retryTasks: [String: Task<Void, Never>] = [:]
    /// The pipelines and retries that may still start a record's transfer.
    /// A pipeline that lost ownership (superseded, deleted, or reset by a new
    /// revision) stops before it can start a second transfer of the file.
    private var restartOwners = DownloadRestartOwners()
    #if canImport(UIKit)
    /// Keeps the app running while a transfer is on its way to the background
    /// session. Without it, iOS suspends the app mid-pipeline and the record
    /// waits for the next launch.
    private var handoffBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    /// Records whose pause is still waiting on the resume-data capture
    /// round-trip. A resume tapped inside that window is deferred to
    /// `finishPause` (via `pendingResumeIds`) so the captured data isn't
    /// dropped and the transfer restarted from byte zero.
    private var pendingPauseIds: Set<String> = []
    private var legacySessionDrainTask: Task<[String: Data], Never>?
    private var legacySessionDrained = false
    /// Resume data of transfers stopped in the pre-rename background session,
    /// keyed by `DownloadSessionDelegate.legacyTransferKey` of the file each
    /// one requested.
    private var legacySessionResumeData: [String: Data] = [:]
    private var pendingResumeIds: Set<String> = []
    /// Serializes disk saves so a rapid burst of `persist()` calls can't land
    /// out of order and overwrite a newer snapshot with an older one.
    private var saveChain: Task<Void, Never>?
    /// Offline progress entries a running flush has sent and is still
    /// waiting on. Dispatched entries outside this set are held.
    private var progressUploadsInFlight: Set<UUID> = []
    /// The last complete watch-state read applied in the active scope, and
    /// the items it covered. See `refreshWatchState()`.
    private var lastWatchStateRead: (scope: ScopeKey, at: Date, itemIds: Set<String>)?
    /// v2 has no per-item progress read, so a watch-state read costs one
    /// request per 200 entries of the profile's whole history (about 70 for a
    /// long one). Runs closer together than this reuse the last read unless a
    /// new download or queued upload needs an item it did not cover.
    nonisolated private static let watchStateReadInterval: TimeInterval = 10 * 60
    /// Claimed offline progress whose batch provably never reached the
    /// server, keyed by the scope that claimed it, when the flush lost its
    /// scope before it could resolve them. The store file is updated too;
    /// this set covers a load of that scope already in flight, and is applied
    /// and cleared when the scope's store is next installed.
    private var releasedProgressClaims: [String: Set<UUID>] = [:]
    /// Cached scope storage usage; refreshed off the MainActor (a filesystem
    /// walk) so SwiftUI bodies reading it don't block.
    private(set) var totalBytesUsed: Int64 = 0
    /// Smoothed transfer rate (bytes/sec) per downloading record, derived
    /// from progress deltas so the UI never needs its own timer competing
    /// with the `@Observable` update path.
    private(set) var transferRates: [String: Double] = [:]
    private var rateSamples: [String: TransferRateSample] = [:]
    nonisolated private static let rateSampleInterval: TimeInterval = 0.5
    nonisolated private static let rateSmoothing = 0.3
    /// Longer than this between progress callbacks means the app was
    /// suspended or the transfer stalled. The bytes of that stretch say
    /// nothing about the current speed, so the rate starts over.
    nonisolated private static let rateMaxSampleGap: TimeInterval = 3
    /// How long the background session's completion handler waits for this
    /// wake's pipelines and retries to hand off their transfers. iOS gives a
    /// background wake roughly 30 seconds.
    private static let backgroundHandoffTimeout: TimeInterval = 20
    /// Background time left for the system completion handler to run before
    /// iOS suspends the app.
    private static let backgroundTimeMargin: TimeInterval = 5
    /// Last time each record's byte counter was published into the
    /// `@Observable` `file` blob. Delegate callbacks arrive many times per
    /// second; UI counters should tick at a readable cadence instead.
    private var lastProgressPublish: [String: Date] = [:]
    private static let progressPublishInterval: TimeInterval = 1.0
    /// The most bytes each record's transfers have reached in this process,
    /// so a restart from zero isn't mistaken for recovery.
    private var progressHighWater: [String: Int64] = [:]
    private var staleStagingSwept = false
    /// How far past its earlier best a transfer must get before its retries
    /// reset.
    nonisolated private static let recoveredProgressBytes: Int64 = 8 << 20
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
    /// The running pass that reads display fields for untitled records.
    private var displayFillTask: Task<Void, Never>?
    /// Records arrived while a pass ran; another pass follows it.
    private var displayFillRequested = false
    /// Records whose display read failed in this scope; not read again until
    /// the scope changes, so a lasting failure isn't retried every poll.
    private var displayFillFailures: Set<String> = []
    private var displayFillScope: ScopeKey?
    /// The wait before another pass after one ended on a connection
    /// failure; doubles up to five minutes and resets after a pass that
    /// wasn't interrupted, or on a scope change.
    private var displayFillRetryDelay: Duration = .seconds(15)
    private var displayFillRetryTask: Task<Void, Never>?
    private static let displayFillConcurrency = 4
    /// Records whose pending status event is being sent.
    private var statusReportsInFlight: Set<String> = []
    /// The running pass over `file.pendingSubscriptionDeletes`, if any.
    private var subscriptionDeleteTask: Task<Void, Never>?
    /// Monitor DELETEs and creates that landed while other monitor requests
    /// were in flight.
    private var subscriptionWrites = SubscriptionWriteLedger()

    private init() {
        // Drain background-session events for the lifetime of the app.
        Task {
            for await event in self.sessionDelegate.events {
                self.handleSessionEvent(event)
            }
        }
        observeConnectivity()
    }

    /// Starts the queue again whenever the device regains a network path.
    /// Offline, `processQueue` leaves queued downloads waiting rather than
    /// spending their retries on requests that can't be sent.
    private func observeConnectivity() {
        let online = withObservationTracking {
            ConnectionMonitor.shared.isDeviceOnline
        } onChange: {
            Task { @MainActor in self.observeConnectivity() }
        }
        if online { processQueue() }
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
    /// the preparing indicator disappear during registration. Each pending id
    /// owns a unique token: an older request may finish after sign-out and
    /// reactivation, but its defer must never clear a newer request for the
    /// same content id.
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
    var records: [DownloadRecord] { Self.newestFirst(file.records.values) }

    /// Cheaper than `records.isEmpty`, which sorts every record first.
    var hasRecords: Bool { !file.records.isEmpty }

    /// Active records, newest first.
    var activeRecords: [DownloadRecord] {
        Self.newestFirst(file.records.values.filter { $0.localStatus.isActive })
    }

    /// Active records as the In Progress list shows them: what is moving
    /// first, then what is about to, then the queue, then paused downloads.
    var inProgressRecords: [DownloadRecord] {
        Self.sortedByActivity(file.records.values.filter { $0.localStatus.isActive })
    }

    /// Ids of `activeRecords`, without sorting.
    var activeRecordIds: Set<String> {
        Set(file.records.values.lazy.filter { $0.localStatus.isActive }.map(\.id))
    }

    /// Failed records, newest first.
    var failedRecords: [DownloadRecord] {
        Self.newestFirst(file.records.values.filter { $0.localStatus == .failed })
    }

    func hasRecord(where predicate: (DownloadRecord) -> Bool) -> Bool {
        file.records.values.contains(where: predicate)
    }

    /// Accessors filter before sorting: Downloads bodies read them several
    /// times per progress publish.
    private static func newestFirst<S: Sequence>(_ records: S) -> [DownloadRecord]
    where S.Element == DownloadRecord {
        records.sorted { $0.registeredAt > $1.registeredAt }
    }

    /// Orders active records by how close they are to moving bytes, and in
    /// queue order within each group, so a long queue never buries the
    /// downloads actually transferring.
    nonisolated static func sortedByActivity(_ records: [DownloadRecord]) -> [DownloadRecord] {
        func rank(_ record: DownloadRecord) -> Int {
            switch record.localStatus {
            case .downloading:
                if record.taskIdentifier == nil { return 2 }  // waiting to restart
                return record.bytesDownloaded > 0 ? 0 : 1
            case .fetchingAssets: return 1
            case .registering, .preparing: return 3
            case .queued: return 4
            case .paused: return 5
            case .completed, .failed, .revoked: return 6
            }
        }
        return records.sorted {
            let (a, b) = (rank($0), rank($1))
            if a != b { return a < b }
            if $0.registeredAt != $1.registeredAt { return $0.registeredAt < $1.registeredAt }
            return $0.id < $1.id
        }
    }

    var subscriptions: [DownloadSubscription] { file.subscriptions }

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

    /// Leaf content ids of downloads still on their way to this device, so
    /// the Download sheet doesn't offer an episode already coming. Cached
    /// like `downloadedContentIds` so progress ticks don't redraw views.
    private(set) var inFlightContentIds: Set<String> = []

    private func rebuildDownloadedIndex() {
        // Revoked downloads keep their on-device file (playable offline),
        // so they badge the same as completed ones.
        let ids = Set(file.records.values.filter(\.isOnDevice).map(\.leafMediaItemId))
        if ids != downloadedContentIds {
            downloadedContentIds = ids
        }
        let inFlight = Set(file.records.values.filter { $0.localStatus.isActive }.map(\.leafMediaItemId))
        if inFlight != inFlightContentIds {
            inFlightContentIds = inFlight
        }
    }

    /// Capability-aware check mirroring `isDownloaded(contentId:)`.
    func isInFlight(contentId: String) -> Bool {
        inFlightContentIds.contains(contentId) && downloadsEnabled
    }

    /// The download record for a leaf content id (movie or episode), if any.
    func record(forContentId contentId: String) -> DownloadRecord? {
        file.records.values.first { $0.contentId == contentId || $0.episodeId == contentId }
    }

    func isRegistering(contentId: String) -> Bool {
        pendingRegistrationTokens[contentId] != nil
    }

    func record(id: String) -> DownloadRecord? { file.records[id] }

    func subscription(forSeriesId seriesId: String) -> DownloadSubscription? {
        file.subscriptions.first { $0.seriesId == seriesId }
    }

    func absoluteMediaURL(for record: DownloadRecord) -> URL? {
        record.mediaFilename.flatMap { fileURL(recordId: record.id, filename: $0) }
    }

    func absoluteFileURL(for record: DownloadRecord, filename: String) -> URL? {
        fileURL(recordId: record.id, filename: filename)
    }

    /// A record's file, by path alone (no file-system calls), in the store
    /// the record was loaded from. Per-record paths go by `fileServerId`, not
    /// the active scope: while a scope switch waits on its load, `file` still
    /// holds the previous scope's records.
    private func fileURL(recordId: String, filename: String) -> URL? {
        guard !fileServerId.isEmpty else { return nil }
        return DownloadFilePaths.fileURL(
            serverId: fileServerId,
            profileId: fileProfileId,
            downloadId: recordId,
            filename: filename
        )
    }

    /// `fileURL(recordId:filename:)`, after creating the record's directory.
    private func absoluteFileURLForNewAsset(recordId: String, filename: String) -> URL? {
        guard !fileServerId.isEmpty else { return nil }
        return DownloadFilePaths.fileURLForWriting(
            serverId: fileServerId,
            profileId: fileProfileId,
            downloadId: recordId,
            filename: filename
        )
    }

    private func removeDownloadDirectory(recordId: String) {
        guard !fileServerId.isEmpty else { return }
        DownloadFilePaths.removeDownloadDirectory(
            serverId: fileServerId,
            profileId: fileProfileId,
            downloadId: recordId
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

    /// On-disk backdrop, fetched by the same asset pass as the poster; nil
    /// when the server's bundle carried none or the file is missing.
    func backdropImageURL(for record: DownloadRecord) -> URL? {
        existingFileURL(for: record, filename: record.backdropFilename)
    }

    /// On-disk title logo, when the server's bundle carried one and the file
    /// exists.
    func logoImageURL(for record: DownloadRecord) -> URL? {
        existingFileURL(for: record, filename: record.logoFilename)
    }

    /// On-disk parent series poster of an episode download. An episode's own
    /// poster is its still, so only this one suits a 2:3 series tile.
    func seriesPosterImageURL(for record: DownloadRecord) -> URL? {
        existingFileURL(for: record, filename: record.seriesPosterFilename)
    }

    /// The poster for a record's 2:3 list tile: an episode's series poster,
    /// else the record's own poster.
    func tilePosterImageURL(for record: DownloadRecord) -> URL? {
        seriesPosterImageURL(for: record) ?? posterImageURL(for: record)
    }

    /// The poster for a downloaded series: the series poster from any of its
    /// episodes, else an episode still from a download made before the server
    /// sent series posters.
    func seriesPosterImageURL(for group: DownloadSeriesGroup) -> URL? {
        let records = group.allRecords
        return records.lazy.compactMap { self.seriesPosterImageURL(for: $0) }.first
            ?? records.lazy.compactMap { self.existingFileURL(for: $0, filename: $0.posterFilename) }.first
    }

    /// Older builds recorded artwork filenames even when the write failed, so
    /// a recorded name alone does not prove the file is there.
    private func existingFileURL(for record: DownloadRecord, filename: String?) -> URL? {
        guard let url = filename.flatMap({ absoluteFileURL(for: record, filename: $0) }),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The record's current speed, or nil once its progress callbacks have
    /// stopped for longer than `rateMaxSampleGap` (a stalled or not yet
    /// started transfer), so the UI never keeps showing an old speed.
    func transferRate(id: String, at now: Date = Date()) -> Double? {
        guard let sample = rateSamples[id],
              now.timeIntervalSince(sample.at) <= Self.rateMaxSampleGap else { return nil }
        return transferRates[id]
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

    // MARK: - Grouped surface

    /// Whether this download's leaf item has been watched to completion —
    /// drives the reclaim suggestion and the "watched" episode dimming.
    func isWatched(_ record: DownloadRecord) -> Bool {
        file.localProgress[record.leafMediaItemId]?.completed == true
    }

    /// Completed/revoked records that physically occupy storage and can be
    /// browsed offline. Excludes failed and in-flight records.
    var onDeviceRecords: [DownloadRecord] {
        Self.newestFirst(file.records.values.filter(\.isOnDevice))
    }

    /// Standalone downloaded movies (no parent series).
    var movieRecords: [DownloadRecord] {
        onDeviceRecords.filter { $0.seriesId == nil }
    }

    /// Downloaded episodes grouped by series, then season.
    var seriesGroups: [DownloadSeriesGroup] {
        DownloadGroupBuilder.seriesGroups(
            from: onDeviceRecords,
            isWatched: { isWatched($0) },
            seriesTitle: { subscription(forSeriesId: $0)?.seriesTitle },
            isMonitored: { subscription(forSeriesId: $0) != nil }
        )
    }

    /// One entry of `seriesGroups`, built without grouping every series.
    func seriesGroup(forSeriesId seriesId: String) -> DownloadSeriesGroup? {
        let episodes = Self.newestFirst(
            file.records.values.filter { $0.isOnDevice && $0.seriesId == seriesId }
        )
        guard !episodes.isEmpty else { return nil }
        let monitor = subscription(forSeriesId: seriesId)
        return DownloadGroupBuilder.makeSeriesGroup(
            seriesId: seriesId,
            records: episodes,
            isWatched: { isWatched($0) },
            seriesTitle: monitor?.seriesTitle,
            isMonitored: monitor != nil
        )
    }

    /// Records downloaded *and* watched to completion — the set the
    /// "Free up space" suggestion offers to delete.
    var reclaimableRecords: [DownloadRecord] {
        onDeviceRecords.filter { $0.localStatus == .completed && isWatched($0) }
    }

    var reclaimableBytes: Int64 {
        file.records.values.reduce(0) {
            $1.localStatus == .completed && isWatched($1) ? $0 + $1.fileSize : $0
        }
    }

    /// Storage split for the hero bar: series vs movies (summed from record
    /// sizes), in-flight transfer bytes (from active records' progress —
    /// invisible to the on-disk walk while the media sits in the session's
    /// staging area), plus an "other" remainder (artwork/manifests/
    /// subtitles) derived from the true on-disk total.
    var storageBreakdown: DownloadStorageBreakdown {
        var series: Int64 = 0
        var movies: Int64 = 0
        var inProgress: Int64 = 0
        for record in file.records.values {
            if record.isOnDevice {
                if record.seriesId == nil { movies += record.fileSize }
                else { series += record.fileSize }
            } else if record.localStatus.isActive {
                inProgress += record.bytesDownloaded
            }
        }
        let other = max(0, totalBytesUsed - series - movies)
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
        // One write to `file`: each one rebuilds the indexes and the Live
        // Activity.
        var records = file.records
        var removedIds: [String] = []
        for id in ids {
            guard var record = records.removeValue(forKey: id) else { continue }
            stopActiveWork(on: &record)
            removedIds.append(id)
        }
        guard !removedIds.isEmpty else { return }
        file.records = records
        // Persist before removing files, so a crash in between never leaves a
        // record pointing at deleted media.
        persist()
        for id in removedIds {
            removeDownloadDirectory(recordId: id)
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
        await drainLegacySessionIfNeeded()
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
            // A switch away and back before the other store loaded keeps
            // this store installed, but a finish in that window was parked.
            if parkedSettle?.scope != loadedScope { startParkedSettle() }
            // Launch activates concurrently from several places; none of
            // them may reconnect before the install's settle has run.
            await awaitParkedSettle()
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
            adoptLegacySessionTasksIfNeeded()
            requeueOrphanedRecords()
            startParkedSettle()
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
        // Downloads re-queued at install start now, even in a background wake.
        // A parked file never belongs to a queued record: only a record that
        // still tracks its task is parked for, and that record isn't queued.
        processQueue()
        removeStaleStagingFilesOnce()
        await awaitParkedSettle()
        refreshStorageUsage()
        await backfillEpisodeMetadataIfNeeded()
        return true
    }

    /// Once per process, after held events have claimed their staged files.
    private func removeStaleStagingFilesOnce() {
        guard !staleStagingSwept else { return }
        staleStagingSwept = true
        Task {
            let freed = await Task.detached(priority: .utility) {
                DownloadFilePaths.removeStaleStagingFiles(olderThan: 60 * 60)
            }.value
            if freed > 0 {
                Self.logger.notice("Removed \(freed, privacy: .public) bytes of abandoned staged downloads")
            }
        }
    }

    /// A freshly installed store has no pipeline or retry running for any of
    /// its records: owners left from the previous scope are dropped, and
    /// records a pipeline or retry was working on when the process ended go
    /// back in the queue. Without this they would hold nothing but still
    /// wait for the next foreground reconcile.
    private func requeueOrphanedRecords() {
        abandonAllRestarts()
        var records = file.records
        var changed = false
        for (id, record) in records where Self.isOrphaned(record) {
            records[id]?.localStatus = .queued
            changed = true
        }
        if changed {
            file.records = records
            persist()
        }
    }

    /// Mid-pipeline, or waiting to restart a transfer, with nothing live.
    /// A record with a task identifier is left to `reconnectActiveTasks`,
    /// which knows whether the task still runs.
    nonisolated static func isOrphaned(_ record: DownloadRecord) -> Bool {
        switch record.localStatus {
        case .fetchingAssets: return true
        case .downloading: return record.taskIdentifier == nil
        default: return false
        }
    }

    /// Stops the pre-rename background session before any scope can start a
    /// transfer in the current one. Once per process; the session itself is
    /// drained once per install.
    private func drainLegacySessionIfNeeded() async {
        let task = legacySessionDrainTask ?? Task { await DownloadSessionDelegate.drainLegacySession() }
        legacySessionDrainTask = task
        let drained = await task.value
        if !legacySessionDrained {
            legacySessionDrained = true
            legacySessionResumeData = drained
        }
    }

    /// Task identifiers are only unique within one session, so identifiers a
    /// store recorded against the pre-rename session must never be matched
    /// against the current one. Clear them when the store loads; a transfer
    /// drained in this process continues from its resume data, like a paused
    /// one, and any other restarts when reconnect re-queues it.
    private func adoptLegacySessionTasksIfNeeded() {
        guard file.taskSessionIdentifier != DownloadSessionDelegate.sessionIdentifier else { return }
        let serverURL = ServerRegistry.shared.entry(with: fileServerId)?.url
        for (id, record) in file.records {
            guard record.taskIdentifier != nil else { continue }
            var record = record
            if record.localStatus == .downloading,
               let serverURL,
               let key = DownloadSessionDelegate.legacyTransferKey(APIv2Client.downloadFileURL(id: id, serverURL: serverURL)),
               let data = legacySessionResumeData.removeValue(forKey: key),
               let url = absoluteFileURLForNewAsset(recordId: id, filename: "resume.bin"),
               (try? data.write(to: url, options: .atomic)) != nil {
                record.resumeDataFilename = "resume.bin"
            }
            record.taskIdentifier = nil
            file.records[id] = record
        }
        file.taskSessionIdentifier = DownloadSessionDelegate.sessionIdentifier
        persist()
    }

    /// Starts settling the loaded scope's parked transfers, replacing the
    /// settle of any earlier install.
    private func startParkedSettle() {
        guard let scope = loadedScope else { return }
        parkedSettle = (scope, Task { @MainActor [weak self] in
            // A later install of this scope has started its own settle.
            guard let self, self.loadedScope == scope else { return }
            await self.settleParkedTransfers(serverId: scope.serverId, profileId: scope.profileId)
        })
    }

    /// Waits for the parked-transfer settle of the loaded scope's store
    /// install. Returns at once when none is running for the loaded scope.
    private func awaitParkedSettle() async {
        guard let settle = parkedSettle, settle.scope == loadedScope else { return }
        await settle.task.value
    }

    /// Settles the finished transfers parked in a scope while its store was
    /// not loaded (another profile or server was active, or the app was not
    /// running). A record that accepts its file completes; any other parked
    /// file is removed, and so is a download directory with a parked file
    /// but no record. Directories without a parked file are never touched.
    private func settleParkedTransfers(serverId: String, profileId: String) async {
        guard let scope = loadedScope, scope.serverId == serverId, scope.profileId == profileId else { return }
        let parked = await Task.detached(priority: .utility) {
            DownloadFilePaths.finishedTransfers(serverId: serverId, profileId: profileId)
        }.value
        guard !parked.isEmpty, loadedScope == scope else { return }
        // Directory names are sanitized download ids.
        let recordIds = Dictionary(
            file.records.keys.map { (DownloadFilePaths.directoryName(forDownloadId: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let fm = FileManager.default
        for (directoryName, url) in parked {
            let recordId = recordIds[directoryName]
            let tag = DownloadTaskTag(serverId: serverId, profileId: profileId, downloadId: recordId ?? directoryName)
            // Evaluated against the current `file`: a live finish may have
            // completed the record since the scan.
            let disposition = Self.finishedTransferDisposition(
                tag: tag,
                loadedServerId: scope.serverId,
                loadedProfileId: scope.profileId,
                record: recordId.flatMap { file.records[$0] }
            )
            switch disposition {
            case .complete:
                if let recordId { completeFinishedTransfer(recordId: recordId, from: url) }
            case .discardFile:
                try? fm.removeItem(at: url)
            case .discardDirectory:
                // The original id is unknown when no record matched, so the
                // directory goes by the URL the scan found.
                try? fm.removeItem(at: url.deletingLastPathComponent())
            case .keepForOwner:
                break
            }
        }
        refreshStorageUsage()
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
        sessionDelegate.refreshProgressDelivery()
        await refreshCapability()
        onCapabilityRefreshed?()
        guard downloadsEnabled else { return }
        await reconcileWithServer(triggerPipeline: true)
        await runMonitoringAndProgressSync()
        await refreshSavedSubtitles()
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
        displayFillRetryTask?.cancel()
        displayFillRetryTask = nil
        abandonAllRestarts()
        progressHighWater.removeAll()
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
        parkedSettle = nil
        rateSamples.removeAll()
        transferRates.removeAll()
        totalBytesUsed = 0
    }

    private func cancelActiveTasks() {
        let servers = attributionServers
        for record in file.records.values where record.localStatus == .downloading {
            if let taskId = record.taskIdentifier, let owner = ownedTag(recordId: record.id) {
                intentionalCancels.insert(IntentionalCancel(taskId: taskId, owner: owner))
                sessionDelegate.cancel(taskId: taskId, expecting: owner, servers: servers)
            }
        }
    }

    // MARK: - Background relaunch

    /// Store the system completion handler delivered when iOS relaunches
    /// the app to finish background events.
    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
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

    func downloadSeason(seriesId: String, seasonNumber: Int, quality: String? = nil) async throws {
        try await requestDownload(contentId: seriesId, quality: quality, series: true, seasonNumber: seasonNumber,
            seriesId: seriesId)
    }

    func downloadSeries(seriesId: String, quality: String? = nil) async throws {
        try await requestDownload(contentId: seriesId, quality: quality, series: true, seriesId: seriesId)
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
        beginContinuedProcessing(title: displayTitle)
        defer {
            finishPendingRegistration(
                contentId: registrationContentId,
                token: registrationToken
            )
            // A registration that added nothing leaves the queue as it was;
            // let the live progress settle on that.
            syncLiveActivity()
        }

        guard let owner = await captureScopeOwner(), owner.generation == capturedScopeGeneration else {
            throw DownloadError.scopeChangedDuringRegistration
        }
        let isBatch = series || seasonNumber != nil
        do {
            if isBatch {
                try await createSeriesPages(seriesId: contentId, seasonNumber: seasonNumber,
                    quality: batchQuality(requestedQuality), owner: owner)
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
    private func createSeriesPages(seriesId: String, seasonNumber: Int?, quality: String,
                                   owner: ScopeOwner) async throws {
        let request = APIv2DownloadCreateRequest.seriesPage(
            seriesId: seriesId,
            seasonNumber: seasonNumber,
            batchId: UUID().uuidString.lowercased(),
            caps: DownloadCaps.current(),
            quality: quality
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
        // One write to `file`: a series page can carry many entries.
        var records = file.records
        for entry in entries {
            upsertRow(
                entry,
                into: &records,
                displayTitle: entries.count == 1 ? displayTitle : nil,
                displaySubtitle: entries.count == 1 ? displaySubtitle : nil,
                type: type,
                seriesId: seriesId,
                posterThumbhash: entries.count == 1 ? posterThumbhash : nil
            )
        }
        file.records = records
        persist()
        processQueue()
        ensurePolling()
        fillMissingDisplay()
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
    }

    private func finishPendingRegistration(contentId: String, token: UUID) {
        guard pendingRegistrationTokens[contentId] == token else { return }
        pendingRegistrationTokens.removeValue(forKey: contentId)
    }

    private func resolvedDownloadQuality(_ requestedQuality: String?) -> String {
        let allowed = capability?.qualityPresets ?? []
        if let requestedQuality, allowed.contains(requestedQuality) {
            return requestedQuality
        }
        return DownloadSettings.shared.resolvedFormat(allowedFormats: allowed)
    }

    /// Whether season and series batches take a quality other than original.
    var canChooseBatchQuality: Bool { capability?.bulkQuality == true }

    /// Whether monitors take a quality other than original.
    var canChooseMonitorQuality: Bool { capability?.monitorQuality == true }

    /// A batch's quality. A server without `bulkQuality` takes original only.
    private func batchQuality(_ requestedQuality: String?) -> String {
        canChooseBatchQuality ? resolvedDownloadQuality(requestedQuality) : DownloadFormat.original.rawValue
    }

    /// The quality a monitor write sends, or nil for a server without
    /// `monitorQuality`, which would not accept the field.
    private func monitorQuality(_ requestedQuality: String?) -> String? {
        canChooseMonitorQuality ? resolvedDownloadQuality(requestedQuality) : nil
    }

    func deleteDownload(id: String) {
        deleteDownloads(ids: [id])
    }

    /// Suspend an in-flight media transfer. The status flips to `.paused`
    /// synchronously (so the UI responds on the tap) and the resume data is
    /// captured asynchronously — the task identifier stays on the record
    /// until then. A transfer that finishes during the race still completes
    /// normally: a finish completes a `.paused` record that has no media.
    func pauseDownload(id: String) {
        guard var record = file.records[id], record.localStatus == .downloading,
              let owner = ownedTag(recordId: id) else { return }
        guard let taskId = record.taskIdentifier else {
            // No live task: the record is waiting out a retry back-off.
            // Abort the timer and park the record so the pause control isn't
            // dead during the window; resume re-queues from scratch.
            cancelRetry(recordId: id)
            record.localStatus = .paused
            file.records[id] = record
            clearTransferRate(recordId: id)
            persist()
            processQueue()
            return
        }
        let claim = IntentionalCancel(taskId: taskId, owner: owner)
        intentionalCancels.insert(claim)
        pendingPauseIds.insert(id)
        record.localStatus = .paused
        file.records[id] = record
        clearTransferRate(recordId: id)
        persist()
        let servers = attributionServers
        Task {
            let data = await self.sessionDelegate.pause(taskId: taskId, expecting: owner, servers: servers)
            self.finishPause(recordId: id, resumeData: data, claim: claim)
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
        beginContinuedProcessing(title: record.title)
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
    ///
    /// Only the record `claim` was made for is changed, and only while it
    /// still names the paused task: `file` may hold another scope by now.
    ///
    /// Once that record stops naming the task, its failure event matches no
    /// record, so the pause's `claim` is dropped here too: a pause that found
    /// no task to cancel gets no failure event, and its claim must not
    /// outlive it. The claim stays while the record may still name the task
    /// (it isn't paused, or its store isn't loaded): the cancelled task's
    /// failure event can arrive after this, and must not read as a failure.
    private func finishPause(recordId: String, resumeData: Data?, claim: IntentionalCancel) {
        pendingPauseIds.remove(recordId)
        let resumeRequested = pendingResumeIds.remove(recordId) != nil
        guard ownedTag(recordId: recordId) == claim.owner else { return }
        guard var record = file.records[recordId], record.taskIdentifier == claim.taskId else {
            intentionalCancels.remove(claim)
            return
        }
        guard record.localStatus == .paused else { return }
        intentionalCancels.remove(claim)
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
        beginContinuedProcessing(title: record.title)
        record.localStatus = .queued
        record.retryCount = 0
        record.lastError = nil
        file.records[id] = record
        persist()
        processQueue()
    }

    // MARK: - Pipeline

    private func processQueue() {
        guard ConnectionMonitor.shared.isDeviceOnline else { return }
        let transferring = file.records.values.filter {
            $0.localStatus == .downloading && $0.taskIdentifier != nil
        }.count
        var slots = Self.queueSlots(
            runningPipelines: restartOwners.pipelineCount,
            transferring: transferring,
            limit: DownloadSettings.shared.simultaneousDownloads
        )
        guard slots.pipelines > 0, slots.transfers > 0 else { return }

        let queued = file.records.values
            .filter { $0.localStatus == .queued }
            .sorted { $0.registeredAt < $1.registeredAt }

        for record in queued where slots.pipelines > 0 && slots.transfers > 0 {
            guard !exceedsStorageCap(for: record) else { continue }
            if startQueuedRecord(record) { slots.pipelines -= 1 }
            slots.transfers -= 1
        }
    }

    /// How many more queued records may start now: a pipeline slot for the
    /// manifest fetch, and room among the `limit` transfers the session runs
    /// at once (counting pipelines about to start one). More transfers would
    /// split the bandwidth so thinly that every file crawls, and their
    /// progress callbacks alone keep the app busy. A retry waiting out its
    /// back-off holds neither slot.
    nonisolated static func queueSlots(
        runningPipelines: Int, transferring: Int, limit: Int
    ) -> (pipelines: Int, transfers: Int) {
        (max(0, maxConcurrentPipelines - runningPipelines),
         max(0, limit - transferring - runningPipelines))
    }

    /// Puts transfers beyond the simultaneous-downloads limit back in the
    /// queue, newest first, keeping their resume data; they continue as the
    /// others finish. Then starts whatever the limit allows.
    func applyTransferLimit() {
        let limit = DownloadSettings.shared.simultaneousDownloads
        let transferring = file.records.values
            .filter { $0.localStatus == .downloading && $0.taskIdentifier != nil }
            .sorted { $0.registeredAt < $1.registeredAt }
        for record in transferring.dropFirst(limit) {
            // A pause whose resume was already requested lands back in the
            // queue with its data (`finishPause`).
            pendingResumeIds.insert(record.id)
            pauseDownload(id: record.id)
        }
        // A running pipeline starts a transfer when it finishes, so it
        // counts against the limit too (`queueSlots`).
        let preparing = file.records.values
            .filter { $0.localStatus == .fetchingAssets && restartOwners.hasPipeline($0.id) }
            .sorted { $0.registeredAt < $1.registeredAt }
        for record in preparing.dropFirst(max(0, limit - transferring.count)) {
            abandonPipeline(recordId: record.id)
            setLocalStatus(.queued, id: record.id)
        }
        processQueue()
    }

    /// Start one queued record, preferring its captured resume data (a
    /// paused transfer) so completed byte ranges aren't refetched; missing
    /// or unreadable data, or data for a retired file URL, falls back to the
    /// full pipeline restart.
    /// Returns whether the record took a pipeline slot; a resume from
    /// captured data goes straight to the session.
    private func startQueuedRecord(_ record: DownloadRecord) -> Bool {
        var record = record
        // Whatever was working on this record before is superseded.
        abandonPipeline(recordId: record.id)
        if let staleTask = record.taskIdentifier {
            // A task still recorded for a queued record is stale. Stop it
            // before starting the replacement so the two never both write.
            // Its failure event then matches no record. The ID isn't marked
            // as an intentional cancel: after a relaunch it can belong to
            // another record's task, whose real failure must still count.
            sessionDelegate.cancel(taskId: staleTask, ifDownloading: record.id)
            record.taskIdentifier = nil
            file.records[record.id] = record
        }
        if let filename = record.resumeDataFilename,
           let url = absoluteFileURL(for: record, filename: filename) {
            let resumeData = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            record.resumeDataFilename = nil
            if let resumeData, let tag = ownedTag(recordId: record.id),
               let taskId = sessionDelegate.resume(data: resumeData, tag: tag) {
                record.taskIdentifier = taskId
                record.localStatus = .downloading
                file.records[record.id] = record
                persist()
                return false
            }
            record.bytesDownloaded = 0
            file.records[record.id] = record
        }
        setLocalStatus(.fetchingAssets, id: record.id)
        let token = claimPipeline(recordId: record.id)
        Task { await self.startMediaPipeline(recordId: record.id, token: token) }
        return true
    }

    /// Fetches the manifest and starts the file transfer, under the scope
    /// owner captured here. Once that scope is gone, nothing a request
    /// returns is applied: the record belongs to a store that is no longer
    /// loaded. The pipeline runs only while it holds the record's `token`,
    /// and releases it (and its queue slot) once the transfer starts; the
    /// artwork and subtitles follow under their own claim.
    private func startMediaPipeline(recordId: String, token: UUID) async {
        var parked = false
        defer {
            releasePipeline(recordId: recordId, token: token)
            // A pipeline that parked its own record (no usable session, or
            // no network) leaves it for the next activation or reconnect:
            // starting the queue now would pick the same record right back up.
            if !parked { processQueue() }
        }
        guard ownsPipeline(recordId, token), file.records[recordId] != nil else { return }
        guard let owner = await captureScopeOwner() else {
            // No usable session for this scope right now. Park the record;
            // the next queue pass or reconcile starts it again.
            if ownsPipeline(recordId, token), file.records[recordId]?.localStatus == .fetchingAssets {
                setLocalStatus(.queued, id: recordId)
                parked = true
            }
            return
        }
        let manifest: OfflineManifest
        do {
            manifest = try await SiloAPI.shared.apiV2Client.downloadManifest(id: recordId, auth: owner.auth)
        } catch {
            // A reconcile may have failed or revoked the record meanwhile.
            guard pipelineIsCurrent(recordId, token, owner),
                  file.records[recordId]?.localStatus == .fetchingAssets else { return }
            parked = handlePipelineError(error, recordId: recordId)
            return
        }
        guard pipelineIsCurrent(recordId, token, owner) else { return }
        await persistManifest(manifest, recordId: recordId, token: token)
        guard pipelineIsCurrent(recordId, token, owner) else { return }
        applyManifestDisplay(manifest, recordId: recordId)
        // The media transfer first, so bytes start moving at once; artwork
        // and subtitles are small and follow while it runs.
        switch await startMediaTransfer(recordId: recordId, owner: owner, token: token) {
        case .parked:
            parked = true
        case .stopped:
            break
        case .started:
            // Claimed before the pipeline lets go, so a retry or a resume from
            // saved data can't cut the assets off, and a fast transfer that
            // finishes first still gets them.
            let assets = restartOwners.claimAssets(recordId)
            updateHandoffBackgroundTask()
            Task { await self.fetchAssets(manifest, recordId: recordId, owner: owner, assets: assets) }
        }
    }

    /// How a pipeline's attempt to start the file transfer ended.
    private enum TransferStart {
        case started
        /// Back in the queue until a session or the network returns.
        case parked
        /// Superseded, failed, or retrying.
        case stopped
    }

    private func startMediaTransfer(recordId: String, owner: ScopeOwner, token: UUID) async -> TransferStart {
        // The owner's current credentials: a token rotated since the capture
        // is used, a different owner is not.
        let auth = await TokenStore.shared.currentOrdinaryRequestAuth(matchingIdentityOf: owner.auth)
        // Only the record's own pipeline, and only while the record still
        // waits for it: a reconcile may have revoked or failed it meanwhile.
        guard pipelineIsCurrent(recordId, token, owner), var record = file.records[recordId],
              record.localStatus == .fetchingAssets, record.taskIdentifier == nil else { return .stopped }
        guard let auth else {
            return handlePipelineError(HTTPError.requestIdentityChanged, recordId: recordId) ? .parked : .stopped
        }
        guard let fileURL = APIv2Client.downloadFileURL(id: recordId, serverURL: auth.account.serverURL) else {
            return handlePipelineError(DownloadError.fileURLUnavailable, recordId: recordId) ? .parked : .stopped
        }
        let request = DownloadAuthHeaders.authorizedRequest(
            url: fileURL,
            auth: auth,
            allowsCellular: !DownloadSettings.shared.wifiOnly
        )
        let tag = DownloadTaskTag(serverId: owner.scope.serverId, profileId: owner.scope.profileId, downloadId: recordId)
        let taskId = sessionDelegate.start(request: request, tag: tag)
        record.taskIdentifier = taskId
        record.localStatus = .downloading
        record.pendingStatusEvent = Self.statusEvent(.downloading, for: record)
        file.records[recordId] = record
        persist()
        reportPendingStatusEvents()
        return .started
    }

    private func persistManifest(_ manifest: OfflineManifest, recordId: String, token: UUID) async {
        guard let url = absoluteFileURLForNewAsset(recordId: recordId, filename: "manifest.json") else { return }
        await DownloadStore.shared.saveManifest(manifest, to: url)
        // A delete or new revision during the save owns the record now.
        guard ownsPipeline(recordId, token) else { return }
        if var record = file.records[recordId] {
            record.manifestFilename = "manifest.json"
            file.records[recordId] = record
        }
    }

    /// The fields a list row shows. Never overwrites what the record
    /// already has, and touches nothing the transfer depends on.
    nonisolated static func applyDisplayFields(_ manifest: OfflineManifest, to record: inout DownloadRecord) {
        record.title = record.title ?? manifest.title
        record.type = record.type ?? manifest.type
        record.posterThumbhash = record.posterThumbhash ?? manifest.posterThumbhash
        record.seriesPosterThumbhash = record.seriesPosterThumbhash ?? manifest.seriesPosterThumbhash
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
    }

    private func applyManifestDisplay(_ manifest: OfflineManifest, recordId: String) {
        guard var record = file.records[recordId] else { return }
        Self.applyDisplayFields(manifest, to: &record)
        record.type = manifest.type
        record.format = manifest.quality
        record.effectiveQuality = manifest.effectiveQuality
        record.deliveryFormat = manifest.deliveryFormat
        record.targetBitrateKbps = manifest.targetBitrateKbps
        record.revision = manifest.revision ?? record.revision
        record.container = manifest.container
        record.seriesPosterThumbhash = manifest.seriesPosterThumbhash ?? record.seriesPosterThumbhash
        record.stableIdentity = manifest.stableIdentity
        if record.fileSize <= 0, let size = manifest.fileSize { record.fileSize = size }
        record.expectedBytes = manifest.integrity?.expectedBytes
        file.records[recordId] = record
        persist()
    }

    /// Saves the manifest's artwork and subtitles while the transfer runs.
    /// A delete, revoke, new revision, or scope change stops it saving.
    private func fetchAssets(_ manifest: OfflineManifest, recordId: String, owner: ScopeOwner, assets: UUID) async {
        defer {
            restartOwners.releaseAssets(recordId, assets)
            updateHandoffBackgroundTask()
        }
        await fetchArtwork(manifest, recordId: recordId, owner: owner, assets: assets)
        await fetchSubtitles(manifest, recordId: recordId, owner: owner, assets: assets)
    }

    private func assetsAreCurrent(_ recordId: String, _ assets: UUID, _ owner: ScopeOwner) -> Bool {
        restartOwners.ownsAssets(recordId, assets) && isCurrent(owner)
    }

    private func fetchArtwork(_ manifest: OfflineManifest, recordId: String, owner: ScopeOwner, assets: UUID) async {
        let kinds: [(kind: String, path: String?, filename: String)] = [
            ("poster", manifest.artworkUrls?.poster, "poster.jpg"),
            ("backdrop", manifest.artworkUrls?.backdrop, "backdrop.jpg"),
            ("logo", manifest.artworkUrls?.logo, "logo.png"),
            ("series_poster", manifest.artworkUrls?.seriesPoster, "series_poster.jpg"),
        ]
        // Saved kinds go into the record in one write after the loop: each
        // write to `file` rebuilds the indexes and the Live Activity.
        var saved: [String] = []
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
            guard assetsAreCurrent(recordId, assets, owner) else { return }
            guard !data.isEmpty,
                  let url = absoluteFileURLForNewAsset(recordId: recordId, filename: entry.filename) else {
                continue
            }
            // Record the file only once it is on disk: the offline detail page
            // shows a recorded logo in place of the title text.
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                Self.logger.warning("download artwork write failed")
                continue
            }
            saved.append(entry.kind)
        }
        // A failed fetch above can end the loop after an await.
        guard assetsAreCurrent(recordId, assets, owner) else { return }
        if !saved.isEmpty, var record = file.records[recordId] {
            for entry in kinds where saved.contains(entry.kind) {
                switch entry.kind {
                case "poster": record.posterFilename = entry.filename
                case "backdrop": record.backdropFilename = entry.filename
                case "logo": record.logoFilename = entry.filename
                case "series_poster": record.seriesPosterFilename = entry.filename
                default: break
                }
            }
            file.records[recordId] = record
        }
        persist()
    }

    private func fetchSubtitles(_ manifest: OfflineManifest, recordId: String, owner: ScopeOwner, assets: UUID) async {
        guard let subtitles = manifest.subtitles, !subtitles.isEmpty else { return }
        for (index, subtitle) in subtitles.enumerated() {
            let ext = (subtitle.format ?? "srt").lowercased()
            let filename = "sub_\(index).\(ext)"
            let data: Data
            let entityTag: String?
            do {
                let result = try await SiloAPI.shared.apiV2Client.revalidateDownloadSubtitle(
                    path: subtitle.fetchUrl, downloadId: recordId, entityTag: nil, auth: owner.auth)
                guard case .changed(let body, let tag) = result else { continue }
                data = body
                entityTag = tag
            } catch {
                Self.logger.warning("download subtitle fetch failed: \(String(describing: error), privacy: .public)")
                continue
            }
            guard assetsAreCurrent(recordId, assets, owner) else { return }
            guard !data.isEmpty,
                  let url = absoluteFileURLForNewAsset(recordId: recordId, filename: filename),
                  (try? data.write(to: url, options: .atomic)) != nil,
                  var record = file.records[recordId] else {
                continue
            }
            record.subtitleFilenames[subtitle.fetchUrl] = filename
            record.setSubtitleEntityTag(entityTag, for: subtitle.fetchUrl)
            record.setSubtitleRevision(subtitle.revision, for: subtitle.fetchUrl)
            file.records[recordId] = record
        }
        persist()
    }

    /// When saved subtitles were last refreshed in this process, and for
    /// which scope: another server or profile is refreshed on its own.
    private var lastSavedSubtitleRefresh: (scope: ScopeKey, at: Date)?
    private static let savedSubtitleRefreshInterval: TimeInterval = 15 * 60

    /// Fetches again each saved subtitle of a finished download whose bytes
    /// changed on the server since it was saved. The server applies a
    /// subtitle's timing correction when it delivers the file, so a sync or a
    /// timing change (or an external file edited on disk) changes those bytes
    /// under the same reference; the download's manifest then shows the
    /// subtitle with another `revision`. The fetch is conditional, so bytes
    /// that did not change answer 304.
    private func refreshSavedSubtitles() async {
        if let last = lastSavedSubtitleRefresh, last.scope == loadedScope,
           Date().timeIntervalSince(last.at) < Self.savedSubtitleRefreshInterval { return }
        guard let owner = await captureScopeOwner() else { return }
        let started = Date()
        lastSavedSubtitleRefresh = (owner.scope, started)
        var failed = false
        // Offline or interrupted: ask again on the next activation. Only this
        // scan's mark is cleared, never one a later scan or scope set.
        defer {
            if failed, let last = lastSavedSubtitleRefresh, last.scope == owner.scope, last.at == started {
                lastSavedSubtitleRefresh = nil
            }
        }
        let candidates = file.records.values
            .filter { $0.localStatus == .completed && !$0.subtitleFilenames.isEmpty }
            .sorted { $0.id < $1.id }
        for record in candidates {
            // A pipeline may have taken the record over while earlier records
            // were being checked; never take its assets from it.
            guard file.records[record.id]?.localStatus == .completed,
                  !restartOwners.fetchesAssets(record.id) else { continue }
            let manifest: OfflineManifest
            do {
                manifest = try await SiloAPI.shared.apiV2Client.downloadManifest(id: record.id, auth: owner.auth)
            } catch {
                Self.logger.warning("saved subtitle manifest read failed: \(String(describing: error), privacy: .public)")
                // Only an unanswered read is retried at the next activation; a
                // refused one (the entry is gone) waits for the interval.
                if Self.isTransientPipelineFailure(error) { failed = true }
                continue
            }
            // The server or profile changed while the manifest was read.
            guard isCurrent(owner) else { return }
            // A newer entry revision replaces every asset through reconcile;
            // these subtitles would belong to the replaced bytes.
            guard let current = file.records[record.id], current.localStatus == .completed,
                  current.revision == nil || manifest.revision == current.revision,
                  !restartOwners.fetchesAssets(record.id) else { continue }
            let refreshes = (manifest.subtitles ?? []).filter {
                Self.savedSubtitleNeedsRefresh($0, in: current)
            }
            guard !refreshes.isEmpty else { continue }
            let assets = restartOwners.claimAssets(record.id)
            defer { restartOwners.releaseAssets(record.id, assets) }
            var changed = false
            for subtitle in refreshes {
                let result: DownloadSubtitleRevalidation
                do {
                    result = try await SiloAPI.shared.apiV2Client.revalidateDownloadSubtitle(
                        path: subtitle.fetchUrl, downloadId: record.id,
                        entityTag: file.records[record.id]?.subtitleEntityTags?[subtitle.fetchUrl], auth: owner.auth)
                } catch {
                    Self.logger.warning("saved subtitle refresh failed: \(String(describing: error), privacy: .public)")
                    if Self.isTransientPipelineFailure(error) { failed = true }
                    continue
                }
                guard assetsAreCurrent(record.id, assets, owner) else { break }
                guard var current = file.records[record.id],
                      let filename = current.subtitleFilenames[subtitle.fetchUrl] else { continue }
                if case .changed(let data, let entityTag) = result {
                    guard !data.isEmpty, let url = absoluteFileURLForNewAsset(recordId: current.id, filename: filename),
                          (try? data.write(to: url, options: .atomic)) != nil else {
                        Self.logger.warning("saved subtitle rewrite failed")
                        failed = true
                        continue
                    }
                    current.setSubtitleEntityTag(entityTag, for: subtitle.fetchUrl)
                }
                current.setSubtitleRevision(subtitle.revision, for: subtitle.fetchUrl)
                file.records[record.id] = current
                changed = true
            }
            // Saved per download: a scope change stops the scan, and nothing
            // saves the store it leaves.
            if changed { persist() }
        }
    }

    /// Whether a subtitle the refreshed manifest lists should be fetched
    /// again: it is saved, and its `revision` differs from the one its saved
    /// bytes belong to. A server that publishes no revision is asked about
    /// stored subtitles only, by ETag; its external subtitles never change.
    static func savedSubtitleNeedsRefresh(_ subtitle: OfflineSubtitle, in record: DownloadRecord) -> Bool {
        guard record.subtitleFilenames[subtitle.fetchUrl] != nil else { return false }
        if let revision = subtitle.revision {
            return record.subtitleRevisions?[subtitle.fetchUrl] != revision
        }
        return isStoredSubtitleReference(subtitle.fetchUrl)
    }

    /// Whether a manifest `fetch_url` names a stored subtitle
    /// (`.../subtitles/downloaded:{id}`), whose bytes follow its timing.
    static func isStoredSubtitleReference(_ fetchUrl: String) -> Bool {
        guard let last = URLComponents(string: fetchUrl)?.path.split(separator: "/").last else { return false }
        return last.hasPrefix("downloaded:")
    }

    /// Returns whether the record was parked back in the queue to wait for
    /// a usable session or the network, rather than retried or failed.
    private func handlePipelineError(_ error: Error, recordId: String) -> Bool {
        guard var record = file.records[recordId] else { return false }
        record.taskIdentifier = nil
        if case HTTPError.requestIdentityChanged = error {
            // The session changed under the request; nothing was applied.
            // Park the record for the next queue pass.
            record.localStatus = .queued
            file.records[recordId] = record
            persist()
            return true
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
                // Bounded back-off, like a failed transfer.
                if record.retryCount < Self.maxRetries {
                    record.retryCount += 1
                    file.records[recordId] = record
                    scheduleRetry(recordId: recordId, refreshToken: false)
                } else {
                    record.localStatus = .failed
                    record.lastError = "http_\(statusCode)"
                    file.records[recordId] = record
                    persist()
                    processQueue()
                }
                return false
            default:
                record.localStatus = .failed
                record.lastError = "http_\(statusCode)"
            }
        } else if Self.isTransientPipelineFailure(error), !ConnectionMonitor.shared.isDeviceOnline {
            // No network: wait in the queue without spending a retry. The
            // queue starts again when the device is back online.
            record.localStatus = .queued
            file.records[recordId] = record
            persist()
            return true
        } else if Self.isTransientPipelineFailure(error), record.retryCount < Self.maxRetries {
            // Same bounded back-off as a 5xx: the request never got an
            // answer, often because iOS suspended the app mid-request.
            record.retryCount += 1
            file.records[recordId] = record
            scheduleRetry(recordId: recordId, refreshToken: false)
            return false
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
        return false
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

    /// Past the furthest point any earlier attempt reached, a transfer has
    /// recovered, so its earlier failures stop counting against the retry
    /// limit. A restart from zero doesn't qualify until it gets further than
    /// before. While retries are counted, that point stays where the failed
    /// attempt left it; otherwise it follows the transfer.
    nonisolated static func recoveryProgress(
        retryCount: Int, furthest: Int64, written: Int64
    ) -> (retryCount: Int, furthest: Int64) {
        if retryCount > 0, written <= furthest + recoveredProgressBytes {
            return (retryCount, furthest)
        }
        return (0, max(furthest, written))
    }

    /// Whether a manifest request failed in transport (the connection dropped,
    /// timed out, or was never made) rather than being answered or cancelled.
    nonisolated static func isTransientPipelineFailure(_ error: Error) -> Bool {
        var transport = error
        if case HTTPError.network(let underlying) = error { transport = underlying }
        guard let urlError = transport as? URLError else { return false }
        return urlError.code != .cancelled
    }

    /// Mirror the active queue into the lock-screen Live Activity. Hooked
    /// into `file`'s `didSet` so every mutation flows through — including
    /// scope deactivation (empty blob ends the activity). The controller
    /// dedupes identical content states, so burst mutations (reconcile
    /// loops, pipeline steps) cost a snapshot build and nothing more. Also
    /// called when continued processing hands the live progress back.
    func syncLiveActivity() {
        #if os(iOS)
        let completedIds = Set(
            file.records.values
                .filter { $0.localStatus == .completed }
                .map(\.id)
        )
        let active = activeRecords
        // Stalled transfers have no rate, so they add nothing.
        let rates = active.reduce(into: [String: Double]()) { result, record in
            if let rate = transferRate(id: record.id) { result[record.id] = rate }
        }
        DownloadLiveActivityController.shared.sync(
            activeRecords: active,
            completedRecordIds: completedIds,
            totalBytesPerSecond: active.compactMap { rates[$0.id] }.reduce(0, +),
            awaitingRegistration: !pendingRegistrationTokens.isEmpty,
            // Downloads of unknown size move too.
            transferredBytes: active.reduce(Int64(0)) { $0 + $1.bytesDownloaded },
            rates: rates
        )
        #endif
    }

    /// What the active downloads wait for right now, if anything, in the
    /// system progress.
    func currentWaitingReason() -> String? {
        if let wait = networkWait() { return wait.label }
        if activeRecords.contains(where: { $0.localStatus == .preparing || $0.localStatus == .registering }) {
            return "Preparing on server"
        }
        return nil
    }

    #if os(iOS)
    /// Whether the Downloads tab should offer to show live progress on the
    /// Lock Screen: transfers are running and nothing shows them there.
    var canShowProgressOnLockScreen: Bool {
        guard #available(iOS 26, *) else { return false }
        return !DownloadContinuedProcessing.shared.ownsProgress
            && activeRecords.contains { $0.localStatus == .downloading }
    }

    /// Starts the system's live progress for the running downloads. Call
    /// only from the user's tap.
    func showProgressOnLockScreen() {
        let headline = DownloadLiveActivityController.headline(of: activeRecords)
        DownloadContinuedProcessing.shared.begin(title: headline?.title ?? "Downloads")
        syncLiveActivity()
    }
    #endif

    /// Silo is on screen: progress the user hid from the Lock Screen comes
    /// back as Silo's own Live Activity, which only the foreground can start.
    func sceneDidBecomeActive() {
        #if os(iOS)
        DownloadContinuedProcessing.shared.clearDismissal()
        syncLiveActivity()
        #endif
    }

    /// Why a record isn't moving, when that is something the user can see
    /// and act on.
    enum Wait: Equatable {
        /// The device has no network.
        case connection
        /// Wi-Fi only is on and the device isn't on Wi-Fi.
        case wifi
        /// The series' storage limit holds this download back.
        case storageLimit

        var label: String {
            switch self {
            case .connection: return "Waiting for a connection"
            case .wifi: return "Waiting for Wi-Fi"
            case .storageLimit: return "Series storage limit reached"
            }
        }
    }

    func wait(for record: DownloadRecord) -> Wait? {
        switch record.localStatus {
        case .queued:
            if exceedsStorageCap(for: record) { return .storageLimit }
            return networkWait()
        case .downloading, .fetchingAssets:
            return networkWait()
        default:
            return nil
        }
    }

    private func networkWait() -> Wait? {
        let monitor = ConnectionMonitor.shared
        if !monitor.isDeviceOnline { return .connection }
        if DownloadSettings.shared.wifiOnly, !monitor.isOnWiFiOrWired { return .wifi }
        return nil
    }

    /// Keeps Silo running with live system progress for a download the user
    /// just started (iOS 26 and later). Call only from the user's action.
    private func beginContinuedProcessing(title: String?) {
        #if os(iOS)
        DownloadContinuedProcessing.shared.begin(title: title ?? "Downloads")
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
        // session replays its buffered events immediately. A finished file
        // is already parked on disk under its owner, so the hold no longer
        // protects media; it keeps early progress and failure events for the
        // first loaded scope, which would otherwise be dropped.
        guard !sessionEventsHeld else {
            pendingSessionEvents.append(event)
            return
        }
        switch event {
        case let .progress(ref, written, total, at):
            // Only the task the record tracks: a cancelled predecessor's
            // buffered progress would overwrite the replacement's counters.
            guard var record = loadedRecord(for: resolveTag(ref)), record.localStatus == .downloading,
                  record.taskIdentifier == ref.taskId else { return }
            updateTransferRate(recordId: record.id, bytes: written, at: at)
            // Publish to the observable blob at a readable cadence — the raw
            // callbacks fire many times per second and each reassignment
            // redraws every byte counter "live". Skipped ticks lose nothing:
            // `written` is cumulative, so the next publish catches up.
            let now = Date()
            guard now.timeIntervalSince(lastProgressPublish[record.id] ?? .distantPast)
                >= Self.progressPublishInterval else { return }
            lastProgressPublish[record.id] = now
            let recovery = Self.recoveryProgress(
                retryCount: record.retryCount,
                furthest: progressHighWater[record.id] ?? record.bytesDownloaded,
                written: written
            )
            record.retryCount = recovery.retryCount
            progressHighWater[record.id] = recovery.furthest
            record.bytesDownloaded = written
            if total > 0 { record.fileSize = total }
            file.records[record.id] = record
            persistProgressThrottled()

        case let .finished(ref, fileURL):
            handleMediaFinished(ref, fileURL: fileURL)

        case let .failed(ref, statusCode, resumeData, message, cause):
            handleMediaFailure(ref, statusCode: statusCode, resumeData: resumeData, message: message, cause: cause)

        case .allEventsDelivered:
            // iOS can suspend the process as soon as the completion handler
            // runs. First let the parked-transfer settle of the store just
            // installed complete its records, or the next launch downloads
            // them again. Then let the pipelines and imminent retries this
            // wake started (the next queued downloads) hand their transfers
            // to the session, or they stop mid-pipeline until the app is next
            // opened. Then flush the store writes still on the async save
            // chain.
            guard let handler = backgroundCompletionHandler else { return }
            backgroundCompletionHandler = nil
            Task {
                await self.parkedSettle?.task.value
                await self.waitForTransferHandoff(timeout: Self.backgroundHandoffTimeout)
                await self.saveChain?.value
                handler()
            }
        }
    }

    /// Replay events held during launch, in arrival order, now that the
    /// registry reflects the active scope (or the lack of one, in which case
    /// finished files stay parked for their owners).
    private func releaseHeldSessionEvents() {
        guard sessionEventsHeld else { return }
        sessionEventsHeld = false
        let held = pendingSessionEvents
        pendingSessionEvents = []
        for event in held {
            handleSessionEvent(event)
        }
    }

    /// Routes a finished file to its owner. `fileURL` is the owner's parked
    /// path for a tagged task, or a staging file for an untagged one.
    private func handleMediaFinished(_ ref: DownloadTaskRef, fileURL: URL) {
        let tag = resolveTag(ref)
        if let tag { intentionalCancels.remove(IntentionalCancel(taskId: ref.taskId, owner: tag)) }
        // Decided against `loadedScope`, never `scopeServerId`: while a switch
        // waits on its load, `scopeServerId` already names the new scope but
        // `file` still holds the old one.
        let scope = loadedScope
        let disposition = Self.finishedTransferDisposition(
            tag: tag,
            loadedServerId: scope?.serverId ?? "",
            loadedProfileId: scope?.profileId ?? "",
            record: loadedRecord(for: tag)
        )
        let fm = FileManager.default
        switch disposition {
        case .complete:
            guard let tag else { return }
            completeFinishedTransfer(recordId: tag.downloadId, from: fileURL)
        case .keepForOwner:
            guard let tag else { return }
            // A tagged file is already parked; an attributed one moves there
            // from staging.
            let parked = DownloadFilePaths.finishedTransferURL(for: tag)
            guard fileURL.standardizedFileURL.path != parked.standardizedFileURL.path else { return }
            try? fm.removeItem(at: parked)
            do {
                try fm.moveItem(at: fileURL, to: parked)
            } catch {
                Self.logger.error("Failed to park finished download: \(String(describing: error), privacy: .private)")
                try? fm.removeItem(at: fileURL)
            }
        case .discardFile:
            try? fm.removeItem(at: fileURL)
        case .discardDirectory:
            guard let tag else { return }
            try? fm.removeItem(at: fileURL)
            DownloadFilePaths.removeDownloadDirectory(
                serverId: tag.serverId,
                profileId: tag.profileId,
                downloadId: tag.downloadId
            )
        }
    }

    /// What happens to a finished transfer's file.
    enum FinishedTransferDisposition: Equatable {
        /// Its record in the loaded scope takes it as its media.
        case complete
        /// Its owner's store is not loaded: it stays parked under that owner
        /// until the store is next installed.
        case keepForOwner
        /// Nothing wants it: the record has media already, was reset, or
        /// the task has no known owner.
        case discardFile
        /// The loaded scope owns it but has no record for it: its download
        /// directory is left over from a deleted record.
        case discardDirectory
    }

    /// `loadedServerId`/`loadedProfileId` name the loaded scope (empty when
    /// none is), and `record` is that scope's record for the tag's download
    /// id, looked up only when the tag names the loaded scope.
    nonisolated static func finishedTransferDisposition(
        tag: DownloadTaskTag?,
        loadedServerId: String,
        loadedProfileId: String,
        record: DownloadRecord?
    ) -> FinishedTransferDisposition {
        guard let tag else { return .discardFile }
        guard !loadedServerId.isEmpty, !loadedProfileId.isEmpty,
              tag.isOwned(byServerId: loadedServerId, profileId: loadedProfileId) else { return .keepForOwner }
        guard let record else { return .discardDirectory }
        // A finish that races a pause still completes the record.
        switch record.localStatus {
        case .downloading, .paused:
            return record.mediaFilename == nil ? .complete : .discardFile
        default:
            return .discardFile
        }
    }

    /// Moves a finished file into its record's media slot and completes the
    /// record. A live finish and the parked-transfer settle can both reach
    /// one parked file; whichever comes second finds it gone and changes
    /// nothing.
    private func completeFinishedTransfer(recordId: String, from source: URL) {
        guard FileManager.default.fileExists(atPath: source.path),
              var record = file.records[recordId] else { return }
        clearTransferRate(recordId: record.id)
        if let expected = record.expectedBytes, expected > 0 {
            let actual = fileSizeOnDisk(source)
            // Only the manifest vouches for the file. A source the server
            // replaced gets a new revision, and the retry below fetches the
            // manifest again before the next transfer.
            if actual != expected {
                Self.logger.error("Finished download is \(actual, privacy: .public) bytes, expected \(expected, privacy: .public); downloading again")
                try? FileManager.default.removeItem(at: source)
                record.taskIdentifier = nil
                record.bytesDownloaded = 0
                if record.retryCount < Self.maxRetries {
                    record.retryCount += 1
                    file.records[record.id] = record
                    scheduleRetry(recordId: record.id, refreshToken: false)
                } else {
                    record.localStatus = .failed
                    record.lastError = "size_mismatch"
                    file.records[record.id] = record
                    persist()
                    notifyTerminalFailure(record)
                    processQueue()
                }
                return
            }
        }
        let ext = mediaExtension(for: record)
        let filename = "media.\(ext)"
        guard let destination = absoluteFileURLForNewAsset(recordId: record.id, filename: filename) else { return }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            Self.logger.error("Failed to move finished media: \(String(describing: error), privacy: .private)")
            try? FileManager.default.removeItem(at: source)
            record.localStatus = .failed
            record.lastError = DownloadSessionDelegate.isOutOfSpace(error) ? "storage_full" : "move_failed"
            record.taskIdentifier = nil
            file.records[record.id] = record
            persist()
            processQueue()
            return
        }
        progressHighWater[record.id] = nil
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
        // `delete_watched` waits for the next monitoring run, which removes a
        // watched episode right after it reads the watch state in full.
    }

    /// Applies a failure only to the loaded scope's record the task belongs
    /// to, and only while that record still names this task: a failure of
    /// another scope's transfer, or of a task the record no longer tracks,
    /// is dropped. The record re-queues when its scope next reconnects.
    private func handleMediaFailure(
        _ ref: DownloadTaskRef, statusCode: Int?, resumeData: Data?, message: String, cause: DownloadFailureCause
    ) {
        let tag = resolveTag(ref)
        if let tag, intentionalCancels.remove(IntentionalCancel(taskId: ref.taskId, owner: tag)) != nil { return }
        guard var record = loadedRecord(for: tag), record.taskIdentifier == ref.taskId else { return }
        record.taskIdentifier = nil
        clearTransferRate(recordId: record.id)

        let action = Self.mediaFailureAction(statusCode: statusCode, retryCount: record.retryCount, message: message,
            cause: cause)
        // Kept on disk rather than in memory, so a pause, a scope switch, or
        // the process ending before the retry doesn't restart from zero.
        let keepsPartialFile: Bool
        switch action {
        case let .retry(keepResumeData, _): keepsPartialFile = keepResumeData
        case .fail: keepsPartialFile = cause == .storageFull
        case .revoke: keepsPartialFile = false
        }
        if keepsPartialFile, let resumeData,
           let url = absoluteFileURLForNewAsset(recordId: record.id, filename: "resume.bin"),
           (try? resumeData.write(to: url, options: .atomic)) != nil {
            record.resumeDataFilename = "resume.bin"
        }

        switch action {
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
            if !keepResumeData { record.bytesDownloaded = 0 }
            if cause == .forceQuit {
                // Closing Silo from the app switcher cancels every transfer;
                // that isn't the download failing. Resume it now.
                record.localStatus = .queued
                file.records[record.id] = record
                persist()
                processQueue()
                return
            }
            record.retryCount += 1
            file.records[record.id] = record
            scheduleRetry(recordId: record.id, refreshToken: refreshToken)
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

    /// Every retry is bounded by `maxRetries`, after which the record fails,
    /// except a force-quit cancellation, which resumes without counting.
    nonisolated static func mediaFailureAction(
        statusCode: Int?, retryCount: Int, message: String, cause: DownloadFailureCause = .other
    ) -> MediaFailureAction {
        switch cause {
        case .forceQuit: return .retry(keepResumeData: true, refreshToken: false)
        case .storageFull: return .fail("storage_full")
        case .other: break
        }
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

    private func scheduleRetry(recordId: String, refreshToken: Bool) {
        // The caller's retry count survives the process ending in the back-off.
        persist()
        let attempt = file.records[recordId]?.retryCount ?? 1
        let delaySeconds = min(120, (1 << min(attempt, 6)) * 5)
        retryTasks[recordId]?.cancel()
        restartOwners.retryScheduled(recordId, firesAt: Date().addingTimeInterval(TimeInterval(delaySeconds)))
        updateHandoffBackgroundTask()
        retryTasks[recordId] = Task {
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled, !self.scopeServerId.isEmpty else { return }
            self.retryTasks[recordId] = nil
            self.restartOwners.retryEnded(recordId)
            // Fire only while the record still looks like the failure this
            // retry was scheduled for — a pause, delete, revoke, re-queue, or
            // running pipeline owns the record now, and restarting on top of
            // it would run two transfers of one file.
            guard self.awaitsRestart(recordId), !self.restartOwners.hasPipeline(recordId) else {
                self.updateHandoffBackgroundTask()
                return
            }
            // The restart owns the record from here, so a reconcile during
            // the token refresh below can't start a second transfer.
            let token = self.claimPipeline(recordId: recordId)
            if refreshToken {
                // Any authenticated v2 read runs HTTPClient's single-flight
                // 401 refresh, so the next background request carries a
                // fresh token.
                await self.refreshCapability()
                guard self.ownsPipeline(recordId, token), self.awaitsRestart(recordId) else {
                    self.releasePipeline(recordId: recordId, token: token)
                    return
                }
            }
            // Restart from the manifest step (a pipeline failure may have
            // been in the manifest fetch, not the media transfer),
            // through the queue so restarts share the pipeline cap. Resume
            // data saved for the record is used from there.
            self.releasePipeline(recordId: recordId, token: token)
            self.setLocalStatus(.queued, id: recordId)
            self.processQueue()
        }
    }

    /// Stops the transfer, pipeline, and retry working on a record being
    /// deleted or that the server no longer wants downloaded, so none of
    /// them brings it back.
    private func stopActiveWork(on record: inout DownloadRecord) {
        if let taskId = record.taskIdentifier {
            // Only this record's task: a stale ID can name another record's
            // transfer after a relaunch. With the ID cleared, the cancelled
            // task's failure event matches no record.
            sessionDelegate.cancel(taskId: taskId, ifDownloading: record.id)
            record.taskIdentifier = nil
        }
        abandonPipeline(recordId: record.id)
        restartOwners.abandonAssets(record.id)
        cancelRetry(recordId: record.id)
        clearTransferRate(recordId: record.id)
        progressHighWater[record.id] = nil
    }

    /// Whether a record is still the failed transfer a retry was scheduled
    /// for: nothing is transferring it, and it wasn't paused, deleted,
    /// revoked, or re-queued since.
    private func awaitsRestart(_ recordId: String) -> Bool {
        guard let record = file.records[recordId], record.taskIdentifier == nil else { return false }
        return record.localStatus == .downloading || record.localStatus == .fetchingAssets
    }

    private func cancelRetry(recordId: String) {
        retryTasks.removeValue(forKey: recordId)?.cancel()
        restartOwners.retryEnded(recordId)
        updateHandoffBackgroundTask()
    }

    /// Cancels every scheduled retry and takes every record away from its
    /// pipeline and asset fetch.
    private func abandonAllRestarts() {
        for task in retryTasks.values { task.cancel() }
        retryTasks.removeAll()
        restartOwners.removeAll()
        updateHandoffBackgroundTask()
    }

    // MARK: - Transfer handoff

    private func claimPipeline(recordId: String) -> UUID {
        let token = restartOwners.claimPipeline(recordId)
        updateHandoffBackgroundTask()
        return token
    }

    private func ownsPipeline(_ recordId: String, _ token: UUID) -> Bool {
        restartOwners.ownsPipeline(recordId, token)
    }

    private func pipelineIsCurrent(_ recordId: String, _ token: UUID, _ owner: ScopeOwner) -> Bool {
        ownsPipeline(recordId, token) && isCurrent(owner)
    }

    private func releasePipeline(recordId: String, token: UUID) {
        restartOwners.releasePipeline(recordId, token)
        updateHandoffBackgroundTask()
    }

    /// Takes the record away from its running pipeline, which stops at its
    /// next check without starting a transfer.
    private func abandonPipeline(recordId: String) {
        restartOwners.abandonPipeline(recordId)
        updateHandoffBackgroundTask()
    }

    /// Waits, at most `timeout` and never into the last of the app's
    /// background time, until no pipeline or imminent retry is still working
    /// toward its transfer and no asset fetch is still running.
    private func waitForTransferHandoff(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while restartOwners.handoffPending(by: deadline), Date() < deadline, hasBackgroundTimeLeft() {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func hasBackgroundTimeLeft() -> Bool {
        #if canImport(UIKit)
        // Effectively unlimited while the app is in the foreground.
        return UIApplication.shared.backgroundTimeRemaining > Self.backgroundTimeMargin
        #else
        return true
        #endif
    }

    /// Holds one background task while a transfer is on its way to the
    /// session or an asset fetch runs, ended when none is or when iOS
    /// reclaims the time.
    private func updateHandoffBackgroundTask() {
        #if canImport(UIKit)
        let deadline = Date().addingTimeInterval(Self.backgroundHandoffTimeout)
        if !restartOwners.handoffPending(by: deadline) {
            endHandoffBackgroundTask()
        } else if handoffBackgroundTask == .invalid {
            handoffBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SiloDownloadHandoff") {
                // iOS calls this on the main thread.
                MainActor.assumeIsolated { DownloadManager.shared.endHandoffBackgroundTask() }
            }
        }
        #endif
    }

    #if canImport(UIKit)
    private func endHandoffBackgroundTask() {
        guard handoffBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(handoffBackgroundTask)
        handoffBackgroundTask = .invalid
    }
    #endif

    // MARK: - Polling (preparing → ready)

    private func ensurePolling() {
        guard pollTask == nil else { return }
        guard file.records.values.contains(where: { $0.localStatus == .preparing }) else { return }
        let token = UUID()
        pollToken = token
        pollTask = Task {
            // `deactivate()` may have started a newer loop meanwhile; only
            // this loop's own handle is cleared.
            defer { if self.pollToken == token { self.pollTask = nil } }
            while !Task.isCancelled {
                guard self.file.records.values.contains(where: { $0.localStatus == .preparing }) else { break }
                try? await Task.sleep(for: .seconds(15))
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

        // One write for the whole pass: every write to `file` rebuilds indexes
        // and the Live Activity, which is costly per record in a large store.
        var records = file.records
        for (id, original) in records {
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
                        stopActiveWork(on: &record)
                        record.localStatus = .revoked
                    }
                case "failed":
                    if record.localStatus != .completed {
                        if record.localStatus.isActive { stopActiveWork(on: &record) }
                        record.localStatus = .failed
                        record.lastError = "server_failed"
                    }
                default:
                    break
                }
                records[id] = record
            } else if original.localStatus.isActive {
                var record = original
                stopActiveWork(on: &record)
                record.localStatus = .failed
                record.lastError = "removed_on_server"
                records[id] = record
            }
        }
        file.records = records

        // Pick up rows registered out-of-band (e.g. subscription sync).
        var legacyRowIds: [String] = []
        if legacyRemovalIncomplete {
            Self.logger.warning("Not importing unknown server downloads: removing earlier versions' downloads did not finish")
        } else {
            let unknownRows = Self.partitionUnknownRows(
                rows.filter { file.records[$0.id] == nil },
                legacyRowsPending: file.legacyRowsPending == true
            )
            if !unknownRows.imported.isEmpty {
                var records = file.records
                for row in unknownRows.imported {
                    records[row.id] = makeRecord(from: row, type: row.episodeId != nil ? "episode" : nil)
                }
                file.records = records
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
            applyTransferLimit()
            ensurePolling()
        }
        fillMissingDisplay()
    }

    /// Season, series, and monitor entries arrive without a title or
    /// artwork, and their manifest is otherwise read only once the file is
    /// ready, which for a prepared quality can take an hour. The server
    /// builds manifests for preparing entries too, so read each untitled
    /// active record's manifest now for its display fields alone. One pass
    /// runs at a time; a record that fails is tried again on the next pass.
    private func fillMissingDisplay() {
        guard displayFillTask == nil else {
            displayFillRequested = true
            return
        }
        displayFillRequested = false
        if displayFillScope != loadedScope {
            displayFillScope = loadedScope
            displayFillFailures = []
            displayFillRetryDelay = .seconds(15)
            // The previous scope's retry neither applies here nor may hold
            // back this scope's own.
            displayFillRetryTask?.cancel()
            displayFillRetryTask = nil
        }
        let ids = file.records.values
            .filter {
                $0.title == nil && $0.localStatus.isActive && $0.manifestFilename == nil
                    && !displayFillFailures.contains($0.id)
            }
            .sorted { ($0.registeredAt, $0.id) < ($1.registeredAt, $1.id) }
            .map(\.id)
        guard !ids.isEmpty else { return }
        displayFillTask = Task {
            let interrupted = await self.fillDisplay(ids)
            self.displayFillTask = nil
            if interrupted {
                self.scheduleDisplayFillRetry()
            } else {
                self.displayFillRetryDelay = .seconds(15)
            }
            if self.displayFillRequested { self.fillMissingDisplay() }
        }
    }

    /// Tries again after a pass a connection failure ended, with backoff,
    /// so an untitled download isn't left waiting on an unrelated trigger.
    private func scheduleDisplayFillRetry() {
        guard displayFillRetryTask == nil else { return }
        let delay = displayFillRetryDelay
        displayFillRetryDelay = min(delay * 2, .seconds(300))
        let scope = loadedScope
        displayFillRetryTask = Task {
            try? await Task.sleep(for: delay)
            // Whoever cancelled a retry also cleared it. Any other clears
            // itself even when its scope is gone, so a finished task can't
            // hold back the retries of a scope that comes back.
            guard !Task.isCancelled else { return }
            self.displayFillRetryTask = nil
            guard self.loadedScope == scope else { return }
            self.fillMissingDisplay()
        }
    }

    /// Reads the manifests a few at a time. Returns true when a connection
    /// failure, timeout, or busy server ended the pass early.
    private func fillDisplay(_ ids: [String]) async -> Bool {
        guard let owner = await captureScopeOwner() else { return false }
        let auth = owner.auth
        let pending = ids.filter { id in file.records[id].map { $0.title == nil } ?? false }
        var manifests: [String: OfflineManifest] = [:]
        var interrupted = false
        for start in stride(from: 0, to: pending.count, by: Self.displayFillConcurrency) {
            guard isCurrent(owner), !interrupted else { break }
            let batch = pending[start..<min(start + Self.displayFillConcurrency, pending.count)]
            let results = await withTaskGroup(of: (String, Result<OfflineManifest, Error>).self) { group in
                for id in batch {
                    group.addTask {
                        do {
                            return (id, .success(try await SiloAPI.shared.apiV2Client.downloadManifest(id: id, auth: auth)))
                        } catch {
                            return (id, .failure(error))
                        }
                    }
                }
                var out: [(String, Result<OfflineManifest, Error>)] = []
                for await result in group { out.append(result) }
                return out
            }
            // A read that outlived its scope says nothing about the new one.
            guard isCurrent(owner) else { return false }
            for (id, result) in results {
                switch result {
                case .success(let manifest):
                    manifests[id] = manifest
                case .failure(let error):
                    Self.logger.info("display read for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    // A refusal of this download, or a manifest the app
                    // can't use, is lasting. A connection failure, timeout,
                    // or busy server would fail the rest too; a retry
                    // follows.
                    let unusable = (error as? DownloadRegistryError) == .unusableManifest
                    if unusable || APIv2Client.downloadRegistryFailure(error) == .rejected {
                        displayFillFailures.insert(id)
                    } else {
                        interrupted = true
                    }
                }
            }
        }
        guard isCurrent(owner), !manifests.isEmpty else { return interrupted }
        // One write for the pass: each write to `file` rebuilds the indexes.
        var records = file.records
        for (id, manifest) in manifests {
            guard var record = records[id], record.title == nil else { continue }
            Self.applyDisplayFields(manifest, to: &record)
            records[id] = record
        }
        file.records = records
        persist()
        return interrupted
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
        serverDeleteTask = Task {
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
        Task {
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
        // A transfer that finished while its store was not loaded is parked
        // on disk; the settle completes its record, which must happen before
        // the missing live task re-queues it here. The scope is captured
        // first: one installed while this waits has its own settle, which
        // this wait did not cover.
        guard let scope = loadedScope else { return }
        await awaitParkedSettle()
        guard loadedScope == scope else { return }
        // A transfer started while the live-task read is in flight may be
        // missing from it; only identifiers held before the read are judged.
        let taskIdsBeforeRead = file.records.compactMapValues(\.taskIdentifier)
        let (current, retired) = await sessionDelegate.liveTasks()
        // Not claimed as intentional cancels. The pass below stops this
        // scope's records naming a retired task before its cancellation's
        // failure event can arrive, so that event matches no record; one of
        // another scope restarts through the ordinary failure path. A claim
        // would outlive a task that ended during the read.
        for ref in retired {
            sessionDelegate.cancelRetired(taskId: ref.taskId)
        }
        guard loadedScope == scope else { return }
        // Task identifiers repeat across session instances and every scope
        // shares the session, so a persisted id says nothing on its own. A
        // task counts as live for a record only when its tag (or, for a
        // task an earlier build started, its request) names this scope and
        // that record.
        let live = Self.liveTaskIds(
            loadedServerId: scope.serverId,
            loadedProfileId: scope.profileId,
            tasks: current.map { ($0.taskId, resolveTag($0)) }
        )
        // One write to `file` for the whole pass.
        var records = file.records
        var changed = false
        var requeued = false
        for (id, record) in file.records {
            let plan = Self.reconnectPlan(
                status: record.localStatus,
                taskIdentifier: record.taskIdentifier,
                taskIdentifierBeforeRead: taskIdsBeforeRead[id],
                liveTaskId: live[id],
                pausing: pendingPauseIds.contains(id),
                restartOwned: restartOwners.ownsRestart(id)
            )
            if plan.taskIdentifier != record.taskIdentifier {
                records[id]?.taskIdentifier = plan.taskIdentifier
                changed = true
            }
            if plan.requeue {
                records[id]?.localStatus = .queued
                changed = true
                requeued = true
            }
        }
        if changed { file.records = records }
        if requeued { persist() }
    }

    /// What reconnect does with one record.
    struct ReconnectPlan: Equatable {
        /// The task the record tracks from now on.
        var taskIdentifier: Int?
        /// Put the record back in the queue to start its transfer again.
        var requeue: Bool
    }

    /// A record tracks the live task its scope owns for it (see
    /// `liveTaskIds`), and nothing when there is none, so a later restart can
    /// cancel a task still running for a paused record. A pause round-trip
    /// keeps its task even when it is no longer live: the cancelled task may
    /// still deliver a final event for this record.
    ///
    /// A downloading record without a live task, or a `.fetchingAssets` one
    /// whose pipeline didn't survive a relaunch, is re-queued. A record whose
    /// retry or pipeline is still running in this process is left to it:
    /// re-queuing would start a second transfer of the same file.
    nonisolated static func reconnectPlan(
        status: LocalDownloadStatus,
        taskIdentifier: Int?,
        taskIdentifierBeforeRead: Int?,
        liveTaskId: Int?,
        pausing: Bool,
        restartOwned: Bool
    ) -> ReconnectPlan {
        if let taskIdentifier, taskIdentifier != taskIdentifierBeforeRead {
            // Started after the read, so the read says nothing about it.
            return ReconnectPlan(taskIdentifier: taskIdentifier, requeue: false)
        }
        let tracked = pausing ? liveTaskId ?? taskIdentifier : liveTaskId
        let requeue = !restartOwned
            && (status == .fetchingAssets || (status == .downloading && liveTaskId == nil))
        return ReconnectPlan(taskIdentifier: tracked, requeue: requeue)
    }

    /// Maps record id to the live task the loaded scope owns for it. When
    /// one record has several live tasks, the newest (highest id) wins.
    nonisolated static func liveTaskIds(
        loadedServerId: String,
        loadedProfileId: String,
        tasks: [(taskId: Int, tag: DownloadTaskTag?)]
    ) -> [String: Int] {
        guard !loadedServerId.isEmpty, !loadedProfileId.isEmpty else { return [:] }
        var live: [String: Int] = [:]
        for task in tasks {
            guard let tag = task.tag, tag.isOwned(byServerId: loadedServerId, profileId: loadedProfileId) else {
                continue
            }
            live[tag.downloadId] = max(live[tag.downloadId] ?? task.taskId, task.taskId)
        }
        return live
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
        maxStorageBytes: Int64,
        quality: String? = nil
    ) async throws {
        guard let owner = await captureScopeOwner() else { throw DownloadError.monitoringScopeChanged }
        let request = CreateSubscriptionRequest(
            seriesId: seriesId,
            mode: mode.rawValue,
            seasonNumbers: mode == .specificSeasons ? seasonNumbers : nil,
            deleteWatched: deleteWatched,
            maxStorageBytes: maxStorageBytes,
            quality: monitorQuality(quality)
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
                active: true,
                quality: request.quality == (monitor.quality ?? DownloadFormat.original.rawValue) ? nil : request.quality
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
              monitor.maxStorageBytes == request.maxStorageBytes,
              request.quality.map({ $0 == (monitor.quality ?? DownloadFormat.original.rawValue) }) ?? true
        else { return false }
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
        active: Bool? = nil,
        quality: String? = nil
    ) async throws {
        guard let owner = await captureScopeOwner() else { throw DownloadError.monitoringScopeChanged }
        guard let existing = file.subscriptions.first(where: { $0.id == id }) else { throw DownloadError.monitorRemoved }
        let patch = UpdateSubscriptionRequest(
            mode: mode?.rawValue,
            seasonNumbers: seasonNumbers,
            deleteWatched: deleteWatched,
            maxStorageBytes: maxStorageBytes,
            active: active,
            quality: quality.flatMap(monitorQuality)
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
        let task = Task {
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
        let stopped = Set((file.pendingSubscriptionDeletes ?? [:]).keys).union(landed.deleted)
        let unknown = Self.unknownMonitorIds(local: file.subscriptions, listed: listed, stopped: stopped)
        // Only ids the server still lists are worth keeping.
        var storedLegacy = (file.legacyMonitorIds ?? []).intersection(listed.map(\.id))
        var legacyPending = file.legacyMonitorsPending
        var legacy = storedLegacy
        if legacyRemovalIncomplete {
            // A removal that did not finish can't tell them apart: hide the
            // unknown ones for this launch without recording anything.
            legacy.formUnion(unknown)
        } else if legacyPending == true {
            // The first complete list after the removal. A monitor this
            // version creates is stored when its create answers, so every
            // unknown one is the earlier version's.
            storedLegacy.formUnion(unknown)
            legacy = storedLegacy
            legacyPending = nil
        }
        let merged = Self.mergeSubscriptions(
            local: file.subscriptions,
            listed: listed,
            stopped: stopped,
            createdDuringRead: landed.created,
            legacy: legacy
        )
        subscriptionWrites.listCompleted(startedAt: started)
        let legacyIds = storedLegacy.isEmpty ? nil : storedLegacy
        if merged != file.subscriptions || legacyIds != file.legacyMonitorIds
            || legacyPending != file.legacyMonitorsPending {
            file.subscriptions = merged
            file.legacyMonitorIds = legacyIds
            file.legacyMonitorsPending = legacyPending
            persist()
        }
        return true
    }

    /// Listed monitors the local list doesn't hold and the user didn't stop.
    nonisolated static func unknownMonitorIds(
        local: [DownloadSubscription],
        listed: [ServerSubscription],
        stopped: Set<String>
    ) -> Set<String> {
        Set(listed.map(\.id)).subtracting(local.map(\.id)).subtracting(stopped)
    }

    /// The local monitor list after a complete read of the server's. Local
    /// titles stay. A monitor the server no longer lists is dropped, unless a
    /// create answered with it during the read (`createdDuringRead`). One the
    /// user stopped (`stopped`: its DELETE is pending or landed during the
    /// read) is not brought back. An unknown monitor in `legacy` belongs to
    /// the downloads an earlier version saved, so it is left out and never
    /// synced.
    nonisolated static func mergeSubscriptions(
        local: [DownloadSubscription],
        listed: [ServerSubscription],
        stopped: Set<String>,
        createdDuringRead: Set<String> = [],
        legacy: Set<String>
    ) -> [DownloadSubscription] {
        let titles = Dictionary(local.map { ($0.id, $0.seriesTitle) }, uniquingKeysWith: { first, _ in first })
        let merged: [DownloadSubscription] = listed.compactMap { monitor in
            guard !stopped.contains(monitor.id) else { return nil }
            if let title = titles[monitor.id] {
                return DownloadSubscription(from: monitor, seriesTitle: title)
            }
            if legacy.contains(monitor.id) { return nil }
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
    private func syncSubscription(id: String, owner: ScopeOwner) async -> (registered: Int, stopRun: Bool, removed: Bool) {
        guard let monitor = file.subscriptions.first(where: { $0.id == id }), monitor.active else { return (0, false, false) }
        // Rows a sync registers are unknown to the store. Until the scope's
        // first complete registry read has set aside the earlier version's
        // rows, that read would take them for legacy rows and delete them.
        guard file.legacyRowsPending != true, !legacyRemovalIncomplete else { return (0, true, false) }
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
        let watchStateOwner = await refreshWatchState()
        await reconcileWithServer(triggerPipeline: true)
        notifyMonitoringBatch(registered: registered, priorRecordIds: priorRecordIds)
        let watched = Self.retentionDeletions(
            readApplied: watchStateOwner != nil,
            ownerStillCurrent: watchStateOwner.map(isCurrent) == true,
            in: file
        )
        deleteDownloads(ids: watched)
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

    /// Client-enforced `delete_watched` at the end of a monitoring run. It
    /// acts only on watch state this run read in full: unless the run applied
    /// a complete read and that read's owner is still current, it removes
    /// nothing, so a read that failed or stopped early can never remove a
    /// file. The server never deletes on-device files.
    nonisolated static func retentionDeletions(
        readApplied: Bool,
        ownerStillCurrent: Bool,
        in file: DownloadStoreFile
    ) -> [String] {
        guard readApplied, ownerStillCurrent else { return [] }
        return watchedDownloadIds(in: file)
    }

    /// The completed downloads whose series is monitored with
    /// `delete_watched` and whose progress in `file` is completed.
    nonisolated static func watchedDownloadIds(in file: DownloadStoreFile) -> [String] {
        let retentionSeries = Set(
            file.subscriptions.filter { $0.deleteWatched }.map { $0.seriesId }
        )
        guard !retentionSeries.isEmpty else { return [] }
        return file.records.values.filter { record in
            // Progress is keyed by the leaf item id (the episode), which for an
            // episode download is `episodeId`, not the series `contentId`.
            let leafId = record.episodeId ?? record.contentId
            return record.localStatus == .completed
                && record.seriesId.map(retentionSeries.contains) == true
                && file.localProgress[leafId]?.completed == true
        }.map(\.id)
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
    private func flushProgressQueue() async {
        // The owner also requires `file` to hold the scope's store, so a
        // flush during a profile switch's load window can't claim the old
        // profile's queue under the new profile's auth. Its generation
        // advances on every scope change, including a switch away and back,
        // so a stale flush cannot touch a newer file.
        guard let owner = await captureScopeOwner() else { return }

        for _ in 0..<Self.maxProgressBatchesPerFlush {
            guard isCurrent(owner) else { return }
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

            let outcome = await SiloAPI.shared.apiV2Client.syncProgress(batch.compactMap(\.syncItem), auth: owner.auth)
            progressUploadsInFlight.subtract(ids)
            guard isCurrent(owner) else {
                // A batch that was sent stays dispatched in the old scope's
                // file, which is the held state it belongs in. One that never
                // reached the server (refused before dispatch, or deferred)
                // goes back to pending there.
                if OfflineProgressQueue.releasesClaims(outcome) {
                    releaseProgressClaims(ids, serverId: owner.scope.serverId, profileId: owner.scope.profileId)
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

    // MARK: - Watch state

    /// Re-reads the profile's whole watch progress through
    /// `GET /api/v2/progress` and merges the entries of this device's
    /// downloads and queued uploads into `localProgress`, which drives
    /// `isWatched`, offline resume and `delete_watched`. v2 has no delta or
    /// per-item read, so a read covers the full set; a read that fails or
    /// stops early changes nothing and is tried again on the next run.
    ///
    /// With no download and nothing queued there is nothing to merge, so no
    /// request is made. A read is also skipped when the last one in this
    /// scope is recent and covered every item (`watchStateReadInterval`).
    ///
    /// Returns the owner the read was applied under, or nil when nothing was
    /// applied.
    private func refreshWatchState() async -> ScopeOwner? {
        guard let owner = await captureScopeOwner() else { return nil }
        let itemIds = Self.watchStateItemIds(in: file)
        if itemIds.isEmpty, !file.localProgress.isEmpty {
            // Nothing left to keep progress for.
            file.localProgress = [:]
            persist()
        }
        let last = lastWatchStateRead.flatMap { $0.scope == owner.scope ? $0 : nil }
        guard Self.watchStateReadNeeded(itemIds: itemIds, lastReadAt: last?.at, lastItemIds: last?.itemIds) else {
            return nil
        }
        let startedAt = Date()
        let outcome: Result<[APIv2ProgressEntry], Error>
        do {
            outcome = .success(try await SiloAPI.shared.apiV2Client.listAllProgress(auth: owner.auth))
        } catch {
            Self.logger.warning("watch state read failed: \(String(describing: error), privacy: .public)")
            outcome = .failure(error)
        }
        guard let merged = Self.applyWatchStateRead(
            outcome,
            ownerStillCurrent: isCurrent(owner),
            to: file,
            readStartedAt: startedAt
        ) else { return nil }
        lastWatchStateRead = (owner.scope, startedAt, itemIds)
        if merged != file.localProgress {
            file.localProgress = merged
            persist()
        }
        return owner
    }

    /// Whether a monitoring run reads the watch state: only when some item
    /// needs it, and not again within `watchStateReadInterval` of a read that
    /// covered every item.
    nonisolated static func watchStateReadNeeded(
        itemIds: Set<String>,
        lastReadAt: Date?,
        lastItemIds: Set<String>?,
        now: Date = Date()
    ) -> Bool {
        guard !itemIds.isEmpty else { return false }
        guard let lastReadAt, let lastItemIds else { return true }
        return now.timeIntervalSince(lastReadAt) >= watchStateReadInterval || !itemIds.isSubset(of: lastItemIds)
    }

    /// The items whose watch state this device keeps: the leaf item of every
    /// download record and every item with a queued offline upload.
    nonisolated static func watchStateItemIds(in file: DownloadStoreFile) -> Set<String> {
        Set(file.records.values.map(\.leafMediaItemId)).union(file.progressQueue.map(\.mediaItemId))
    }

    /// The watch state one read leaves in `file`: the merge of a complete
    /// read whose owner is still current, or nil when the read failed,
    /// stopped early or outlived its owner, in which case nothing changes.
    nonisolated static func applyWatchStateRead(
        _ outcome: Result<[APIv2ProgressEntry], Error>,
        ownerStillCurrent: Bool,
        to file: DownloadStoreFile,
        readStartedAt: Date
    ) -> [String: LocalProgressEntry]? {
        guard ownerStillCurrent, case .success(let entries) = outcome else { return nil }
        return mergeProgress(
            file.localProgress,
            read: entries,
            readStartedAt: readStartedAt,
            queuedItemIds: Set(file.progressQueue.map(\.mediaItemId)),
            keptItemIds: watchStateItemIds(in: file)
        )
    }

    /// Merges a complete progress read into the local entries: for each item
    /// the side with the later `updated_at` wins whole, `completed` included,
    /// so an unwatch on another device reaches this one. An entry the read
    /// does not hold has no progress on the server (cleared, or marked
    /// unwatched) and is dropped, unless this device wrote it during the read
    /// or still has it queued for upload. Only items in `keptItemIds` (this
    /// device's downloads and queued uploads) are kept at all, so the rest of
    /// the profile's history is never stored.
    nonisolated static func mergeProgress(
        _ local: [String: LocalProgressEntry],
        read: [APIv2ProgressEntry],
        readStartedAt: Date,
        queuedItemIds: Set<String>,
        keptItemIds: Set<String>
    ) -> [String: LocalProgressEntry] {
        var merged = local.filter { id, entry in
            keptItemIds.contains(id) && (queuedItemIds.contains(id) || entry.updatedAt >= readStartedAt)
        }
        for item in read where keptItemIds.contains(item.mediaItemId) {
            if let existing = local[item.mediaItemId], existing.updatedAt > item.updatedAt {
                merged[item.mediaItemId] = existing
                continue
            }
            let duration = item.durationSeconds > 0 ? item.durationSeconds : (local[item.mediaItemId]?.duration ?? 0)
            merged[item.mediaItemId] = LocalProgressEntry(
                position: item.positionSeconds,
                duration: duration,
                completed: item.completed,
                updatedAt: item.updatedAt
            )
        }
        return merged
    }

    // MARK: - Helpers

    private func upsertRow(
        _ row: APIv2DownloadEntry,
        into records: inout [String: DownloadRecord],
        displayTitle: String?,
        displaySubtitle: String?,
        type: String?,
        seriesId: String?,
        posterThumbhash: String?
    ) {
        if let existing = records[row.id] {
            var merged = mergeExistingRecord(existing, with: row)
            if existing.localStatus == .failed || existing.localStatus == .revoked {
                merged.localStatus = Self.mapInitialStatus(row.status)
                merged.lastError = nil
                merged.retryCount = 0
            }
            records[row.id] = merged
            return
        }
        var record = makeRecord(from: row, type: type)
        record.title = displayTitle
        record.subtitle = displaySubtitle
        record.seriesId = seriesId ?? record.seriesId
        record.posterThumbhash = posterThumbhash
        records[row.id] = record
    }

    private func mergeExistingRecord(_ existing: DownloadRecord, with row: APIv2DownloadEntry) -> DownloadRecord {
        var record = existing
        if shouldReplaceLocalAssets(record, with: row) {
            // A running transfer or pipeline would deliver the replaced
            // revision's bytes, and an asset fetch would save its files.
            // `stopActiveWork` cancels only this record's own task: before
            // reconnect drops stale ids, the stored one can name another
            // record's transfer.
            stopActiveWork(on: &record)
            removeDownloadDirectory(recordId: record.id)
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

    private func resetLocalAssets(on record: inout DownloadRecord, status: String) {
        record.mediaFilename = nil
        record.manifestFilename = nil
        record.posterFilename = nil
        record.backdropFilename = nil
        record.logoFilename = nil
        record.seriesPosterFilename = nil
        record.subtitleFilenames = [:]
        record.subtitleEntityTags = nil
        record.subtitleRevisions = nil
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
        record.preparation = row.status == "preparing" ? row.preparation : nil
        if row.fileSize > 0, record.fileSize <= 0 {
            record.fileSize = row.fileSize
        }
        if let completedAt = row.completedAt {
            record.downloadedAt = completedAt
        }
    }

    private func makeRecord(from row: APIv2DownloadEntry, type: String?) -> DownloadRecord {
        var record = DownloadRecord(
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
        record.preparation = row.status == "preparing" ? row.preparation : nil
        return record
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
        guard let seriesId = Self.seriesKey(for: record),
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
                guard other.id != record.id, Self.seriesKey(for: other) == seriesId else { return false }
                switch other.localStatus {
                case .completed, .downloading, .fetchingAssets, .paused: return true
                default: return false
                }
            }
            .reduce(Int64(0)) { $0 + max($1.fileSize, $1.bytesDownloaded) }
        return used + max(record.fileSize, 0) > subscription.maxStorageBytes
    }

    /// The series a download belongs to. Episode rows registered by
    /// subscription sync carry the series id in `contentId` until the
    /// manifest hydrates `seriesId` — without the fallback, freshly synced
    /// episodes would bypass the storage cap entirely.
    nonisolated static func seriesKey(for record: DownloadRecord) -> String? {
        record.seriesId ?? (record.episodeId != nil ? record.contentId : nil)
    }

    /// The owner tag of a record in `file`: the scope `file` was loaded for
    /// and the record id. Nil when no store is loaded.
    private func ownedTag(recordId: String) -> DownloadTaskTag? {
        guard !fileServerId.isEmpty, !fileProfileId.isEmpty else { return nil }
        return DownloadTaskTag(serverId: fileServerId, profileId: fileProfileId, downloadId: recordId)
    }

    /// The owner of the task an event came from: its tag, or for a task an
    /// earlier build started without one, the owner its request names.
    private func resolveTag(_ ref: DownloadTaskRef) -> DownloadTaskTag? {
        ref.tag ?? DownloadTaskTag.attributing(
            requestURL: ref.requestURL,
            profileId: ref.requestProfileId,
            servers: attributionServers
        )
    }

    /// The servers an untagged task is attributed among. Pause and cancel
    /// pass this snapshot to the session delegate, which checks ownership
    /// off the main actor, so they claim an untagged task only when its
    /// events would reach the same owner.
    private var attributionServers: [(id: String, url: String)] {
        ServerRegistry.shared.entries.map { ($0.id, $0.url) }
    }

    /// The loaded scope's record `tag` names, or nil when there is no tag,
    /// no loaded scope, or the tag names another scope.
    private func loadedRecord(for tag: DownloadTaskTag?) -> DownloadRecord? {
        guard let tag, let scope = loadedScope,
              tag.isOwned(byServerId: scope.serverId, profileId: scope.profileId) else { return nil }
        return file.records[tag.downloadId]
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
            totalBytesUsed = 0
            return
        }
        Task {
            let bytes = await Task.detached(priority: .utility) {
                DownloadFilePaths.bytesUsed(serverId: serverId, profileId: profileId)
            }.value
            // A slower walk of a scope switched away from must not overwrite
            // the new scope's number.
            guard serverId == scopeServerId, profileId == scopeProfileId else { return }
            totalBytesUsed = bytes
        }
    }

    /// Throttle disk writes during the high-frequency progress callbacks;
    /// the in-memory mutation already drives the UI.
    private func persistProgressThrottled() {
        guard Date().timeIntervalSince(lastProgressPersist) > 2 else { return }
        persist()
    }

    // MARK: - Transfer rate

    /// The start of a record's current rate window.
    struct TransferRateSample: Equatable {
        var bytes: Int64
        var at: Date
    }

    private func updateTransferRate(recordId: String, bytes: Int64, at: Date) {
        let next = Self.nextTransferRate(
            sample: rateSamples[recordId],
            rate: transferRates[recordId],
            bytes: bytes,
            now: at
        )
        if next.sample != rateSamples[recordId] { rateSamples[recordId] = next.sample }
        if next.rate != transferRates[recordId] { transferRates[recordId] = next.rate }
    }

    /// Exponentially-smoothed rate from progress deltas. Samples at least
    /// `rateSampleInterval` apart so the burst-y delegate callbacks don't
    /// produce jittery instantaneous rates. Returns the window to keep and
    /// the rate to publish (nil clears it).
    nonisolated static func nextTransferRate(
        sample: TransferRateSample?,
        rate: Double?,
        bytes: Int64,
        now: Date
    ) -> (sample: TransferRateSample, rate: Double?) {
        let fresh = TransferRateSample(bytes: bytes, at: now)
        guard let sample else { return (fresh, rate) }
        let elapsed = now.timeIntervalSince(sample.at)
        guard elapsed >= rateSampleInterval else { return (sample, rate) }
        // After a gap, the bytes would be averaged over time the transfer
        // may have spent waiting; resume-data restarts can report fewer bytes
        // than the last sample. Either way, start a fresh window instead of
        // publishing a misleading (or negative) rate.
        guard elapsed <= rateMaxSampleGap, bytes >= sample.bytes else { return (fresh, nil) }
        let instant = Double(bytes - sample.bytes) / elapsed
        return (fresh, rate.map { $0 + rateSmoothing * (instant - $0) } ?? instant)
    }

    private func clearTransferRate(recordId: String) {
        rateSamples.removeValue(forKey: recordId)
        transferRates.removeValue(forKey: recordId)
        lastProgressPublish.removeValue(forKey: recordId)
    }
}

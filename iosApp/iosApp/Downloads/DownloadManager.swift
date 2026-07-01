import Foundation
import OSLog

enum DownloadError: LocalizedError {
    case unavailable
    case fileURLUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Downloads aren't available for this profile."
        case .fileURLUnavailable: return "Could not resolve the download URL."
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
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "Downloads"
    )

    private static let maxConcurrentTransfers = 3
    private static let maxRetries = 4
    private static let capabilityTTL: TimeInterval = 86_400

    /// In-memory persisted blob. `private(set)` so the `@Observable` macro
    /// tracks reads of its derived accessors below.
    private(set) var file: DownloadStoreFile = .empty

    private(set) var scopeServerId: String = ""
    private(set) var scopeProfileId: String = ""

    private let sessionDelegate = DownloadSessionDelegate()
    private var intentionalCancels: Set<Int> = []
    private var pollTask: Task<Void, Never>?
    private var lastProgressPersist = Date.distantPast
    /// Serializes disk saves so a rapid burst of `persist()` calls can't land
    /// out of order and overwrite a newer snapshot with an older one.
    private var saveChain: Task<Void, Never>?
    /// Cached scope storage usage; refreshed off the MainActor (a filesystem
    /// walk) so SwiftUI bodies reading `totalBytesUsed` don't block.
    private(set) var storageBytesUsed: Int64 = 0

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
    var downloadsEnabled: Bool { capability?.isUsable == true }
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
    var completedRecords: [DownloadRecord] { records.filter { !$0.localStatus.isActive } }
    var subscriptions: [DownloadSubscription] { file.subscriptions }

    var totalBytesUsed: Int64 { storageBytesUsed }

    // MARK: - Lookups

    /// The download record for a leaf content id (movie or episode), if any.
    func record(forContentId contentId: String) -> DownloadRecord? {
        file.records.values.first { $0.contentId == contentId || $0.episodeId == contentId }
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
    /// sizes), plus an "other" remainder (artwork/manifests/subtitles/
    /// in-flight) derived from the true on-disk total.
    var storageBreakdown: DownloadStorageBreakdown {
        var series: Int64 = 0
        var movies: Int64 = 0
        for record in onDeviceRecords {
            if record.seriesId == nil { movies += record.fileSize }
            else { series += record.fileSize }
        }
        let other = max(0, storageBytesUsed - series - movies)
        return DownloadStorageBreakdown(series: series, movies: movies, other: other)
    }

    /// Total bytes downloaded for one series across all seasons.
    func bytesForSeries(_ seriesId: String) -> Int64 {
        onDeviceRecords
            .filter { $0.seriesId == seriesId }
            .reduce(0) { $0 + $1.fileSize }
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
        var removed = false
        for id in ids {
            guard let record = file.records[id] else { continue }
            if let taskId = record.taskIdentifier {
                intentionalCancels.insert(taskId)
                sessionDelegate.cancel(taskId: taskId)
            }
            file.records.removeValue(forKey: id)
            if !scopeServerId.isEmpty {
                DownloadFilePaths.removeDownloadDirectory(
                    serverId: scopeServerId,
                    profileId: scopeProfileId,
                    downloadId: id
                )
            }
            removed = true
        }
        guard removed else { return }
        persist()
        let serverIds = ids
        Task {
            for id in serverIds { try? await ContinuumAPI.shared.deleteDownloadRow(id: id) }
        }
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
        let serverId = ServerRegistry.shared.activeServerId ?? ""
        let profileId = await TokenStore.shared.getProfileId() ?? ""
        guard !serverId.isEmpty, !profileId.isEmpty else {
            deactivate()
            return false
        }
        if serverId == scopeServerId, profileId == scopeProfileId, !file.records.isEmpty || file.capability != nil {
            return true
        }
        scopeServerId = serverId
        scopeProfileId = profileId
        file = await DownloadStore.shared.load(serverId: serverId, profileId: profileId)
        refreshStorageUsage()
        await backfillEpisodeMetadataIfNeeded()
        return true
    }

    /// Called on app launch / foreground and on the first authenticated
    /// transition. Refreshes capability, reconciles with the server, and
    /// runs subscription + progress sync.
    func onAppActive() async {
        guard await activateScopeIfNeeded() else { return }
        await refreshCapabilityIfStale()
        guard downloadsEnabled else { return }
        await reconcileWithServer(triggerPipeline: true)
        await runMonitoringAndProgressSync()
    }

    /// Profile/server switched — load the new scope and refresh.
    func onScopeChanged() async {
        deactivate()
        await onAppActive()
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
        scopeServerId = ""
        scopeProfileId = ""
        file = .empty
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

    func refreshCapability() async {
        guard !scopeServerId.isEmpty else { return }
        do {
            let capability = try await ContinuumAPI.shared.downloadCapability()
            file.capability = capability
            file.capabilityFetchedAt = Date()
            persist()
        } catch {
            Self.logger.debug("capability refresh failed: \(String(describing: error), privacy: .public)")
        }
    }

    func refreshCapabilityIfStale() async {
        let stale: Bool = {
            guard let fetchedAt = file.capabilityFetchedAt else { return true }
            return Date().timeIntervalSince(fetchedAt) > Self.capabilityTTL
        }()
        if file.capability == nil || stale {
            await refreshCapability()
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
        let rows = try await ContinuumAPI.shared.createDownload(request)
        for row in rows {
            upsertRow(
                row,
                displayTitle: rows.count == 1 ? displayTitle : nil,
                displaySubtitle: rows.count == 1 ? displaySubtitle : nil,
                type: type,
                seriesId: seriesId,
                posterThumbhash: rows.count == 1 ? posterThumbhash : nil
            )
        }
        persist()
        processQueue()
        ensurePolling()
    }

    private func resolvedDownloadQuality(_ requestedQuality: String?) -> String {
        let allowed = capability?.qualityPresets ?? []
        if let requestedQuality, allowed.contains(requestedQuality) {
            return requestedQuality
        }
        return DownloadSettings.shared.resolvedFormat(allowedFormats: allowed)
    }

    func deleteDownload(id: String) {
        guard let record = file.records[id] else { return }
        if let taskId = record.taskIdentifier {
            intentionalCancels.insert(taskId)
            sessionDelegate.cancel(taskId: taskId)
        }
        file.records.removeValue(forKey: id)
        persist()
        if !scopeServerId.isEmpty {
            DownloadFilePaths.removeDownloadDirectory(
                serverId: scopeServerId,
                profileId: scopeProfileId,
                downloadId: id
            )
        }
        Task { try? await ContinuumAPI.shared.deleteDownloadRow(id: id) }
        processQueue()
        refreshStorageUsage()
    }

    func deleteDownload(forContentId contentId: String) {
        if let record = record(forContentId: contentId) {
            deleteDownload(id: record.id)
        }
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
            setLocalStatus(.fetchingAssets, id: record.id)
            Task { await self.startMediaPipeline(recordId: record.id) }
        }
    }

    private func startMediaPipeline(recordId: String) async {
        guard file.records[recordId] != nil else { return }
        do {
            let manifest = try await ContinuumAPI.shared.fetchManifest(downloadId: recordId)
            await persistManifest(manifest, recordId: recordId)
            applyManifestDisplay(manifest, recordId: recordId)
            await fetchArtwork(manifest, recordId: recordId)
            await fetchSubtitles(manifest, recordId: recordId)
            await startMediaTransfer(recordId: recordId)
        } catch {
            handlePipelineError(error, recordId: recordId)
        }
    }

    private func startMediaTransfer(recordId: String) async {
        guard var record = file.records[recordId] else { return }
        guard let fileURL = await ContinuumAPI.shared.downloadFileURL(downloadId: recordId) else {
            handlePipelineError(DownloadError.fileURLUnavailable, recordId: recordId)
            return
        }
        let request = await DownloadAuthHeaders.authorizedRequest(
            url: fileURL,
            allowsCellular: !DownloadSettings.shared.wifiOnly
        )
        let taskId = sessionDelegate.start(request: request)
        record.taskIdentifier = taskId
        record.localStatus = .downloading
        file.records[recordId] = record
        persist()
        Task { try? await ContinuumAPI.shared.patchDownloadStatus(id: recordId, status: "downloading") }
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
        record.mediaFileId = manifest.mediaFileId
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

    private func fetchArtwork(_ manifest: OfflineManifest, recordId: String) async {
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
            guard let data = try? await ContinuumAPI.shared.fetchDownloadAssetData(path: path),
                  !data.isEmpty,
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

    private func fetchSubtitles(_ manifest: OfflineManifest, recordId: String) async {
        guard let subtitles = manifest.subtitles, !subtitles.isEmpty else { return }
        for (index, subtitle) in subtitles.enumerated() {
            let ext = (subtitle.format ?? "srt").lowercased()
            let filename = "sub_\(index).\(ext)"
            guard let data = try? await ContinuumAPI.shared.fetchDownloadAssetData(path: subtitle.fetchUrl),
                  !data.isEmpty,
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
        if case let HTTPError.http(statusCode, _) = error {
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
        processQueue()
    }

    // MARK: - Background session events

    private func handleSessionEvent(_ event: DownloadSessionEvent) {
        switch event {
        case let .progress(taskId, written, total):
            guard var record = recordByTask(taskId) else { return }
            record.bytesDownloaded = written
            if total > 0 { record.fileSize = total }
            file.records[record.id] = record
            persistProgressThrottled()

        case let .finished(taskId, stagedURL, _):
            handleMediaFinished(taskId: taskId, stagedURL: stagedURL)

        case let .failed(taskId, statusCode, resumeData, message):
            handleMediaFailure(taskId: taskId, statusCode: statusCode, resumeData: resumeData, message: message)

        case .allEventsDelivered:
            sessionDelegate.backgroundCompletionHandler?()
            sessionDelegate.backgroundCompletionHandler = nil
        }
    }

    private func handleMediaFinished(taskId: Int, stagedURL: URL) {
        intentionalCancels.remove(taskId)
        guard var record = recordByTask(taskId) else {
            try? FileManager.default.removeItem(at: stagedURL)
            return
        }
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
            Self.logger.error("Failed to move finished media for \(record.id, privacy: .public): \(String(describing: error), privacy: .public)")
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
        file.records[record.id] = record
        persist()
        let id = record.id
        Task { try? await ContinuumAPI.shared.patchDownloadStatus(id: id, status: "completed") }
        processQueue()
        refreshStorageUsage()
        Task { await self.enforceRetention() }
    }

    private func handleMediaFailure(taskId: Int, statusCode: Int?, resumeData: Data?, message: String) {
        if intentionalCancels.remove(taskId) != nil { return }
        guard var record = recordByTask(taskId) else { return }
        record.taskIdentifier = nil

        if let statusCode {
            switch statusCode {
            case 409:
                record.localStatus = .revoked
                record.serverStatus = "revoked"
                file.records[record.id] = record
                persist()
                processQueue()
                return
            case 404, 403:
                record.localStatus = .failed
                record.lastError = statusCode == 404 ? "not_found" : "forbidden"
                file.records[record.id] = record
                persist()
                processQueue()
                return
            case 401:
                file.records[record.id] = record
                scheduleRetry(recordId: record.id, resumeData: nil, refreshToken: true)
                return
            default:
                break
            }
        }

        if record.retryCount < Self.maxRetries {
            record.retryCount += 1
            file.records[record.id] = record
            scheduleRetry(recordId: record.id, resumeData: resumeData, refreshToken: false)
        } else {
            record.localStatus = .failed
            record.lastError = message
            file.records[record.id] = record
            persist()
            processQueue()
        }
    }

    private func scheduleRetry(recordId: String, resumeData: Data?, refreshToken: Bool) {
        let attempt = file.records[recordId]?.retryCount ?? 1
        let delaySeconds = min(120, Int(pow(2.0, Double(attempt))) * 5)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard let self, !self.scopeServerId.isEmpty else { return }
            guard let record = self.file.records[recordId], record.localStatus != .completed else { return }
            if refreshToken {
                // Force HTTPClient's single-flight 401 refresh so the next
                // background request carries a fresh token.
                _ = try? await ContinuumAPI.shared.listDownloads()
            }
            if let resumeData {
                let taskId = self.sessionDelegate.resume(data: resumeData)
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

    func reconcileWithServer(triggerPipeline: Bool) async {
        guard !scopeServerId.isEmpty, downloadsEnabled else { return }
        let rows: [ServerDownloadRow]
        do {
            rows = try await ContinuumAPI.shared.listDownloads()
        } catch {
            return
        }
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
        for row in rows where file.records[row.id] == nil {
            file.records[row.id] = makeRecord(from: row, type: row.episodeId != nil ? "episode" : nil)
        }
        persist()

        await reconnectActiveTasks()
        if triggerPipeline {
            processQueue()
            ensurePolling()
        }
    }

    /// After a relaunch the background session may have lost in-flight
    /// tasks (or finished them while we were dead). Re-queue records whose
    /// task is no longer live.
    private func reconnectActiveTasks() async {
        let active = await sessionDelegate.activeTaskIdentifiers()
        // `.fetchingAssets` records were mid-pipeline in a detached Task that
        // did not survive the relaunch; re-queue them too so they aren't
        // wedged (and don't keep occupying a concurrency slot forever).
        for (id, record) in file.records
        where record.localStatus == .downloading || record.localStatus == .fetchingAssets {
            if record.localStatus == .downloading,
               let taskId = record.taskIdentifier, active.contains(taskId) {
                continue
            }
            setLocalStatus(.queued, id: id)
        }
    }

    // MARK: - Series monitoring

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
        let response = try await ContinuumAPI.shared.createSubscription(request)
        upsertSubscription(response.subscription, seriesTitle: seriesTitle)
        persist()
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
        let response = try await ContinuumAPI.shared.updateSubscription(id: id, request)
        upsertSubscription(response.subscription, seriesTitle: existingTitle)
        persist()
        await reconcileWithServer(triggerPipeline: true)
    }

    func deleteSubscription(id: String) async {
        file.subscriptions.removeAll { $0.id == id }
        persist()
        try? await ContinuumAPI.shared.deleteSubscription(id: id)
    }

    /// Subscription sync + offline progress reconciliation, run on
    /// foreground. Client-driven: no server background worker.
    func runMonitoringAndProgressSync() async {
        guard downloadsEnabled else { return }
        if !file.subscriptions.isEmpty {
            _ = try? await ContinuumAPI.shared.syncSubscriptions()
        }
        await flushProgressQueue()
        await pullProgressDeltas()
        await reconcileWithServer(triggerPipeline: true)
        await enforceRetention()
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

        // Collapse to the latest event per item so an offline session that
        // ticks every few seconds doesn't grow an unbounded flush queue.
        file.progressQueue.removeAll { $0.mediaItemId == mediaItemId }
        file.progressQueue.append(QueuedProgress(
            id: UUID(),
            mediaItemId: mediaItemId,
            position: position,
            duration: duration,
            updatedAt: now,
            attempts: 0
        ))
        persist()
    }

    func flushProgressQueue() async {
        guard !file.progressQueue.isEmpty else { return }
        let items = file.progressQueue.map {
            SyncProgressItem(
                mediaItemId: $0.mediaItemId,
                position: $0.position,
                duration: $0.duration,
                forceOverwrite: false,
                updatedAt: $0.updatedAt
            )
        }
        let sentIds = Set(items.map { $0.mediaItemId })
        do {
            let results = try await ContinuumAPI.shared.syncProgressBatch(items: items)
            let okIds = Set(results.filter { $0.isOK }.map { $0.mediaItemId })
            // Only touch items that were part of this batch — items enqueued
            // while the POST was in flight keep their full retry budget.
            file.progressQueue.removeAll {
                okIds.contains($0.mediaItemId)
                    || ($0.attempts >= Self.maxRetries && sentIds.contains($0.mediaItemId))
            }
            for index in file.progressQueue.indices
            where sentIds.contains(file.progressQueue[index].mediaItemId) {
                file.progressQueue[index].attempts += 1
            }
            persist()
        } catch {
            // Keep the queue for the next reconnect.
        }
    }

    func pullProgressDeltas() async {
        do {
            let response = try await ContinuumAPI.shared.pullProgressDeltas(since: file.progressCursor)
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
        _ row: ServerDownloadRow,
        displayTitle: String?,
        displaySubtitle: String?,
        type: String?,
        seriesId: String?,
        posterThumbhash: String?
    ) {
        if let existing = file.records[row.id] {
            var merged = mergeExistingRecord(existing, with: row)
            if existing.localStatus == .failed || existing.localStatus == .revoked {
                merged.localStatus = mapInitialStatus(row.status)
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

    private func mergeExistingRecord(_ existing: DownloadRecord, with row: ServerDownloadRow) -> DownloadRecord {
        var record = existing
        if shouldReplaceLocalAssets(record, with: row) {
            discardLocalAssets(for: record)
            resetLocalAssets(on: &record, status: row.status)
        }
        applyServerRow(row, to: &record)
        return record
    }

    private func shouldReplaceLocalAssets(_ record: DownloadRecord, with row: ServerDownloadRow) -> Bool {
        if let currentRevision = record.revision,
           let serverRevision = row.revision,
           serverRevision > currentRevision {
            return true
        }
        if record.revision == nil {
            return record.mediaFileId != row.mediaFileId || record.format != row.quality
        }
        return false
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
        record.container = nil
        record.stableIdentity = nil
        record.bytesDownloaded = 0
        record.localStatus = mapInitialStatus(status)
        record.downloadedAt = nil
        record.lastError = nil
        record.retryCount = 0
        record.taskIdentifier = nil
    }

    private func applyServerRow(_ row: ServerDownloadRow, to record: inout DownloadRecord) {
        record.contentId = row.contentId
        record.mediaFileId = row.mediaFileId
        record.format = row.quality
        record.effectiveQuality = row.effectiveQuality
        record.deliveryFormat = row.deliveryFormat
        record.targetBitrateKbps = row.targetBitrateKbps
        record.revision = row.revision ?? record.revision
        record.serverStatus = row.status
        if let size = row.fileSize, size > 0, record.fileSize <= 0 {
            record.fileSize = size
        }
        if let completedAt = row.completedAt {
            record.downloadedAt = completedAt
        }
    }

    private func makeRecord(from row: ServerDownloadRow, type: String?) -> DownloadRecord {
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
            localStatus: mapInitialStatus(row.status),
            fileSize: row.fileSize ?? 0,
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
            registeredAt: row.createdAt ?? Date(),
            downloadedAt: row.completedAt,
            lastError: nil,
            retryCount: 0,
            taskIdentifier: nil
        )
    }

    private func mapInitialStatus(_ serverStatus: String) -> LocalDownloadStatus {
        switch serverStatus {
        case "ready": return .queued
        case "preparing": return .preparing
        case "revoked": return .revoked
        case "failed": return .failed
        default: return .registering
        }
    }

    private func upsertSubscription(_ server: ServerSubscription, seriesTitle: String?) {
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
        guard let seriesId = record.seriesId,
              let subscription = subscription(forSeriesId: seriesId),
              subscription.maxStorageBytes > 0 else {
            return false
        }
        let used = file.records.values
            .filter { $0.seriesId == seriesId && $0.localStatus == .completed }
            .reduce(Int64(0)) { $0 + $1.fileSize }
        return used + max(record.fileSize, 0) > subscription.maxStorageBytes
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

    private func persist() {
        guard !scopeServerId.isEmpty, !scopeProfileId.isEmpty else { return }
        lastProgressPersist = Date()
        let snapshot = file
        let serverId = scopeServerId
        let profileId = scopeProfileId
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
}

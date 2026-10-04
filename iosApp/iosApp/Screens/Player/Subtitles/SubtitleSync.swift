import Foundation
import Observation

/// The server calls ``SubtitleSyncModel`` makes for one server, by sync key.
struct SubtitleSyncEndpoints {
    var list: (_ mediaFileId: Int) async throws -> [SubtitleSyncState]
    var read: (_ mediaFileId: Int, _ key: String) async throws -> SubtitleSyncState
    /// Starts a sync, or returns the active job (coalescing).
    var start: (_ mediaFileId: Int, _ key: String) async throws -> SubtitleSyncJob
    var resetTiming: (_ mediaFileId: Int, _ key: String) async throws -> SubtitleSyncState

    /// The sync-key operations (`listSubtitleSync` and its siblings): stored
    /// subtitles and sidecar files alike.
    static let keyed = SubtitleSyncEndpoints(
        list: { try await SiloAI.shared.subtitleSyncStates(mediaFileId: $0) },
        read: { try await SiloAI.shared.subtitleSyncState(mediaFileId: $0, key: $1) },
        start: { file, key in
            guard let job = try await SiloAI.shared.startSubtitleSync(mediaFileId: file, key: key).sync else {
                throw APIv2Error.invalidSubtitleResponse
            }
            return job
        },
        resetTiming: { try await SiloAI.shared.resetSubtitleTiming(mediaFileId: $0, key: $1) }
    )

    /// A server that predates sync keys syncs stored subtitles only, through
    /// their own routes; the player names them `stored-{id}`.
    static let storedOnly = SubtitleSyncEndpoints(
        list: { try await SiloAI.shared.downloadedSubtitles(mediaFileId: $0).map(\.syncState) },
        read: { file, key in
            try await SiloAI.shared.storedSubtitleSync(id: storedId(key), mediaFileId: file).syncState
        },
        start: { _, key in try await SiloAI.shared.requestStoredSubtitleSync(id: storedId(key)) },
        resetTiming: { file, key in
            try await SiloAI.shared.resetStoredSubtitleTiming(id: storedId(key), mediaFileId: file).syncState
        }
    )

    private static func storedId(_ key: String) throws -> String {
        guard key.hasPrefix("stored-"), key.count > "stored-".count else { throw APIv2Error.invalidSubtitleResponse }
        return String(key.dropFirst("stored-".count))
    }
}

/// How ``SubtitleSyncModel`` reaches the server, injectable for tests.
struct SubtitleSyncService {
    var status: () async throws -> APIv2SubtitleSyncStatus
    /// The operations a server with this status answers.
    var endpoints: (APIv2SubtitleSyncStatus) -> SubtitleSyncEndpoints

    static let live = SubtitleSyncService(
        status: { try await SiloAI.shared.subtitleSyncStatus() },
        endpoints: { $0.usesSyncKeys ? .keyed : .storedOnly }
    )
}

/// Timing and sync state of the playing file's syncable subtitles (stored
/// ones and the subtitle files next to the media), by sync key: loads them,
/// follows running jobs through realtime updates with polling as the
/// fallback, performs "Sync to Audio" and "Reset Timing", and turns the
/// viewer's own jobs into the player's sync card. Mirrors the web player's
/// `useSubtitleSync` and `useSubtitleSyncFeedback`.
///
/// ``onTimingChanged`` fires once per observed timing change, so the player
/// fetches that track's cues again. A realtime `subtitle_timing_changed`
/// reports the change itself and marks the timing as already handled, so the
/// read that follows it does not ask for a second fetch.
@MainActor
@Observable
final class SubtitleSyncModel {
    struct Entry: Equatable {
        var state: SubtitleSyncState
        /// A sync or timing request is on the wire.
        var isBusy = false
        /// The server refused to let this viewer retime the subtitle (403).
        var isForbidden = false
        /// The subtitle's format cannot be synced (422).
        var isUnsupported = false
        /// The last action's failure, in plain words.
        var error: String?
        /// Polling gave up; reopening the menu re-arms it.
        var pollExpired = false
        /// A job this viewer started: a sync they asked for, or the automatic
        /// sync of a subtitle they just downloaded. The player reports its
        /// progress and outcome to them.
        var watchedJobId: String?

        var key: String { state.key }
        var job: SubtitleSyncJob? { state.sync }
        var isInProgress: Bool { state.sync?.isInProgress == true }
        var canReset: Bool { !state.timing.isIdentity }
        var statusLabel: String? { SubtitleSyncLabel.status(timing: state.timing, sync: state.sync) }
        /// The last finished job's result, when it says something.
        var result: SubtitleSyncLabel.Result? {
            guard !isInProgress, error == nil else { return nil }
            return SubtitleSyncLabel.result(timing: state.timing, sync: state.sync)
        }
        /// What "Sync to Audio" does, shown before the first result.
        var actionNote: String { SubtitleSyncLabel.actionNote(isExternal: state.isExternal) }
    }

    static let pollInterval: Duration = .seconds(3)
    static let pollLimit: TimeInterval = 5 * 60
    /// A realtime update this recent makes the next poll of that subtitle
    /// redundant.
    static let pushFreshness: TimeInterval = 4
    /// A `subtitle_timing_changed` this soon after this player fetched the
    /// track's cues again for the same change (a `subtitle_sync_updated`
    /// carrying the new timing) only re-reads the state.
    static let refetchCoalescing: TimeInterval = 2
    static let noticeDuration: Duration = .seconds(6)
    static let warningDuration: Duration = .seconds(9)
    /// How long "Applying new timing…" waits for the reloaded cues before it
    /// reports success anyway (a burned-in track never reloads).
    static let applyTimeout: Duration = .seconds(8)

    /// The server can align subtitles to audio, and this viewer may.
    private(set) var isSyncAvailable = false
    /// Sidecar files can be synced, not only stored subtitles.
    private(set) var isExternalSyncAvailable = false
    private(set) var entries: [String: Entry] = [:]
    /// The sync card: the progress and outcome of the viewer's own job, or a
    /// short note when someone else's change reached the track on screen.
    private(set) var notice: SubtitleSyncNotice?

    @ObservationIgnored var onTimingChanged: ((String) -> Void)?

    private enum KnownTiming: Equatable {
        case known(SubtitleTiming)
        /// A realtime event already reported this subtitle's change.
        case dirty
    }

    @ObservationIgnored private let service: SubtitleSyncService
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var endpoints: SubtitleSyncEndpoints?
    @ObservationIgnored private var mediaFileId: Int?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var knownTiming: [String: KnownTiming] = [:]
    @ObservationIgnored private var pollStarted: [String: Date] = [:]
    @ObservationIgnored private var pushedAt: [String: Date] = [:]
    @ObservationIgnored private var refetchedAt: [String: Date] = [:]
    @ObservationIgnored private var reading: Set<String> = []
    /// The file binding a listing is in flight for.
    @ObservationIgnored private var reloadingGeneration: Int?
    /// A listing was asked for while one was in flight.
    @ObservationIgnored private var reloadQueued = false
    /// Subtitles asked to be read again while a read of them was in flight.
    @ObservationIgnored private var rereads: Set<String> = []
    @ObservationIgnored private var pendingWatch: [String: String] = [:]
    /// Grows with each realtime update of a subtitle. A read sent before one
    /// arrived describes an older state and is dropped.
    @ObservationIgnored private var pushVersions: [String: Int] = [:]
    @ObservationIgnored private var usesSyncKeys = true
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    // Feedback inputs the player reports.
    @ObservationIgnored private var cueRevisions: [String: Int] = [:]
    @ObservationIgnored private var activeKey: String?
    @ObservationIgnored private var isActiveTrackLoading = false
    @ObservationIgnored private var feedback = SubtitleSyncFeedback()
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    /// The applying state `applyTask` waits on.
    @ObservationIgnored private var armedApplying: SubtitleSyncFeedback.Applying?

    init(service: SubtitleSyncService = .live, now: @escaping () -> Date = Date.init) {
        self.service = service
        self.now = now
    }

    /// Shown in place of the timing actions after the server refused them.
    var forbiddenMessage: String {
        usesSyncKeys
            ? "This server doesn't allow changing subtitle timing."
            : "Only the person who added this subtitle or an admin can change its timing."
    }

    func entry(for key: String?) -> Entry? {
        key.flatMap { entries[$0] }
    }

    /// Whether "Sync to Audio" applies to the entry.
    func canSync(_ entry: Entry) -> Bool {
        isSyncAvailable && !entry.isUnsupported && (!entry.state.isExternal || isExternalSyncAvailable)
    }

    /// Whether the timing controls have anything to show for the entry.
    func showsTimingControls(_ entry: Entry) -> Bool {
        isSyncAvailable && (entry.isForbidden || canSync(entry) || entry.canReset || entry.error != nil)
    }

    /// A track's one-line sync status ("Syncing… 40%", "Synced −3.0 s"),
    /// or nil when there is nothing to say or sync is unavailable.
    func statusLabel(for key: String?) -> String? {
        guard isSyncAvailable else { return nil }
        return entry(for: key)?.statusLabel
    }

    /// Points the model at the file now playing; `nil` when playback ends.
    /// A different file drops everything in flight.
    func bind(mediaFileId: Int?) {
        guard mediaFileId != self.mediaFileId else { return }
        generation &+= 1
        self.mediaFileId = mediaFileId
        entries = [:]
        knownTiming = [:]
        pollStarted = [:]
        pushedAt = [:]
        refetchedAt = [:]
        reading = []
        rereads = []
        reloadQueued = false
        pendingWatch = [:]
        pushVersions = [:]
        pollTask?.cancel()
        pollTask = nil
        cueRevisions = [:]
        activeKey = nil
        isActiveTrackLoading = false
        feedback = SubtitleSyncFeedback()
        noticeTask?.cancel()
        applyTask?.cancel()
        armedApplying = nil
        notice = nil
    }

    /// Re-reads the file's syncable subtitles and re-arms expired polls, so a
    /// job that finished while the menu was closed shows its result.
    func reload() async {
        guard let mediaFileId else { return }
        pollStarted = [:]
        for key in entries.keys { entries[key]?.pollExpired = false }
        // One listing at a time: a burst of realtime updates for a subtitle
        // not loaded yet asks for several. A request during a listing runs
        // one more after it, since the listing drops what a realtime update
        // superseded while it was on the wire.
        let current = generation
        guard reloadingGeneration != current else {
            reloadQueued = true
            return
        }
        reloadingGeneration = current
        defer { if reloadingGeneration == current { reloadingGeneration = nil } }
        repeat {
            reloadQueued = false
            // Sync state is decoration; the tracks still play without it.
            guard let endpoints = await probedEndpoints(), current == generation, isSyncAvailable else { return }
            let versions = pushVersions
            guard let states = try? await endpoints.list(mediaFileId), current == generation else { return }
            for state in states where pushVersions[state.key] == versions[state.key] { observe(state) }
            updatePolling()
            advanceFeedback()
        } while reloadQueued && current == generation
    }

    /// Records a subtitle the viewer just downloaded, following its
    /// automatic sync.
    func remember(_ subtitle: DownloadedSubtitle) {
        guard subtitle.mediaFileId == mediaFileId else { return }
        let state = subtitle.syncState
        pollStarted[state.key] = nil
        if let job = state.sync, job.isInProgress {
            watch(job, key: state.key)
        }
        observe(state)
        updatePolling()
        advanceFeedback()
        let current = generation
        Task {
            guard await probedEndpoints() != nil, current == generation else { return }
            advanceFeedback()
        }
    }

    /// The server announced new timing for `key` (realtime): reload its cues
    /// now and re-read its state.
    func timingChanged(key: String) {
        pushVersions[key, default: 0] += 1
        // A change this player fetched the cues for already (a sync update
        // carrying the new timing) is only re-read; the read still catches a
        // different timing that landed meanwhile. A recent fetch made for an
        // earlier timing_changed proves nothing about this one: its timing
        // was never known, so this change fetches the cues again.
        let fetchedAlready = knownTiming[key] != .dirty
            && refetchedAt[key].map { now().timeIntervalSince($0) < Self.refetchCoalescing } ?? false
        if !fetchedAlready {
            knownTiming[key] = .dirty
            refetchCues(key)
            advanceFeedback()
        }
        Task { await readOne(key) }
    }

    /// The server reported a step of a sync job (realtime).
    func syncUpdated(_ update: PlaybackRealtimeSubtitleSyncUpdatedPayload) {
        pushVersions[update.syncKey, default: 0] += 1
        guard let entry = entries[update.syncKey] else {
            // Not loaded yet (a track the inventory just gained): read them all.
            Task { await reload() }
            return
        }
        pushedAt[update.syncKey] = now()
        // News of the job: the poll limit counts from here.
        pollStarted[update.syncKey] = nil
        patch(update.syncKey) { $0.pollExpired = false }
        observe(entry.state.replacing(timing: update.timing, sync: update.job))
        updatePolling()
        advanceFeedback()
    }

    func requestSync(key: String) async {
        guard let mediaFileId, let endpoints, entries[key] != nil else { return }
        let current = generation
        patch(key) {
            $0.isBusy = true
            $0.error = nil
            $0.pollExpired = false
        }
        pollStarted[key] = nil
        let version = pushVersions[key]
        do {
            let job = try await endpoints.start(mediaFileId, key)
            guard current == generation, let entry = entries[key] else { return }
            watch(job, key: key)
            // A realtime update during the request described the job more
            // recently than its answer does.
            if pushVersions[key] == version {
                observe(entry.state.replacing(sync: job))
            }
            patch(key) { $0.isBusy = false }
            updatePolling()
            advanceFeedback()
        } catch {
            guard current == generation else { return }
            handleActionError(error, key: key, fallback: "Couldn't sync this subtitle. Try again.")
        }
    }

    func resetTiming(key: String) async {
        guard let mediaFileId, let endpoints, entries[key] != nil else { return }
        let current = generation
        patch(key) {
            $0.isBusy = true
            $0.error = nil
        }
        do {
            let state = try await endpoints.resetTiming(mediaFileId, key)
            guard current == generation else { return }
            observe(state)
            patch(key) { $0.isBusy = false }
            advanceFeedback()
        } catch {
            guard current == generation else { return }
            handleActionError(error, key: key, fallback: "Couldn't reset the timing. Try again.")
        }
    }

    // MARK: Player inputs

    /// The sync key of the primary track on screen, or nil.
    func setActiveTrack(key: String?) {
        guard key != activeKey else { return }
        activeKey = key
        advanceFeedback()
    }

    /// Whether the engine is loading the cues of the track on screen. A load
    /// that ends after the track's timing changed puts the new cues on screen.
    func setActiveTrackLoading(_ loading: Bool) {
        guard loading != isActiveTrackLoading else { return }
        isActiveTrackLoading = loading
        advanceFeedback()
    }

    func dismissNotice() {
        feedback.dismiss()
        publishFeedback()
    }

    // MARK: - Internals

    private func probedEndpoints() async -> SubtitleSyncEndpoints? {
        if let endpoints { return endpoints }
        guard let status = try? await service.status() else { return nil }
        if let endpoints { return endpoints }
        isSyncAvailable = status.isAvailable
        isExternalSyncAvailable = status.isAvailable && status.external == true
        usesSyncKeys = status.usesSyncKeys
        let resolved = service.endpoints(status)
        endpoints = resolved
        return resolved
    }

    private func patch(_ key: String, _ update: (inout Entry) -> Void) {
        guard var entry = entries[key] else { return }
        update(&entry)
        entries[key] = entry
    }

    /// Marks a job as this viewer's. A subtitle not loaded yet records it
    /// when it is first observed.
    private func watch(_ job: SubtitleSyncJob, key: String) {
        feedback.noteWatchStart(jobId: job.id, revision: cueRevisions[key, default: 0])
        if entries[key] != nil {
            patch(key) { $0.watchedJobId = job.id }
        } else {
            pendingWatch[key] = job.id
        }
    }

    /// Records a fresh server view of a subtitle and reports a timing change.
    private func observe(_ state: SubtitleSyncState) {
        let key = state.key
        let previous = knownTiming[key]
        knownTiming[key] = .known(state.timing)
        var entry = entries[key] ?? Entry(state: state)
        entry.state = state
        if let watched = pendingWatch.removeValue(forKey: key) {
            entry.watchedJobId = watched
        }
        if !entry.isInProgress {
            pollStarted[key] = nil
            entry.pollExpired = false
        }
        entries[key] = entry
        if case .known(let timing)? = previous, timing != state.timing {
            refetchCues(key)
        }
    }

    private func refetchCues(_ key: String) {
        cueRevisions[key, default: 0] += 1
        refetchedAt[key] = now()
        onTimingChanged?(key)
    }

    /// Reads one subtitle. A request while a read of it is in flight reads
    /// it once more afterwards: a realtime update that arrived meanwhile
    /// makes the answer in flight stale, so it is dropped.
    private func readOne(_ key: String) async {
        guard let mediaFileId, let endpoints else { return }
        guard !reading.contains(key) else {
            rereads.insert(key)
            return
        }
        let current = generation
        reading.insert(key)
        defer {
            // A reset swapped in a new set; never unlock a newer context's read.
            if current == generation { reading.remove(key) }
        }
        repeat {
            rereads.remove(key)
            let version = pushVersions[key]
            do {
                let state = try await endpoints.read(mediaFileId, key)
                guard current == generation else { return }
                if pushVersions[key] == version {
                    observe(state)
                    updatePolling()
                    advanceFeedback()
                }
            } catch {
                // A lost subtitle or file stops polling (a reload re-arms it); a
                // read that failed on the way is tried again at the next tick.
                guard current == generation else { return }
                if Self.stopsPolling(error) {
                    rereads.remove(key)
                    patch(key) { $0.pollExpired = true }
                    advanceFeedback()
                    return
                }
            }
        } while current == generation && rereads.contains(key)
    }

    private var pollingKeys: [String] {
        entries.values.filter { $0.isInProgress && !$0.pollExpired }.map(\.key).sorted()
    }

    private func updatePolling() {
        guard !pollingKeys.isEmpty else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        let current = generation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, current == self.generation, !Task.isCancelled else { return }
                guard await self.pollTick() else { return }
            }
        }
    }

    /// One poll of every running job. Returns false once nothing is left to
    /// poll. Realtime updates usually arrive first; a subtitle that had one
    /// recently skips the poll.
    private func pollTick() async -> Bool {
        let keys = pollingKeys
        guard !keys.isEmpty else {
            pollTask = nil
            return false
        }
        for key in keys {
            // The first tick starts the clock; remember() and reload() clear it.
            let started = pollStarted[key] ?? now()
            pollStarted[key] = started
            if now().timeIntervalSince(started) >= Self.pollLimit {
                pollStarted[key] = nil
                patch(key) { $0.pollExpired = true }
                advanceFeedback()
            } else if now().timeIntervalSince(pushedAt[key] ?? .distantPast) >= Self.pushFreshness {
                await readOne(key)
            }
        }
        return true
    }

    private func handleActionError(_ error: Error, key: String, fallback: String) {
        patch(key) { entry in
            entry.isBusy = false
            switch Self.httpStatus(of: error) {
            case 403:
                entry.isForbidden = true
                entry.error = nil
            case 422:
                entry.isUnsupported = true
                entry.error = "This format can't be synced."
            case 412:
                entry.error = "The subtitle changed. Try again."
            default:
                entry.error = fallback
            }
        }
    }

    /// Whether a failed poll means the subtitle or file is gone (or no longer
    /// readable by this viewer), rather than a read that failed on the way.
    nonisolated static func stopsPolling(_ error: Error) -> Bool {
        switch httpStatus(of: error) {
        case 401, 403, 404, 410: return true
        default: return false
        }
    }

    nonisolated static func httpStatus(of error: Error) -> Int? {
        switch error as? APIv2Error {
        case .problem(let problem)?: return problem.status
        case .httpStatus(let status)?: return status
        default: return nil
        }
    }

    // MARK: Feedback

    /// The most recent job this viewer started, among the file's subtitles.
    private var watchedEntry: Entry? {
        entries.values
            .filter { $0.watchedJobId != nil && $0.job?.id == $0.watchedJobId }
            .max { ($0.job?.createdAt ?? "") < ($1.job?.createdAt ?? "") }
    }

    /// Steps the feedback with what the model and the player know now.
    private func advanceFeedback() {
        // A running job whose polling gave up has no outcome coming; its
        // progress card leaves rather than stay forever.
        let latest = watchedEntry
        let following = latest.flatMap { $0.pollExpired && $0.isInProgress ? nil : $0 }
        if following == nil, let job = latest?.job, feedback.notice?.id == job.id,
           feedback.notice?.tone == .progress, feedback.applying == nil {
            feedback.dismiss()
        }
        let watched = following.flatMap { entry in
            entry.job.map { job in
                SubtitleSyncFeedback.Watched(key: entry.key, name: SubtitleSyncLabel.name(of: entry.state),
                    job: job, timing: entry.state.timing, revision: cueRevisions[entry.key, default: 0])
            }
        }
        let active = activeKey.flatMap { entries[$0] }
        feedback.step(SubtitleSyncFeedback.Input(
            watched: watched,
            activeKey: activeKey,
            activeRevision: activeKey.map { cueRevisions[$0, default: 0] } ?? 0,
            activeJob: active?.job,
            activeWatchedJobId: active?.watchedJobId,
            isActiveTrackLoading: isActiveTrackLoading
        ))
        publishFeedback()
    }

    /// Publishes the feedback's notice and arms its timers: finished notices
    /// leave on their own, and "Applying new timing…" gives up waiting for a
    /// reload that never reports.
    private func publishFeedback() {
        if notice != feedback.notice {
            notice = feedback.notice
            noticeTask?.cancel()
            noticeTask = nil
            if let shown = notice, shown.tone != .progress {
                let current = generation
                noticeTask = Task { [weak self] in
                    try? await Task.sleep(for: shown.tone == .warning ? Self.warningDuration : Self.noticeDuration)
                    guard let self, !Task.isCancelled, current == self.generation,
                          self.feedback.notice == shown else { return }
                    self.dismissNotice()
                }
            }
        }
        guard feedback.applying != armedApplying else { return }
        applyTask?.cancel()
        applyTask = nil
        armedApplying = feedback.applying
        guard let applying = feedback.applying else { return }
        let current = generation
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: Self.applyTimeout)
            guard let self, !Task.isCancelled, current == self.generation,
                  self.feedback.applying == applying else { return }
            self.feedback.finishApplying()
            self.publishFeedback()
        }
    }
}

/// What the player's sync card shows.
struct SubtitleSyncNotice: Equatable {
    enum Tone: Equatable {
        case progress, success, info, warning
    }

    /// Stays the same while one job runs, so the card updates in place.
    let id: String
    let tone: Tone
    let title: String
    var detail: String? = nil
    /// 0...100 while a job runs.
    var percent: Int? = nil
}

/// Turns sync state into one notice at a time for the viewer: the progress,
/// then the outcome, of a sync this viewer started; when it changed the
/// subtitle on screen, the moment its corrected cues show; and a note when
/// someone else's change to the subtitle on screen shows. A port of the web
/// player's `stepFeedback`.
struct SubtitleSyncFeedback {
    struct Watched: Equatable {
        let key: String
        /// "English", for "Syncing English subtitles".
        let name: String
        let job: SubtitleSyncJob
        let timing: SubtitleTiming
        /// The track's cue revision now.
        let revision: Int
    }

    /// What the model and the player know at one moment.
    struct Input: Equatable {
        /// The most recent job this viewer started, with its subtitle.
        var watched: Watched?
        /// Sync key of the track on screen.
        var activeKey: String?
        /// Cue revision of the track on screen: it grows each time the player
        /// fetches its cues again after a timing change.
        var activeRevision = 0
        /// The latest job of the track on screen, and the one this viewer
        /// started on it.
        var activeJob: SubtitleSyncJob?
        var activeWatchedJobId: String?
        var isActiveTrackLoading = false
    }

    struct Applying: Equatable {
        let key: String
        let jobId: String
        let detail: String
        /// The track's cue revision when the job started; a later one that
        /// loads shows the result.
        let startRevision: Int
    }

    private struct Foreign: Equatable {
        let key: String
        let revision: Int
    }

    private(set) var input: Input?
    private(set) var notice: SubtitleSyncNotice?
    private(set) var applying: Applying?
    /// Watched jobs whose outcome was announced.
    private var announced: Set<String> = []
    /// Watched synced jobs whose corrected cues are showing.
    private var applied: Set<String> = []
    /// Cue revision of a watched job's track when the job started.
    private var startRevision: [String: Int] = [:]
    /// The cue revision of each track whose cues finished loading last. A
    /// load that started before a timing change bumped the revision still
    /// shows the old cues; only a loading-to-loaded pass after it shows the
    /// corrected ones.
    private var loadedRevision: [String: Int] = [:]
    /// A timing change of the track on screen nobody here asked for, until it
    /// shows.
    private var foreign: Foreign?

    /// Records the cue revision of a track when the viewer starts a job on
    /// it, before the job's own timing change can bump it.
    mutating func noteWatchStart(jobId: String, revision: Int) {
        if startRevision[jobId] == nil { startRevision[jobId] = revision }
    }

    mutating func dismiss() {
        notice = nil
    }

    /// Shows the success the applying job earned once its cues show.
    mutating func finishApplying() {
        guard let applying else { return }
        self.applying = nil
        applied.insert(applying.jobId)
        notice = SubtitleSyncNotice(id: applying.jobId, tone: .success, title: "Subtitles synced",
                                    detail: applying.detail)
    }

    mutating func step(_ input: Input) {
        let before = self.input
        self.input = input

        if let key = input.activeKey, let before, before.activeKey == key,
           before.isActiveTrackLoading, !input.isActiveTrackLoading {
            loadedRevision[key] = input.activeRevision
        }

        if let watched = input.watched {
            let job = watched.job
            if startRevision[job.id] == nil { startRevision[job.id] = watched.revision }
            // Once its outcome is out, a job says nothing more, even when a
            // stale read still describes it as running.
            if !announced.contains(job.id) {
                if job.isInProgress {
                    show(SubtitleSyncNotice(
                        id: job.id, tone: .progress, title: "Syncing \(watched.name) subtitles",
                        detail: SubtitleSyncLabel.phase(job), percent: SubtitleSyncLabel.percent(job) ?? 0
                    ))
                } else {
                    announced.insert(job.id)
                    if job.status == "synced", watched.key == input.activeKey {
                        applying = Applying(key: watched.key, jobId: job.id,
                                            detail: SubtitleSyncLabel.describe(watched.timing),
                                            startRevision: startRevision[job.id] ?? watched.revision)
                        show(SubtitleSyncNotice(id: job.id, tone: .progress, title: "Applying new timing…",
                                                percent: 100))
                    } else {
                        show(Self.outcome(of: watched))
                    }
                }
            }
        }

        if let applying, applying.key != input.activeKey || loaded(applying.key, after: applying.startRevision) {
            finishApplying()
        }

        if let key = input.activeKey, let before, before.activeKey == key,
           input.activeRevision > before.activeRevision {
            let job = input.activeJob
            let own = input.activeWatchedJobId != nil && job?.id == input.activeWatchedJobId
                && (job?.isInProgress == true || (job?.status == "synced" && !applied.contains(job?.id ?? "")))
            if !own { foreign = Foreign(key: key, revision: before.activeRevision) }
        }
        if let foreign {
            if foreign.key != input.activeKey {
                self.foreign = nil
            } else if loaded(foreign.key, after: foreign.revision) {
                self.foreign = nil
                show(SubtitleSyncNotice(id: "timing:\(foreign.key):\(input.activeRevision)", tone: .info,
                                        title: "Subtitle timing updated"))
            }
        }
    }

    private func loaded(_ key: String, after revision: Int) -> Bool {
        (loadedRevision[key] ?? -1) > revision
    }

    private mutating func show(_ notice: SubtitleSyncNotice?) {
        if self.notice != notice { self.notice = notice }
    }

    private static func outcome(of watched: Watched) -> SubtitleSyncNotice? {
        let job = watched.job
        let name = watched.name
        switch job.status {
        case "synced":
            return SubtitleSyncNotice(id: job.id, tone: .success, title: "\(name) subtitles synced",
                                      detail: SubtitleSyncLabel.describe(watched.timing))
        case "already_synced":
            return SubtitleSyncNotice(id: job.id, tone: .info, title: "\(name) subtitles already match the audio")
        case "no_match":
            return SubtitleSyncNotice(id: job.id, tone: .warning, title: "\(name) subtitles don't match the audio",
                                      detail: "They're probably for another release. The timing wasn't changed.")
        case "failed":
            return SubtitleSyncNotice(id: job.id, tone: .warning, title: "Couldn't sync \(name) subtitles",
                                      detail: SubtitleSyncLabel.failure(job.failure))
        default:
            return nil
        }
    }
}

/// The words the player uses for subtitle sync, the same as the web
/// player's ("Synced −3.2 s", "Doesn't match this video", …).
enum SubtitleSyncLabel {
    /// One short line describing a subtitle's timing, or nil when there is
    /// nothing to say (never synced and never adjusted).
    static func status(timing: SubtitleTiming, sync: SubtitleSyncJob?) -> String? {
        switch sync?.status ?? "" {
        case "pending", "running":
            let percent = sync.flatMap(percent) ?? 0
            return percent > 0 ? "Syncing… \(percent)%" : "Syncing…"
        case "no_match":
            return "Doesn't match this video"
        case "failed":
            return "Sync failed"
        case "already_synced":
            if timing.isIdentity { return "Already in sync" }
        case "synced":
            if timing.isIdentity { return "Original timing" }
            if sync?.result == timing { return "Synced \(describe(timing))" }
        default:
            break
        }
        return timing.isIdentity ? nil : "Timing adjusted \(describe(timing))"
    }

    static func status(for subtitle: DownloadedSubtitle) -> String? {
        status(timing: subtitle.timing, sync: subtitle.sync)
    }

    /// An active job's progress as a whole percentage, or nil once it ended.
    static func percent(_ job: SubtitleSyncJob) -> Int? {
        guard job.isInProgress else { return nil }
        return Int((min(1, max(0, job.progress ?? 0)) * 100).rounded())
    }

    /// What an active job is doing, in a few words.
    static func phase(_ job: SubtitleSyncJob) -> String? {
        guard job.isInProgress else { return nil }
        switch job.phase {
        case "matching": return "Matching lines to speech…"
        case "analyzing": return "Listening to the audio…"
        default: return "Waiting to start…"
        }
    }

    /// Why a failed job failed, in plain words.
    static func failure(_ failure: String?) -> String {
        switch failure {
        case "subtitle_changed": return "The subtitle changed while it was syncing. Try again."
        case "no_audio": return "This video has no audio Silo can read."
        case "unavailable": return "The server is busy. Try again in a few minutes."
        default: return "Sync failed. Try again."
        }
    }

    struct Result: Equatable {
        let text: String
        var isWarning = false
    }

    /// The last finished job's result, for the selected track's timing
    /// controls.
    static func result(timing: SubtitleTiming, sync: SubtitleSyncJob?) -> Result? {
        switch sync?.status {
        case "synced":
            return timing.isIdentity ? nil : Result(text: "Synced to the audio: \(describe(timing))")
        case "already_synced":
            return Result(text: "Already matches the audio.")
        case "no_match":
            return Result(text: "Doesn't match this video's audio; probably for another release.", isWarning: true)
        case "failed":
            return Result(text: failure(sync?.failure), isWarning: true)
        default:
            return nil
        }
    }

    static func actionNote(isExternal: Bool) -> String {
        isExternal
            ? "Matches the timing to the audio for everyone. The file itself isn't changed."
            : "Matches the timing to the audio for everyone watching."
    }

    /// The subtitle's language ("English"), or its label.
    static func name(of state: SubtitleSyncState) -> String {
        if let key = SubtitleDisplayOrder.canonicalLanguageKey(state.language) {
            return SubtitleDisplayOrder.languageDisplayName(key)
        }
        return state.label.isEmpty ? "Subtitle" : state.label
    }

    /// "+2.3 s" / "−0.4 s".
    static func offset(_ offsetMs: Int) -> String {
        let seconds = Double(abs(offsetMs)) / 1000
        return "\(offsetMs < 0 ? "\u{2212}" : "+")\(String(format: "%.1f", seconds)) s"
    }

    private static let frameRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]

    /// Names a scale as the frame-rate conversion it most likely is
    /// ("25→23.976 fps"), or as a plain speed factor. Original time `t`
    /// plays at `t * scale`, so a subtitle cut for the faster rate `from`
    /// stretched onto the slower video rate `to` has `scale = from / to`.
    static func scale(_ scale: Double) -> String? {
        guard scale.isFinite, scale != 1 else { return nil }
        for from in frameRates {
            for to in frameRates where from != to && abs(from / to - scale) <= 1e-6 {
                return "\(rate(from))→\(rate(to)) fps"
            }
        }
        let rounded = (scale * 10_000).rounded() / 10_000
        return "×\(rate(rounded)) speed"
    }

    /// "+2.3 s · 25→23.976 fps": a correction in a few characters.
    static func describe(_ timing: SubtitleTiming) -> String {
        let scaleText = scale(timing.scale)
        let offsetText = timing.offsetMs != 0 || scaleText == nil ? offset(timing.offsetMs) : nil
        return [offsetText, scaleText].compactMap { $0 }.joined(separator: " · ")
    }

    /// `25` → "25", `23.976` → "23.976", as JavaScript prints numbers.
    private static func rate(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

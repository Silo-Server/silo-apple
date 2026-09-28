#if os(iOS)
import BackgroundTasks
import Foundation
import Observation
import OSLog

/// On iOS 26 and later, keeps Silo running while downloads the user started
/// are in progress, through a continued processing task. iOS draws its own
/// Live Activity for the task (title, subtitle, a progress ring, and a stop
/// button), so the downloads' progress stays live after Silo leaves the
/// screen and the queue keeps moving without waiting for a background wake.
///
/// The transfers themselves stay on the background `URLSession`. When the
/// task ends early, downloads keep going: only the live progress goes away.
/// iOS expires a task whose progress stops advancing for about 30 seconds and
/// then labels it failed, so the reported progress only ever grows, and Silo
/// ends the task itself first whenever nothing is moving (waiting for Wi-Fi,
/// a connection, or the server), saying what the downloads wait for.
@MainActor
@Observable
final class DownloadContinuedProcessing {
    static let shared = DownloadContinuedProcessing()
    private init() {}

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Downloads"
    )

    /// Each request needs a unique identifier under the wildcard listed in
    /// `BGTaskSchedulerPermittedIdentifiers` (iosApp/Info.plist).
    private static var identifierPrefix: String {
        (Bundle.main.bundleIdentifier ?? "org.siloserver.silo") + ".downloads.continued"
    }

    /// The progress total until the first byte counts arrive.
    private static let progressUnits: Int64 = 1_000_000
    /// A submitted request iOS hasn't started by now never will be; iOS can
    /// accept a request and then drop it without reporting an error.
    private static let startDeadline: Duration = .seconds(5)
    /// Silo ends the task after this long with no download moving at all,
    /// before iOS's own stall check marks it failed. While anything moves,
    /// the task keeps running and iOS alone decides.
    private static let stallLimit: TimeInterval = 20
    /// A named file slower than this, as a fraction of its size per second
    /// (1.5% per 30 seconds), hands the title to a faster one, so the pill
    /// names a download that is visibly moving.
    private static let minFractionPerSecond = 0.0005

    /// How the queue stood when Silo ended the task.
    enum Outcome {
        /// Every download finished.
        case completed
        /// Every download is paused.
        case paused
        /// Nothing left to download that finished (deleted, failed, or a
        /// registration that added nothing).
        case emptied
    }

    private enum State {
        case idle
        /// Submitted; iOS hasn't handed over the task yet.
        case submitted(identifier: String)
        /// Holds the `BGContinuedProcessingTask`.
        case running(AnyObject, identifier: String)
        /// The user stopped the task. Nothing shows the queue's progress
        /// until it empties or the user starts another download.
        case dismissed
    }

    private var state: State = .idle
    private var latest: DownloadActivityAttributes.ContentState?
    private var latestHeadline: DownloadRecord?
    /// The download the task's text names; see `pickReported`.
    private var reportedId: String?
    /// Bytes downloaded, across every download, since the task started.
    /// Only ever grows: iOS counts progress only once it passes its previous
    /// high, so a ring that stepped back (a new file starting, a finished one
    /// leaving the queue) read as a stall and the task expired.
    private var sessionBytes: Int64 = 0
    /// Each download's bytes at the last update, to count what arrived since.
    private var lastBytes: [String: Int64] = [:]
    private var remainingBytes: Int64 = 0
    private var transferredBytes: Int64 = 0
    /// When the queue last moved (new bytes or a finished download).
    private var lastMovedAt = Date()
    private var stallWatch: Task<Void, Never>?
    /// Completes the running task exactly once, from any thread.
    private var completion: TaskCompletion?
    private var lastSubtitleUpdate = Date.distantPast

    /// Whether this owns the queue's live progress, so Silo's own Live
    /// Activity stays out of the way.
    var ownsProgress: Bool {
        if case .idle = state { return false }
        return true
    }

    /// Starts the task for a download the user just started. Must run in
    /// the foreground, in direct response to the user's action. Does nothing
    /// while a task is already running or starting.
    func begin(title: String) {
        guard #available(iOS 26, *) else { return }
        switch state {
        case .submitted, .running:
            return
        case .idle, .dismissed:
            break
        }
        let identifier = "\(Self.identifierPrefix).\(UUID().uuidString)"
        // Each identifier is registered once, just before its request:
        // registering the wildcard itself doesn't match submitted requests.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { DownloadContinuedProcessing.shared.started(task, identifier: identifier) }
        }
        guard registered else {
            Self.logger.warning("Continued processing identifier not permitted")
            state = .idle
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Starting…")
        // Run now or not at all; Silo's own Live Activity covers the rest.
        request.strategy = .fail
        state = .submitted(identifier: identifier)
        lastMovedAt = Date()
        if #available(iOS 27, *) {
            // Reports errors the older call can't, and must not run on main.
            nonisolated(unsafe) let request = request
            DispatchQueue.global(qos: .userInitiated).async {
                BGTaskScheduler.shared.submitTaskRequest(request) { error in
                    guard let error else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            DownloadContinuedProcessing.shared.submitFailed(identifier: identifier, error: error)
                        }
                    }
                }
            }
        } else {
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                submitFailed(identifier: identifier, error: error)
                return
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.startDeadline)
            self?.abandonIfNotStarted(identifier: identifier)
        }
    }

    /// Mirrors the queue into the running task. `transferredBytes` counts
    /// every active download, including those of unknown size, to tell a
    /// moving queue from a stalled one.
    func update(
        _ content: DownloadActivityAttributes.ContentState,
        transferredBytes: Int64,
        headline fallback: DownloadRecord?,
        active: [DownloadRecord],
        rates: [String: Double]
    ) {
        if transferredBytes > self.transferredBytes
            || content.completedCount > (latest?.completedCount ?? content.completedCount) {
            lastMovedAt = Date()
        }
        let headline = pickReported(active: active, rates: rates) ?? fallback
        if case .running = state { accumulate(active) }
        latest = content
        latestHeadline = headline
        self.transferredBytes = transferredBytes
        guard #available(iOS 26, *), case .running(let object, _) = state,
              let task = object as? BGContinuedProcessingTask else { return }
        apply(content, headline: headline, to: task)
    }

    /// Ends the task on Silo's terms. A stop the user made stays in place
    /// while the queue still has downloads.
    func finish(_ outcome: Outcome) {
        switch state {
        case .idle:
            return
        case .dismissed:
            if outcome != .paused { state = .idle }
            return
        case .submitted:
            // Not cancelled: iOS shows a cancelled request as failed. If it
            // still starts, `started` completes it quietly.
            break
        case .running(let object, _):
            if #available(iOS 26, *), let task = object as? BGContinuedProcessingTask {
                switch outcome {
                case .completed:
                    task.progress.completedUnitCount = task.progress.totalUnitCount
                case .paused:
                    task.updateTitle(task.title, subtitle: "Paused")
                case .emptied:
                    break
                }
                completion?(success: true)
            }
        }
        endRun()
    }

    // MARK: - Task lifecycle

    @available(iOS 26, *)
    private func started(_ task: BGTask, identifier: String) {
        guard let task = task as? BGContinuedProcessingTask,
              case .submitted(let submitted) = state, submitted == identifier else {
            // Superseded: the queue finished, or the start came too late.
            // Complete it quietly rather than as a failure.
            task.setTaskCompleted(success: true)
            return
        }
        state = .running(task, identifier: identifier)
        lastMovedAt = Date()
        let completion = TaskCompletion { task.setTaskCompleted(success: $0) }
        self.completion = completion
        task.progress.totalUnitCount = Self.progressUnits
        task.expirationHandler = {
            // At once, on whatever thread iOS calls from: a busy main thread
            // must not delay it, or iOS ends the app too.
            completion(success: false)
            if Thread.isMainThread {
                MainActor.assumeIsolated { DownloadContinuedProcessing.shared.expired(identifier: identifier) }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { DownloadContinuedProcessing.shared.expired(identifier: identifier) }
                }
            }
        }
        if let latest { apply(latest, headline: latestHeadline, to: task) }
        stallWatch?.cancel()
        stallWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.endIfStalled()
            }
        }
    }

    /// iOS ended the task: the user tapped stop, or iOS reclaimed it (the
    /// handler can't tell which). While the queue was moving, that's taken
    /// as the user's stop; otherwise the queue had stalled and nothing is
    /// hidden on purpose.
    private func expired(identifier: String) {
        guard #available(iOS 26, *), case .running(let object, let current) = state, current == identifier,
              object is BGContinuedProcessingTask else { return }
        let wasMoving = Date().timeIntervalSince(lastMovedAt) < Self.stallLimit
        endRun()
        if wasMoving {
            Self.logger.notice("Continued processing stopped; downloads continue in the background")
            state = .dismissed
        }
    }

    private func endIfStalled() {
        guard #available(iOS 26, *), case .running(let object, _) = state,
              let task = object as? BGContinuedProcessingTask,
              Date().timeIntervalSince(lastMovedAt) >= Self.stallLimit else { return }
        // Read now: a lost network changes no download, so nothing pushed a
        // newer reason.
        let reason = DownloadManager.shared.currentWaitingReason() ?? "Waiting to continue"
        task.updateTitle(task.title, subtitle: "\(reason) · Downloads resume on their own")
        completion?(success: true)
        endRun()
        // Silo's own Live Activity takes over while the app is in front.
        DownloadManager.shared.refreshLiveProgress()
    }

    private func submitFailed(identifier: String, error: Error) {
        guard case .submitted(let submitted) = state, submitted == identifier else { return }
        Self.logger.notice("Continued processing not started: \(String(describing: error), privacy: .public)")
        state = .idle
        DownloadManager.shared.refreshLiveProgress()
    }

    private func abandonIfNotStarted(identifier: String) {
        guard case .submitted(let submitted) = state, submitted == identifier else { return }
        Self.logger.notice("Continued processing request never started")
        if #available(iOS 26, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        state = .idle
        DownloadManager.shared.refreshLiveProgress()
    }

    /// Silo is on screen, where its own Live Activity can show the queue.
    func clearDismissal() {
        if case .dismissed = state { state = .idle }
    }

    private func endRun() {
        stallWatch?.cancel()
        stallWatch = nil
        completion = nil
        state = .idle
        latest = nil
        latestHeadline = nil
        reportedId = nil
        transferredBytes = 0
        sessionBytes = 0
        lastBytes = [:]
        remainingBytes = 0
    }

    private func accumulate(_ active: [DownloadRecord]) {
        var remaining: Int64 = 0
        for record in active {
            let bytes = max(record.bytesDownloaded, 0)
            // A download seen for the first time, or one that restarted from
            // zero, only sets its baseline.
            if let last = lastBytes[record.id], bytes > last { sessionBytes += bytes - last }
            lastBytes[record.id] = bytes
            if record.fileSize > bytes { remaining += record.fileSize - bytes }
        }
        remainingBytes = remaining
    }

    /// The transfer whose own progress moves fastest for its size, which the
    /// task reports: iOS judges the task by that one progress value, and a
    /// file starved by its neighbours would look stalled. The choice sticks
    /// while its file keeps moving fast enough, so the pill doesn't flip
    /// between titles.
    private func pickReported(active: [DownloadRecord], rates: [String: Double]) -> DownloadRecord? {
        let transferring = active.filter {
            $0.localStatus == .downloading && $0.taskIdentifier != nil && $0.fileSize > 0
        }
        func speed(_ record: DownloadRecord) -> Double {
            (rates[record.id] ?? 0) / Double(record.fileSize)
        }
        let current = transferring.first { $0.id == reportedId }
        let chosen: DownloadRecord?
        if let current, speed(current) >= Self.minFractionPerSecond {
            chosen = current
        } else if let fastest = transferring.max(by: { speed($0) < speed($1) }), speed(fastest) > 0 {
            chosen = fastest
        } else {
            chosen = current
        }
        reportedId = chosen?.id
        return chosen
    }

    /// Reports the headline file's bytes, as its own row does. iOS expires a
    /// task whose progress looks stalled, and a fraction of a whole queue
    /// (or of a 50 GB file's neighbours) moves too little to count.
    @available(iOS 26, *)
    private func apply(
        _ content: DownloadActivityAttributes.ContentState, headline: DownloadRecord?, to task: BGContinuedProcessingTask
    ) {
        // Bytes since the task started, out of those plus what's left.
        let progress = task.progress
        let total = max(sessionBytes + remainingBytes, sessionBytes + 1)
        if progress.totalUnitCount != total { progress.totalUnitCount = total }
        if progress.completedUnitCount != sessionBytes { progress.completedUnitCount = sessionBytes }
        // Each title change crosses to the system; once a second is plenty
        // for a byte count.
        let subtitle = Self.subtitle(for: content, headline: headline)
        let title = headline.map(Self.title(for:)) ?? content.title
        if task.title != title
            || (task.subtitle != subtitle && Date().timeIntervalSince(lastSubtitleUpdate) >= 1) {
            task.updateTitle(title, subtitle: subtitle)
            lastSubtitleUpdate = Date()
        }
    }

    nonisolated static func title(for record: DownloadRecord) -> String {
        if record.type == "episode", let episode = record.subtitle, !episode.isEmpty {
            return "\(record.seriesTitle ?? record.title ?? "Episode") · \(episode)"
        }
        return record.title ?? record.seriesTitle ?? "Download"
    }

    /// The headline file's "427.29 MB / 1.42 GB", led by "2 of 5 done" when
    /// several downloads are in the queue.
    nonisolated static func subtitle(
        for content: DownloadActivityAttributes.ContentState, headline: DownloadRecord?
    ) -> String {
        var parts: [String] = []
        if content.totalCount > 1 {
            parts.append("\(content.completedCount) of \(content.totalCount) done")
        }
        switch content.phase {
        case .preparing:
            parts.append("Preparing on server…")
        case .paused:
            parts.append("Paused")
        case .downloading, .completed:
            if let headline, headline.fileSize > 0 {
                parts.append(headline.bytesDownloaded.formatted(.byteCount(style: .file))
                    + " / " + headline.fileSize.formatted(.byteCount(style: .file)))
            } else {
                parts.append("Starting…")
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Completes a continued processing task at most once, whichever of the
/// expiration handler (any thread) and Silo (main actor) gets there first.
private final class TaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let complete: (Bool) -> Void

    init(_ complete: @escaping (Bool) -> Void) {
        self.complete = complete
    }

    func callAsFunction(success: Bool) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { complete(success) }
    }
}
#endif

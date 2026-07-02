#if os(iOS)
import ActivityKit
import Foundation

/// Owns the single downloads Live Activity: starts it when the queue gains
/// its first active record, updates it as `DownloadManager` publishes
/// progress, and ends it when the queue drains.
///
/// Fed exclusively from `DownloadManager.file`'s `didSet`, so every state
/// mutation flows through here; identical content states are deduped before
/// touching ActivityKit, and the manager's 1s progress-publish cadence
/// already keeps update frequency readable.
///
/// Known limitation, by design: transfers run on a background `URLSession`,
/// whose progress callbacks stop once iOS suspends the app. The content is
/// stamped with a short `staleDate` so the widget can switch to a
/// "Continuing in background…" treatment instead of freezing a live-looking
/// bar; the completion relaunch then ends the activity with a final state.
@MainActor
final class DownloadLiveActivityController {
    static let shared = DownloadLiveActivityController()
    private init() {}

    private var activity: Activity<DownloadActivityAttributes>?
    private var adoptedExisting = false
    /// Every record id seen active while the current activity has been live.
    /// Intersected with the completed set each sync to produce the
    /// "2 of 5" numerator — the store itself has no notion of "finished
    /// during this batch".
    private var trackedActiveIds: Set<String> = []
    private var sessionCompletedIds: Set<String> = []
    private var lastState: DownloadActivityAttributes.ContentState?
    /// Serializes ActivityKit calls so a burst of syncs can't land updates
    /// out of order (mirror of `DownloadManager.saveChain`).
    private var activityChain: Task<Void, Never>?

    /// How long after the last update the widget may treat the content as
    /// current. Progress publishes every ~1s while the app runs, so blowing
    /// past this means the app was suspended mid-transfer.
    private static let staleInterval: TimeInterval = 90
    /// How long the final "complete" card lingers on the lock screen.
    private static let completedLinger: TimeInterval = 240

    func sync(
        activeRecords: [DownloadRecord],
        completedRecordIds: Set<String>,
        totalBytesPerSecond: Double
    ) {
        adoptExistingActivityIfNeeded()
        sessionCompletedIds.formUnion(trackedActiveIds.intersection(completedRecordIds))
        trackedActiveIds.formUnion(activeRecords.map(\.id))

        guard !activeRecords.isEmpty else {
            finishActivity()
            return
        }
        let state = makeState(activeRecords: activeRecords, totalBytesPerSecond: totalBytesPerSecond)
        guard state != lastState else { return }
        if let activity {
            lastState = state
            queueUpdate(activity, state: state)
        } else {
            startActivity(state)
        }
    }

    // MARK: - Lifecycle

    private func startActivity(_ state: DownloadActivityAttributes.ContentState) {
        // Don't resurrect an activity at launch for a queue that's entirely
        // user-paused — a days-old paused download shouldn't repopulate the
        // lock screen every time the app opens. An already-live activity
        // still updates into the paused state normally.
        guard state.phase != .paused else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Requesting throws when the app isn't foreground — e.g. a
        // monitored-series download kicked off by a background refresh.
        // Silent by design: the next foreground sync starts it.
        activity = try? Activity.request(
            attributes: DownloadActivityAttributes(),
            content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleInterval))
        )
        if activity != nil { lastState = state }
    }

    private func queueUpdate(
        _ activity: Activity<DownloadActivityAttributes>,
        state: DownloadActivityAttributes.ContentState
    ) {
        let previous = activityChain
        activityChain = Task {
            await previous?.value
            await activity.update(
                ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleInterval))
            )
        }
    }

    private func finishActivity() {
        let completedCount = sessionCompletedIds.count
        sessionCompletedIds.removeAll()
        trackedActiveIds.removeAll()
        lastState = nil
        guard let activity else { return }
        self.activity = nil
        let previous = activityChain
        activityChain = Task {
            await previous?.value
            if completedCount > 0 {
                let state = DownloadActivityAttributes.ContentState(
                    phase: .completed,
                    title: completedCount == 1
                        ? "Download complete"
                        : "\(completedCount) downloads complete",
                    subtitle: nil,
                    fraction: 1,
                    bytesDownloaded: 0,
                    bytesExpected: 0,
                    completedCount: completedCount,
                    totalCount: completedCount,
                    bytesPerSecond: nil
                )
                await activity.end(
                    ActivityContent(state: state, staleDate: nil),
                    dismissalPolicy: .after(Date().addingTimeInterval(Self.completedLinger))
                )
            } else {
                // The queue drained without finishing anything (cancelled,
                // failed, signed out) — nothing worth lingering for.
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// A relaunch can find the previous run's activity still on the lock
    /// screen. Adopt it instead of stacking a duplicate; fold any extras
    /// (there should only ever be one).
    private func adoptExistingActivityIfNeeded() {
        guard !adoptedExisting else { return }
        adoptedExisting = true
        let existing = Activity<DownloadActivityAttributes>.activities
        guard !existing.isEmpty else { return }
        activity = existing.first
        for extra in existing.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    // MARK: - State

    private func makeState(
        activeRecords: [DownloadRecord],
        totalBytesPerSecond: Double
    ) -> DownloadActivityAttributes.ContentState {
        // `activeRecords` arrives newest-first; headline the transfer the
        // user has been waiting on longest.
        let headline = activeRecords.reversed().first {
            $0.localStatus == .downloading || $0.localStatus == .fetchingAssets
        } ?? activeRecords.last

        let completedCount = sessionCompletedIds.count
        let totalCount = completedCount + activeRecords.count
        let fractionSum = activeRecords.reduce(0.0) { $0 + $1.progressFraction }
        let fraction = totalCount > 0
            ? min(1, (Double(completedCount) + fractionSum) / Double(totalCount))
            : 0

        let sized = activeRecords.filter { $0.fileSize > 0 }
        let bytesDownloaded = sized.reduce(Int64(0)) { $0 + min($1.bytesDownloaded, $1.fileSize) }
        let bytesExpected = sized.reduce(Int64(0)) { $0 + $1.fileSize }

        let phase: DownloadActivityAttributes.ContentState.Phase
        if activeRecords.contains(where: {
            $0.localStatus == .downloading || $0.localStatus == .fetchingAssets
        }) {
            phase = .downloading
        } else if activeRecords.allSatisfy({ $0.localStatus == .paused }) {
            phase = .paused
        } else {
            phase = .preparing
        }

        let title = headline?.title
            ?? headline?.seriesTitle
            ?? (activeRecords.count == 1 ? "Download" : "\(activeRecords.count) downloads")
        var subtitleParts: [String] = []
        if let headline {
            if let series = headline.seriesTitle, series != title {
                subtitleParts.append(series)
            }
            if let sub = headline.subtitle {
                subtitleParts.append(sub)
            }
        }

        return DownloadActivityAttributes.ContentState(
            phase: phase,
            title: title,
            subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · "),
            fraction: fraction,
            bytesDownloaded: bytesDownloaded,
            bytesExpected: bytesExpected,
            completedCount: completedCount,
            totalCount: totalCount,
            bytesPerSecond: phase == .downloading && totalBytesPerSecond > 0
                ? totalBytesPerSecond
                : nil
        )
    }
}
#endif

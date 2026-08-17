#if os(iOS)
import BackgroundTasks
import Foundation
import OSLog

/// Schedules and services the app-refresh task that keeps series monitoring
/// alive while the app is backgrounded. Media transfers already ride the
/// background `URLSession` on their own; this task exists only to run the
/// subscription/progress sync and kick the pipeline for anything it
/// registered — without it, "auto-download new episodes" would only happen
/// when the user opens the app.
enum DownloadBackgroundRefresh {
    /// Must stay listed in `BGTaskSchedulerPermittedIdentifiers`
    /// (iosApp/Info.plist); the scheduler rejects submissions for
    /// identifiers outside that allowlist.
    static let taskIdentifier = "com.continuum.play.downloads-refresh"

    /// A floor, not a promise — iOS picks the real cadence from usage
    /// patterns. Hours-scale matches the monitoring feature: new episodes
    /// land on a release schedule, not minute-by-minute.
    private static let earliestInterval: TimeInterval = 4 * 60 * 60

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Downloads"
    )

    /// Must run before `didFinishLaunching` returns — the system traps if a
    /// task it launched the app for has no registered handler.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    /// Submit (or re-submit) the next refresh. Safe to call on every
    /// background transition — a pending request with the same identifier is
    /// replaced, not stacked.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected on the simulator (BGTaskScheduler is unavailable)
            // and when the user disabled Background App Refresh; the
            // foreground sync path still covers both.
            logger.debug("BG refresh submit failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // Chain the next wake before doing any work so an expiration or
        // crash mid-sync doesn't drop the schedule.
        schedule()
        let work = Task { @MainActor in
            // A cold BGTaskScheduler launch lands here before
            // ContentView.checkInitialState() has pointed TokenStore at the
            // active registry server, and the sync authenticates through
            // it. Idempotent on every later call.
            if let serverId = ServerRegistry.shared.activeServerId, !serverId.isEmpty {
                await TokenStore.shared.retargetActiveServer(serverId: serverId)
            }
            // Same capability-gated path as a foreground activation:
            // activate scope → refresh capability → reconcile →
            // monitoring/progress sync (which also kicks the pipeline).
            await DownloadManager.shared.onAppActive()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = {
            // Abandon cleanly: the sync's HTTP calls are async URLSession
            // requests, so cancellation propagates and the task above
            // finishes fast, reporting `success: false` via the flag.
            work.cancel()
        }
    }
}
#endif

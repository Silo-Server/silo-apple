#if os(iOS)
import UIKit
import UserNotifications

extension SiloAppDelegate: UNUserNotificationCenterDelegate {
    /// iOS gives background remote-notification wakes roughly 30 seconds to
    /// call the completion handler, while HTTPClient's default URLSession
    /// request timeout is 60 seconds — so the syncs are raced against a
    /// deadline that leaves the system budget intact. 20s (up from 15s)
    /// because the wake now also runs the download monitoring sync, whose
    /// chain of sequential requests ends with the pipeline kick that
    /// enqueues new episodes — cutting it short loses the enqueue.
    private static let backgroundSyncDeadlineSeconds: TimeInterval = 20

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // BGTaskScheduler requires every identifier to be registered before
        // launch finishes — the system traps when it launches the app for a
        // task with no handler.
        DownloadBackgroundRefresh.register()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadSessionDelegate.sessionIdentifier else {
            completionHandler()
            return
        }
        Task { @MainActor in
            // Touching `shared` recreates the background session so its
            // buffered events replay; the handler fires once the manager
            // drains `allEventsDelivered`. Scope activation runs right
            // after so finished media can resolve its on-disk destination
            // even on a cold background relaunch.
            DownloadManager.shared.setBackgroundCompletionHandler(completionHandler)
            // A cold background relaunch lands here before
            // ContentView.checkInitialState() has pointed TokenStore at the
            // active registry server; activating against an unresolved
            // profile would release the held session events into an empty
            // scope and discard the staged completions.
            if let serverId = ServerRegistry.shared.activeServerId, !serverId.isEmpty {
                await TokenStore.shared.retargetActiveServer(serverId: serverId)
            }
            await DownloadManager.shared.activateScopeIfNeeded()
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await ApplePushRegistrationCoordinator.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        ApplePushRegistrationCoordinator.shared.didFailToRegisterForRemoteNotifications(error: error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let synced = await Self.syncWithDeadline(Self.backgroundSyncDeadlineSeconds)
            completionHandler(synced ? .newData : .noData)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Present immediately: the inbox sync must never delay the banner,
        // and the system only waits a few seconds for this return value.
        // Local download notifications carry no inbox payload, so only a
        // remote push kicks the sync.
        if notification.request.trigger is UNPushNotificationTrigger {
            Task { @MainActor in
                await ApplePushNotificationSyncCoordinator.shared.refreshFromRemoteNotification()
            }
        }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Navigation depends only on the payload already in hand — post the
        // deep link before any network work so the tap routes instantly.
        let userInfo = response.notification.request.content.userInfo
        await ApplePushDeepLinkCoordinator.shared.postDeepLink(from: userInfo)
        if response.notification.request.trigger is UNPushNotificationTrigger {
            Task { @MainActor in
                await ApplePushNotificationSyncCoordinator.shared.refreshFromRemoteNotification()
            }
        }
    }

    /// Runs the notification-inbox sync and the download monitoring sync,
    /// but returns `false` once the deadline passes, cancelling the
    /// underlying requests. The completion handler for a background wake
    /// must be called inside the system budget even when the server is
    /// unreachable.
    @MainActor
    private static func syncWithDeadline(_ seconds: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                // A cold background launch lands here before
                // ContentView.checkInitialState() has pointed TokenStore at
                // the active registry server, and both syncs authenticate
                // through it. Idempotent on every later call.
                if let serverId = ServerRegistry.shared.activeServerId, !serverId.isEmpty {
                    await TokenStore.shared.retargetActiveServer(serverId: serverId)
                }
                async let inboxSynced = ApplePushNotificationSyncCoordinator.shared
                    .refreshFromRemoteNotification()
                // Same path as DownloadBackgroundRefresh: a new-episode push
                // for a monitored series registers the episode and enqueues
                // it into the background URLSession here, so the transfer
                // runs out-of-process without the user opening the app.
                //
                // Deadline check between the phases: `withTaskGroup` only
                // returns once this child unwinds, so when the timer has
                // already won (cancelAll ran) don't start the download sync
                // — it would hold the completion handler past the budget.
                if !Task.isCancelled {
                    await DownloadManager.shared.onAppActive()
                }
                return await inboxSynced
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
#endif

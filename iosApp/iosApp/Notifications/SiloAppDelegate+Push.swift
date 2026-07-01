#if os(iOS)
import UIKit
import UserNotifications

extension SiloAppDelegate: UNUserNotificationCenterDelegate {
    /// iOS gives background remote-notification wakes roughly 30 seconds to
    /// call the completion handler, while HTTPClient's default URLSession
    /// request timeout is 60 seconds — so the sync is raced against a
    /// deadline that leaves the system budget intact.
    private static let backgroundSyncDeadlineSeconds: TimeInterval = 15

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
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
        Task { @MainActor in
            await ApplePushNotificationSyncCoordinator.shared.refreshFromRemoteNotification()
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
        Task { @MainActor in
            await ApplePushNotificationSyncCoordinator.shared.refreshFromRemoteNotification()
        }
    }

    /// Runs the notification sync but returns `false` once the deadline
    /// passes, cancelling the underlying request. The completion handler for
    /// a background wake must be called inside the system budget even when
    /// the server is unreachable.
    @MainActor
    private static func syncWithDeadline(_ seconds: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                await ApplePushNotificationSyncCoordinator.shared.refreshFromRemoteNotification()
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

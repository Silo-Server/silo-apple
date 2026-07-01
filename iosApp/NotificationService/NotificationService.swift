import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    /// Guards all mutable state below. `didReceive` and
    /// `serviceExtensionTimeWillExpire` arrive on system-owned threads while
    /// the enrichment task completes on the Swift concurrency pool, and the
    /// system's content handler must be invoked exactly once.
    private let stateLock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var enrichmentTask: Task<Void, Never>?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        stateLock.lock()
        self.contentHandler = contentHandler
        stateLock.unlock()

        guard let bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
            complete(with: request.content)
            return
        }
        stateLock.lock()
        self.bestAttemptContent = bestAttemptContent
        stateLock.unlock()

        guard let deliveryID = ApplePushDisplayWire.deliveryID(from: bestAttemptContent.userInfo),
              let state = ApplePushDisplayStateReader().currentState() else {
            complete(with: bestAttemptContent)
            return
        }

        let client = ApplePushDisplayClient()
        let task = Task { [weak self, bestAttemptContent] in
            do {
                let response = try await client.fetchDisplay(deliveryID: deliveryID, state: state)
                response.apply(to: bestAttemptContent)
            } catch {
                // The generic APNs fallback remains the notification content.
            }
            self?.complete(with: bestAttemptContent)
        }
        stateLock.lock()
        if self.contentHandler == nil {
            // Already completed (expiry raced ahead); the task's own
            // complete(with:) will no-op, so just stop the fetch.
            stateLock.unlock()
            task.cancel()
        } else {
            self.enrichmentTask = task
            stateLock.unlock()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        stateLock.lock()
        let task = enrichmentTask
        let content = bestAttemptContent
        stateLock.unlock()
        task?.cancel()
        if let content {
            complete(with: content)
        }
    }

    private func complete(with content: UNNotificationContent) {
        stateLock.lock()
        let handler = contentHandler
        contentHandler = nil
        bestAttemptContent = nil
        enrichmentTask = nil
        stateLock.unlock()
        handler?(content)
    }
}

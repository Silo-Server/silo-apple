import Synchronization
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private struct State {
        var contentHandler: ((UNNotificationContent) -> Void)?
        var bestAttemptContent: UNMutableNotificationContent?
        var enrichmentTask: Task<Void, Never>?
    }

    /// `didReceive` and `serviceExtensionTimeWillExpire` arrive on
    /// system-owned threads while the enrichment task completes on the Swift
    /// concurrency pool, and the system's content handler must be invoked
    /// exactly once.
    private let state = Mutex(State())

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        state.withLock { $0.contentHandler = contentHandler }

        guard let bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
            complete(with: request.content)
            return
        }
        state.withLock { $0.bestAttemptContent = bestAttemptContent }

        guard let deliveryID = ApplePushDisplayWire.deliveryID(from: bestAttemptContent.userInfo),
              let displayState = ApplePushDisplayStateReader().currentState() else {
            complete(with: bestAttemptContent)
            return
        }

        let client = ApplePushDisplayClient()
        let task = Task { [weak self, bestAttemptContent] in
            do {
                let response = try await client.fetchDisplay(deliveryID: deliveryID, state: displayState)
                response.apply(to: bestAttemptContent)
            } catch {
                // The generic APNs fallback remains the notification content.
            }
            self?.complete(with: bestAttemptContent)
        }
        let alreadyCompleted = state.withLock { state in
            // Expiry may have completed already; then the task's own
            // complete(with:) no-ops, so just stop the fetch.
            guard state.contentHandler != nil else { return true }
            state.enrichmentTask = task
            return false
        }
        if alreadyCompleted { task.cancel() }
    }

    override func serviceExtensionTimeWillExpire() {
        let (task, content) = state.withLock { ($0.enrichmentTask, $0.bestAttemptContent) }
        task?.cancel()
        if let content {
            complete(with: content)
        }
    }

    private func complete(with content: UNNotificationContent) {
        let handler = state.withLock { state in
            let handler = state.contentHandler
            state = State()
            return handler
        }
        handler?(content)
    }
}

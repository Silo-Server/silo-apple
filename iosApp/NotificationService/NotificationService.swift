import OSLog
import Synchronization
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private struct State {
        var contentHandler: ((UNNotificationContent) -> Void)?
        var bestAttemptContent: UNMutableNotificationContent?
        var enrichmentTask: Task<Void, Never>?
        var startedAt = Date()
        var credential: String?
    }

    private static let logger = Logger(subsystem: "org.siloserver.silo.NotificationService", category: "display")

    /// `didReceive` and `serviceExtensionTimeWillExpire` arrive on
    /// system-owned threads while the enrichment task completes on the Swift
    /// concurrency pool, and the system's content handler must be invoked
    /// exactly once.
    private let state = Mutex(State())

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let startedAt = Date()
        state.withLock {
            $0.contentHandler = contentHandler
            $0.startedAt = startedAt
        }

        guard let bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
            complete(with: request.content)
            return
        }
        state.withLock { $0.bestAttemptContent = bestAttemptContent }

        guard let deliveryID = ApplePushDisplayWire.deliveryID(from: bestAttemptContent.userInfo) else {
            complete(with: bestAttemptContent)
            return
        }
        let displayState = ApplePushDisplayStateReader().storedState()
        let missing = displayState.missingParts
        guard missing.isEmpty else {
            complete(with: bestAttemptContent, outcome: ApplePushDisplayOutcome(
                kind: .missingState,
                reason: missing.joined(separator: ","),
                attempts: 0,
                credential: nil,
                startedAt: startedAt
            ))
            return
        }
        state.withLock { $0.credential = displayState.credentialKind }

        let client = ApplePushDisplayClient()
        let task = Task { [weak self, bestAttemptContent] in
            let result = await client.fetchDisplay(deliveryID: deliveryID, state: displayState)
            if case .success(let response) = result.outcome {
                response.apply(to: bestAttemptContent)
            }
            // On failure the generic APNs fallback remains the notification content.
            self?.complete(
                with: bestAttemptContent,
                outcome: ApplePushDisplayOutcome(result: result, startedAt: startedAt)
            )
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
        let (task, content, startedAt, credential) = state.withLock {
            ($0.enrichmentTask, $0.bestAttemptContent, $0.startedAt, $0.credential)
        }
        task?.cancel()
        if let content {
            complete(with: content, outcome: ApplePushDisplayOutcome(
                kind: .expired,
                reason: nil,
                attempts: 0,
                credential: credential,
                startedAt: startedAt
            ))
        }
    }

    /// Hands `content` to the system once. Only the call that does so records
    /// `outcome`, so a fetch finishing after expiry cannot log a second one.
    private func complete(with content: UNNotificationContent, outcome: ApplePushDisplayOutcome? = nil) {
        let handler = state.withLock { state in
            let handler = state.contentHandler
            state = State()
            return handler
        }
        guard let handler else { return }
        if let outcome {
            Self.logger.log("Push display \(outcome.kind.rawValue, privacy: .public) reason=\(outcome.reason ?? "-", privacy: .public) attempts=\(outcome.attempts, privacy: .public) duration_ms=\(outcome.durationMs, privacy: .public) credential=\(outcome.credential ?? "-", privacy: .public)")
            ApplePushDisplayOutcomeLog.append(outcome)
        }
        handler(content)
    }
}

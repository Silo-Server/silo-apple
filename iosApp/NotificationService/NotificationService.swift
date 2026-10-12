import OSLog
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private static let logger = Logger(subsystem: "org.siloserver.silo.NotificationService", category: "display")

    private let completion = ApplePushDisplayCompletion { outcome in
        NotificationService.logger.log("Push display \(outcome.kind.rawValue, privacy: .public) reason=\(outcome.reason ?? "-", privacy: .public) attempts=\(outcome.attempts, privacy: .public) duration_ms=\(outcome.durationMs, privacy: .public) credential=\(outcome.credential ?? "-", privacy: .public)")
        ApplePushDisplayOutcomeLog.append(outcome)
    }

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let startedAt = Date()
        completion.begin(handler: contentHandler, startedAt: startedAt)

        guard let bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
            completion.complete(with: request.content)
            return
        }
        completion.setFallback(bestAttemptContent)

        guard let deliveryID = ApplePushDisplayWire.deliveryID(from: bestAttemptContent.userInfo) else {
            completion.complete(with: bestAttemptContent)
            return
        }
        let route = ApplePushDisplayStateReader().route(for: bestAttemptContent.userInfo)
        guard case .fetch(let displayState) = route else {
            completion.complete(with: bestAttemptContent, outcome: ApplePushDisplayOutcome(
                kind: .unknownTarget,
                reason: route == .ambiguousTarget ? "ambiguous_target" : nil,
                attempts: 0,
                credential: nil,
                startedAt: startedAt
            ))
            return
        }
        let missing = displayState.missingParts
        guard missing.isEmpty else {
            completion.complete(with: bestAttemptContent, outcome: ApplePushDisplayOutcome(
                kind: .missingState,
                reason: missing.joined(separator: ","),
                attempts: 0,
                credential: nil,
                startedAt: startedAt
            ))
            return
        }
        let client = ApplePushDisplayClient()
        let completion = self.completion
        completion.attach(Task { [bestAttemptContent] in
            let result = await client.fetchDisplay(deliveryID: deliveryID, state: displayState) {
                completion.progress(attempts: $0, credential: $1)
            }
            if case .success(let response) = result.outcome {
                response.apply(to: bestAttemptContent)
            }
            // On failure the generic APNs fallback remains the notification content.
            completion.complete(
                with: bestAttemptContent,
                outcome: ApplePushDisplayOutcome(result: result, startedAt: startedAt)
            )
        })
    }

    override func serviceExtensionTimeWillExpire() {
        completion.expire()
    }
}

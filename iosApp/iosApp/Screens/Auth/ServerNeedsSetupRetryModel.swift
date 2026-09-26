import Foundation

/// Retry state for the "server needs setup" screen, shared by
/// `ServerNeedsSetupView` (iOS/macOS) and `TVServerNeedsSetupView` (tvOS).
/// The views keep only their layout and focus; this model re-probes the
/// active server and reports whether it still waits for administrator setup.
@Observable
@MainActor
final class ServerNeedsSetupRetryModel {
    static let stillNeedsSetupMessage = "This server still needs administrator setup."
    static let unreachableMessage = "Couldn't reach the server. Check it's running and try again."

    private(set) var isChecking = false
    private(set) var error: String?

    @ObservationIgnored private let checkServer: ServerSetupViewModel.ServerCheck
    @ObservationIgnored private let currentServerURL: @MainActor () -> String
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    init(
        checkServer: @escaping ServerSetupViewModel.ServerCheck = { try await AuthService.shared.checkServer(url: $0) },
        currentServerURL: @escaping @MainActor () -> String = { AuthService.shared.serverUrl }
    ) {
        self.checkServer = checkServer
        self.currentServerURL = currentServerURL
    }

    /// Re-probes the active server. If it is now set up, calls `onReady`
    /// (the screens pop back to the login screen beneath them in the
    /// `.needsLogin` stack); otherwise surfaces a gentle nudge. The result is
    /// dropped if the check is cancelled or the active server changes while
    /// it runs. Returns nil, and does nothing, while a check is already
    /// running.
    @discardableResult
    func retry(onReady: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard !isChecking else { return nil }
        isChecking = true
        error = nil
        let expectedServerURL = currentServerURL()
        let task = Task { @MainActor in
            do {
                let status = try await checkServer(expectedServerURL)
                guard !Task.isCancelled else { return }
                isChecking = false
                retryTask = nil
                guard currentServerURL() == expectedServerURL else { return }
                if status.needsSetup {
                    error = Self.stillNeedsSetupMessage
                } else {
                    onReady()
                }
            } catch {
                guard !Task.isCancelled else { return }
                isChecking = false
                retryTask = nil
                self.error = Self.unreachableMessage
            }
        }
        retryTask = task
        return task
    }

    /// Cancels a running check and suppresses its result.
    func cancel() {
        retryTask?.cancel()
        retryTask = nil
        isChecking = false
    }
}

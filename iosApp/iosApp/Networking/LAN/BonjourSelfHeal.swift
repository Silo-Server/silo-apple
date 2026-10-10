import Foundation

/// Generation-guarded self-heal for a long-lived NWBrowser or NWListener.
/// Call `activate()` each time you create a browser or listener and capture
/// the returned generation in its handlers. Call `deactivate()` on a
/// deliberate stop. `scheduleRestart` runs `restart` once after `delay`,
/// unless the owner stopped or started a newer instance in the meantime.
@MainActor
final class BonjourSelfHeal {
    nonisolated static let defaultDelay: Duration = .seconds(2)
    nonisolated let delay: Duration
    private(set) var generation = 0
    private(set) var isActive = false
    /// The scheduled restart, if any. Tests await it.
    private(set) var pendingRestart: Task<Void, Never>?

    nonisolated init(delay: Duration = BonjourSelfHeal.defaultDelay) {
        self.delay = delay
    }

    /// Marks the owner active, cancels any pending restart, and returns a
    /// fresh generation for the new browser/listener's handlers.
    @discardableResult
    func activate() -> Int {
        cancelPendingRestart()
        isActive = true
        generation += 1
        return generation
    }

    /// Deliberate stop: inactive, generation bumped, pending restart cancelled.
    func deactivate() {
        cancelPendingRestart()
        isActive = false
        generation += 1
    }

    /// Whether handlers captured with `generation` belong to the running
    /// instance of an owner that has not stopped.
    func isCurrent(_ generation: Int) -> Bool {
        isActive && generation == self.generation
    }

    /// No-op when inactive or a restart is already pending (coalesces
    /// `.failed` followed by `.cancelled`). After `delay`, runs `restart` only
    /// if the task was not cancelled and the scheduled generation is still
    /// current.
    func scheduleRestart(_ restart: @escaping @MainActor () -> Void) {
        guard isActive, pendingRestart == nil else { return }
        let scheduled = generation
        let delay = delay
        pendingRestart = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.isCurrent(scheduled) else { return }
            // Clear before calling out: the owner's restart calls `activate()`,
            // which would otherwise cancel this running task.
            self.pendingRestart = nil
            restart()
        }
    }

    private func cancelPendingRestart() {
        pendingRestart?.cancel()
        pendingRestart = nil
    }
}

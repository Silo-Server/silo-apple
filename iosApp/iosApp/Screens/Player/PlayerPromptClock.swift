import Foundation

/// Timers for the player's timed prompts, ``IntroSkipPrompt`` and
/// ``BufferingQualityController``. Injected so tests can drive the wall clock.
@MainActor
protocol PlayerPromptClock: AnyObject {
    var now: Date { get }
    /// Runs `action` once after `delay` seconds unless the returned handle is
    /// cancelled first.
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> PlayerPromptTimer
}

@MainActor
protocol PlayerPromptTimer: AnyObject {
    func cancel()
}

/// The production clock: wall-clock time and main-actor tasks.
@MainActor
final class LivePlayerPromptClock: PlayerPromptClock {
    private final class TaskTimer: PlayerPromptTimer {
        var task: Task<Void, Never>?
        func cancel() { task?.cancel() }
    }

    var now: Date { Date() }

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> PlayerPromptTimer {
        let timer = TaskTimer()
        timer.task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
        return timer
    }
}

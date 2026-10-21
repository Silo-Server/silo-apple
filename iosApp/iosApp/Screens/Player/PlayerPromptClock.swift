import Foundation

/// Timers for the player's timed prompts, ``IntroSkipPrompt`` and
/// ``BufferingQualityController``. Injected so tests can drive the clock.
@MainActor
protocol PlayerPromptClock: AnyObject {
    /// Wall-clock time.
    var now: Date { get }
    /// Elapsed real time in milliseconds, on a clock that a change of the
    /// wall clock does not move and that keeps counting while the device
    /// sleeps. Only differences are meaningful.
    var elapsedMs: Int { get }
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

/// The production clock: wall-clock time, `ContinuousClock` elapsed time and
/// main-actor tasks.
@MainActor
final class LivePlayerPromptClock: PlayerPromptClock {
    private final class TaskTimer: PlayerPromptTimer {
        var task: Task<Void, Never>?
        func cancel() { task?.cancel() }
    }

    private static let origin = ContinuousClock.now

    var now: Date { Date() }

    var elapsedMs: Int { Self.origin.duration(to: .now).wholeMilliseconds }

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> PlayerPromptTimer {
        let timer = TaskTimer()
        timer.task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, delay)), clock: .continuous)
            guard !Task.isCancelled else { return }
            action()
        }
        return timer
    }
}

extension Duration {
    /// The duration in whole milliseconds, rounded toward zero.
    var wholeMilliseconds: Int {
        Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}

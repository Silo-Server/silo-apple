#if os(iOS) || os(tvOS)
import Darwin
import Foundation

/// The timing rules of `HangWatchdog`, kept free of queues and clocks so they
/// can be tested directly. Times are seconds on a monotonic clock.
///
/// Each tick either sends the main thread a ping or, while a ping is still
/// unanswered, measures how long the main thread has been blocked. A gap
/// between ticks much longer than the poll interval means the whole process
/// was suspended (backgrounded, or the device slept), not that the main
/// thread hung, so the measurement in flight is thrown away.
struct HangDetector {
    struct Configuration: Equatable {
        var pollInterval: TimeInterval = 0.5
        /// A gap between two ticks, or between the last tick and an answer,
        /// longer than this means the process itself was not running.
        var suspensionGap: TimeInterval = 1.5
        /// Shortest block worth recording. Two seconds is four missed polls,
        /// well past anything a person reads as a stutter, and short enough
        /// that a freeze ending in a system kill is on record before it.
        var hangThreshold: TimeInterval = 2
    }

    enum Action: Equatable {
        case none
        case sendPing
        /// The main thread has been blocked at least `hangThreshold` and still is.
        case hangOngoing(startedAt: TimeInterval, duration: TimeInterval)
        /// A hang of at least `hangThreshold` ended.
        case hangEnded(startedAt: TimeInterval, duration: TimeInterval)
        /// A recorded hang turned out to span a suspension; forget it.
        case hangDiscarded
    }

    let configuration: Configuration
    private(set) var pingSentAt: TimeInterval?
    private var lastTickAt: TimeInterval?
    private var hangRecorded = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func tick(at now: TimeInterval) -> Action {
        defer { lastTickAt = now }
        if let lastTickAt, now - lastTickAt > configuration.suspensionGap {
            let discarded = hangRecorded
            reset()
            return discarded ? .hangDiscarded : .none
        }
        guard let pingSentAt else {
            self.pingSentAt = now
            return .sendPing
        }
        let blocked = now - pingSentAt
        guard blocked >= configuration.hangThreshold else { return .none }
        hangRecorded = true
        return .hangOngoing(startedAt: pingSentAt, duration: blocked)
    }

    /// The main thread ran the ping sent at `sentAt`; `now` is when it did.
    mutating func pong(sentAt: TimeInterval, at now: TimeInterval) -> Action {
        guard sentAt == pingSentAt else { return .none }
        let wasRecorded = hangRecorded
        let ticked = lastTickAt ?? sentAt
        pingSentAt = nil
        hangRecorded = false
        // The watchdog itself stopped ticking, so the process was suspended
        // while this ping waited: the delay is not a hang.
        if now - ticked > configuration.suspensionGap {
            return wasRecorded ? .hangDiscarded : .none
        }
        let duration = now - sentAt
        guard duration >= configuration.hangThreshold else { return .none }
        return .hangEnded(startedAt: sentAt, duration: duration)
    }

    mutating func reset() {
        pingSentAt = nil
        lastTickAt = nil
        hangRecorded = false
    }
}

/// Watches the main thread on Apple TV, where MetricKit reports no hangs.
///
/// A background timer pings the main queue every half second. A hang still in
/// progress is written to the exit marker (with the app's memory footprint)
/// so a system kill during it is labelled on the next launch; a finished hang
/// becomes a lifecycle breadcrumb and a `hang` report. The watchdog runs only
/// while the app is in the foreground.
final class HangWatchdog {
    static let shared = HangWatchdog()

    private let queue = DispatchQueue(label: "org.siloserver.silo.hang-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var detector = HangDetector()
    /// Bumped on stop so a ping answered after it is ignored.
    private var generation: UInt64 = 0

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            detector.reset()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let interval = detector.configuration.pollInterval
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            generation &+= 1
            detector.reset()
            ExitSentinel.shared.clearOngoingHang()
        }
    }

    private func tick() {
        let action = detector.tick(at: Self.monotonicNow())
        if action == .sendPing, let sentAt = detector.pingSentAt {
            let generation = generation
            DispatchQueue.main.async { [weak self] in
                let answeredAt = Self.monotonicNow()
                self?.queue.async {
                    guard let self, generation == self.generation else { return }
                    self.handle(self.detector.pong(sentAt: sentAt, at: answeredAt))
                }
            }
            return
        }
        handle(action)
    }

    private func handle(_ action: HangDetector.Action) {
        switch action {
        case .none, .sendPing:
            return
        case .hangOngoing(_, let duration):
            ExitSentinel.shared.recordOngoingHang(
                startedAt: Date().addingTimeInterval(-duration),
                duration: duration,
                residentMB: Self.residentMB()
            )
        case .hangDiscarded:
            ExitSentinel.shared.clearOngoingHang()
        case .hangEnded(_, let duration):
            ExitSentinel.shared.clearOngoingHang()
            let residentMB = Self.residentMB()
            let endedAt = Date()
            DiagTrace.breadcrumb(
                .essential,
                level: .warning,
                category: .lifecycle,
                tag: "MainThreadHang",
                message: "main thread did not respond",
                attrs: Self.hangAttributes(duration: duration, residentMB: residentMB)
            )
            // A debugger pausing or stepping the main thread is not a hang.
            guard !ExitSentinelEnvironment.isDebuggerAttached() else { return }
            let epoch = DiagnosticsCoordinator.currentEvidenceEpoch()
            Task {
                await DiagnosticsCoordinator.shared.captureWatchdogHang(
                    startedAt: endedAt.addingTimeInterval(-duration),
                    endedAt: endedAt,
                    residentMB: residentMB,
                    epoch: epoch
                )
            }
        }
    }

    static func hangAttributes(duration: TimeInterval, residentMB: Int?) -> [String: DiagLogAttributeValue] {
        var attrs: [String: DiagLogAttributeValue] = ["duration_ms": .int(Int((duration * 1000).rounded()))]
        attrs["resident_mb"] = residentMB.map(DiagLogAttributeValue.int)
        return attrs
    }

    /// `CLOCK_MONOTONIC` keeps counting while the device sleeps, so a sleep
    /// shows up as a gap between ticks rather than hiding inside one.
    private static func monotonicNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// The process's physical memory footprint, the figure the system's
    /// memory limit is enforced against.
    static func residentMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }
}
#endif

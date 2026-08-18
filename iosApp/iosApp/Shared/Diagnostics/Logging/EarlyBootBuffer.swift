#if os(iOS) || os(tvOS)
import Foundation
import os

/// In-memory staging area for breadcrumbs emitted before the diagnostics
/// consent context resolves.
///
/// `BreadcrumbJournal` is the only diagnostics artifact that survives a crash,
/// but it refuses every write until `breadcrumbCaptureEnabled()` passes, which
/// needs a resolved binding *and* an available status — both of which land
/// after authentication. Everything before that (launch crashes, restored
/// session failures, an unreachable server at boot) was previously discarded,
/// including the `app launched` breadcrumb emitted from `SiloApp.init`.
///
/// Staging is not only about keeping those lines. A refused journal write
/// *purges the journal directory*, so routing a pre-consent line through it
/// would delete the previous run's breadcrumbs — the tvOS abnormal-exit
/// report's entire content — before the relaunch gets far enough to read them.
/// `DiagnosticsCoordinator.recordBreadcrumb` therefore stages here directly
/// rather than treating a refusal as the signal to stage.
///
/// This buffer holds those lines in memory only. The gate is not weakened: the
/// staged lines reach disk only if, at the first consent establish of the
/// launch, the same consent check the journal enforces says the account may
/// capture — and even then they are written through
/// `BreadcrumbJournal.append(_:)` so the enabled-gate is re-checked at write
/// time rather than duplicated here.
///
/// Core invariant: this type has no filesystem API and never touches disk.
final class EarlyBootBuffer {
    /// A rendered breadcrumb is roughly 200-400 bytes, so 200 lines caps the
    /// staging cost near 40-80 KB. That stays well under the journal's 128 KiB
    /// segment, so a full flush cannot immediately rotate away the very lines
    /// it just wrote, and it is an order of magnitude more than the handful of
    /// lifecycle breadcrumbs a normal pre-auth boot emits — overflow means
    /// something pathological is looping, and the newest lines are the ones
    /// worth keeping.
    static let defaultCapacity = 200

    /// Steady-state deadline, measured from the first staged line. A launch
    /// that reaches an authenticated status refresh does so in seconds, and
    /// even a slow/timing-out one is done well inside two minutes; a launch
    /// still without an established binding after that is parked in sign-in or
    /// onboarding and is no longer "early boot". Discarding there is what keeps
    /// the buffer from retaining lines indefinitely and handing them to
    /// whichever account eventually signs in. Consent decisions seal the buffer
    /// sooner (see `drain()`/`discard()`); this is the unconditional backstop
    /// for a launch where no decision ever arrives.
    static let defaultStagingWindow: TimeInterval = 120

    static let shared = EarlyBootBuffer()

    struct Snapshot: Equatable {
        let lines: [String]
        let droppedCount: Int
        let isSealed: Bool
    }

    private let capacity: Int
    private let stagingWindow: TimeInterval
    private let scheduleExpiration: (TimeInterval, @escaping () -> Void) -> Void
    private var lines: [String] = []
    private var droppedCount = 0
    /// Set by the first `drain()`/`discard()`. Once the launch's consent
    /// decision has been made, later lines belong to an established account and
    /// go through the journal's own gate; re-staging them here would rebuild
    /// exactly the cross-account carryover this buffer must not create.
    private var sealed = false
    private var expirationScheduled = false
    /// Bumped by `resetForTests` so an expiration scheduled by an earlier test
    /// cannot fire into a buffer that has since been reset.
    private var stagingGeneration: UInt64 = 0
    // Matches `LogRing`: an uncontended in-memory append on a hot path. The
    // journal uses NSLock because it also performs file I/O under the lock.
    // `OSAllocatedUnfairLock` and not a stored `os_unfair_lock_s`: locking the
    // latter through `&lock` is an inout access the compiler may satisfy with a
    // temporary copy, so callers on the URLSession threads, the HTTPClient
    // actor, and the main actor could each lock a different word and lose
    // mutual exclusion over the staged lines and the seal.
    private let lock = OSAllocatedUnfairLock()

    init(
        capacity: Int = EarlyBootBuffer.defaultCapacity,
        stagingWindow: TimeInterval = EarlyBootBuffer.defaultStagingWindow,
        scheduleExpiration: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        precondition(capacity > 0, "EarlyBootBuffer capacity must be positive")
        self.capacity = capacity
        self.stagingWindow = stagingWindow
        self.scheduleExpiration = scheduleExpiration
    }

    /// Stages one pre-consent breadcrumb. Returns whether it was staged.
    ///
    /// The line is rendered by `DiagLog.renderedLine` — the same call the
    /// journal and the log ring use — so redaction, contract validation, and
    /// the capture-session id are identical to every other line, and a staged
    /// line is byte-for-byte what the journal would have written.
    @discardableResult
    func record(
        level: DiagnosticsLogLevel = .info,
        category: DiagnosticsLogCategory,
        tag: String,
        message: String,
        attrs: [String: DiagLogAttributeValue] = [:],
        timestamp: Date = Date(),
        captureSessionID: String = DiagLog.captureSessionID
    ) -> Bool {
        // Mirrors BreadcrumbJournal's category gate: staging a line the journal
        // would reject at flush time only wastes a slot.
        guard category == .lifecycle || category == .playback || category == .focus else {
            return false
        }
        guard !isSealed else {
            return false
        }
        guard let rendered = DiagLog.renderedLine(
            level: level,
            category: category,
            tag: tag,
            message: message,
            attrs: attrs,
            timestamp: timestamp,
            captureSessionID: captureSessionID
        ) else {
            return false
        }
        return append(rendered)
    }

    /// Returns the staged lines oldest-first and clears them, sealing the
    /// buffer. The caller owns writing them through the journal's gate.
    func drain() -> [String] {
        lock.lock()
        let drained = lines
        lines.removeAll()
        droppedCount = 0
        sealed = true
        lock.unlock()
        return drained
    }

    /// Drops every staged line without flushing, and seals the buffer. Used on
    /// every consent/account boundary: a refused consent check, a binding
    /// change, a destination change, a profile switch, and the erase path.
    ///
    /// The seal is permanent, so this is not a "close the gate for now" call —
    /// it ends staging for the launch. `DiagnosticsCoordinator` therefore only
    /// reaches it for a boundary that is genuinely crossing accounts, and not
    /// for the profile *restoration* pass every authenticated launch performs
    /// before its consent context resolves (see
    /// `launchProfileRestorationPassSpent`). Sealing there would have discarded
    /// the launch breadcrumbs this buffer exists to hold, on exactly the
    /// launches it exists for. Keeping them staged is safe because it does not
    /// attribute them: they still reach disk only through the first-establish
    /// consent check and the live gate re-checked at flush time.
    func discard() {
        lock.lock()
        lines.removeAll()
        droppedCount = 0
        sealed = true
        lock.unlock()
    }

    var isSealed: Bool {
        lock.lock()
        let sealed = self.sealed
        lock.unlock()
        return sealed
    }

    var isEmpty: Bool {
        lock.lock()
        let empty = lines.isEmpty
        lock.unlock()
        return empty
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(lines: lines, droppedCount: droppedCount, isSealed: sealed)
        lock.unlock()
        return snapshot
    }

    /// Test hook: `shared` is process-wide, so a test that stages lines must
    /// return it to its launch state or it leaks into later tests.
    func resetForTests() {
        lock.lock()
        lines.removeAll()
        droppedCount = 0
        sealed = false
        expirationScheduled = false
        stagingGeneration &+= 1
        lock.unlock()
    }

    /// Drop the staged lines only if no reset has intervened since the
    /// expiration was scheduled.
    private func expireStaging(generation: UInt64) {
        lock.lock()
        guard generation == stagingGeneration else {
            lock.unlock()
            return
        }
        lines.removeAll()
        droppedCount = 0
        sealed = true
        lock.unlock()
    }

    private func append(_ rendered: String) -> Bool {
        var scheduledGeneration: UInt64?
        lock.lock()
        // Re-check under the lock: the unlocked fast path above can race a
        // concurrent drain/discard, and a line staged after the launch's
        // consent decision must not survive it.
        guard !sealed else {
            lock.unlock()
            return false
        }
        if lines.count >= capacity {
            // Oldest-first eviction. `count` never exceeds `capacity`, so this
            // drops exactly enough to make room for the incoming line.
            let evicted = lines.count - capacity + 1
            lines.removeFirst(evicted)
            droppedCount += evicted
        }
        lines.append(rendered)
        if !expirationScheduled {
            expirationScheduled = true
            scheduledGeneration = stagingGeneration
        }
        lock.unlock()

        if let scheduledGeneration {
            // Outside the lock: the scheduler is caller-supplied and may run
            // the work item inline in tests.
            scheduleExpiration(stagingWindow) { [weak self] in
                self?.expireStaging(generation: scheduledGeneration)
            }
        }
        return true
    }
}
#endif

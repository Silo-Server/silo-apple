import Foundation

/// What Silo does when playback enters a detected intro —
/// `playback.intro_skip_mode`, settings contract revision 7.
///
/// The spec is the server repo's `docs/design/2026-08-16-intro-skip-mode.md`;
/// ``IntroSkipPrompt`` implements the tables in its "Prompt behaviour"
/// section, and `IntroSkipPromptTests` asserts them case for case. Web and
/// Android implement the same tables.
enum IntroSkipMode: String, CaseIterable, Identifiable, Sendable {
    /// Entering an intro does nothing: no pill, no skip.
    case never
    /// Offer a "Skip Intro" pill for ``IntroSkipPrompt/promptSeconds``.
    case ask
    /// Skip immediately and offer an "Intro skipped / Watch Intro" undo.
    case always

    /// The contract default, and exactly what `auto_skip_intro = false` did.
    static let `default`: IntroSkipMode = .ask

    var id: String { rawValue }

    /// The contract's enum member spelling.
    var wireValue: String { rawValue }

    /// The contract's option labels, shared with web and Android.
    var label: String {
        switch self {
        case .never: return "Never"
        case .ask: return "Ask to skip"
        case .always: return "Skip automatically"
        }
    }

    /// Parses a stored or wire value; nil for absent or unrecognized input.
    init?(wireValue: String?) {
        guard let wireValue, let mode = IntroSkipMode(rawValue: wireValue) else { return nil }
        self = mode
    }

    /// What the deprecated `auto_skip_intro` boolean meant — for a value this
    /// device cached before the enum existed, or one the onboarding tour writes
    /// through the legacy profile field. It cannot produce `never`.
    init(legacyAutoSkip: Bool) {
        self = legacyAutoSkip ? .always : .ask
    }

    /// The deprecated boolean this mode projects onto.
    var legacyAutoSkip: Bool { self == .always }
}

/// Timers for ``IntroSkipPrompt``. Injected so tests can drive the wall clock.
@MainActor
protocol IntroSkipPromptClock: AnyObject {
    var now: Date { get }
    /// Runs `action` once after `delay` seconds unless the returned handle is
    /// cancelled first.
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> IntroSkipPromptTimer
}

@MainActor
protocol IntroSkipPromptTimer: AnyObject {
    func cancel()
}

/// The production clock: wall-clock time and main-actor tasks.
@MainActor
final class LiveIntroSkipPromptClock: IntroSkipPromptClock {
    private final class TaskTimer: IntroSkipPromptTimer {
        var task: Task<Void, Never>?
        func cancel() { task?.cancel() }
    }

    var now: Date { Date() }

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> IntroSkipPromptTimer {
        let timer = TaskTimer()
        timer.task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
        return timer
    }
}

/// The intro-skip pill's state machine, shared by the iOS, tvOS and macOS
/// players.
///
/// The player feeds it playback inputs through ``update(_:)`` and acts on the
/// pill through ``select()`` and ``dismiss()``. Everything else — the timer,
/// which intros have been decided, when the pill may come back — lives here so
/// the platforms cannot drift from each other or from web and Android.
///
/// ### Seeks
///
/// The only seek this type asks for on its own is the immediate skip that
/// `always` is: ``update(_:)`` returns its target and the caller performs it.
/// Every seek the viewer triggers is returned by ``select()`` the same way.
///
/// ### Timing
///
/// The timer is wall-clock and the pill's fill reads the same ``Pill/deadline``,
/// so the bar always lands full exactly when the action happens. Accessibility
/// motion settings may shorten decorative transitions, never the countdown.
@MainActor
@Observable
final class IntroSkipPrompt {
    /// The spec's `INTRO_PROMPT_SECONDS`.
    static let promptSeconds: TimeInterval = 5
    /// The spec's `PLAYBACK_PAUSE_GRACE_MS`: a stall shorter than this is a
    /// rebuffer and does not touch the timer.
    static let pauseGraceSeconds: TimeInterval = 1.5

    enum Kind: Equatable {
        /// `ask`: "Skip Intro". Select seeks to the intro's end.
        case skip
        /// `always`: the intro was already skipped. "Watch Intro" seeks back
        /// to its start.
        case undo
    }

    /// How playback is moving, as far as the timer is concerned.
    enum Activity: Equatable {
        case playing
        /// Playback wants to run but cannot — loading or rebuffering. Treated
        /// as a pause only after ``IntroSkipPrompt/pauseGraceSeconds``.
        case stalled
        /// The viewer paused. Freezes the timer at once.
        case paused
    }

    struct Pill: Equatable {
        let kind: Kind
        /// When the timer runs out; nil while a pause holds it.
        let deadline: Date?
        /// Seconds left as of the last arm or freeze.
        let remaining: TimeInterval
        /// Where a fresh timer starts, for drawing progress against it.
        let total: TimeInterval

        /// How far the fill has crept, 0 when the pill appears and 1 when the
        /// timer runs out.
        func progress(at now: Date) -> Double {
            guard total > 0 else { return 1 }
            let left = deadline.map { $0.timeIntervalSince(now) } ?? remaining
            return min(max(1 - left / total, 0), 1)
        }
    }

    struct Inputs: Equatable {
        var position: Double
        var range: TimeRange?
        /// Stable identity for this intro within the current content, so a
        /// decision survives seeks and stream reloads. Nil disables the pill.
        var key: String?
        var mode: IntroSkipMode
        var activity: Activity
    }

    /// The pill on screen, or nil.
    private(set) var pill: Pill?

    var isVisible: Bool { pill != nil }

    @ObservationIgnored private let clock: IntroSkipPromptClock
    @ObservationIgnored private let duration: TimeInterval

    /// Intros the viewer has decided in this playback. A resolved intro never
    /// shows a pill again, including after scrubbing back into it.
    @ObservationIgnored private var resolved: Set<String> = []
    /// The intro whose `ask` offer timed out while the position is still inside
    /// it. Timing out does not resolve the intro, but it must not re-offer on
    /// the spot either, so this holds until the position leaves the range.
    @ObservationIgnored private var expiredKey: String?
    @ObservationIgnored private var active: (key: String, range: TimeRange, kind: Kind)?
    @ObservationIgnored private var lastMode: IntroSkipMode?
    @ObservationIgnored private var activity: Activity = .paused
    /// Time left when a stall began, while its grace window runs.
    @ObservationIgnored private var remainingAtStall: TimeInterval?
    @ObservationIgnored private var expiryTimer: IntroSkipPromptTimer?
    @ObservationIgnored private var graceTimer: IntroSkipPromptTimer?

    init(
        clock: IntroSkipPromptClock? = nil,
        duration: TimeInterval = IntroSkipPrompt.promptSeconds
    ) {
        self.clock = clock ?? LiveIntroSkipPromptClock()
        self.duration = duration
    }

    /// Re-evaluates the pill against the latest playback inputs.
    ///
    /// Returns a position when `always` has just skipped an intro; the caller
    /// must seek there. The intro is resolved as the skip is issued, so a
    /// stream reload that lands a little short of the intro's end cannot read
    /// as a fresh intro and skip again in a loop.
    @discardableResult
    func update(_ inputs: Inputs) -> Double? {
        activity = inputs.activity

        // A mode change re-evaluates from scratch: ask -> never takes the offer
        // down, never -> always skips the intro the viewer is sitting in.
        if inputs.mode != lastMode {
            lastMode = inputs.mode
            expiredKey = nil
            clearPrompt()
        }

        // The undo pill is anchored to the intro it skipped, not to the
        // position: the skip itself moved playback out of the range. Only the
        // timer, Select, Back, a different intro, a content reset or a mode
        // change take it down.
        if let active, active.kind == .undo, inputs.key == nil || inputs.key == active.key {
            applyActivity()
            return nil
        }

        guard let range = inputs.range,
              let key = inputs.key,
              inputs.position >= range.start,
              inputs.position < range.end else {
            // Leaving the range clears the timed-out marker, so seeking back in
            // re-offers with a full timer. It does not clear `resolved`.
            expiredKey = nil
            clearPrompt()
            return nil
        }

        if let active, active.key != key {
            expiredKey = nil
            clearPrompt()
        }

        if inputs.mode == .never || resolved.contains(key) || key == expiredKey {
            clearPrompt()
            return nil
        }

        guard active == nil else {
            applyActivity()
            return nil
        }

        // The pill and its fill start together, once playback is actually
        // running rather than while the player is still coming up.
        guard inputs.activity == .playing else { return nil }

        switch inputs.mode {
        case .always:
            active = (key, range, .undo)
            resolved.insert(key)
            arm(remaining: duration)
            return range.end
        case .ask:
            active = (key, range, .skip)
            arm(remaining: duration)
            return nil
        case .never:
            return nil
        }
    }

    /// The pill's action — tap, click, or Select while it is focused.
    ///
    /// Resolves the intro, hides the pill, and returns where the caller must
    /// seek: the intro's end for the `ask` offer, its start for the `always`
    /// undo. Nil when no pill is showing, so a stray press does nothing.
    func select() -> Double? {
        guard let active else { return nil }
        resolved.insert(active.key)
        expiredKey = nil
        clearPrompt()
        switch active.kind {
        case .skip: return active.range.end
        case .undo: return active.range.start
        }
    }

    /// Back / Menu / Escape while the pill is showing: hide it and resolve the
    /// intro without moving playback. True when a pill was dismissed, so the
    /// caller consumes the press only then and a second Back behaves normally.
    @discardableResult
    func dismiss() -> Bool {
        guard let active else { return false }
        resolved.insert(active.key)
        expiredKey = nil
        clearPrompt()
        return true
    }

    /// Takes the pill down without deciding anything, for when playback stops
    /// underneath it: a failed reload or a terminal error. An `ask` intro is
    /// offered again if playback later comes back into it; `always` resolved
    /// its intro when it skipped, so its undo does not return.
    func withdraw() {
        clearPrompt()
    }

    /// Forgets every decision, for when playback moves to different content.
    func reset() {
        resolved.removeAll()
        expiredKey = nil
        lastMode = nil
        clearPrompt()
    }

    // MARK: - Timer

    private func arm(remaining: TimeInterval) {
        cancelTimers()
        remainingAtStall = nil
        let left = max(0, remaining)
        let deadline = clock.now.addingTimeInterval(left)
        publish(deadline: deadline, remaining: left)
        scheduleExpiry(in: left)
    }

    private func scheduleExpiry(in delay: TimeInterval) {
        expiryTimer?.cancel()
        expiryTimer = clock.schedule(after: max(0, delay)) { [weak self] in
            self?.expire()
        }
    }

    /// Follows the latest ``Activity`` while a pill is up.
    ///
    /// A pause freezes the timer; play continues it from where it stopped. A
    /// stall keeps the deadline but holds the expiry for the grace window: if
    /// playback comes back inside it, the timer runs on as if nothing happened
    /// (firing at once if the stall outlasted it); if not, the timer freezes at
    /// what it had left when the stall began.
    private func applyActivity() {
        guard let pill else { return }
        switch activity {
        case .playing:
            graceTimer?.cancel()
            graceTimer = nil
            if pill.deadline == nil {
                arm(remaining: pill.remaining)
            } else if let deadline = pill.deadline, remainingAtStall != nil {
                remainingAtStall = nil
                let left = deadline.timeIntervalSince(clock.now)
                if left > 0 {
                    scheduleExpiry(in: left)
                } else {
                    expire()
                }
            }
        case .paused:
            guard pill.deadline != nil else { return }
            let left = remainingAtStall ?? remaining(of: pill)
            freeze(remaining: left)
        case .stalled:
            guard pill.deadline != nil, remainingAtStall == nil else { return }
            remainingAtStall = remaining(of: pill)
            expiryTimer?.cancel()
            expiryTimer = nil
            graceTimer = clock.schedule(after: Self.pauseGraceSeconds) { [weak self] in
                guard let self, self.activity != .playing, let left = self.remainingAtStall else { return }
                self.freeze(remaining: left)
            }
        }
    }

    private func freeze(remaining: TimeInterval) {
        cancelTimers()
        remainingAtStall = nil
        publish(deadline: nil, remaining: remaining)
    }

    private func remaining(of pill: Pill) -> TimeInterval {
        guard let deadline = pill.deadline else { return pill.remaining }
        return max(0, deadline.timeIntervalSince(clock.now))
    }

    private func publish(deadline: Date?, remaining: TimeInterval) {
        guard let active else { return }
        pill = Pill(kind: active.kind, deadline: deadline, remaining: remaining, total: duration)
    }

    /// The timer ran out. The two pills differ here and only here: the `ask`
    /// offer withdraws without deciding anything, while the `always` undo
    /// resolves the intro — the viewer was told it was skipped and let it go.
    private func expire() {
        guard let active else { return }
        switch active.kind {
        case .undo: resolved.insert(active.key)
        case .skip: expiredKey = active.key
        }
        clearPrompt()
    }

    private func cancelTimers() {
        expiryTimer?.cancel()
        expiryTimer = nil
        graceTimer?.cancel()
        graceTimer = nil
    }

    /// Takes the pill down and drops its anchor, deciding nothing.
    private func clearPrompt() {
        cancelTimers()
        remainingAtStall = nil
        active = nil
        if pill != nil { pill = nil }
    }
}

import Foundation

/// The player's own start deadline for a plan whose route has none in the
/// engine. AetherEngine fails a server-HLS load that is still not ready
/// after 45 s (`noPlayableTrackWithinBudget`), but nothing bounds a start on
/// direct play or the software route: one too slow for its link would wait
/// on "Loading…" until a frame or an engine failure. A plan that has shown
/// no first frame within the same budget of its adoption has missed its
/// start, not counting time the viewer held it paused.
///
/// Bookkeeping only, in milliseconds of the caller's elapsed clock. The
/// player schedules the check for ``dueAtMs`` and disarms the deadline at
/// the plan's first frame, its end, or the next plan.
struct PlaybackStartDeadline {
    /// AetherEngine's server-HLS readiness budget.
    static let budgetMs = 45_000

    /// The budget spent before the current run.
    private var spentMs = 0
    /// When the current run began; nil while the viewer holds it paused.
    private var runningSince: Int?

    /// Arms the deadline as a plan is adopted.
    init(atMs now: Int, running: Bool) {
        runningSince = running ? now : nil
    }

    /// When the budget runs out if the start keeps running; nil while paused.
    var dueAtMs: Int? {
        runningSince.map { $0 + Self.budgetMs - spentMs }
    }

    /// The viewer wants the start to run, or holds it paused.
    mutating func setRunning(_ running: Bool, atMs now: Int) {
        if running, runningSince == nil {
            runningSince = now
        } else if !running, let since = runningSince {
            spentMs += now - since
            runningSince = nil
        }
    }

    func hasPassed(atMs now: Int) -> Bool {
        dueAtMs.map { now >= $0 } ?? false
    }
}

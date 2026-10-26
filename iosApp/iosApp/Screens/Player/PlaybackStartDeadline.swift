import Foundation

/// The player's own start deadline for a plan whose route has none in the
/// engine. AetherEngine fails a server-HLS load that is still not ready
/// after 45 s (`noPlayableTrackWithinBudget`), but nothing bounds a start on
/// direct play or the software route: one too slow for its link would show
/// the loading spinner until a frame or an engine failure. A plan that has shown
/// no first frame within the same budget of its adoption has missed its
/// start, not counting time the viewer held it paused or an outage held it:
/// an outage never ends playback by itself, so a start that waits one out
/// has not missed anything.
///
/// Bookkeeping only, in milliseconds of the caller's elapsed clock. It is
/// armed held; the player updates it from adoption on, schedules the check
/// for ``dueAtMs`` and disarms it at the plan's first frame, its end, or the
/// next plan.
struct PlaybackStartDeadline {
    /// AetherEngine's server-HLS readiness budget.
    static let budgetMs = 45_000

    /// The budget spent before the current run.
    private var spentMs = 0
    /// When the current run began; nil while the start is held.
    private var runningSince: Int?

    /// When the budget runs out if the start keeps running; nil while held.
    var dueAtMs: Int? {
        runningSince.map { $0 + Self.budgetMs - spentMs }
    }

    /// The budget runs while the viewer wants to play and no outage holds
    /// the start.
    mutating func update(viewerWantsToPlay: Bool, outage: Bool, atMs now: Int) {
        let running = viewerWantsToPlay && !outage
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

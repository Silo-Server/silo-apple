import Foundation

/// Coalesces a burst of producer-restart requests into at most one in-flight
/// restart plus one settled follow-up target
/// (see `docs/tvos-player/03-dolby-vision-and-avplayer-route.md`).
///
/// Not thread-safe: callers serialize access under their own lock. The
/// in-flight signal is exposed so segment fetches can ride a progressing
/// restart instead of burning their own retry budget or firing a stale
/// restart of their own.
struct LoopbackRestartCoalescer {
    private(set) var isInFlight = false
    private var pending: Int?
    private var pendingIsAuthoritative = false

    /// Returns true when the caller becomes the restart worker; false when
    /// the target was parked (or dropped) because a restart is already in
    /// flight.
    ///
    /// An authoritative target — a recovery re-base computed from the
    /// player's real rendered position rather than a best-effort scrub —
    /// owns the pending slot: a stale burst-tail scrub must not leave the
    /// producer anchored away from where recovery reconciled. Newest wins
    /// within each class; an ordinary target never displaces an
    /// authoritative one (the player re-requests via its next segment
    /// fetch, so a dropped scrub target loses nothing).
    mutating func begin(_ index: Int, authoritative: Bool = false) -> Bool {
        if !isInFlight {
            isInFlight = true
            return true
        }
        if authoritative {
            pending = index
            pendingIsAuthoritative = true
        } else if !pendingIsAuthoritative {
            pending = index
        }
        return false
    }

    /// The worker calls this after finishing a restart; the return value is
    /// the next target to run, or nil when the burst has settled. A pending
    /// target equal to the one that just ran is dropped — re-running the
    /// same index forever would livelock.
    mutating func next(justRan index: Int) -> Int? {
        pendingIsAuthoritative = false
        if let target = pending, target != index {
            pending = nil
            return target
        }
        pending = nil
        isInFlight = false
        return nil
    }
}

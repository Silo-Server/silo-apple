import Foundation

/// Pass-out protection: counts consecutive unattended episode advances so the
/// next one can wait for the viewer once the limit is reached.
///
/// With threshold N, N automatic advances in a row are allowed and the next
/// waits. A deliberate start clears the count; a threshold of 0 never gates.
struct PlayerStillWatchingGuard {
    private var consecutiveAutoAdvances = 0

    mutating func recordAutoAdvance() {
        consecutiveAutoAdvances += 1
    }

    mutating func recordViewerAction() {
        consecutiveAutoAdvances = 0
    }

    func shouldGate(threshold: Int) -> Bool {
        threshold > 0 && consecutiveAutoAdvances >= threshold
    }
}

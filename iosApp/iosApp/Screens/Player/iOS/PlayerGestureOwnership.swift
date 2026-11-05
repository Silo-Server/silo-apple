#if os(iOS)
/// Which continuous player gesture owns the current touch. Hold for 2×,
/// edge drags, and pinch run as simultaneous recognizers; without one owner,
/// a thumb slipping while it held 2× also moved the volume. The first
/// gesture to claim the touch keeps it until it releases.
struct PlayerGestureOwnership: Equatable {
    enum Gesture { case hold, edgeAdjustment, pinch }

    private(set) var owner: Gesture?

    /// Gives the touch to `gesture` if no other gesture owns it. Returns
    /// whether `gesture` owns the touch afterwards.
    mutating func claim(_ gesture: Gesture) -> Bool {
        if owner == nil { owner = gesture }
        return owner == gesture
    }

    /// Frees the touch, but only if `gesture` owns it.
    mutating func release(_ gesture: Gesture) {
        if owner == gesture { owner = nil }
    }

    /// Frees the touch when gestures were cancelled without their end
    /// callbacks.
    mutating func reset() {
        owner = nil
    }
}
#endif

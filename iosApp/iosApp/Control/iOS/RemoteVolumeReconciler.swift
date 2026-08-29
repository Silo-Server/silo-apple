#if os(iOS)
import Foundation

/// Holds a locally-requested volume in place until the TV echoes it back.
///
/// Volume commands are absolute, and the TV answers each one with a full state
/// frame. During a burst of hardware-button steps the reply to the *first* step
/// arrives while later steps are still in flight; taking that frame at face
/// value rewinds the level, and the next step is then computed from the stale
/// value — resending a volume already requested and dropping the press.
///
/// So the requested level wins over inbound state until the TV confirms it, or
/// until ``window`` lapses. The window matters: a command can be dropped, and
/// the level can change on the TV itself, and neither should leave the remote
/// permanently showing a volume the TV does not have.
struct RemoteVolumeReconciler {
    static let window: TimeInterval = 4
    static let tolerance = 0.001

    private var pending: Double?
    private var requestedAt = Date(timeIntervalSince1970: 0)

    /// Records a volume this client just asked the TV for.
    mutating func requested(_ volume: Double, at now: Date = Date()) {
        pending = volume
        requestedAt = now
    }

    /// Drops any held level, for changes that supersede it — an explicit mute,
    /// or a session that no longer has state.
    mutating func clear() {
        pending = nil
    }

    /// The volume to show for an inbound state frame.
    mutating func reconcile(inbound: Double, at now: Date = Date()) -> Double {
        guard let pending else { return inbound }
        if abs(inbound - pending) < Self.tolerance {
            self.pending = nil    // confirmed
            return inbound
        }
        if now.timeIntervalSince(requestedAt) >= Self.window {
            self.pending = nil    // lost, or changed on the TV — trust the TV
            return inbound
        }
        return pending
    }
}
#endif

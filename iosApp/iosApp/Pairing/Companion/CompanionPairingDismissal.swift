import Foundation

/// Computes the stable "Not Now" dismissal key for a discovered TV.
///
/// Keying on the TV's per-session nonce (`sid`) means a dismissal lasts until
/// the TV starts a new setup session — it advertises a fresh `sid` each time it
/// (re)starts advertising (reboot, or re-entering the setup screen). The `sid`
/// is stable across pairing attempts within one setup session, and a brief
/// Bonjour flap keeps the same `sid`, so both stay dismissed. Falls back to the
/// device `id` for older TVs that don't advertise a nonce.
///
/// No platform guard: `CompanionDismissalKeyTests` also runs in the tvOS test
/// bundle.
enum CompanionPairingDismissal {
    static func key(id: String, sid: String?) -> String {
        if let sid, !sid.isEmpty { return "\(id)#\(sid)" }
        return id
    }
}

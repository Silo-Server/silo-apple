import Foundation

/// Process-wide bookkeeping for which `AetherEngine` instances are alive and which
/// of them are actually holding audio, so a teardown on one of them can tell whether
/// releasing the shared `AVAudioSession` is safe.
///
/// `AVAudioSession` is process-global. AetherEngine declares the category at init
/// but leaves activation to the playback path, and only releases the session on a
/// final teardown when the host opts in via `deactivatesAudioSessionOnStop`
/// (AetherEngine README, "Who owns the audio session"). That opt-in is only correct
/// when the app owns the session outright — Silo runs two engines (audiobooks and
/// video), so an audiobook that stops while a video is playing would otherwise pull
/// the session out from under the video.
///
/// Every owner of an `AetherEngine` holds a ``Claim`` for the engine's lifetime:
///
/// ```swift
/// private let aetherSessionClaim = AetherAudioSessionOwnership.Claim(engine: engine)
/// ```
///
/// The claim's lifetime does the registration; there is nothing to release by hand.
///
/// Counting live engines is not on its own a usable safety test: an engine that
/// exists but has no media loaded is not holding the session, and gating on mere
/// existence means the session is never released while such an engine is alive —
/// leaving whatever Silo interrupted (another app's audio) paused or ducked until
/// Silo is killed. A claim therefore carries an *activity probe*, and the release
/// test asks whether any **other** claim is actually holding audio right now.
enum AetherAudioSessionOwnership {
    private static let lock = NSLock()
    private static var registrations: [ObjectIdentifier: Registration] = [:]

    /// A claim's answer to "is your engine holding audio right now?".
    ///
    /// A `nil` probe means the claim was registered without one: unanswerable, and so
    /// treated as active. That is the conservative direction — the cost is a session
    /// that stays active longer than necessary, against cutting off live playback.
    private struct Registration {
        let probe: (@MainActor @Sendable () -> Bool)?
    }

    /// A live-engine claim. Declare one as a stored property next to the engine it
    /// stands for; `deinit` releases it when the owner is deallocated.
    final class Claim {
        /// A claim whose activity cannot be interrogated. Always counts as holding
        /// audio, so no other engine's teardown will release the shared session while
        /// it is alive. Prefer the engine-probed `Claim(engine:)` convenience
        /// (defined app-side — this file is shared into extension targets that
        /// do not link AetherEngine, so it must stay engine-type-free).
        init() {
            AetherAudioSessionOwnership.register(ObjectIdentifier(self), probe: nil)
        }

        /// A claim with a caller-supplied activity probe, for owners that know more
        /// about "holding audio" than the engine state alone says.
        init(isHoldingAudio probe: @escaping @MainActor @Sendable () -> Bool) {
            AetherAudioSessionOwnership.register(ObjectIdentifier(self), probe: probe)
        }

        deinit {
            AetherAudioSessionOwnership.unregister(ObjectIdentifier(self))
        }
    }

    /// Number of live engine claims in this process.
    static var liveEngineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registrations.count
    }

    /// True when the caller's own engine is the only one alive.
    ///
    /// Read this from a caller that is itself holding a ``Claim``; it counts that claim.
    /// Prefer ``canReleaseSharedSession(excluding:)``, which also tolerates another
    /// engine that exists but is idle.
    static var isSoleLiveEngine: Bool {
        liveEngineCount <= 1
    }

    /// Whether the claim's owner may let its final teardown release the shared
    /// `AVAudioSession` — i.e. no *other* live engine is holding audio.
    ///
    /// Pass the caller's own claim; it is excluded, because a final teardown is by
    /// definition the caller giving its own audio up.
    @MainActor
    static func canReleaseSharedSession(excluding claim: Claim) -> Bool {
        let ownID = ObjectIdentifier(claim)
        lock.lock()
        let others = registrations.filter { $0.key != ownID }.map(\.value)
        lock.unlock()
        // Probes run outside the lock: they are main-actor reads into engines, and a
        // probe must never be able to re-enter this registry while it is locked.
        return !others.contains { $0.probe?() ?? true }
    }

    private static func register(
        _ id: ObjectIdentifier,
        probe: (@MainActor @Sendable () -> Bool)?
    ) {
        lock.lock()
        registrations[id] = Registration(probe: probe)
        lock.unlock()
    }

    private static func unregister(_ id: ObjectIdentifier) {
        lock.lock()
        registrations.removeValue(forKey: id)
        lock.unlock()
    }
}

import Foundation
import Synchronization

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
///
/// That test runs at `stop()`, but the engine's release runs later, off the main
/// actor (`setActive(false)` alone takes about half a second on an Atmos route),
/// and only a load on the same engine cancels it. A player opened in that window
/// gets a new controller and engine, so every load first calls ``takeSession()``,
/// and every opted-in stop hands its engine a ``releaseGate()`` that drops the
/// late release once another load has taken the session.
enum AetherAudioSessionOwnership {
    private static let registrations = Mutex<[ObjectIdentifier: Registration]>([:])
    /// Bumped by every ``takeSession()``.
    private static let sessionGeneration = Mutex<UInt64>(0)

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

    /// Whether the claim's owner may let its final teardown release the shared
    /// `AVAudioSession` — i.e. no *other* live engine is holding audio.
    ///
    /// Pass the caller's own claim; it is excluded, because a final teardown is by
    /// definition the caller giving its own audio up.
    @MainActor
    static func canReleaseSharedSession(excluding claim: Claim) -> Bool {
        let ownID = ObjectIdentifier(claim)
        let others = registrations.withLock { all in all.filter { $0.key != ownID }.map(\.value) }
        // Probes run outside the lock: they are main-actor reads into engines, and a
        // probe must never be able to re-enter this registry while it is locked.
        return !others.contains { $0.probe?() ?? true }
    }

    /// Records that an engine is about to load and take the shared session. Call
    /// right before `AetherEngine.load`.
    static func takeSession() {
        sessionGeneration.withLock { $0 &+= 1 }
    }

    /// For `AetherEngine.audioSessionReleaseGate`, built at `stop()`: answers true
    /// only while no load has called ``takeSession()`` since. A load that began
    /// before the stop is the activity probe's job in ``canReleaseSharedSession(excluding:)``.
    /// The returned closure is safe to call off the main actor.
    static func releaseGate() -> @Sendable () -> Bool {
        let atStop = sessionGeneration.withLock { $0 }
        return { sessionGeneration.withLock { $0 == atStop } }
    }

    private static func register(
        _ id: ObjectIdentifier,
        probe: (@MainActor @Sendable () -> Bool)?
    ) {
        registrations.withLock { $0[id] = Registration(probe: probe) }
    }

    private static func unregister(_ id: ObjectIdentifier) {
        registrations.withLock { _ = $0.removeValue(forKey: id) }
    }
}

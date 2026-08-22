import Foundation

/// Process-wide bookkeeping for how many `AetherEngine` instances are alive, so a
/// teardown on one of them can tell whether releasing the shared `AVAudioSession`
/// is safe.
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
/// private let aetherSessionClaim = AetherAudioSessionOwnership.Claim()
/// ```
///
/// The claim's lifetime does the registration; there is nothing to release by hand.
enum AetherAudioSessionOwnership {
    private static let lock = NSLock()
    private static var liveClaims = 0

    /// A live-engine claim. Declare one as a stored property next to the engine it
    /// stands for; `deinit` releases it when the owner is deallocated.
    final class Claim {
        init() {
            AetherAudioSessionOwnership.retain()
        }

        deinit {
            AetherAudioSessionOwnership.release()
        }
    }

    /// Number of live engine claims in this process.
    static var liveEngineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return liveClaims
    }

    /// True when the caller's own engine is the only one alive, i.e. deactivating the
    /// shared audio session on teardown cannot cut off another engine's playback.
    ///
    /// Read this from a caller that is itself holding a ``Claim``; it counts that claim.
    static var isSoleLiveEngine: Bool {
        liveEngineCount <= 1
    }

    private static func retain() {
        lock.lock()
        liveClaims += 1
        lock.unlock()
    }

    private static func release() {
        lock.lock()
        liveClaims = max(0, liveClaims - 1)
        lock.unlock()
    }
}

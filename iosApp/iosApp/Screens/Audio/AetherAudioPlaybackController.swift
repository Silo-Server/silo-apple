import AetherEngine
import Combine
import Foundation
#if os(iOS) || os(tvOS)
import MediaPlayer
#endif

@MainActor
final class AetherAudioPlaybackController {
    struct LoadEpoch: RawRepresentable, Equatable, Hashable, Sendable {
        let rawValue: UInt64
    }

    enum Event: Equatable {
        case state(PlaybackState)
        case phase(PlaybackPhase)
        case time(Double)
        case duration(Double)
        case failure(PlaybackErrorInfo?)
    }

    struct ScopedEvent: Equatable {
        let epoch: LoadEpoch
        let event: Event
    }

    /// Built on the first real playback start, not at controller init: the store
    /// that owns this controller is created eagerly at app launch, and
    /// `AetherEngine()` can throw. Constructing it lazily keeps an engine
    /// initialization failure inside a playback attempt, where it surfaces as a
    /// player error, instead of taking down the app before login.
    private var engine: AetherEngine?
    /// Registers this engine process-wide for as long as it is alive so a
    /// teardown can tell whether it is safe to release the shared audio session.
    private var sessionClaim: AetherAudioSessionOwnership.Claim?
    private var subscriptions: Set<AnyCancellable> = []
    private(set) var playbackRate: Float = 1.0
    private var generation: UInt64 = 0
    private(set) var activeLoadEpoch: LoadEpoch?

    var onEvent: ((ScopedEvent) -> Void)?

    #if os(iOS) || os(tvOS)
    var audioNowPlayingSession: MPNowPlayingSession? {
        engine?.audioNowPlayingSession
    }
    #endif

    /// Returns the engine, building and wiring it on first use. Throws whatever
    /// `AetherEngine.init` throws so the caller can report it as a playback failure.
    private func requireEngine() throws -> AetherEngine {
        if let engine { return engine }
        let engine = try AetherEngine()
        self.engine = engine
        // Engine-probed claim: while this audiobook engine is idle the video
        // teardown may release the shared audio session; a probe-less Claim()
        // would read as permanently active and block that release forever.
        sessionClaim = AetherAudioSessionOwnership.Claim(engine: engine)
        // `deactivatesAudioSessionOnStop` stays at the engine default (false) here and is
        // decided per teardown in `stop()`; see the note there.

        engine.clock.$currentTime
            .sink { [weak self] time in
                self?.publish(.time(time))
            }
            .store(in: &subscriptions)
        engine.$state
            .sink { [weak self] state in
                self?.publish(.state(state))
            }
            .store(in: &subscriptions)
        engine.$playbackPhase
            .sink { [weak self] phase in
                self?.publish(.phase(phase))
            }
            .store(in: &subscriptions)
        engine.$duration
            .sink { [weak self] duration in
                self?.publish(.duration(duration))
            }
            .store(in: &subscriptions)
        engine.$errorInfo
            .sink { [weak self] failure in
                self?.publish(.failure(failure))
            }
            .store(in: &subscriptions)
        return engine
    }

    @discardableResult
    func beginLoad() -> LoadEpoch {
        generation &+= 1
        let epoch = LoadEpoch(rawValue: generation)
        activeLoadEpoch = epoch
        return epoch
    }

    func finishLoad(
        _ epoch: LoadEpoch,
        url: URL,
        headers: [String: String],
        startSeconds: Double
    ) async throws {
        guard epoch == activeLoadEpoch else { throw CancellationError() }
        let engine: AetherEngine
        do {
            engine = try requireEngine()
        } catch {
            if epoch == activeLoadEpoch { activeLoadEpoch = nil }
            throw error
        }
        do {
            try await engine.load(
                url: url,
                startPosition: max(0, startSeconds),
                options: LoadOptions(
                    httpHeaders: headers,
                    audioOnly: true,
                    autoplay: false
                )
            )
        } catch {
            guard epoch == activeLoadEpoch else { throw CancellationError() }
            activeLoadEpoch = nil
            throw error
        }
        guard epoch == activeLoadEpoch else { throw CancellationError() }
    }

    func play() {
        // No engine means nothing has been loaded yet, so there is nothing to
        // resume; the engine is built by `finishLoad`.
        guard let engine else { return }
        engine.play()
        engine.setRate(playbackRate)
    }

    func pause() {
        engine?.pause()
    }

    func setRate(_ rate: Double, shouldResume: Bool) {
        playbackRate = Float(min(max(rate, 0.5), 3.0))
        if shouldResume {
            play()
        }
    }

    func seek(to seconds: Double, epoch: LoadEpoch) async throws {
        guard epoch == activeLoadEpoch, let engine else { throw CancellationError() }
        await engine.seek(to: max(0, seconds))
        guard epoch == activeLoadEpoch else { throw CancellationError() }
    }

    func stop() {
        generation &+= 1
        activeLoadEpoch = nil
        guard let engine else { return }
        // AVAudioSession is process-global and Silo runs a second AetherEngine for video.
        // Only let this teardown release the session when no other engine is alive,
        // otherwise a stopped audiobook would cut the session out from under playing
        // video. Decided per stop because the video engine comes and goes with the
        // player screen.
        engine.deactivatesAudioSessionOnStop = AetherAudioSessionOwnership.isSoleLiveEngine
        engine.stop(finalTeardown: true)
    }

    private func publish(_ event: Event) {
        guard let activeLoadEpoch else { return }
        onEvent?(ScopedEvent(epoch: activeLoadEpoch, event: event))
    }
}

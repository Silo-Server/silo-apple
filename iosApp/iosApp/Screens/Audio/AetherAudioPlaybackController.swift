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

    private let engine: AetherEngine
    private var subscriptions: Set<AnyCancellable> = []
    private(set) var playbackRate: Float = 1.0
    private var generation: UInt64 = 0
    private(set) var activeLoadEpoch: LoadEpoch?

    var onEvent: ((ScopedEvent) -> Void)?

    #if os(iOS) || os(tvOS)
    var audioNowPlayingSession: MPNowPlayingSession? {
        engine.audioNowPlayingSession
    }
    #endif

    init() {
        do {
            engine = try AetherEngine()
        } catch {
            fatalError("AetherEngine audio initialization failed: \(error)")
        }
        engine.deactivatesAudioSessionOnStop = true

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
        engine.play()
        engine.setRate(playbackRate)
    }

    func pause() {
        engine.pause()
    }

    func setRate(_ rate: Double, shouldResume: Bool) {
        playbackRate = Float(min(max(rate, 0.5), 3.0))
        if shouldResume {
            play()
        }
    }

    func seek(to seconds: Double, epoch: LoadEpoch) async throws {
        guard epoch == activeLoadEpoch else { throw CancellationError() }
        await engine.seek(to: max(0, seconds))
        guard epoch == activeLoadEpoch else { throw CancellationError() }
    }

    func stop() {
        generation &+= 1
        activeLoadEpoch = nil
        engine.stop(finalTeardown: true)
    }

    private func publish(_ event: Event) {
        guard let activeLoadEpoch else { return }
        onEvent?(ScopedEvent(epoch: activeLoadEpoch, event: event))
    }
}

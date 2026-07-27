import Foundation

/// Separates the product route family from the concrete implementation that
/// renders frames. This is the new engine contract boundary; existing backends
/// are adapted to it before their internals are rewritten.
protocol PlaybackEngine: AnyObject {
    var kind: PlaybackEngineKind { get }
    var routeFamily: PlaybackRouteFamily { get }
    var capabilities: PlayerBackendCapabilities { get }
    var renderTarget: PlaybackRenderTarget { get }

    func load(plan: PlaybackExecutionPlan) throws
    func play()
    func pause()
    func seek(to seconds: Double)
    func currentTime() -> Double
    func isPaused() -> Bool
    func dispose()
    func prepareToBackground()
    func setSpeed(_ rate: Double)
}

enum PlaybackRenderTarget {
    case none
    case coreMedia(PlayerCore)
    case avPlayer(AVPlayerBackend)

    var core: PlayerCore? {
        if case .coreMedia(let core) = self { return core }
        return nil
    }

    var avBackend: AVPlayerBackend? {
        if case .avPlayer(let backend) = self { return backend }
        return nil
    }
}

enum PlaybackEngineLoadError: LocalizedError {
    case missingLoopbackSession
    case unsupportedEngine(expected: PlaybackEngineKind, actual: PlaybackEngineKind)

    var errorDescription: String? {
        switch self {
        case .missingLoopbackSession:
            return "SiloPlayer loopback requires a loopback session."
        case .unsupportedEngine(let expected, let actual):
            return "Playback engine mismatch: expected \(expected.label), got \(actual.label)."
        }
    }
}

enum PlaybackEngineFailure: Equatable {
    case message(String)
    case unsupportedStream(String)
    case videoToolbox(OSStatus)
    case avPlayerItemFailed(String)
    case siloStartupTimeout(String)
    case sourceProxyFailed(String)
    case featureContractLost(String)
}

enum PlaybackEngineEvent {
    case timeChanged(Double)
    case durationChanged(Double)
    case pauseChanged(Bool)
    case readyToPlay
    case failed(PlaybackEngineFailure)
    case ended
    case bufferingChanged(Bool)
    case bufferedAheadChanged(Double)
    case statsChanged(PlaybackStats)
    case tracksChanged([PlayerTrack])
    case chaptersChanged([PlayerChapterInfo])
}

final class CompatibilityPlayerEngine: PlaybackEngine {
    let kind: PlaybackEngineKind = .playerCoreDirect
    let core: PlayerCore

    init(core: PlayerCore) {
        self.core = core
    }

    var routeFamily: PlaybackRouteFamily { kind.routeFamily }
    var capabilities: PlayerBackendCapabilities { kind.capabilities }
    var renderTarget: PlaybackRenderTarget { .coreMedia(core) }

    func load(plan: PlaybackExecutionPlan) throws {
        guard plan.engine == kind else {
            throw PlaybackEngineLoadError.unsupportedEngine(expected: kind, actual: plan.engine)
        }
        core.load(
            url: plan.streamRequest.url,
            headers: plan.streamRequest.headers,
            startTime: plan.startMode.seconds,
            colorRangeHint: plan.delivery.preservesSourceVideoMetadata
                ? plan.sourceMetadata.colorRange
                : nil
        )
    }

    func play() { core.play() }
    func pause() { core.pause() }
    func seek(to seconds: Double) { core.seek(to: seconds) }
    func currentTime() -> Double { core.currentTime() }
    func isPaused() -> Bool { core.isPaused() }
    func dispose() { core.dispose() }
    func prepareToBackground() { core.prepareToBackground() }
    func setSpeed(_ rate: Double) { core.setSpeed(rate) }
}

final class AVFoundationPlayerEngine: PlaybackEngine {
    let kind: PlaybackEngineKind
    let backend: AVPlayerBackend

    init(kind: PlaybackEngineKind, backend: AVPlayerBackend) {
        self.kind = kind
        self.backend = backend
    }

    var routeFamily: PlaybackRouteFamily { kind.routeFamily }
    var capabilities: PlayerBackendCapabilities { kind.capabilities }
    var renderTarget: PlaybackRenderTarget { .avPlayer(backend) }

    func load(plan: PlaybackExecutionPlan) throws {
        guard plan.engine == kind else {
            throw PlaybackEngineLoadError.unsupportedEngine(expected: kind, actual: plan.engine)
        }
        let startTime = plan.startMode.seconds
        let request = plan.streamRequest
        switch kind {
        case .playerCoreDirect:
            throw PlaybackEngineLoadError.unsupportedEngine(expected: kind, actual: plan.engine)
        case .avPlayerHLS:
            backend.loadRemoteHLS(url: request.url, headers: request.headers, startTime: startTime)
        case .avPlayerNativeDirect:
            backend.loadDirectFile(url: request.url, headers: request.headers, startTime: startTime)
        case .siloPlayerLoopback:
            guard let loopbackSession = plan.loopbackSession else {
                throw PlaybackEngineLoadError.missingLoopbackSession
            }
            backend.load(sessionSpec: loopbackSession, startTime: startTime)
        }
    }

    func play() { backend.play() }
    func pause() { backend.pause() }
    func seek(to seconds: Double) { backend.seek(to: seconds) }
    func currentTime() -> Double { backend.currentTime() }
    func isPaused() -> Bool { backend.isPaused() }
    func dispose() { backend.dispose() }
    func prepareToBackground() { backend.prepareToBackground() }
    func setSpeed(_ rate: Double) { backend.setSpeed(rate) }
}

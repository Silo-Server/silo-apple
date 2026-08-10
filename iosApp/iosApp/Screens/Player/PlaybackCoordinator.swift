import Foundation
import OSLog

/// Owns the active playback engine and centralizes route installation. This is
/// intentionally small at first: it wraps today's backends without changing VM
/// behavior, then grows as fallback and recovery policy move out of the VM.
final class PlaybackCoordinator {
    typealias CoreFactory = () -> PlayerCore
    typealias AVPlayerFactory = (_ kind: PlaybackEngineKind) -> AVPlayerBackend

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PlaybackCoordinator"
    )

    private let makeCore: CoreFactory
    private let makeAVPlayer: AVPlayerFactory
    private(set) var activeEngine: PlaybackEngine?

    init(
        makeCore: @escaping CoreFactory,
        makeAVPlayer: @escaping AVPlayerFactory
    ) {
        self.makeCore = makeCore
        self.makeAVPlayer = makeAVPlayer
    }

    var renderTarget: PlaybackRenderTarget {
        activeEngine?.renderTarget ?? .none
    }

    var activeKind: PlaybackEngineKind? {
        activeEngine?.kind
    }

    @discardableResult
    func installEngine(for kind: PlaybackEngineKind) -> PlaybackEngine {
        activeEngine?.dispose()
        let engine: PlaybackEngine
        switch kind {
        case .playerCoreDirect:
            engine = CompatibilityPlayerEngine(core: makeCore())
        case .avPlayerHLS, .avPlayerNativeDirect, .siloPlayerLoopback:
            engine = AVFoundationPlayerEngine(kind: kind, backend: makeAVPlayer(kind))
        }
        activeEngine = engine
        Self.logger.info(
            "[CMP-ENGINE] installed kind=\(kind.label, privacy: .public) family=\(kind.routeFamily.diagnosticsLabel, privacy: .public)"
        )
        return engine
    }

    /// Keeps an already-installed engine when the implementation route did
    /// not change. In-place replans (notably an audio-track change on the
    /// SiloPlayer loopback route) need the backend to survive so it can keep
    /// the active audio session and identical tvOS display criteria instead
    /// of renegotiating HDMI around the replacement item.
    @discardableResult
    func prepareEngine(for kind: PlaybackEngineKind) -> PlaybackEngine {
        if let activeEngine, activeEngine.kind == kind {
            Self.logger.info(
                "[CMP-ENGINE] reusing kind=\(kind.label, privacy: .public) family=\(kind.routeFamily.diagnosticsLabel, privacy: .public)"
            )
            return activeEngine
        }
        return installEngine(for: kind)
    }

    func load(plan: PlaybackExecutionPlan) throws {
        let engine: PlaybackEngine
        if let activeEngine, activeEngine.kind == plan.engine {
            engine = activeEngine
        } else {
            engine = installEngine(for: plan.engine)
        }
        try engine.load(plan: plan)
    }

    func play() { activeEngine?.play() }
    func pause() { activeEngine?.pause() }
    func seek(to seconds: Double) { activeEngine?.seek(to: seconds) }
    func currentTime() -> Double { activeEngine?.currentTime() ?? 0 }
    func isPaused() -> Bool { activeEngine?.isPaused() ?? true }
    func prepareToBackground() { activeEngine?.prepareToBackground() }
    func setSpeed(_ rate: Double) { activeEngine?.setSpeed(rate) }

    func dispose() {
        activeEngine?.dispose()
        activeEngine = nil
    }
}

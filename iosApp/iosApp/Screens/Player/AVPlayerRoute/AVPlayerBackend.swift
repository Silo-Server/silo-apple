import AVFoundation
import Foundation
import OSLog
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct AVPlayerSeekDeadlineState {
    private var nextID: UInt64 = 0
    private(set) var activeID: UInt64?

    mutating func begin() -> UInt64 {
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        activeID = nextID
        return nextID
    }

    mutating func complete(_ id: UInt64) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }

    mutating func cancel() {
        activeID = nil
    }
}

/// Transport commands issued outside the app: the AirPlay receiver's remote,
/// or the PiP window's play/pause button. Both mutate `AVPlayer` directly
/// instead of calling the backend, so the only evidence is a
/// `timeControlStatus` transition.
///
/// That signal is noisy — the player also stops and starts on its own during
/// startup, seeks, stalls, and at end of file — so a transition only counts as
/// a command when nothing else explains it. Reading a stall as a receiver
/// pause is the expensive mistake: it latches `isUserPaused`, and every
/// loopback stall-recovery path is gated on `!isUserPaused`, so the session
/// would wedge with no way back.
enum AVPlayerSystemTransportIntent: Equatable {
    case play
    case pause

    /// Everything the backend knows about why the transport state may have
    /// moved without us asking.
    struct Context {
        let timeControlStatus: AVPlayer.TimeControlStatus
        let isUserPaused: Bool
        /// AirPlay handoff or PiP owns the transport UI right now.
        let systemControlsAreActive: Bool
        /// The first KVO delivery reports the state the player was already in
        /// (`.paused`, pre-roll) rather than a transition, so it carries no
        /// intent.
        let isInitialObservation: Bool
        /// False until the initial start/resume seek has been issued; before
        /// that the player is legitimately parked at rate 0.
        let hasStartedPlayback: Bool
        let isSeekInFlight: Bool
        /// The loopback route runs with `automaticallyWaitsToMinimizeStalling`
        /// off, so a drained buffer stops the player outright.
        let isBufferStarved: Bool
        let hasReachedEnd: Bool
    }

    static func resolve(_ context: Context) -> Self? {
        guard context.systemControlsAreActive,
              !context.isInitialObservation,
              context.hasStartedPlayback,
              !context.isSeekInFlight,
              !context.hasReachedEnd else { return nil }
        switch context.timeControlStatus {
        case .paused:
            guard !context.isBufferStarved else { return nil }
            return context.isUserPaused ? nil : .pause
        case .waitingToPlayAtSpecifiedRate, .playing:
            return context.isUserPaused ? .play : nil
        default:
            return nil
        }
    }
}

struct AVPlayerAudioSessionActivationState {
    struct Request: Equatable {
        let id: UInt64
        let needsActivation: Bool
    }

    private var nextID: UInt64 = 0
    private var active = false
    private var activationPending = false

    mutating func beginActivation() -> Request {
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        let request = Request(id: nextID, needsActivation: !active)
        activationPending = request.needsActivation
        return request
    }

    mutating func finishActivation(id: UInt64, succeeded: Bool) -> Bool {
        guard nextID == id else { return false }
        activationPending = false
        if succeeded { active = true }
        return true
    }

    mutating func cancelAndDeactivate() -> Bool {
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        let shouldDeactivate = active || activationPending
        active = false
        activationPending = false
        return shouldDeactivate
    }

    func isCurrent(id: UInt64) -> Bool {
        nextID == id
    }
}

/// Serializes the blocking AVAudioSession category/activation calls away
/// from the main thread. Generation tracking prevents an activation that
/// finishes after teardown or source replacement from attaching a stale item.
final class AVPlayerAudioSessionCoordinator: @unchecked Sendable {
    typealias Operation = () throws -> Void

    private let workQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let activation: Operation
    private let deactivation: Operation
    private let lock = NSLock()
    private var state = AVPlayerAudioSessionActivationState()

    /// One serial queue shared by every coordinator: AVAudioSession is a
    /// process-wide singleton, so an old backend's teardown deactivation and
    /// a new backend's activation must keep their submission order. Separate
    /// per-instance queues would let a stale deactivation land after the next
    /// playback's activation and silently kill its audio route.
    private static let sharedWorkQueue = DispatchQueue(
        label: "org.siloserver.silo.avplayer-audio-session",
        qos: .userInitiated
    )

    init(
        workQueue: DispatchQueue = AVPlayerAudioSessionCoordinator.sharedWorkQueue,
        callbackQueue: DispatchQueue = .main,
        activation: @escaping Operation,
        deactivation: @escaping Operation
    ) {
        self.workQueue = workQueue
        self.callbackQueue = callbackQueue
        self.activation = activation
        self.deactivation = deactivation
    }

    func activate(completion: @escaping (Error?) -> Void) {
        let request = locked { state.beginActivation() }
        guard request.needsActivation else {
            callbackQueue.async { [weak self] in
                guard self?.isCurrent(id: request.id) == true else { return }
                completion(nil)
            }
            return
        }

        workQueue.async { [weak self] in
            guard let self else { return }
            let error: Error?
            do {
                try self.activation()
                error = nil
            } catch let activationError {
                error = activationError
            }
            let shouldDeliver = self.locked {
                self.state.finishActivation(id: request.id, succeeded: error == nil)
            }
            guard shouldDeliver else { return }
            callbackQueue.async { [weak self] in
                guard self?.isCurrent(id: request.id) == true else { return }
                completion(error)
            }
        }
    }

    func deactivate() {
        let shouldDeactivate = locked { state.cancelAndDeactivate() }
        guard shouldDeactivate else { return }
        workQueue.async { [deactivation] in
            try? deactivation()
        }
    }

    private func isCurrent(id: UInt64) -> Bool {
        locked { state.isCurrent(id: id) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class AVPlayerBackend {
    enum SourceStrategy {
        case remoteHLS(url: URL, headers: [String: String])
        case remoteDirect(url: URL, headers: [String: String])
        case siloLoopback(spec: LoopbackSessionSpec)
    }

    private struct MediaSelectionState {
        let kind: PlayerTrack.Kind
        let group: AVMediaSelectionGroup
        let optionsByTrackId: [Int64: AVMediaSelectionOption]
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "AVPlayerBackend"
    )

    /// Forward buffer applied to the loopback `AVPlayerItem` at item
    /// creation. Sized for fast initial readyToPlay — AVPlayer otherwise
    /// waits for whole GOP-sized fragments before declaring ready.
    private static let loopbackStartupForwardBuffer: Double = 4.0
    /// Local loopback startup watchdog (AetherEngine-style, replaces the old
    /// fixed 12 s readiness timeout that killed healthy-but-slow startups —
    /// living-room DV P7 + TrueHD→FLAC at a far resume needed >12 s while
    /// segment GETs were flowing the whole time). This is the tick period only:
    /// the ladder it drives (nudge seek → in-place item reload → report), its
    /// stall window and its absolute backstop are `RecoveryPolicy`'s.
    private static let loopbackStartupWatchdogTickSeconds: TimeInterval = 1.0
    private static let seekCompletionDeadlineSeconds: TimeInterval = 15.0

    /// Initial video display gate. The gate holds `onFileLoaded` (and with it
    /// the app's loading overlay) until the picture is genuinely on screen, so
    /// a start reads as one continuous loader instead of dismissing onto a
    /// black panel and handing off to the transport's buffering chip.
    ///
    /// Layer readiness alone was measured insufficient on device: an Apple TV
    /// DV start reports `isReadyForDisplay` as soon as a frame is decoded and
    /// enqueued, seconds before the HDMI/DV pipeline actually presents it. So
    /// the startup release requires readiness AND that the playhead has run —
    /// a decoded frame proves the decoder opened, a running clock proves the
    /// renderer is consuming — with no mode switch underway at the moment of
    /// release.
    ///
    /// How much clock is demanded depends on how far the surface's readiness
    /// can be trusted. A start that wrote HDMI display criteria hands the
    /// panel a renegotiation whose tail is invisible to us, so it must show
    /// `initialVideoDisplaySustainedAdvanceSeconds` of motion. Everywhere else
    /// — iOS, macOS, a tvOS start that changed no mode — readiness lands on
    /// the same surface the viewer is looking at, so one tick of motion
    /// (`initialVideoDisplayMinimumAdvanceSeconds`) is proof enough and the
    /// overlay does not linger over running video.
    ///
    /// `initialVideoDisplayFallbackSeconds` is the re-check tick, not a flat
    /// timeout: waiting on the sustained signal re-arms it, so the constant
    /// now bounds "nothing has reported readiness at all" rather than the
    /// whole gate. The absolute backstop is the only hard ceiling — a wedged
    /// display manager, a surface that never reports, or a renderer that never
    /// advances all land there instead of stranding the overlay.
    private static let initialVideoDisplayFallbackSeconds: TimeInterval = 3.0
    private static let initialVideoDisplayAbsoluteBackstopSeconds: TimeInterval = 15.0
    private static let initialVideoDisplaySustainedAdvanceSeconds: Double = 0.5
    private static let initialVideoDisplayMinimumAdvanceSeconds: Double = 0.05
    /// Bridged-audio routes re-encode onto the session axis, so the produced
    /// stream has no audio before the encoder's anchor. Releasing the gate
    /// (and with it the startup unmute) before the playhead reaches that
    /// anchor is what showed as video-without-audio on a resume.
    private static let initialVideoDisplayAudioAnchorLeadSeconds: Double = 0.05

    /// Local DV loopback playhead watchdog. Driven by an independent wall-clock
    /// timer (AVPlayer's periodic time observer stops firing when the playhead
    /// freezes, so it cannot detect a stationary playhead on its own). This is
    /// the tick period only: the tick reports a `PlayheadSample` and every
    /// threshold it is judged against is `RecoveryPolicy`'s.
    private static let playheadWatchdogTickSeconds: TimeInterval = 1.0
    private static let generatedHLSSpillBudgetBytes: Int64 = 4 * 1024 * 1024 * 1024
    private static var loopbackSegmentStoreMemoryBudgetBytes: Int {
        PlaybackSourceCache.isConstrainedMemoryDevice ? 96 * 1024 * 1024 : 128 * 1024 * 1024
    }

    /// Forward-buffer target applied once the first frame is on screen. Larger
    /// than the startup target: startup optimizes for time-to-first-frame
    /// (AVPlayer declares ready as soon as one fragment is decodable), while
    /// steady state optimizes for riding out origin jitter on a high-bitrate
    /// source. 12 s is ~3 nominal segments of headroom, which the bounded
    /// producer window can sustain without forcing store eviction of segments
    /// AVPlayer may still request.
    ///
    /// NOT YET DEVICE-VALIDATED: raising this from an effective 4 s changes how
    /// far AVPlayer runs ahead of the bounded producer/store window. On a
    /// constrained-memory Apple TV (`PlaybackSourceCache.isConstrainedMemoryDevice`)
    /// with a high-bitrate DV/TrueHD source, a larger forward buffer can pull
    /// segments faster than the store's memory budget retains them. Validate on
    /// a real constrained Apple TV before release — 4K DV P7 + TrueHD, two
    /// seeks, confirm no `edge_watchdog` escalation, no `item buffer empty`
    /// bursts, and `Generated temp spill` within budget; record the run under
    /// `docs/tvos-player/validations/`. Constrained-memory devices take the
    /// conservative `8.0` tier until that run exists, matching how the source
    /// cache, proxy, and writer already gate their budgets.
    static let loopbackSteadyStateForwardBufferTarget: Double =
        PlaybackSourceCache.isConstrainedMemoryDevice ? 8.0 : 12.0

    /// The `reason` is a log token only (`LoopbackSegmentStore` prints it at
    /// construction and nothing else reads it) — it names why the disk cache
    /// is on, not which playlist shape is being served.
    private static func generatedHLSSpillPolicy(for spec: LoopbackSessionSpec) -> LoopbackSegmentStore.SpillPolicy {
        .enabled(
            reason: spec.sourceBitrateBps == nil ? "source_bitrate_unknown" : "local_hls_vod_cache",
            maxBytes: generatedHLSSpillBudgetBytes
        )
    }

    var onTimeChange: ((Double) -> Void)?
    var onDurationChange: ((Double) -> Void)?
    var onPauseChange: ((Bool) -> Void)?
    /// Carries the initial-video-display gate's release reason.
    var onFileLoaded: ((String) -> Void)?
    var onFirstFrame: ((Int) -> Void)?
    var onError: ((PlaybackFailure) -> Void)?
    var onEndOfFile: (() -> Void)?
    var onBufferingChange: ((Bool) -> Void)?
    var onBufferedAheadChange: ((PlaybackBufferedAhead) -> Void)?
    var onPlaybackStatsChange: ((PlaybackStats) -> Void)?
    var onTracksChange: (([PlayerTrack]) -> Void)?
    var onChaptersChange: (([PlayerChapterInfo]) -> Void)?
    var onTimelineOffsetChange: ((Double) -> Void)?
    /// AirPlay video handoff started (`true`) or ended (`false`). Bound for
    /// the player's whole lifetime rather than per item, because the route can
    /// change while the app is backgrounded and no item-scoped event reports
    /// it.
    var onExternalPlaybackActiveChange: ((Bool) -> Void)?
    /// Whether the current route can hand video to an AirPlay receiver at all.
    /// Drives the visibility of the route picker: offering it on a route the
    /// receiver cannot fetch just produces a dead TV screen.
    var onExternalPlaybackAllowedChange: ((Bool) -> Void)?
    /// An AirPlay handoff was attempted but no LAN address the receiver could
    /// reach exists. Playback stays on this device; the shell tells the user.
    var onExternalPlaybackUnavailable: (() -> Void)?
    /// PiP controls mutate `AVPlayer` directly instead of calling this
    /// backend's `play()` / `pause()` methods. The shell supplies PiP ownership
    /// here so transport KVO can reconcile those changes into Silo's intent.
    var isPictureInPictureActiveProvider: (() -> Bool)?
    var onSidecarTracksRegistered: (([SidecarSubtitleDescriptor]) -> Void)?
    /// Live query into the source proxy's outage state; handed to writers so
    /// their blocking source reads can park through a flagged outage. Wired by
    /// the engine session, which owns the proxy.
    var sourceOutageStateProvider: (() -> Bool)?
    /// Every in-route recovery signal, emitted where the ladder used to decide.
    /// `RecoveryDriver` turns these into `RecoveryAction`s through the one
    /// `RecoveryPolicy`; nothing in this file decides any more.
    var onRecoveryObservation: ((RecoveryObservation) -> Void)?
    /// A new engine load started on this backend (`load(strategy:)`), including
    /// the in-session reloads a reanchor / rebuild / deferred `play()` recovery
    /// performs. The recovery owner resets exactly the per-load state that
    /// function reset when it owned those fields.
    var onEngineReloaded: (() -> Void)?
    /// The loopback startup ladder was (re-)armed; the payload is the local HLS
    /// server's served-request baseline. The recovery owner seeds
    /// `RecoveryContext.StartupState` from it.
    var onStartupLadderArmed: ((UInt64) -> Void)?
    /// Diagnostic mirror of `RecoveryContext.suspendedReasons`, written by the
    /// engine session whenever the driver's latch changes. It exists only so
    /// the periodic `[CMP-AVP] loopback playhead state` line keeps printing its
    /// `suspended=[…]` suffix; no code branches on it.
    var suspendedRecoveryReasons: Set<String> = []
    /// The recovery owner's `stationaryFor`, for the same telemetry line. The
    /// advance tracker moved into `RecoveryContext.PlayheadState` with the rungs
    /// that read it, and this line is the only thing left here that printed it.
    var recoveryStationarySecondsProvider: (() -> Double)?

    /// Reports an in-route recovery signal. Every ladder that used to decide
    /// here calls this instead.
    ///
    /// Every emitter is a main-queue notification observer, a `RunLoop.main`
    /// timer, a `DispatchQueue.main` KVO hop or a transport verb — the same
    /// contexts the rungs ran their decisions in, and the recovery owner is
    /// nonisolated for exactly that reason.
    private func emitRecoveryObservation(_ observation: RecoveryObservation) {
        onRecoveryObservation?(observation)
    }

    /// A live transport sample for the notification-driven rungs, which read the
    /// player at the moment their notification fires rather than off the 1 Hz
    /// tick. `RecoveryDriver` pulls this immediately before each `decide`.
    var recoveryPlayheadSample: PlayheadSample? {
        guard !isDisposed, let item = currentItem else { return nil }
        let position = currentTime()
        let bufferedAhead = playableAheadSeconds(for: item, referenceTime: position)
        let generatedEnd = latestLoopbackGeneratedStats?.playlistVisibleEndSeconds
            ?? segmentStore?.stats().generatedMediaSeconds
            ?? 0
        return PlayheadSample(
            position: position,
            timeControl: Self.timeControl(for: avPlayer.timeControlStatus),
            bufferedAhead: bufferedAhead,
            generatedAhead: max(0, generatedEnd - position),
            secondsSinceLastServe: segmentStore?.secondsSinceLastSegmentServe() ?? .infinity,
            userPaused: isUserPaused,
            playbackEstablished: didFireFileLoaded,
            pendingSeekMediaTarget: vodPendingSeekMediaTarget
        )
    }

    /// Injected so a test can hand the backend a player it controls; the
    /// default keeps every production call site unchanged (review §9 stage 1).
    let avPlayer: AVPlayer
    private let subtitleOverlayAttachments = SubtitleOverlayAttachmentRegistry()
    var subtitleOverlay: SubtitleOverlayView? {
        subtitleOverlayAttachments.currentOverlay
    }

    func attachSubtitleOverlay(_ overlay: SubtitleOverlayView, owner: AnyObject) {
        subtitleOverlayAttachments.attach(owner: owner, overlay: overlay)
    }

    func detachSubtitleOverlay(owner: AnyObject) {
        subtitleOverlayAttachments.detach(owner: owner)
    }
    var subtitleRendererForOverlay: SubtitleRenderer? {
        subtitleSession?.underlyingRenderer
    }
    var hasControlledSubtitleSelection: Bool {
        selectedControlledSubtitleTrackId != nil || selectedSecondaryControlledSubtitleTrackId != nil
    }

    private var currentSourceStrategy: SourceStrategy?
    private var currentItem: AVPlayerItem?
    private var audioSelectionState: MediaSelectionState?
    private var subtitleSelectionState: MediaSelectionState?
    private var timeObserver: Any?
    #if os(macOS)
    private var subtitleDisplayLink: Timer?
    #else
    private var subtitleDisplayLink: CADisplayLink?
    #endif
    private var didFireFileLoaded = false
    private var pendingStartTime: Double = 0
    private var hasSeekedToStart = false
    private var isDisposed = false
    private var isSeekPending = false
    private var seekDeadlineState = AVPlayerSeekDeadlineState()
    private var seekDeadlineWorkItem: DispatchWorkItem?
    private enum SeekDeadlineKind {
        case interactive(mediaTarget: Double)
        case initial(mediaTarget: Double)
        /// A seek issued by an in-route recovery rung (stall nudge, item
        /// reload). It carries no follow-up recovery of its own: the deadline
        /// exists so a recovery seek that never completes stops masking the
        /// playhead watchdog, which owns the next rung and its budgets.
        case recovery(reason: String)
    }
    /// Kind of the seek behind the active deadline generation. When a new
    /// deadline supersedes an in-flight `.initial` seek, its AVPlayer
    /// completion arrives against a stale generation and is ignored, so the
    /// supersede/cancel paths must release `isInitialSeekInFlight` here —
    /// nothing else will, and `attemptInitialPlaybackStart` gates on it.
    private var activeSeekDeadlineKind: SeekDeadlineKind?
    private var isInitialSeekInFlight = false
    private var subtitleSession: SubtitleSession?
    private var embeddedSubtitleExtractor: AVPlayerEmbeddedSubtitleExtractor?
    /// Change-detection key for the overlay's bitmap cue layers: overlay
    /// size and the identity of each active cue image. The display link
    /// pumps at vsync rate but bitmap cues change on the order of
    /// seconds, so all layer work is skipped while the key is unchanged.
    ///
    /// Bitmap cues (PGS/DVD) render exactly as authored — position, size,
    /// and background are part of the source pixels, so the user's text
    /// appearance preferences deliberately do not apply here.
    private struct BitmapCueRenderKey: Equatable {
        let videoRect: CGRect
        let images: [ObjectIdentifier]
    }
    private var lastBitmapCueRenderKey: BitmapCueRenderKey?
    /// Whether a libass-composited frame may still be on the text layer.
    /// Lets the pump clear the layer exactly once on a text → bitmap
    /// transition instead of dispatching a no-op clear to main every vsync
    /// for the whole duration of bitmap-only (PGS/DVD) playback.
    private var textOverlayMayHaveFrame = false
    /// Text renders currently queued or executing on the renderer's session
    /// queue. The display link enqueues at vsync rate but a render can take
    /// >100 ms (full 4K re-rasterization), so without a cap the queue grows
    /// unboundedly and every downstream mutation (cue feeds, styling,
    /// track drops) lands seconds late. Capped at 2: one executing, one
    /// queued behind it. Main thread only.
    private var subPumpRendersInFlight = 0
    private var selectedControlledSubtitleTrackId: Int64?
    private var selectedSecondaryControlledSubtitleTrackId: Int64?
    private var sidecarDescriptorsByTrackId: [Int64: SidecarSubtitleDescriptor] = [:]
    /// Text-subtitle cues harvested from the loopback writer's own demuxer
    /// (see LoopbackSubtitleTap). Keyed to the source URL: producer
    /// restarts and reanchors reuse the store; a new source resets it.
    private var loopbackSubtitleTap: LoopbackSubtitleTap?
    private var loopbackSubtitleTapSourceURL: URL?
    /// Bitmap (PGS/DVD) streams the loopback writer's tap can serve, and
    /// the currently selected one. The selection is re-applied to every
    /// new writer so it survives producer restarts.
    private var bitmapTapAvailableStreams: Set<Int> = []
    private var selectedBitmapTapStreamIndex: Int?
    private var mediaTimelineOffsetSeconds: Double = 0
    private var serverChapters: [PlayerChapterInfo] = []
    private var currentLoopbackAudioTracks: [PlayerTrack] = []
    private var rebufferCount = 0
    /// How long after a seek settles an `isPlaybackBufferEmpty` transition is
    /// still attributed to that seek rather than to a rebuffer.
    private static let rebufferSeekGraceSeconds: CFTimeInterval = 1.5
    private var lastSeekSettledAt: CFTimeInterval = 0
    private var lastStatsEmitWall: CFTimeInterval = 0
    private var loopbackDemuxReadBitrateBps: Double?
    private var loopbackHDR10PlusDetected = false
    private var loopbackSourceBytesRead: Int64?
    private var latestLoopbackGeneratedStats: LoopbackSegmentWriter.GeneratedMediaStats?
    private var isInitialVideoDisplayGatePrepared = false
    private var isWaitingForInitialVideoDisplay = false
    private var didTemporarilyMuteForInitialVideoDisplay = false
    private var initialVideoDisplayGateStartTime: Double?
    private var initialVideoDisplayGateArmedAt: Date?
    /// Startup is the only load that waits for the surface's first-frame
    /// signal. A reanchor re-arms the same gate against a layer that has
    /// already displayed this player once, so it keeps the permissive
    /// clock-advance release rather than risking a seek that sits on the
    /// overlay waiting for a readiness edge that may not come a second time.
    private var didCompleteInitialVideoDisplayGate = false
    /// Latched, not sampled: the render surface publishes readiness once per
    /// item and the gate may evaluate long after that edge.
    private var didObserveVideoSurfaceReadyForDisplay = false
    /// Wall clock of the last HDMI criteria settle (or of the apply itself
    /// when no negotiation was needed). Reported as `sinceSettleMs` on the
    /// release line so a device capture can measure how far behind the
    /// manager's "settled" the panel's real presentation runs.
    private var tvDisplaySettleCompletedAt: Date?
    /// Whether this start wrote HDMI display criteria. Only such a start has
    /// a panel renegotiation running behind the surface's readiness signal.
    private var didApplyTVDisplayCriteriaForStart = false
    /// Session-axis second at which the bridged-audio encoder anchored, as
    /// reported by the segment writer. Nil on copy-mode routes.
    private var loopbackBridgedAudioAnchorSeconds: Double?
    private var initialVideoDisplayFallback: DispatchWorkItem?
    private var loopbackStartupWatchdog: Timer?
    /// In-flight HDMI mode-switch settle wait (gated non-DV HDR, plus any
    /// fresh DV criteria apply — the master playlist's VIDEO-RANGE is
    /// validated against the panel's current mode on tvOS 26.5). The
    /// AVPlayerItem attach is deferred behind it; teardown cancels it so a
    /// reanchor or dispose can't race a late attach.
    private var displayModeSettleTask: Task<Void, Never>?

    /// The local HLS pipeline for the running `.siloLoopback` session: store,
    /// server, producer and session directory (`LocalHLSHost`). Non-nil
    /// exactly while such a session is live — `startSiloLoopback` builds one
    /// and `teardownMediaPipeline` tears it down and clears it. The host IS
    /// the session identity the retired session-id string used to carry:
    /// every closure installed on it re-checks `loopbackHost === host`.
    private var loopbackHost: LocalHLSHost?
    /// The VOD plan resolved for the current source. It outlives the host
    /// that resolved it deliberately: a reanchor tears the session down, and
    /// the next producer must be handed the same segment grid instead of
    /// re-harvesting one.
    private var carriedVODPlan: LocalHLSHost.ResolvedVODPlan?
    /// Read-only views onto the host's pipeline for the stats, ladder, AirPlay
    /// and subtitle readers that stayed in this adapter.
    private var segmentWriter: LoopbackSegmentWriter? { loopbackHost?.segmentWriter }
    private var segmentServer: LoopbackSegmentServer? { loopbackHost?.segmentServer }
    private var segmentStore: LoopbackSegmentStore? { loopbackHost?.segmentStore }
    private var loopbackPlaylistName: String?
    private var loopbackPlaybackUsesExternalURL = false
    private let loopbackPlaybackClockLock = NSLock()
    private var loopbackPlaybackClockSecondsValue: Double = 0
    /// The media time a `playlist_unchanged` recovery latched while the user
    /// was paused (`RecoveryAction.deferUntilPlay`), consumed by `play()`.
    private var deferredRecoveryMediaTime: Double?
    private var loopbackPlayheadWatchdog: Timer?
    private var watchdogLastStateLogWall: CFTimeInterval = 0
    /// Which sampler produced the edge observation currently being decided, so
    /// `perform(_:)` can name it on the `edge_watchdog` trigger line — together
    /// with the two clock-derived values the decision was actually taken on.
    /// The legacy rung printed its own `referenceTime`/`loadedEnd` locals, and
    /// for the periodic-time-observer trigger `referenceTime` is `time.seconds`,
    /// not `currentTime()`.
    private var lastEdgeSampleTrigger = "-"
    private var lastEdgeSampleReferenceTime: Double?
    private var lastEdgeSampleLoadedEnd: Double?
    /// Which KVO produced the auto-resume observation currently being decided,
    /// for the same reason.
    private var lastAutoResumeTrigger = "-"
    private var isUserPaused = false
    /// Guards `reconcileSystemTransportIntent` against the `.initial` KVO
    /// delivery, which reports pre-roll state rather than a transport command.
    private var hasObservedTimeControlStatus = false
    /// True between `AVPlayerItemDidPlayToEndTime` and the next load or seek.
    /// The player parks at rate 0 there, which is not a receiver pause.
    private var hasReachedItemEnd = false
    private var isPreservingTVDisplayCriteriaForReload = false

    private let audioSessionCoordinator: AVPlayerAudioSessionCoordinator = {
        #if os(macOS)
        AVPlayerAudioSessionCoordinator(activation: {}, deactivation: {})
        #else
        AVPlayerAudioSessionCoordinator(
            activation: {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback, options: [])
                // Routing preference, not a claim: tells the system this app
                // plays multichannel content so route negotiation (HDMI/AirPlay)
                // prefers a multichannel-capable path. AetherEngine sets the
                // same before its Atmos passthrough.
                try? session.setSupportsMultichannelContent(true)
                try session.setActive(true, options: [])
            },
            deactivation: {
                try AVAudioSession.sharedInstance().setActive(
                    false, options: [.notifyOthersOnDeactivation]
                )
            }
        )
        #endif
    }()

    private var statusObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var timeControlObs: NSKeyValueObservation?
    private var bufferFullObs: NSKeyValueObservation?
    private var bufferEmptyObs: NSKeyValueObservation?
    private var itemPlaybackStalledObserver: NSObjectProtocol?
    private var itemFailedToEndObserver: NSObjectProtocol?
    private var itemErrorLogObserver: NSObjectProtocol?
    private var durationObs: NSKeyValueObservation?
    private var loadedRangesObs: NSKeyValueObservation?
    private var seekableRangesObs: NSKeyValueObservation?
    private var externalPlaybackObs: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    init(player: AVPlayer = AVPlayer()) {
        avPlayer = player
        // Stays off until a route that the receiver can actually fetch is
        // loaded; `applyExternalPlaybackPolicy(for:)` opens it per strategy.
        avPlayer.allowsExternalPlayback = false
        #if !os(macOS)
        // Mirrored-display handoff is an iOS/tvOS concept; macOS has no
        // equivalent and the property is unavailable there.
        avPlayer.usesExternalPlaybackWhileExternalScreenIsActive = false
        #endif
        // Player-scoped, not item-scoped: `detachPerItemObservers()` runs on
        // every reanchor/quality switch and would otherwise blind us to route
        // changes mid-session. Invalidated in `dispose()`.
        externalPlaybackObs = avPlayer.observe(
            \.isExternalPlaybackActive,
            options: [.new]
        ) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor [weak self] in
                guard let self, !self.isDisposed else { return }
                self.updateLoopbackURLForExternalPlayback(active)
                self.onExternalPlaybackActiveChange?(active)
            }
        }

        let session = SubtitleSession()
        session.onSidecarTracksRegistered = { [weak self] descriptors in
            self?.onSidecarTracksRegistered?(descriptors)
        }
        session.currentPositionSecondsProvider = { [weak self] in
            guard let self else { return 0 }
            return self.mediaTime(for: self.currentTime())
        }
        subtitleSession = session
        let extractor = AVPlayerEmbeddedSubtitleExtractor(subtitleSession: session)
        extractor.currentMediaTimeProvider = { [weak self] in
            guard let self else { return 0 }
            return self.mediaTime(for: self.currentTime())
        }
        extractor.onTracksChanged = { [weak self] _ in
            DispatchQueue.main.async {
                self?.emitTrackList()
            }
        }
        embeddedSubtitleExtractor = extractor
    }

    deinit {
        dispose()
    }

    func load(
        sessionSpec: LoopbackSessionSpec,
        startTime: Double,
    ) {
        isUserPaused = false
        load(
            strategy: .siloLoopback(spec: sessionSpec),
            startTime: startTime
        )
    }

    func loadRemoteHLS(url: URL, headers: [String: String], startTime: Double) {
        isUserPaused = false
        load(
            strategy: .remoteHLS(url: url, headers: headers),
            startTime: startTime
        )
    }

    func loadDirectFile(url: URL, headers: [String: String], startTime: Double) {
        isUserPaused = false
        load(
            strategy: .remoteDirect(url: url, headers: headers),
            startTime: startTime
        )
    }

    func play() {
        isUserPaused = false
        onPauseChange?(false)
        if case .some(.siloLoopback(let spec)) = currentSourceStrategy,
           let mediaSeconds = deferredRecoveryMediaTime {
            deferredRecoveryMediaTime = nil
            Self.logger.info(
                "[CMP-AVP] local loopback deferred recovery reanchor media=\(mediaSeconds, privacy: .public)"
            )
            subtitleSession?.flushOnSeek()
            embeddedSubtitleExtractor?.seek(to: mediaSeconds)
            load(strategy: .siloLoopback(spec: spec.reanchored(at: mediaSeconds)), startTime: mediaSeconds)
            return
        }
        avPlayer.play()
    }

    func pause() {
        isUserPaused = true
        onPauseChange?(true)
        avPlayer.pause()
    }

    @discardableResult
    private func reconcileSystemTransportIntent(
        from player: AVPlayer,
        isInitialObservation: Bool
    ) -> Bool {
        let systemControlsAreActive = player.isExternalPlaybackActive
            || isPictureInPictureActiveProvider?() == true
        guard let intent = AVPlayerSystemTransportIntent.resolve(
            .init(
                timeControlStatus: player.timeControlStatus,
                isUserPaused: isUserPaused,
                systemControlsAreActive: systemControlsAreActive,
                isInitialObservation: isInitialObservation,
                hasStartedPlayback: hasSeekedToStart,
                isSeekInFlight: isSeekPending || isInitialSeekInFlight,
                isBufferStarved: currentItem?.isPlaybackBufferEmpty == true,
                hasReachedEnd: hasReachedItemEnd
            )
        ) else { return false }

        switch intent {
        case .play:
            Self.logger.info("System transport requested play")
            play()
        case .pause:
            Self.logger.info("System transport requested pause")
            pause()
        }
        return true
    }

    var isExternalPlaybackActive: Bool {
        avPlayer.isExternalPlaybackActive
    }

    var isExternalPlaybackAllowed: Bool {
        avPlayer.allowsExternalPlayback
    }

    private func applyExternalPlaybackPolicy(for strategy: SourceStrategy) {
        let allowed: Bool
        switch strategy {
        case .siloLoopback:
            // Only the iOS loopback server is LAN-reachable; elsewhere it
            // binds to 127.0.0.1 and no receiver could ever fetch it.
            #if os(iOS)
            allowed = true
            #else
            allowed = false
            #endif
        case .remoteHLS(let url, let headers), .remoteDirect(let url, let headers):
            allowed = Self.isReceiverFetchableAsset(url: url, headers: headers)
        }
        setExternalPlaybackAllowed(allowed)
    }

    /// Can an AirPlay receiver fetch this asset itself? It gets the URL and
    /// nothing else — none of the asset's HTTP headers, and its own network
    /// stack. Two disqualifiers, both of which occur on direct-play routes:
    ///
    /// - Header authentication. Silo's `/api/v1/...` stream URLs carry a
    ///   bearer token in `Authorization`, and the receiver's fetch gets a 401.
    /// - A loopback host. `PlayerViewModel.prepareSourceProxy` rewrites
    ///   direct-play URLs to the on-device caching proxy at 127.0.0.1 *and
    ///   drops the headers*, so "no headers" on its own is not evidence that
    ///   anything off-device can reach it.
    ///
    /// Local files pass: AVPlayer streams a `file://` asset to the receiver
    /// itself instead of handing over a URL that means nothing there.
    static func isReceiverFetchableAsset(url: URL, headers: [String: String]) -> Bool {
        if url.isFileURL { return true }
        guard headers.isEmpty,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return !isLoopbackHost(url.host)
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        return host.hasPrefix("127.")
    }

    private func setExternalPlaybackAllowed(_ allowed: Bool) {
        avPlayer.allowsExternalPlayback = allowed
        #if !os(macOS)
        // Mirrored-display handoff is an iOS/tvOS concept; macOS has no
        // equivalent and the property is unavailable there.
        avPlayer.usesExternalPlaybackWhileExternalScreenIsActive = allowed
        #endif
        onExternalPlaybackAllowedChange?(allowed)
    }

    @MainActor
    private func updateLoopbackURLForExternalPlayback(_ active: Bool) {
        guard active != loopbackPlaybackUsesExternalURL,
              case .some(.siloLoopback) = currentSourceStrategy,
              let item = currentItem,
              let server = segmentServer,
              let playlistName = loopbackPlaylistName else { return }
        guard let url = server.resourceURL(
            for: playlistName,
            reachableFromExternalDevice: active
        ) else {
            // The item is still pointed at 127.0.0.1, which the receiver
            // cannot fetch: leaving it there would strand the TV on a spinner
            // with nothing on screen here either.
            abandonExternalPlaybackHandoff()
            return
        }

        let position = currentTime()
        loopbackPlaybackUsesExternalURL = active
        server.setAcceptsExternalClients(active)
        reloadEstablishedLoopbackItem(
            item,
            at: position.isFinite ? max(0, position) : 0,
            reason: active ? "airplay_started" : "airplay_ended",
            replacementURL: url
        )
    }

    /// No LAN address the receiver could reach (Wi-Fi off, cellular-only, an
    /// isolated guest network). Bring playback back to this device and say so
    /// — `allowsExternalPlayback = false` makes AVPlayer render locally again,
    /// and the `isExternalPlaybackActive` KVO that follows leaves the item on
    /// the loopback URL it already has.
    private func abandonExternalPlaybackHandoff() {
        cmpLog("[CMP-AVP] airplay handoff unavailable: no reachable local network address")
        setExternalPlaybackAllowed(false)
        onExternalPlaybackUnavailable?()
    }

    func videoSurfaceBecameReadyForDisplay() {
        guard !isDisposed else { return }
        // Latch first: the surface publishes this edge once per item, and the
        // startup gate may still be waiting on the clock when it lands.
        if !didObserveVideoSurfaceReadyForDisplay {
            didObserveVideoSurfaceReadyForDisplay = true
            cmpLog("[CMP-AVP] video surface ready for display")
        }
        evaluateInitialVideoDisplayGate(trigger: "ready_for_display")
    }

    func setMediaTimelineOffset(_ offset: Double) {
        mediaTimelineOffsetSeconds = offset.isFinite ? max(0, offset) : 0
        onTimelineOffsetChange?(mediaTimelineOffsetSeconds)
        Self.logger.info(
            "[CMP-SEEK] AVPlayer timeline offset set requested=\(offset, privacy: .public) applied=\(self.mediaTimelineOffsetSeconds, privacy: .public)"
        )
    }

    func seek(to seconds: Double) {
        let mediaSeconds = seconds.isFinite ? max(0, seconds) : 0
        let playerSeconds = playerTime(forMediaTime: mediaSeconds)
        hasReachedItemEnd = false
        if case .some(.siloLoopback) = currentSourceStrategy {
            // Every loopback seek is in-item: the static playlist covers the
            // whole title, and a fetch into never-produced content restarts
            // the producer behind the stable item (1e).
            //
            // Recovery anchor (M7): if this seek wedges, the watchdog must aim
            // at the requested target — the frozen clock still reports the
            // pre-seek position.
            vodPendingSeekMediaTarget = mediaSeconds
            // The generated-media snapshot describes the OLD anchor. A
            // backward seek would otherwise inflate the runway (and every
            // scrubber's buffered fill) with a playlist tail whose media was
            // retired behind the previous playhead, until the restarted
            // producer finalizes its first segment and re-emits. Drop it;
            // runway honestly falls back to the decode buffer meanwhile.
            latestLoopbackGeneratedStats = nil
        }

        let time = CMTime(seconds: playerSeconds, preferredTimescale: 600)
        isSeekPending = true
        rebaseInitialVideoDisplayGateStartTime(to: playerSeconds, context: "user_seek")
        let seekItem = currentItem
        let seekID = beginSeekDeadline(
            kind: .interactive(mediaTarget: mediaSeconds),
            item: seekItem
        )
        Self.logger.info(
            "[CMP-SEEK] AVPlayer seek request media=\(mediaSeconds, privacy: .public) player=\(playerSeconds, privacy: .public) offset=\(self.mediaTimelineOffsetSeconds, privacy: .public)"
        )
        subtitleSession?.flushOnSeek()
        avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self, !self.isDisposed else { return }
            guard self.completeSeekDeadline(seekID) else {
                Self.logger.info(
                    "[CMP-SEEK] ignoring late/superseded AVPlayer seek completion id=\(seekID, privacy: .public)"
                )
                return
            }
            guard seekItem === self.currentItem else { return }
            self.markSeekSettled()
            self.vodPendingSeekMediaTarget = nil
            let landed = self.avPlayer.currentTime().seconds
            let mediaTime = self.mediaTime(for: landed)
            Self.logger.info(
                "[CMP-SEEK] AVPlayer seek complete finished=\(finished, privacy: .public) landedPlayer=\(landed, privacy: .public) landedMedia=\(mediaTime, privacy: .public) requestedMedia=\(mediaSeconds, privacy: .public) offset=\(self.mediaTimelineOffsetSeconds, privacy: .public)"
            )
            guard finished, landed.isFinite, mediaTime.isFinite else { return }
            self.resyncControlledSubtitlesAfterSeek(mediaSeconds: mediaTime)
            self.onTimeChange?(landed)
            self.pumpSubtitleOverlay(referenceTime: mediaTime)
        }
    }

    @discardableResult
    private func beginSeekDeadline(
        kind: SeekDeadlineKind,
        item: AVPlayerItem?
    ) -> UInt64 {
        seekDeadlineWorkItem?.cancel()
        releaseSupersededInitialSeekGateIfNeeded()
        activeSeekDeadlineKind = kind
        let id = seekDeadlineState.begin()
        let work = DispatchWorkItem { [weak self, weak item] in
            guard let self, !self.isDisposed else { return }
            self.handleSeekDeadline(id: id, kind: kind, item: item)
        }
        seekDeadlineWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.seekCompletionDeadlineSeconds,
            execute: work
        )
        return id
    }

    private func completeSeekDeadline(_ id: UInt64) -> Bool {
        guard seekDeadlineState.complete(id) else { return false }
        seekDeadlineWorkItem?.cancel()
        seekDeadlineWorkItem = nil
        activeSeekDeadlineKind = nil
        return true
    }

    /// The only way a seek stops being pending. Clearing `isSeekPending`
    /// without stamping `lastSeekSettledAt` would let the very next
    /// buffer-empty count as a rebuffer, so the pair is structural here.
    private func markSeekSettled() {
        isSeekPending = false
        lastSeekSettledAt = CACurrentMediaTime()
    }

    private func cancelSeekDeadline() {
        seekDeadlineWorkItem?.cancel()
        seekDeadlineWorkItem = nil
        releaseSupersededInitialSeekGateIfNeeded()
        activeSeekDeadlineKind = nil
        seekDeadlineState.cancel()
        markSeekSettled()
        vodPendingSeekMediaTarget = nil
    }

    private func releaseSupersededInitialSeekGateIfNeeded() {
        guard seekDeadlineState.activeID != nil,
              case .some(.initial) = activeSeekDeadlineKind else { return }
        isInitialSeekInFlight = false
    }

    private func handleSeekDeadline(
        id: UInt64,
        kind: SeekDeadlineKind,
        item: AVPlayerItem?
    ) {
        guard completeSeekDeadline(id), item === currentItem else { return }
        markSeekSettled()
        // Clearing `isSeekPending` is all the deadline owes the watchdogs.
        // Whether the seek itself is discarded depends on the kind: a
        // `.recovery` seek from an item reload is issued right after
        // `replaceCurrentItem` and stays queued in AVFoundation until the
        // fresh item is ready, which is exactly what takes longer than the
        // deadline on the paths that reload (poisoned loader, receiver-side
        // LAN fetch after an AirPlay handoff). Cancelling it there would
        // start the fresh item at zero and silently lose the resume
        // position while the playhead watchdog saw an advancing clock and
        // called the route healthy. Leaving it queued is safe: a late
        // completion finds the deadline generation already closed and
        // returns without touching a flag, and every following rung cancels
        // pending seeks before issuing its own.
        switch kind {
        case .interactive, .initial:
            item?.cancelPendingSeeks()
        case .recovery:
            break
        }

        switch kind {
        case .interactive(let mediaTarget):
            Self.logger.error(
                "[CMP-SEEK] AVPlayer seek deadline mediaTarget=\(mediaTarget, privacy: .public) id=\(id, privacy: .public); re-enabling recovery"
            )
            // Which recovery an expired interactive seek deserves — the
            // loopback stall nudge anchored at the unlanded target, or a bare
            // resume on the remote routes — is `RecoveryPolicy`'s
            // `decideInteractiveSeekDeadlineExpired`.
            emitRecoveryObservation(.interactiveSeekDeadlineExpired(mediaTarget: mediaTarget))
            vodPendingSeekMediaTarget = nil

        case .recovery(let reason):
            // Do not stack another recovery here: the rung that issued this
            // seek (playhead watchdog, item-death reload) owns the ladder and
            // its retry budget, and it was blind while `isSeekPending` was
            // latched. Clearing the flag above hands control straight back.
            Self.logger.error(
                "[CMP-SEEK] recovery seek deadline reason=\(reason, privacy: .public) id=\(id, privacy: .public); releasing the watchdog"
            )
            cmpLog("[CMP-AVP] recovery seek never completed reason=\(reason)")

        case .initial(let mediaTarget):
            isInitialSeekInFlight = false
            Self.logger.error(
                "[CMP-SEEK] initial AVPlayer seek deadline mediaTarget=\(mediaTarget, privacy: .public)"
            )
            // The deadline is the whole budget for the initial resume seek:
            // start playing rather than leave the item parked. `hasSeekedToStart`
            // stays false, so the item's `seekableTimeRanges`/`loadedTimeRanges`
            // observers re-enter `attemptInitialPlaybackStart` as soon as more
            // media makes the target reachable.
            if let item = currentItem {
                startPlaybackIfNeeded(for: item)
            }
        }
    }

    /// Issues an in-route recovery seek through the same deadline machinery a
    /// user seek uses. Recovery seeks used to be fire-and-forget, so one that
    /// never completed left the route wedged with nothing recording it.
    /// Marking the seek pending also keeps the position watchdogs from
    /// stacking another recovery on top of an in-flight one; the 15 s
    /// deadline bounds that quiet window and hands the ladder back.
    private func performRecoverySeek(to time: CMTime, reason: String) {
        isSeekPending = true
        let seekID = beginSeekDeadline(kind: .recovery(reason: reason), item: currentItem)
        avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self, !self.isDisposed else { return }
            guard self.completeSeekDeadline(seekID) else { return }
            self.markSeekSettled()
            Self.logger.info(
                "[CMP-SEEK] recovery seek complete reason=\(reason, privacy: .public) finished=\(finished, privacy: .public)"
            )
        }
    }

    func currentTime() -> Double {
        avPlayer.currentTime().seconds
    }

    private func mediaTime(for playerTime: Double) -> Double {
        guard playerTime.isFinite else { return 0 }
        return max(0, playerTime + mediaTimelineOffsetSeconds)
    }

    private func setLoopbackPlaybackClock(_ seconds: Double) {
        guard seconds.isFinite else { return }
        loopbackPlaybackClockLock.lock()
        loopbackPlaybackClockSecondsValue = max(0, seconds)
        loopbackPlaybackClockLock.unlock()
    }

    private func loopbackPlaybackClockSeconds() -> Double {
        loopbackPlaybackClockLock.lock()
        let value = loopbackPlaybackClockSecondsValue
        loopbackPlaybackClockLock.unlock()
        return value
    }

    private func playerTime(forMediaTime mediaTime: Double) -> Double {
        guard mediaTime.isFinite else { return 0 }
        return max(0, mediaTime - mediaTimelineOffsetSeconds)
    }

    func isPaused() -> Bool {
        isUserPaused
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        Self.logger.info("[CMP-AVP] dispose")
        externalPlaybackObs?.invalidate()
        externalPlaybackObs = nil
        onExternalPlaybackActiveChange = nil
        isPictureInPictureActiveProvider = nil
        teardownMediaPipeline()
    }

    func setSpeed(_ rate: Double) {
        avPlayer.defaultRate = Float(rate)
        if avPlayer.rate != 0 {
            avPlayer.rate = Float(rate)
        }
    }

    private var userVolume: Float = 1.0
    private var userMuted = false

    func setUserVolume(_ v: Float) {
        userVolume = min(max(v, 0), 1)
        // An explicit volume change requests an audible level, so it clears
        // mute — otherwise the gain stays at 0 and the slider disagrees with
        // the silent output.
        userMuted = false
        applyUserGain()
    }
    func setUserMuted(_ m: Bool) {
        userMuted = m
        applyUserGain()
    }
    var currentUserVolume: Float { userVolume }

    // User mute is modeled as volume = 0, NOT avPlayer.isMuted: the latter is
    // owned by the initial-video-display gate (begin/finishInitialVideoDisplayGate)
    // and its unmute would clobber a user mute.
    private func applyUserGain() {
        avPlayer.volume = userMuted ? 0 : userVolume
    }

    func setSubtitleDelay(_ seconds: Double) {
        cmpLog("[CMP-SUB] setSubtitleDelay seconds=\(seconds) session=\(subtitleSession == nil ? "nil" : "live")")
        var params = subtitleSession?.currentParams ?? .default
        params.syncOffsetMs = Int((seconds * 1000.0).rounded())
        subtitleSession?.applyStyling(params)
    }

    func applySubtitleAppearance(_ appearance: SubtitleAppearance) {
        cmpLog("[CMP-SUB] applySubtitleAppearance size=\(appearance.fontSize.rawValue) session=\(subtitleSession == nil ? "nil" : "live")")
        let syncOffset = subtitleSession?.currentParams.syncOffsetMs ?? 0
        let params = SubtitleStylingOverride.Parameters.from(
            appearance: appearance,
            syncOffsetMs: syncOffset
        )
        subtitleSession?.applyStyling(params)
    }

    func selectAudioTrack(_ trackId: Int64) {
        if case .some(.siloLoopback(let spec)) = currentSourceStrategy {
            guard let selectedTrack = spec.availableAudioTracks.first(where: { $0.trackId == trackId }),
                  let selectedTrackIndex = selectedTrack.srcId else {
                return
            }
            guard selectedTrackIndex != spec.selectedAudio.trackIndex else {
                Self.logger.debug(
                    "[CMP-AVP] ignoring unchanged loopback audio trackId=\(trackId, privacy: .public) trackIndex=\(selectedTrackIndex, privacy: .public)"
                )
                return
            }
            let playerSeconds = currentTime()
            let startTime = playerSeconds.isFinite
                ? mediaTime(for: max(0, playerSeconds))
                : pendingStartTime
            let updatedTracks = spec.availableAudioTracks.map { $0.selecting($0.trackId == trackId) }
            let updatedSpec = LoopbackSessionSpec(
                sourceURL: spec.sourceURL,
                headers: spec.headers,
                sourceStartTimeSeconds: startTime,
                sourceBitrateBps: spec.sourceBitrateBps,
                videoMode: spec.videoMode,
                sourceVideoFrameRate: spec.sourceVideoFrameRate,
                selectedAudio: LoopbackSessionSpec.SelectedAudio(
                    trackIndex: selectedTrackIndex,
                    ffIndex: selectedTrack.ffIndex,
                    sourceCodec: selectedTrack.codec,
                    sourceChannelCount: selectedTrack.audioChannelCount,
                    sourceChannelLayout: selectedTrack.audioChannelsLayout,
                    outputMode: Self.loopbackAudioOutputMode(for: selectedTrack),
                    preservesAtmos: Self.loopbackPreservesAtmos(for: selectedTrack)
                ),
                availableAudioTracks: updatedTracks,
                manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                    advertisedDolbyVisionProfile: spec.manifestMetadata.advertisedDolbyVisionProfile,
                    compatibilityBrand: spec.manifestMetadata.compatibilityBrand,
                    videoRange: spec.manifestMetadata.videoRange,
                    mayClaimAtmos: Self.loopbackPreservesAtmos(for: selectedTrack)
                )
            )
            Self.logger.info(
                "[CMP-AVP] rebuilding loopback for audio trackId=\(trackId, privacy: .public) trackIndex=\(selectedTrackIndex, privacy: .public) ffIndex=\(selectedTrack.ffIndex ?? -1, privacy: .public)"
            )
            load(
                strategy: .siloLoopback(spec: updatedSpec),
                startTime: startTime
            )
            return
        }

        guard let item = currentItem,
              let state = audioSelectionState,
              let option = state.optionsByTrackId[trackId] else {
            return
        }

        item.select(option, in: state.group)
        emitTrackList()
    }

    func selectSubtitleTrack(_ trackId: Int64?) {
        cmpLog("[CMP-SUB] selectSubtitleTrack id=\(trackId.map(String.init) ?? "nil") item=\(currentItem == nil ? "nil" : "live")")
        guard let item = currentItem else {
            return
        }

        // Live AI path: the synthetic live track is already installed in
        // the renderer (and being fed cues). Selecting it just records the
        // selection and drops any AVFoundation/extractor caption in the
        // slot; the live track stays installed and visible. Checked BEFORE
        // the sidecar branch so a live id is never routed to `openSidecar`.
        if let trackId, SubtitleTrackIdSpace.isAILive(trackId) {
            if let state = subtitleSelectionState {
                item.select(nil, in: state.group)
            }
            loopbackSubtitleTap?.deactivate()
            clearBitmapTapSelection()
            embeddedSubtitleExtractor?.clear(slot: .primary)
            selectedControlledSubtitleTrackId = trackId
            emitTrackList()
            return
        }

        if let trackId, SubtitleTrackIdSpace.isSidecar(trackId) {
            if let state = subtitleSelectionState {
                item.select(nil, in: state.group)
            }
            loopbackSubtitleTap?.deactivate()
            clearBitmapTapSelection()
            embeddedSubtitleExtractor?.clear(slot: .primary)
            selectedControlledSubtitleTrackId = trackId
            subtitleSession?.openSidecar(
                urlIndex: SubtitleTrackIdSpace.sidecarIndex(from: trackId),
                slot: .primary
            )
            emitTrackList()
            return
        }

        // Tap-served embedded text tracks: instant enable from the store,
        // no side demuxer. Checked before the extractor so text tracks
        // never pay the second-connection open/seek.
        if let trackId, tapServesEmbeddedTrack(trackId) {
            if let state = subtitleSelectionState {
                item.select(nil, in: state.group)
            }
            embeddedSubtitleExtractor?.stopFeeding(slot: .primary)
            clearBitmapTapSelection()
            selectedControlledSubtitleTrackId = trackId
            activateTapSubtitleTrack(trackId: trackId, slot: .primary)
            emitTrackList()
            return
        }

        // Tap-served embedded bitmap tracks (PGS/DVD) on the loopback
        // route: decoded by the writer's own demux loop. The extractor's
        // side connection has to re-download the full interleave and falls
        // behind realtime at Blu-ray bitrates — cues stop shortly after
        // the shared-cache head start runs out.
        if let trackId, bitmapTapServesEmbeddedTrack(trackId) {
            if let state = subtitleSelectionState {
                item.select(nil, in: state.group)
            }
            loopbackSubtitleTap?.deactivate()
            embeddedSubtitleExtractor?.stopFeeding(slot: .primary)
            selectedControlledSubtitleTrackId = trackId
            activateBitmapTapSubtitleTrack(trackId: trackId)
            emitTrackList()
            return
        }

        if let trackId, embeddedSubtitleExtractor?.canSelect(trackId: trackId) == true {
            if let state = subtitleSelectionState {
                item.select(nil, in: state.group)
            }
            loopbackSubtitleTap?.deactivate()
            clearBitmapTapSelection()
            selectedControlledSubtitleTrackId = trackId
            embeddedSubtitleExtractor?.select(
                trackId: trackId,
                slot: .primary,
                startSeconds: mediaTime(for: currentTime())
            )
            emitTrackList()
            return
        }

        loopbackSubtitleTap?.deactivate()
        clearBitmapTapSelection()
        embeddedSubtitleExtractor?.clear(slot: .primary)
        selectedControlledSubtitleTrackId = nil
        if let state = subtitleSelectionState {
            item.select(nil, in: state.group)
        }
        if trackId != nil {
            Self.logger.info(
                "[CMP-AVP] primary subtitle ignored because track is not controlled by libass trackId=\(trackId.map(String.init) ?? "nil", privacy: .public)"
            )
        }
        emitTrackList()
    }

    func setSecondarySubtitleTrack(_ trackId: Int64?) {
        guard let trackId else {
            embeddedSubtitleExtractor?.clear(slot: .secondary)
            selectedSecondaryControlledSubtitleTrackId = nil
            subtitleSession?.closeSlot(.secondary)
            return
        }
        if embeddedSubtitleExtractor?.canSelect(trackId: trackId) == true {
            selectedSecondaryControlledSubtitleTrackId = trackId
            embeddedSubtitleExtractor?.select(
                trackId: trackId,
                slot: .secondary,
                startSeconds: mediaTime(for: currentTime())
            )
            return
        }
        guard SubtitleTrackIdSpace.isSidecar(trackId) else {
            embeddedSubtitleExtractor?.clear(slot: .secondary)
            selectedSecondaryControlledSubtitleTrackId = nil
            subtitleSession?.closeSlot(.secondary)
            Self.logger.info(
                "[CMP-AVP] secondary subtitle ignored for non-sidecar trackId=\(trackId, privacy: .public)"
            )
            return
        }
        embeddedSubtitleExtractor?.clear(slot: .secondary)
        selectedSecondaryControlledSubtitleTrackId = trackId
        subtitleSession?.openSidecar(
            urlIndex: SubtitleTrackIdSpace.sidecarIndex(from: trackId),
            slot: .secondary
        )
    }

    func registerSidecarSubtitles(_ descriptors: [SidecarSubtitleDescriptor]) {
        sidecarDescriptorsByTrackId = Dictionary(
            uniqueKeysWithValues: descriptors.map {
                (SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: $0.index), $0)
            }
        )
        subtitleSession?.registerSidecarTracks(descriptors)
        emitTrackList()
    }

    // MARK: - Live AI subtitle track

    /// Open a synthetic live AI subtitle track in `slot`. The underlying
    /// `SubtitleSession`/`SubtitleRenderer` serialise the work on their own
    /// queue, so this forwards directly (mirroring `openSidecar`).
    func openLiveSubtitleTrack(slot: SubtitleSlot, label: String?, language: String?) {
        subtitleSession?.openLive(slot: slot, label: label, language: language)
    }

    /// Feed a single converted live AI cue to the live track in `slot`.
    func feedLiveSubtitleCue(
        slot: SubtitleSlot,
        eventText: String,
        startMs: Int64,
        durationMs: Int64
    ) {
        subtitleSession?.feedLiveCue(
            slot: slot,
            eventText: eventText,
            startMs: startMs,
            durationMs: durationMs
        )
    }

    /// Close the live AI subtitle track in `slot`.
    func closeLiveSubtitleTrack(slot: SubtitleSlot) {
        subtitleSession?.closeLive(slot: slot)
    }

    func setServerChapters(_ chapters: [PlayerChapterInfo]) {
        serverChapters = chapters
        if didFireFileLoaded {
            onChaptersChange?(chapters)
        }
    }

    // MARK: - Startup (TTFF) telemetry — SiloPlayer plan Stage 0

    private var ttffLoadAnchor: CFAbsoluteTime = 0
    private var ttffFirstSegmentMs: Int?
    private var ttffReadyMs: Int?
    private var ttffEmitted = true
    private var ttffLastObservedTime: Double = .nan

    private func ttffElapsedMs() -> Int {
        Int((CFAbsoluteTimeGetCurrent() - ttffLoadAnchor) * 1000)
    }

    private func ttffMarkLoad() {
        ttffLoadAnchor = CFAbsoluteTimeGetCurrent()
        ttffFirstSegmentMs = nil
        ttffReadyMs = nil
        ttffEmitted = false
        ttffLastObservedTime = .nan
    }

    /// Emits one `[CMP-TTFF]` line per load at the first observed playhead
    /// advance while playing — the closest observable proxy for "first frame
    /// rendered" that works on both the loopback and the remote AVPlayer
    /// routes, and is axis-agnostic (the loopback item timeline is
    /// session-relative, not media-relative).
    private func ttffEmitIfNeeded(currentTime: Double) {
        guard !ttffEmitted else { return }
        defer { ttffLastObservedTime = currentTime }
        guard !ttffLastObservedTime.isNaN,
              avPlayer.rate > 0,
              currentTime > ttffLastObservedTime + 0.02 else { return }
        ttffEmitted = true
        let firstFrameMs = ttffElapsedMs()
        onFirstFrame?(firstFrameMs)
        let route = currentSourceStrategy.map(Self.describe) ?? "unknown"
        let firstSegment = ttffFirstSegmentMs.map(String.init) ?? "-"
        let ready = ttffReadyMs.map(String.init) ?? "-"
        cmpLog("[CMP-TTFF] route=\(route) first_segment_ms=\(firstSegment) ready_ms=\(ready) first_frame_ms=\(firstFrameMs)")
    }

    private func load(strategy: SourceStrategy, startTime: Double) {
        guard !isDisposed else { return }
        cmpLog("[CMP-AVP] load strategy=\(Self.describe(strategy)) startTime=\(startTime)")
        ttffMarkLoad()

        let preserveDisplayCriteria = shouldPreserveTVDisplayCriteriaDuringReload(
            from: currentSourceStrategy,
            to: strategy
        )
        teardownMediaPipeline(
            clearDisplayCriteria: !preserveDisplayCriteria,
            deactivateAudioSession: false
        )
        isPreservingTVDisplayCriteriaForReload = preserveDisplayCriteria
        currentSourceStrategy = strategy
        applyExternalPlaybackPolicy(for: strategy)
        currentLoopbackAudioTracks = Self.normalizedLoopbackAudioTracks(for: strategy)
        configureEmbeddedSubtitleExtraction(for: strategy)
        setLoopbackPlaybackClock(0)
        rebufferCount = 0
        lastSeekSettledAt = 0
        lastStatsEmitWall = 0
        loopbackDemuxReadBitrateBps = nil
        loopbackHDR10PlusDetected = false
        loopbackSourceBytesRead = nil
        latestLoopbackGeneratedStats = nil
        deferredRecoveryMediaTime = nil
        vodPendingSeekMediaTarget = nil
        watchdogLastStateLogWall = 0
        // The recovery owner resets the edge watch, the reanchor cooldown and
        // playhead advance-tracking for the new session so a reanchor's
        // pre-reanchor position does not read as instantly stationary. The
        // reanchor retry budget (count/window/escalation) deliberately survives
        // across reanchors and only resets on window expiry.
        onEngineReloaded?()
        didFireFileLoaded = false
        hasSeekedToStart = false
        hasReachedItemEnd = false
        pendingStartTime = startTime
        isInitialSeekInFlight = false

        switch strategy {
        case .remoteHLS(let url, let headers):
            prepareAssetPlayback(url: url, headers: headers)
        case .remoteDirect(let url, let headers):
            prepareAssetPlayback(url: url, headers: headers)
        case .siloLoopback(let spec):
            // The VOD item timeline is the plan's playlist axis; its origin is
            // the plan anchor (near 0 for normal titles, the content start for
            // late-start ones). Refined again when the first session resolves
            // the plan.
            setMediaTimelineOffset(
                vodPlanForCurrentSource(spec: spec)?.anchorSourceSeconds ?? 0
            )
            startSiloLoopback(sessionSpec: spec)
        }
    }

    // MARK: - VOD serving-mode plan continuity (loopback-primary plan, 1c)

    /// The segment plan the live session has resolved, if any. `LocalHLSHost`
    /// owns it while the session runs; `carriedVODPlan` is what a teardown
    /// leaves behind for the next one.
    private var loopbackVODPlan: LoopbackSegmentPlan? { loopbackHost?.vodPlan }

    /// The plan carried out of the retired session, when it was resolved for
    /// this source. Read by `load(strategy:)` after `teardownMediaPipeline`
    /// has already cleared the host, which is the only place the value has to
    /// outlive a session.
    private func vodPlanForCurrentSource(spec: LoopbackSessionSpec) -> LoopbackSegmentPlan? {
        carriedVODPlan?.matching(spec.sourceURL)
    }

    // MARK: - VOD demand-driven producer restarts (loopback-primary plan, 1e)

    /// The unlanded in-item seek target (media seconds). Cleared when the
    /// seek completion fires; while it survives, stall recovery aims here
    /// instead of at the frozen clock (M7).
    private var vodPendingSeekMediaTarget: Double?

    static func vodRetentionBudgetBytes() -> Int64 {
        // `volumeAvailableCapacityForImportantUsage` is unavailable on
        // tvOS, and the plain capacity key can report 0 for the sandboxed
        // temp volume there — a 0 the old code passed straight through as
        // the budget, silently disabling retention (living-room 4GB spill
        // deadlock). Use the filesystem-attributes helper (valid on every
        // platform) and clamp through the pure budget function, which
        // treats any non-positive reading as "query broken", never as 0.
        return Self.vodRetentionBudget(availableBytes: freeDiskSpaceBytes())
    }

    /// Pure clamp for the VOD retention budget; shared with the source
    /// cache's spill budget so both spill tiers size against the same policy.
    static func vodRetentionBudget(availableBytes: Int64?) -> Int64 {
        PlaybackDiskBudget.retentionBudget(availableBytes: availableBytes)
    }

    /// VOD stall-recovery ladder (M7) — never tears the session down. The
    /// anchor is the unlanded seek target when one exists (a wedged
    /// zero-tolerance seek leaves the frozen clock at the PRE-seek
    /// position). Attempt 1 nudges AVPlayer — cancel pending seeks, fresh
    /// zero-tolerance seek, play — which rebuilds its loading pipeline;
    /// later attempts swap the item in place (same URL, no pre-pause, the
    /// old item keeps rendering until the swap lands). Both ride alongside
    /// an authoritative producer restart at the anchor segment. The
    /// exhausted watchdog rebuilds the loopback session at the rendered
    /// clock; recovery never switches playback engines.
    @MainActor
    private func performVODStallRecovery(anchorPlayerSeconds anchorPlayer: Double, attempt: Int) {
        if let plan = loopbackVODPlan {
            loopbackHost?.requestProducerRestart(
                atSegmentIndex: plan.segmentIndex(forPlaylistSeconds: anchorPlayer),
                authoritative: true
            )
        }
        let time = CMTime(seconds: max(0, anchorPlayer), preferredTimescale: 600)
        if attempt <= 1 {
            cmpLog("[CMP-AVP] vod stall recovery nudge anchorPlayer=\(anchorPlayer)")
            currentItem?.cancelPendingSeeks()
            performRecoverySeek(to: time, reason: "vod_stall_nudge")
            avPlayer.play()
        } else {
            cmpLog("[CMP-AVP] vod stall recovery in-place item reload anchorPlayer=\(anchorPlayer)")
            guard let item = currentItem else { return }
            reloadEstablishedLoopbackItem(item, at: anchorPlayer, reason: "vod_stall")
        }
    }

    /// Rebuild only AVFoundation's item/loader state while preserving the
    /// loopback producer, segment plan/store/server, display criteria, audio
    /// session, selected tracks, and recovery budgets.
    @MainActor
    private func reloadEstablishedLoopbackItem(
        _ oldItem: AVPlayerItem,
        at playerSeconds: Double,
        reason: String,
        replacementURL: URL? = nil
    ) {
        guard oldItem === currentItem,
              let asset = oldItem.asset as? AVURLAsset else { return }
        cancelSeekDeadline()
        oldItem.cancelPendingSeeks()
        detachPerItemObservers()

        let itemURL = replacementURL ?? asset.url
        let item = AVPlayerItem(asset: AVURLAsset(url: itemURL))
        applyLoopbackItemBufferPolicy(
            to: item,
            phase: canRampLoopbackBufferToSteadyState ? .steadyState : .startup
        )
        currentItem = item
        attachItemObservers(item)
        // A fresh item has not played to its end, whatever the retired one
        // did; leaving the latch set would suppress transport-intent
        // resolution and the auto-resume rung for the rest of the session.
        hasReachedItemEnd = false
        avPlayer.replaceCurrentItem(with: item)

        let target = CMTime(seconds: max(0, playerSeconds), preferredTimescale: 600)
        performRecoverySeek(to: target, reason: "item_reload_\(reason)")
        if !isUserPaused {
            avPlayer.play()
        }
        cmpLog(
            "[CMP-AVP] established loopback item reloaded reason=\(reason) player=\(playerSeconds) url=\(loggableURLDescription(itemURL))"
        )
    }

    private func startSiloLoopback(
        sessionSpec: LoopbackSessionSpec
    ) {
        let sessionID = UUID().uuidString
        let debugBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-dv-hls-debug", isDirectory: true)
        let sessionDir = debugBaseDir.appendingPathComponent(sessionID, isDirectory: true)
        #if os(iOS)
        let exposure = LoopbackSegmentServer.Exposure.localNetwork
        #else
        let exposure = LoopbackSegmentServer.Exposure.loopbackOnly
        #endif
        let host = LocalHLSHost(
            sessionSpec: sessionSpec,
            sessionDirectory: sessionDir,
            keepArtifacts: LocalHLSHost.keepArtifactsFromEnvironment,
            storeMemoryBudgetBytes: Self.loopbackSegmentStoreMemoryBudgetBytes,
            storeSpillPolicy: Self.generatedHLSSpillPolicy(for: sessionSpec),
            vodRetentionBudgetBytes: Self.vodRetentionBudgetBytes(),
            serverExposure: exposure,
            carriedVODPlan: carriedVODPlan,
            playbackPositionProvider: { [weak self] in
                self?.loopbackPlaybackClockSeconds()
            },
            isSourceOutageActive: { [weak self] in
                self?.sourceOutageStateProvider?() ?? false
            },
            // The cue tap stays with the adapter: its store is keyed to the
            // SOURCE and outlives the session, so a reanchor of the same
            // title re-enables subtitles instantly.
            subtitleTap: { [weak self] sourceURL in
                self?.ensureLoopbackSubtitleTap(for: sourceURL)
            }
        )
        loopbackHost = host
        // Armed before any component of the session exists, exactly as it was
        // when this function built the store and server itself.
        installLoopbackPlayheadWatchdog()
        installLoopbackHostCallbacks(host)
        host.start()
    }

    /// Wires a freshly built `LocalHLSHost` back into the adapter. Every
    /// callback re-checks `loopbackHost === host`: a host the backend has
    /// dropped is no longer the session, which is exactly what the retired
    /// session-id string compare used to mean.
    private func installLoopbackHostCallbacks(_ host: LocalHLSHost) {
        host.isExternalPlaybackActive = { [weak self] in
            self?.avPlayer.isExternalPlaybackActive ?? false
        }
        host.canAttachFirstSegment = { [weak self, weak host] in
            guard let self, let host, self.loopbackHost === host else { return false }
            return !self.isDisposed && self.currentItem == nil
        }
        host.selectedBitmapSubtitleTapStream = { [weak self] in
            self?.selectedBitmapTapStreamIndex ?? nil
        }
        host.hasDetectedHDR10Plus = { [weak self] in
            self?.loopbackHDR10PlusDetected ?? false
        }
        host.onFirstSegmentReady = { [weak self, weak host] ready in
            guard let self, let host, self.loopbackHost === host else { return }
            self.handleFirstSegmentReady(ready, host: host)
        }
        host.onSegmentPlanResolved = { [weak self, weak host] plan in
            guard let self, let host, self.loopbackHost === host, !self.isDisposed else { return }
            // The item timeline's origin is the plan anchor; the initial
            // media-time seek (pendingStartTime) converts through this
            // offset, and plan resolution always precedes item creation.
            self.setMediaTimelineOffset(plan.anchorSourceSeconds)
        }
        host.onBitmapSubtitleTapTracks = { [weak self, weak host] indices in
            guard let self, let host, self.loopbackHost === host, !self.isDisposed else { return }
            self.bitmapTapAvailableStreams = Set(indices)
            // A selection that landed before availability fell through
            // to the extractor (which can't keep up at Blu-ray
            // bitrates); re-route it to the tap now that the writer
            // has declared its bitmap streams.
            if let trackId = self.selectedControlledSubtitleTrackId,
               self.selectedBitmapTapStreamIndex == nil,
               self.bitmapTapServesEmbeddedTrack(trackId) {
                self.embeddedSubtitleExtractor?.stopFeeding(slot: .primary)
                self.activateBitmapTapSubtitleTrack(trackId: trackId)
            }
        }
        // Mux thread; the writer only decodes (and therefore only emits)
        // while a stream is selected, and SubtitleSession serialises feeds
        // on its own queue — same pattern as the extractor's decode thread.
        host.onBitmapSubtitleTapCue = { [weak self] _, cues, trimActiveAt in
            self?.subtitleSession?.feedBitmapCues(
                slot: .primary,
                cues: cues,
                trimActiveAt: trimActiveAt
            )
        }
        host.onFinished = { [weak self, weak host] error in
            guard let self, let host, self.loopbackHost === host, !self.isDisposed else { return }
            if let error {
                self.reportFailure(.writerFailed(
                    kind: Self.writerFailureKind(for: error),
                    detail: String(describing: error)
                ))
            }
        }
        host.onSourceDownloadStats = { [weak self, weak host] bitsPerSecond, totalBytesRead in
            guard let self, let host, self.loopbackHost === host, !self.isDisposed else { return }
            let previousBitrate = self.loopbackDemuxReadBitrateBps
            self.loopbackDemuxReadBitrateBps = bitsPerSecond
            self.loopbackSourceBytesRead = totalBytesRead
            self.emitPlaybackStats(referenceTime: self.currentTime(), force: true)
            if let bitsPerSecond {
                let mbps = bitsPerSecond / 1_000_000
                let mib = totalBytesRead.map { Double($0) / 1_048_576 } ?? 0
                Self.logger.info(
                    "[CMP-AVP] loopback source rate=\(String(format: "%.1f", mbps), privacy: .public)Mbps totalRead=\(String(format: "%.1f", mib), privacy: .public)MiB"
                )
            }
            // First measurable source bitrate — re-evaluate the
            // steady-state forward buffer, since the gate may already
            // have released before any rate was known.
            if previousBitrate == nil, bitsPerSecond != nil,
               let item = self.currentItem,
               self.canRampLoopbackBufferToSteadyState {
                self.rampLoopbackBufferToSteadyStateIfNeeded(for: item)
            }
        }
        host.onGeneratedMediaStats = { [weak self, weak host] generatedStats in
            guard let self, let host, self.loopbackHost === host, !self.isDisposed else { return }
            self.latestLoopbackGeneratedStats = generatedStats
            self.emitPlaybackStats(referenceTime: self.currentTime(), force: true)
            if let item = self.currentItem,
               self.canRampLoopbackBufferToSteadyState {
                self.rampLoopbackBufferToSteadyStateIfNeeded(for: item)
                self.sampleLocalLoopbackEdge(item: item, referenceTime: self.currentTime(), trigger: "generated_stats")
            }
        }
        host.onBridgedAudioAnchored = { [weak self, weak host] seconds in
            guard let self, let host, self.loopbackHost === host, !self.isDisposed else { return }
            guard seconds.isFinite else { return }
            // The encoder anchors while segment 0 is written, so this
            // lands before the gate is even prepared — scope it to the
            // load rather than to the gate's own window. A producer that
            // restarts before the load finishes re-anchors later, and the
            // gate wants that newer value.
            guard !self.didFireFileLoaded else { return }
            self.loopbackBridgedAudioAnchorSeconds = seconds
            cmpLog("[CMP-AVP] initial video display gate audio anchor=\(seconds)")
            self.evaluateInitialVideoDisplayGate(trigger: "audio_anchor")
        }
        // HDR10+ badge: the host installs the one-shot SEI scan only for
        // plain HEVC PQ sessions whose label currently reads "HDR10" and has
        // not flipped. DV Profile 8 sources keep their validated labels.
        host.onHDR10PlusMetadataDetected = { [weak self, weak host] in
            guard let self, let host, self.loopbackHost === host, !self.isDisposed else { return }
            self.loopbackHDR10PlusDetected = true
            cmpLog("[CMP-AVP] hdr10+ dynamic metadata detected — badge flips HDR10 → HDR10+")
            self.emitPlaybackStats(referenceTime: self.currentTime(), force: true)
        }
        host.onExternalPlaybackHandoffAbandoned = { [weak self] in
            self?.abandonExternalPlaybackHandoff()
        }
        host.onFailure = { [weak self, weak host] failure in
            guard let self, let host, self.loopbackHost === host, !self.isDisposed else { return }
            self.reportFailure(failure)
        }
    }

    private func handleFirstSegmentReady(
        _ ready: (url: URL, playlistName: String, usesExternalURL: Bool),
        host: LocalHLSHost
    ) {
        let url = ready.url
        let playlistName = ready.playlistName
        loopbackPlaylistName = playlistName
        loopbackPlaybackUsesExternalURL = ready.usesExternalURL
        cmpLog("[CMP-AVP] local playlist ready host=\(url.host ?? "unknown") external=\(ready.usesExternalURL ? 1 : 0)")
        if ttffFirstSegmentMs == nil { ttffFirstSegmentMs = ttffElapsedMs() }
        logTVDisplayManagerState(context: "before_prepare_\(playlistName)")
        // The criteria write always happens synchronously before the item is
        // created; only the gated non-DV HDR path additionally holds the item
        // back until the HDMI negotiation settles, so the item's startup
        // probes don't race the mode switch.
        let needsModeSettleWait = applyTVDisplayCriteriaForLoopbackIfNeeded(
            context: "before_prepare_\(playlistName)"
        )
        guard needsModeSettleWait else {
            // Criteria written with no negotiation to wait out (a reload that
            // preserved them): the panel is already in this start's mode, so
            // that is the settle reference point.
            if didApplyTVDisplayCriteriaForStart {
                tvDisplaySettleCompletedAt = Date()
            }
            attachLoopbackItem(url: url)
            return
        }
        #if os(tvOS)
        displayModeSettleTask?.cancel()
        displayModeSettleTask = Task { @MainActor [weak self, weak host] in
            let hosted = await TVDisplayCriteria.waitForModeSwitchSettle()
            guard let self, let host, !self.isDisposed, !Task.isCancelled,
                  self.loopbackHost === host,
                  self.currentItem == nil else { return }
            // Panel-readiness snapshot. The loopback route now serves the
            // VIDEO-RANGE-claiming master playlist (Atmos claims are
            // master-level grants), so this wait is what keeps the item's
            // synchronous VIDEO-RANGE validation from racing the HDMI mode
            // switch. hdrHosted=0 after the wait means the panel stayed
            // SDR; AetherEngine ships the same master shape to such panels
            // in production, so the attach proceeds either way.
            cmpLog("[CMP-AVP] tv display settle hdrHosted=\(hosted ? 1 : 0)")
            self.tvDisplaySettleCompletedAt = Date()
            self.attachLoopbackItem(url: url)
        }
        #else
        attachLoopbackItem(url: url)
        #endif
    }

    /// Hands AVPlayer its loopback item plus the VOD resume pre-seek. Split
    /// from `handleFirstSegmentReady` so the gated HDR path can defer it
    /// behind the display-mode settle wait.
    private func attachLoopbackItem(url: URL) {
        // The local loopback server is an in-app HTTP surface. Remote auth
        // headers are only for libavformat's source fetch and should not be
        // propagated into AVPlayer's localhost HLS requests.
        prepareAssetPlayback(url: url, headers: [:]) { [weak self] in
            self?.issueVODResumePreSeekIfNeeded(context: "first_segment")
        }
    }

    /// Resume: aim AVPlayer's very first media fetches at the resume
    /// segment. The producer is anchored there; without this, the
    /// item buffers from position 0 whose segments may never exist.
    /// Re-issued after a startup-watchdog item reload for the same reason.
    private func issueVODResumePreSeekIfNeeded(context: String) {
        guard case .some(.siloLoopback) = currentSourceStrategy,
              pendingStartTime > 0 else { return }
        let target = max(0, playerTime(forMediaTime: pendingStartTime))
        avPlayer.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        rebaseInitialVideoDisplayGateStartTime(to: target, context: "vod_pre_seek_\(context)")
        cmpLog("[CMP-AVP] vod resume pre-seek player=\(target) mediaSeconds=\(pendingStartTime) context=\(context)")
    }

    private func prepareAssetPlayback(
        url: URL,
        headers: [String: String],
        completion: (() -> Void)? = nil
    ) {
        activateAudioSession { [weak self] error in
            guard let self, !self.isDisposed else { return }
            if let error {
                let message = "AVPlayer audio session setup failed: \(error.localizedDescription)"
                cmpLog("[CMP-AVP] ERROR: \(message)")
            }
            self.finishPreparingAssetPlayback(url: url, headers: headers)
            completion?()
        }
    }

    private func finishPreparingAssetPlayback(url: URL, headers: [String: String]) {
        var options: [String: Any] = [:]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        // For the local DV loopback the writer produces segments much faster
        // than realtime against a localhost server, so AVPlayer's default
        // automatic buffer-up was waiting for many of the source's long
        // (~30s, one per GOP) fragments before declaring readyToPlay. The
        // startup phase therefore disables
        // `automaticallyWaitsToMinimizeStalling` and caps the forward buffer
        // at `loopbackStartupForwardBuffer` (one fragment-equivalent) so the
        // first frame lands as soon as it is decodable.
        //
        // After the initial-video-display gate releases (see
        // `finishInitialVideoDisplayGate` →
        // `rampLoopbackBufferToSteadyStateIfNeeded`) the item moves to the
        // steady-state phase: `loopbackSteadyStateForwardBufferTarget` and
        // automatic waiting back on, so AVPlayer can ride out origin jitter
        // on high-bitrate sources where headroom over the source's bitrate is
        // small (e.g. 4K DV at 72 Mbps over 80 Mbps).
        //
        // Both phases are written in exactly one place,
        // `applyLoopbackItemBufferPolicy(to:phase:)`, which also no-ops on the
        // remote routes since automatic buffering is genuinely useful there.
        applyLoopbackItemBufferPolicy(to: item, phase: .startup)
        currentItem = item
        beginInitialVideoDisplayGate()
        attachItemObservers(item)
        avPlayer.replaceCurrentItem(with: item)
        armLoopbackStartupWatchdogIfNeeded()
        installPeriodicTimeObserver()
        installSubtitleDisplayLink()
    }

    private func activateAudioSession(completion: @escaping (Error?) -> Void) {
        audioSessionCoordinator.activate(completion: completion)
    }

    private func deactivateAudioSession() {
        audioSessionCoordinator.deactivate()
    }

    private func configureEmbeddedSubtitleExtraction(for strategy: SourceStrategy) {
        let source: AVPlayerSubtitleExtractionSource?
        switch strategy {
        case .remoteDirect(let url, let headers):
            source = AVPlayerSubtitleExtractionSource(
                mediaURL: url,
                requestHeaders: headers,
                routeLabel: "remoteDirect",
                seekable: true
            )
        case .siloLoopback(let spec):
            source = AVPlayerSubtitleExtractionSource(
                mediaURL: spec.sourceURL,
                requestHeaders: spec.headers,
                routeLabel: "siloLoopback",
                seekable: true
            )
        case .remoteHLS:
            source = nil
        }
        embeddedSubtitleExtractor?.configure(source: source)
    }

    /// The tap store survives producer restarts and reanchors (same source,
    /// same timeline); switching to a different source resets it.
    private func ensureLoopbackSubtitleTap(for sourceURL: URL) -> LoopbackSubtitleTap {
        if let tap = loopbackSubtitleTap, loopbackSubtitleTapSourceURL == sourceURL {
            return tap
        }
        let tap = LoopbackSubtitleTap()
        loopbackSubtitleTap = tap
        loopbackSubtitleTapSourceURL = sourceURL
        return tap
    }

    /// True when `trackId` is an embedded text track the tap can serve.
    /// Loopback-route only: other routes have no writer harvesting cues,
    /// so a leftover store must not shadow the extractor.
    private func tapServesEmbeddedTrack(_ trackId: Int64) -> Bool {
        guard case .some(.siloLoopback) = currentSourceStrategy,
              SubtitleTrackIdSpace.isAVPlayerEmbedded(trackId),
              let tap = loopbackSubtitleTap else { return false }
        let streamIndex = Int(SubtitleTrackIdSpace.avPlayerEmbeddedStreamIndex(from: trackId))
        return tap.hasTrack(forStream: streamIndex)
    }

    private func bitmapTapServesEmbeddedTrack(_ trackId: Int64) -> Bool {
        guard case .some(.siloLoopback) = currentSourceStrategy,
              SubtitleTrackIdSpace.isAVPlayerEmbedded(trackId) else { return false }
        let streamIndex = Int(SubtitleTrackIdSpace.avPlayerEmbeddedStreamIndex(from: trackId))
        return bitmapTapAvailableStreams.contains(streamIndex)
    }

    /// Point the writer's bitmap tap at the selected stream and open the
    /// bitmap track in the renderer. Selection schedules a backlog replay
    /// in the writer: packets the producer read before this call landed
    /// (it races ahead of both the playhead and this main-thread hop) are
    /// decoded into the fresh store, so cues cover from the anchor — not
    /// just from wherever the read head happened to be.
    private func activateBitmapTapSubtitleTrack(trackId: Int64) {
        guard let session = subtitleSession else { return }
        let streamIndex = Int(SubtitleTrackIdSpace.avPlayerEmbeddedStreamIndex(from: trackId))
        selectedBitmapTapStreamIndex = streamIndex
        // Wide window: the tap feeds from the producer's read head, which
        // the produce-ahead byte gate bounds ~48-100 s ahead of the
        // playhead. 300 s of retention keeps those early-decoded cues alive
        // until playback reaches them; 512 cues bounds worst-case memory
        // (~25 MB) while covering dense dialogue across the whole window.
        session.openBitmapTrack(slot: .primary, retentionSeconds: 300, maxCueCount: 512)
        segmentWriter?.setBitmapSubtitleTapStream(streamIndex)
        cmpLog("[CMP-TAP] bitmap activated stream=\(streamIndex)")
    }

    private func clearBitmapTapSelection() {
        guard selectedBitmapTapStreamIndex != nil else { return }
        selectedBitmapTapStreamIndex = nil
        segmentWriter?.setBitmapSubtitleTapStream(nil)
        cmpLog("[CMP-TAP] bitmap deactivated")
    }

    /// (Re)install the libass track for a tap-served stream and feed it:
    /// a fresh track, the full backfill snapshot, then live forwarding —
    /// exactly once per cue (libass ReadOrder dedup is disabled). Also the
    /// post-seek resync: re-running replaces the track wholesale, so
    /// flushed state can't double-feed.
    private func activateTapSubtitleTrack(trackId: Int64, slot: SubtitleSlot) {
        guard let tap = loopbackSubtitleTap,
              let session = subtitleSession else { return }
        let streamIndex = Int(SubtitleTrackIdSpace.avPlayerEmbeddedStreamIndex(from: trackId))
        guard let info = tap.trackInfo(forStream: streamIndex) else { return }

        if info.header.isEmpty {
            session.openEmbedded(
                slot: slot, isNativeASS: info.isNativeASS,
                extradata: nil, extradataSize: 0
            )
        } else {
            info.header.withUnsafeBytes { raw in
                session.openEmbedded(
                    slot: slot,
                    isNativeASS: info.isNativeASS,
                    extradata: raw.bindMemory(to: UInt8.self).baseAddress,
                    extradataSize: info.header.count
                )
            }
        }
        let backfill = tap.activate(streamIndex: streamIndex) { [weak session] cue in
            session?.feedEmbedded(
                slot: slot,
                eventText: cue.eventText,
                startMs: cue.startMs,
                durationMs: cue.durationMs
            )
        }
        for cue in backfill {
            session.feedEmbedded(
                slot: slot,
                eventText: cue.eventText,
                startMs: cue.startMs,
                durationMs: cue.durationMs
            )
        }
        cmpLog("[CMP-TAP] activated stream=\(streamIndex) backfill=\(backfill.count)")
    }

    /// After a completed in-item seek: extractor-owned slots re-seek their
    /// side demuxer (the extractor only iterates its own selections, so
    /// this is a no-op for tap-served slots), and a tap-served primary
    /// re-installs + re-feeds (the session's flushOnSeek dropped its
    /// libass events).
    private func resyncControlledSubtitlesAfterSeek(mediaSeconds: Double) {
        embeddedSubtitleExtractor?.seek(to: mediaSeconds)
        if let trackId = selectedControlledSubtitleTrackId,
           tapServesEmbeddedTrack(trackId) {
            activateTapSubtitleTrack(trackId: trackId, slot: .primary)
        }
    }

    private func installPeriodicTimeObserver() {
        if let observer = timeObserver {
            avPlayer.removeTimeObserver(observer)
            timeObserver = nil
        }

        let interval = CMTime(value: 1, timescale: 10)
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self, !self.isDisposed else { return }
            if self.isSeekPending { return }
            if case .siloLoopback = self.currentSourceStrategy {
                self.setLoopbackPlaybackClock(time.seconds)
            }
            self.evaluateInitialVideoDisplayGate(trigger: "time")
            self.ttffEmitIfNeeded(currentTime: time.seconds)
            self.onTimeChange?(time.seconds)
            self.emitBufferedAhead(referenceTime: time.seconds)
            self.emitPlaybackStats(referenceTime: time.seconds)
            if let item = self.currentItem {
                self.sampleLocalLoopbackEdge(item: item, referenceTime: time.seconds, trigger: "time")
            }
        }
    }

    private func installSubtitleDisplayLink() {
        subtitleDisplayLink?.invalidate()
        #if os(macOS)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard !self.isDisposed, !self.isSeekPending else { return }
            self.pumpSubtitleOverlay(referenceTime: self.mediaTime(for: self.avPlayer.currentTime().seconds))
        }
        RunLoop.main.add(timer, forMode: .common)
        subtitleDisplayLink = timer
        #else
        let link = CADisplayLink(target: self, selector: #selector(subtitleDisplayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        subtitleDisplayLink = link
        #endif
    }

    #if !os(macOS)
    @objc private func subtitleDisplayLinkTick(_ link: CADisplayLink) {
        guard !isDisposed, !isSeekPending else { return }
        pumpSubtitleOverlay(referenceTime: mediaTime(for: avPlayer.currentTime().seconds))
    }
    #endif

    /// Empty-state semantics: `0` when an item exists but nothing covering the
    /// playhead is loaded; **no emission at all** when there is no item, so the
    /// view model keeps its last value.
    private func emitBufferedAhead(referenceTime: Double) {
        guard let item = currentItem, referenceTime.isFinite else { return }
        let playable = playableAheadSeconds(for: item, referenceTime: referenceTime)
        onBufferedAheadChange?(
            PlaybackBufferedAhead(
                playableAheadSeconds: playable,
                runwaySeconds: runwaySeconds(
                    for: item,
                    referenceTime: referenceTime,
                    playableAhead: playable
                )
            )
        )
    }

    /// Main thread only: reads `latestLoopbackGeneratedStats`, which is written
    /// via `DispatchQueue.main.async` in `writer.onGeneratedMediaStats`, and is
    /// only ever called from main-thread paths (the periodic time observer is
    /// installed with `queue: .main`, the `loadedTimeRanges` KVO handler hops
    /// to main, and the stats snapshot is `@MainActor`). Deliberately NOT
    /// marked `@MainActor`: `AVPlayerBackend` is not a `@MainActor` class and
    /// `emitBufferedAhead` is nonisolated, so a synchronous call into a
    /// `@MainActor` method would not compile. The class is main-confined by
    /// construction; do not introduce a hop.
    private func runwaySeconds(
        for item: AVPlayerItem,
        referenceTime: Double,
        playableAhead: Double
    ) -> Double {
        // `latestLoopbackGeneratedStats` is non-nil only on the loopback
        // route (written solely by the session-gated writer callback), so its
        // nilness already encodes the route.
        let visibleAhead = latestLoopbackGeneratedStats
            .map { max(0, $0.playlistVisibleEndSeconds - referenceTime) }
        return PlaybackRunwayPolicy.runwaySeconds(
            playableAheadSeconds: playableAhead,
            generatedVisibleAheadSeconds: visibleAhead
        )
    }

    private func emitPlaybackStats(referenceTime: Double, force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastStatsEmitWall >= 1.0 else { return }
        lastStatsEmitWall = now
        guard let item = currentItem else { return }

        Task { [weak self, item] in
            await self?.emitPlaybackStatsSnapshot(for: item, referenceTime: referenceTime)
        }
    }

    @MainActor
    private func emitPlaybackStatsSnapshot(for item: AVPlayerItem, referenceTime: Double) async {
        guard currentItem === item else { return }
        let accessEvent = item.accessLog()?.events.last
        let indicatedBitrate = positive(accessEvent?.indicatedBitrate)
        let shouldPublishNetworkStats = publishesRemoteAccessLogNetworkStats
        let observedBitrate = shouldPublishNetworkStats
            ? positive(accessEvent?.observedBitrate)
            : nil
        let videoFormat = await AVFoundationPlaybackIntrospection.videoFormat(for: item)
        let audio = await audioStats(for: item)
        guard currentItem === item else { return }

        var stats = PlaybackStats()
        stats.route = currentSourceStrategy.map(Self.displayRouteLabel)
        stats.source = sourceLabel(for: currentSourceStrategy)
        stats.video = PlaybackStats.MediaStream(
            codec: videoFormat.stream.codec ?? videoCodecLabel(for: currentSourceStrategy),
            detail: videoFormat.stream.detail ?? videoDetail(for: item),
            bitrateBps: indicatedBitrate ?? observedBitrate ?? videoFormat.stream.bitrateBps
        )
        // Prefer the format description of what AVPlayer is actually
        // playing (e.g. "Dolby Vision Profile 8 Level 6 (HDR10
        // compatible)") over the spec-derived expectation. The route-derived
        // label is a diagnostic fallback describing what was planned, so it
        // deliberately does not feed `confirmedDynamicRange`, which the HUD
        // badge trusts.
        stats.dynamicRange = videoFormat.dynamicRange ?? dynamicRangeLabel(for: currentSourceStrategy)
        stats.confirmedDynamicRange = videoFormat.confirmedDynamicRange
        stats.audio = audio
        stats.subtitles = selectedSubtitleLabel()
        stats.screenFrameRate = PlatformScreen.maximumFramesPerSecond
        stats.playbackRate = Double(avPlayer.rate == 0 ? avPlayer.defaultRate : avPlayer.rate)
        stats.bufferStatus = bufferStatus(for: item)
        stats.playableAheadSeconds = playableAheadSeconds(for: item, referenceTime: referenceTime)
        stats.runwaySeconds = runwaySeconds(
            for: item,
            referenceTime: referenceTime,
            playableAhead: stats.playableAheadSeconds ?? 0
        )
        stats.rebufferCount = rebufferCount
        // AVPlayer's own transport figures, published only on routes where its
        // item URL is the origin. Behind the proxy or the loopback server they
        // describe a 127.0.0.1 socket, and the stats panel would print that
        // local-read rate as "Observed bitrate" beside the proxy-derived
        // "Download rate". Those routes get their honest transport numbers
        // from the proxy, reconciled in `PlaybackStatsComposer`.
        stats.observedBitrateBps = observedBitrate
        stats.indicatedBitrateBps = shouldPublishNetworkStats ? indicatedBitrate : nil
        // The backend publishes only what it measures itself; the route's
        // download rate is the composer's call.
        stats.demuxReadRateBps = loopbackDemuxReadBitrateBps
        if let segmentStats = segmentStore?.stats() {
            stats.generatedAheadSeconds = max(0, segmentStats.generatedMediaSeconds - referenceTime)
            stats.generatedSegmentCount = segmentStats.segmentCount
            stats.generatedSpilledSegmentCount = segmentStats.spilledSegmentCount
            stats.segmentStoreBytes = segmentStats.memoryBytes
            stats.segmentStoreBudgetBytes = segmentStats.memoryBudgetBytes
            stats.segmentStoreTempSpillBytes = segmentStats.tempSpillBytes
            stats.segmentStoreTempSpillBudgetBytes = segmentStats.tempSpillBudgetBytes
            if segmentStats.tempSpillBudgetBytes > 0 {
                stats.segmentStoreTempSpillPercent = Double(segmentStats.tempSpillBytes)
                    / Double(segmentStats.tempSpillBudgetBytes) * 100
            }
            stats.segmentStoreDebugMirrorBytes = segmentStats.debugMirrorBytes
            stats.segmentServerRequestCount = segmentStats.requestCount
            stats.segmentServerBytesServed = segmentStats.bytesServed
            stats.segmentServerLastLatencyMs = segmentStats.lastRequestLatencyMs
            stats.segmentServerWaitCount = segmentStats.waitCount
        }
        if let generatedStats = latestLoopbackGeneratedStats {
            stats.generatedVisibleAheadSeconds = max(0, generatedStats.playlistVisibleEndSeconds - referenceTime)
            stats.generatedMediaBitrateBps = generatedStats.rollingBitrateBps
            stats.generatedLoopbackGeneration = generatedStats.generation
            stats.generatedPlaylistMediaSequence = "\(generatedStats.firstMediaSequence)-\(generatedStats.lastMediaSequence)"
            stats.generatedPlaylistVisibleRange = String(
                format: "%.1f-%.1f s",
                generatedStats.playlistVisibleStartSeconds,
                generatedStats.playlistVisibleEndSeconds
            )
            stats.generatedPlaylistBytes = generatedStats.playlistBodyBytes
            stats.generatedPlaylistHash = generatedStats.playlistBodyHash
            stats.generatedDurationSource = generatedStats.durationSource
        }
        if shouldPublishNetworkStats,
           let bytes = accessEvent?.numberOfBytesTransferred,
           bytes > 0 {
            stats.networkBytesTransferred = bytes
        }
        stats.demuxReadBytes = loopbackSourceBytesRead
        stats.deviceInfo = Self.deviceInfo()
        stats.freeDiskSpaceBytes = Self.freeDiskSpaceBytes()
        stats.volumeAvailableCapacityBytes = Self.volumeAvailableCapacityBytes()
        onPlaybackStatsChange?(stats)
    }

    /// True only when AVPlayer's own transport is the one talking to the
    /// origin, which is what makes its access log a network measurement.
    ///
    /// `.siloLoopback` always reads the in-app segment server, and a proxied
    /// `.remoteDirect` item points at the 127.0.0.1 `PlaybackSourceProxy`, so
    /// on both the access log measures a loopback socket. An unproxied
    /// `.remoteDirect` — an offline `file://` source, or a proxy that failed
    /// to start — still fetches the origin itself and keeps these figures.
    private var publishesRemoteAccessLogNetworkStats: Bool {
        switch currentSourceStrategy {
        case .siloLoopback:
            return false
        case .remoteHLS(let url, _), .remoteDirect(let url, _):
            return !Self.isLoopbackHost(url.host)
        case .none:
            return false
        }
    }

    private func sourceLabel(for strategy: SourceStrategy?) -> String? {
        switch strategy {
        case .remoteHLS(let url, _), .remoteDirect(let url, _):
            return url.host ?? url.scheme
        case .siloLoopback(let spec):
            // The loopback is an implementation detail; the user-meaningful
            // source is the origin the media is actually fetched from.
            return spec.sourceURL.host ?? "local"
        case .none:
            return nil
        }
    }

    private func videoCodecLabel(for strategy: SourceStrategy?) -> String? {
        switch strategy {
        case .siloLoopback(let spec):
            return spec.videoMode.sampleEntryCodec
        case .remoteHLS:
            return "hls"
        case .remoteDirect, .none:
            return nil
        }
    }

    private func videoDetail(for item: AVPlayerItem) -> String? {
        let size = item.presentationSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return nil
        }
        return "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    @MainActor
    private func audioStats(for item: AVPlayerItem) async -> PlaybackStats.MediaStream {
        if case .siloLoopback(let spec) = currentSourceStrategy,
           spec.selectedAudio.isPresent {
            let outputMode = Self.audioOutputModeLabel(spec.selectedAudio.outputMode)
            let liveStream = await AVFoundationPlaybackIntrospection.audioStream(for: item)
            return PlaybackStats.MediaStream(
                codec: liveStream.codec ?? outputMode,
                detail: audioDetail(
                    channels: spec.selectedAudio.sourceChannelCount,
                    layout: spec.selectedAudio.sourceChannelLayout,
                    suffix: loopbackAudioSuffix(sourceCodec: spec.selectedAudio.sourceCodec, outputMode: outputMode, preservesAtmos: spec.selectedAudio.preservesAtmos)
                ),
                bitrateBps: liveStream.bitrateBps
            )
        }

        guard let state = audioSelectionState,
              let option = item.currentMediaSelection.selectedMediaOption(in: state.group) else {
            return await AVFoundationPlaybackIntrospection.audioStream(for: item)
        }
        let selectionLabel = normalizedTitle(for: option) ?? languageCode(for: option)
        let liveStream = await AVFoundationPlaybackIntrospection.audioStream(for: item, selectionHint: selectionLabel)
        return PlaybackStats.MediaStream(
            codec: liveStream.codec ?? codecLabel(for: option),
            detail: joined([liveStream.detail, selectionLabel]),
            bitrateBps: liveStream.bitrateBps
        )
    }

    private func selectedSubtitleLabel() -> String? {
        if let selectedControlledSubtitleTrackId,
           let track = embeddedSubtitleExtractor?
            .playerTracks(selectedPrimaryTrackId: selectedControlledSubtitleTrackId)
            .first(where: { $0.trackId == selectedControlledSubtitleTrackId }) {
            return track.title ?? track.lang ?? track.codec ?? "On"
        }
        if let selectedControlledSubtitleTrackId,
           let descriptor = sidecarDescriptorsByTrackId[selectedControlledSubtitleTrackId] {
            return descriptor.label ?? descriptor.language ?? descriptor.codec ?? "On"
        }
        guard let state = subtitleSelectionState,
              let option = currentItem?.currentMediaSelection.selectedMediaOption(in: state.group) else {
            return "Off"
        }
        return normalizedTitle(for: option) ?? languageCode(for: option) ?? codecLabel(for: option) ?? "On"
    }

    private func audioDetail(channels: Int?, layout: String?, suffix: String?) -> String? {
        var parts: [String] = []
        if let layout, !layout.isEmpty {
            parts.append(layout)
        } else if let channels, channels > 0 {
            parts.append("\(channels) ch")
        }
        if let suffix, !suffix.isEmpty {
            parts.append(suffix)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func dynamicRangeLabel(for strategy: SourceStrategy?) -> String? {
        guard case .siloLoopback(let spec) = strategy else { return nil }
        switch spec.videoMode {
        case .passthroughProfile5:
            return "Dolby Vision (Profile \(spec.manifestMetadata.advertisedDolbyVisionProfile ?? 5))"
        case .convertProfile7To81:
            return "Dolby Vision (Profile 7 → 8.1)"
        case .passthroughProfile8(.hdr10):
            return "Dolby Vision (Profile 8.1)"
        case .passthroughProfile8(.sdr):
            return "Dolby Vision (Profile 8.2)"
        case .passthroughProfile8(.hlg):
            return "Dolby Vision (Profile 8.4)"
        case .passthroughHEVC:
            switch spec.manifestMetadata.videoRange {
            case "HLG": return "HLG"
            case "SDR": return "SDR"
            default: return loopbackHDR10PlusDetected ? "HDR10+" : "HDR10"
            }
        case .passthroughH264:
            return "SDR"
        }
    }

    private func shouldPreserveTVDisplayCriteriaDuringReload(
        from current: SourceStrategy?,
        to next: SourceStrategy
    ) -> Bool {
        #if os(tvOS)
        guard case .siloLoopback(let currentSpec) = current,
              case .siloLoopback(let nextSpec) = next else {
            return false
        }
        // With the HDR gate off this reduces to the shipped DV→DV rule
        // (non-DV modes select `.none`); with it on, same-range HDR10/HLG
        // reloads also keep their criteria so an audio-track change doesn't
        // renegotiate the HDMI mode.
        let hdrGateEnabled = HDRDisplayCriteriaPolicy.isEnabled()
        return HDRDisplayCriteriaPolicy.shouldPreserveCriteriaAcrossReload(
            current: HDRDisplayCriteriaPolicy.selection(
                videoMode: currentSpec.videoMode,
                manifestVideoRange: currentSpec.manifestMetadata.videoRange,
                hdrGateEnabled: hdrGateEnabled
            ),
            next: HDRDisplayCriteriaPolicy.selection(
                videoMode: nextSpec.videoMode,
                manifestVideoRange: nextSpec.manifestMetadata.videoRange,
                hdrGateEnabled: hdrGateEnabled
            ),
            currentRate: currentSpec.sourceVideoFrameRate ?? 24.0,
            nextRate: nextSpec.sourceVideoFrameRate ?? 24.0
        )
        #else
        return false
        #endif
    }

    private func loopbackAudioSuffix(sourceCodec: String?, outputMode: String, preservesAtmos: Bool) -> String {
        var parts: [String] = []
        if let sourceCodec,
           !sourceCodec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           sourceCodec.caseInsensitiveCompare(outputMode) != .orderedSame {
            parts.append("from \(sourceCodec)")
        }
        if preservesAtmos {
            parts.append("receiver Atmos validation required")
        }
        if parts.isEmpty {
            parts.append(outputMode)
        }
        return parts.joined(separator: ", ")
    }

    private func joined(_ parts: [String?]) -> String? {
        let values = parts.compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private func bufferStatus(for item: AVPlayerItem) -> String {
        if item.isPlaybackBufferEmpty { return "Buffering" }
        if item.isPlaybackLikelyToKeepUp { return "Healthy" }
        return "Filling"
    }

    /// Raw AVPlayer decode buffer ahead of `referenceTime`, from
    /// `loadedTimeRanges`. `0` when an item exists but nothing covering the
    /// playhead is loaded. The recovery ladder and both watchdogs consume this
    /// value and nothing else — it is deliberately NOT the user-facing runway
    /// (see `PlaybackRunwayPolicy`).
    private func playableAheadSeconds(for item: AVPlayerItem, referenceTime: Double) -> Double {
        loadedRangeEnd(for: item, referenceTime: referenceTime).map { max(0, $0 - referenceTime) } ?? 0
    }

    private func loadedRangeEnd(for item: AVPlayerItem, referenceTime: Double) -> Double? {
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue)
        let end = ranges.compactMap { range -> Double? in
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            guard start.isFinite, end.isFinite, end > referenceTime, start <= referenceTime else {
                return nil
            }
            return end
        }.max()
        return end
    }

    private func describeRanges(_ timeRanges: [NSValue]) -> String {
        let ranges = timeRanges.map(\.timeRangeValue)
        guard !ranges.isEmpty else { return "[]" }
        return ranges.map { range in
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            return String(format: "%.2f-%.2f", start, end)
        }.joined(separator: ",")
    }

    private func installLoopbackPlayheadWatchdog() {
        loopbackPlayheadWatchdog?.invalidate()
        let timer = Timer(
            timeInterval: Self.playheadWatchdogTickSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.loopbackPlayheadWatchdogTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        loopbackPlayheadWatchdog = timer
    }

    /// Independent wall-clock check for a local DV loopback playhead that has
    /// stopped advancing while AVPlayer believes it is playing and generated
    /// media is available ahead of it. This is the failure mode the existing
    /// recovery hooks miss: `.AVPlayerItemPlaybackStalled` only fires on buffer
    /// starvation, the edge watchdog requires the buffered edge to sit at the
    /// playhead, and the periodic time observer stops firing the moment the
    /// playhead freezes. Silo's explicit play-intent latch distinguishes a
    /// terminal AVPlayer pause from an intentional user pause.
    private func loopbackPlayheadWatchdogTick() {
        guard !isDisposed,
              case .siloLoopback = currentSourceStrategy,
              let item = currentItem,
              didFireFileLoaded,
              !isSeekPending else { return }

        let now = CACurrentMediaTime()
        let position = currentTime()
        guard position.isFinite else { return }

        let timeControl = Self.timeControl(for: avPlayer.timeControlStatus)
        let bufferedAhead = playableAheadSeconds(for: item, referenceTime: position)
        let generatedEnd = latestLoopbackGeneratedStats?.playlistVisibleEndSeconds
            ?? segmentStore?.stats().generatedMediaSeconds
            ?? 0
        let generatedAhead = max(0, generatedEnd - position)
        let statusLabel = timeControl.rawValue

        // Periodic transport-state telemetry so a captured stall can be
        // classified (pause vs. wedge) directly from the log.
        if now - watchdogLastStateLogWall >= 3 {
            watchdogLastStateLogWall = now
            let suspendedSuffix = suspendedRecoveryReasons.isEmpty
                ? ""
                : " suspended=[\(suspendedRecoveryReasons.sorted().joined(separator: ","))]"
            let stationaryFor = recoveryStationarySecondsProvider?() ?? 0
            cmpLog(
                "[CMP-AVP] loopback playhead state pos=\(position) tc=\(statusLabel) rate=\(avPlayer.rate) paused=\(isUserPaused ? 1 : 0) bufAhead=\(bufferedAhead) generatedAhead=\(generatedAhead) stationaryFor=\(stationaryFor)\(suspendedSuffix)"
            )
        }

        // Every rung below this line was a decision; they all live in
        // `RecoveryPolicy` now. The tick keeps its period, its guards and its
        // telemetry and reports what it saw.
        emitRecoveryObservation(
            .playheadTick(
                PlayheadSample(
                    position: position,
                    timeControl: timeControl,
                    bufferedAhead: bufferedAhead,
                    generatedAhead: generatedAhead,
                    secondsSinceLastServe: segmentStore?.secondsSinceLastSegmentServe() ?? .infinity,
                    userPaused: isUserPaused,
                    playbackEstablished: didFireFileLoaded,
                    pendingSeekMediaTarget: vodPendingSeekMediaTarget
                )
            )
        )
    }

    /// The one `AVPlayer.TimeControlStatus` mapping in the app. Every transport
    /// label printed anywhere is `PlayheadSample.TimeControl`'s raw value.
    private static func timeControl(
        for status: AVPlayer.TimeControlStatus
    ) -> PlayheadSample.TimeControl {
        switch status {
        case .paused: return .paused
        case .waitingToPlayAtSpecifiedRate: return .waiting
        case .playing: return .playing
        @unknown default: return .unknown
        }
    }

    private func sampleLocalLoopbackEdge(item: AVPlayerItem, referenceTime: Double, trigger: String) {
        guard case .siloLoopback = currentSourceStrategy,
              item === currentItem,
              didFireFileLoaded,
              !isUserPaused,
              !isSeekPending,
              referenceTime.isFinite,
              let generatedStats = latestLoopbackGeneratedStats else {
            return
        }
        let loadedEnd = loadedRangeEnd(for: item, referenceTime: referenceTime) ?? referenceTime
        let targetDuration = max(1.0, Double(generatedStats.targetDuration))
        // Seeding, advance tracking and the five qualification tests are the
        // edge ladder's decision; they live in `RecoveryPolicy` now. This is the
        // sampler.
        lastEdgeSampleTrigger = trigger
        lastEdgeSampleReferenceTime = referenceTime
        lastEdgeSampleLoadedEnd = loadedEnd
        emitRecoveryObservation(
            .edgeSample(
                EdgeSample(
                    referenceTime: referenceTime,
                    loadedEnd: loadedEnd,
                    playlistEnd: generatedStats.playlistVisibleEndSeconds,
                    playlistHash: generatedStats.playlistBodyHash,
                    loadedAhead: max(0, loadedEnd - referenceTime),
                    visibleAhead: max(0, generatedStats.playlistVisibleEndSeconds - referenceTime),
                    targetDuration: targetDuration,
                    longestSegment: generatedStats.longestSegmentDuration
                )
            )
        )
    }

    /// The edge watchdog's trigger line, printed by the rung that fires rather
    /// than by the sampler. The clock values are the sampler's own, carried on
    /// `lastEdgeSample*`: the decision was taken on them, and for the
    /// periodic-time-observer trigger they are `time.seconds` rather than
    /// `currentTime()`.
    private func logEdgeWatchdogTrigger() {
        guard let item = currentItem,
              let generatedStats = latestLoopbackGeneratedStats else { return }
        let referenceTime = lastEdgeSampleReferenceTime ?? currentTime()
        let loadedEnd = lastEdgeSampleLoadedEnd
            ?? loadedRangeEnd(for: item, referenceTime: referenceTime)
            ?? referenceTime
        let loadedAhead = max(0, loadedEnd - referenceTime)
        let visibleAhead = max(0, generatedStats.playlistVisibleEndSeconds - referenceTime)
        let trigger = lastEdgeSampleTrigger
        Self.logger.info(
            "[CMP-AVP] edge_watchdog trigger=\(trigger, privacy: .public) player=\(referenceTime, privacy: .public) loadedEnd=\(loadedEnd, privacy: .public) loadedAhead=\(loadedAhead, privacy: .public) playlistStart=\(generatedStats.playlistVisibleStartSeconds, privacy: .public) playlistEnd=\(generatedStats.playlistVisibleEndSeconds, privacy: .public) visibleAhead=\(visibleAhead, privacy: .public) mediaSeq=\(generatedStats.firstMediaSequence, privacy: .public)-\(generatedStats.lastMediaSequence, privacy: .public) targetDuration=\(generatedStats.targetDuration, privacy: .public) longestSegment=\(generatedStats.longestSegmentDuration, privacy: .public) playlistBytes=\(generatedStats.playlistBodyBytes, privacy: .public) playlistHash=\(generatedStats.playlistBodyHash, privacy: .public) forwardBuffer=\(item.preferredForwardBufferDuration, privacy: .public) loadedRanges=\(self.describeRanges(item.loadedTimeRanges), privacy: .public) seekableRanges=\(self.describeRanges(item.seekableTimeRanges), privacy: .public)"
        )
    }

    private func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func deviceInfo() -> String {
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        #if os(macOS)
        let model = Host.current().localizedName ?? "Mac"
        #else
        let model = UIDevice.current.model
        #endif
        return "\(model) / \(String(format: "%.0f", memoryGB)) GB"
    }

    private static func freeDiskSpaceBytes() -> Int64? {
        PlaybackDiskBudget.freeDiskSpaceBytes()
    }

    private static func volumeAvailableCapacityBytes() -> Int64? {
        #if os(tvOS)
        return freeDiskSpaceBytes()
        #else
        let url = FileManager.default.temporaryDirectory
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #endif
    }

    private static func audioOutputModeLabel(_ mode: LoopbackSessionSpec.AudioOutputMode) -> String {
        switch mode {
        case .copy: return "copy"
        case .transcodeFLAC: return "flac"
        case .requireFLAC: return "flac(required)"
        case .transcodeEC3: return "ec-3"
        case .transcodeAC3: return "ac-3"
        case .transcodeAAC: return "aac"
        }
    }

    private func attachItemObservers(_ item: AVPlayerItem) {
        statusObs = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                switch item.status {
                case .readyToPlay:
                    if self.ttffReadyMs == nil { self.ttffReadyMs = self.ttffElapsedMs() }
                    self.cancelLoopbackStartupWatchdog()
                    self.attemptInitialPlaybackStart(for: item, trigger: "status.readyToPlay")
                case .failed:
                    self.cancelLoopbackStartupWatchdog()
                    self.reportItemFailure(item)
                default:
                    break
                }
            }
        }

        rateObs = avPlayer.observe(\.rate, options: [.new, .initial]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                self.onPauseChange?(self.isUserPaused)
                // A pause under an armed gate stops the periodic clock, so
                // this is the only wake the gate would otherwise get.
                self.evaluateInitialVideoDisplayGate(trigger: "rate")
            }
        }

        hasObservedTimeControlStatus = false
        timeControlObs = avPlayer.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                // Deliveries arrive in order on main, so the first one to land
                // for this observation is `.initial`.
                let isInitialObservation = !self.hasObservedTimeControlStatus
                self.hasObservedTimeControlStatus = true
                if self.reconcileSystemTransportIntent(
                    from: player,
                    isInitialObservation: isInitialObservation
                ) { return }
                guard case .siloLoopback = self.currentSourceStrategy else { return }
                let status = Self.timeControl(for: player.timeControlStatus).rawValue
                let reason = player.reasonForWaitingToPlay?.rawValue ?? "-"
                Self.logger.info(
                    "[CMP-AVP] timeControlStatus=\(status, privacy: .public) reason=\(reason, privacy: .public) rate=\(player.rate, privacy: .public) current=\(player.currentTime().seconds, privacy: .public) userPaused=\(self.isUserPaused ? 1 : 0, privacy: .public) itemStatus=\(self.currentItem?.status.rawValue ?? -1, privacy: .public)"
                )
                cmpLog(
                    "[CMP-AVP] timeControlStatus=\(status) reason=\(reason) rate=\(player.rate) current=\(player.currentTime().seconds) userPaused=\(self.isUserPaused ? 1 : 0) itemStatus=\(self.currentItem?.status.rawValue ?? -1)"
                )
            }
        }

        bufferEmptyObs = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                if item.isPlaybackBufferEmpty {
                    // A seek empties the decode buffer by definition, and so
                    // does the initial fill before the first frame; counting
                    // either made the figure a seek/startup counter. Only
                    // unattributed empties after playback established are
                    // rebuffers.
                    if self.didFireFileLoaded,
                       !self.isSeekPending,
                       CACurrentMediaTime() - self.lastSeekSettledAt >= Self.rebufferSeekGraceSeconds {
                        self.rebufferCount += 1
                    }
                    if case .siloLoopback = self.currentSourceStrategy {
                        Self.logger.info(
                            "[CMP-AVP] item buffer empty current=\(self.currentTime(), privacy: .public) loadedRanges=\(self.describeRanges(item.loadedTimeRanges), privacy: .public)"
                        )
                    }
                    self.onBufferingChange?(true)
                    self.emitPlaybackStats(referenceTime: self.currentTime(), force: true)
                }
            }
        }

        bufferFullObs = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                if item.isPlaybackLikelyToKeepUp {
                    self.onBufferingChange?(false)
                    self.emitPlaybackStats(referenceTime: self.currentTime(), force: true)
                    self.sampleLoopbackAutoResume(for: item, trigger: "likely_to_keep_up")
                }
            }
        }

        durationObs = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let duration = item.duration.seconds
            guard duration.isFinite, duration > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                self.onDurationChange?(duration)
            }
        }

        loadedRangesObs = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                self.emitBufferedAhead(referenceTime: self.currentTime())
                self.attemptInitialPlaybackStart(for: item, trigger: "loadedTimeRanges")
                self.sampleLoopbackAutoResume(for: item, trigger: "loaded_ranges")
            }
        }

        seekableRangesObs = item.observe(\.seekableTimeRanges, options: [.new, .initial]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                self.attemptInitialPlaybackStart(for: item, trigger: "seekableTimeRanges")
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isDisposed else { return }
            self.hasReachedItemEnd = true
            self.onEndOfFile?()
        }

        itemPlaybackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isDisposed else { return }
            Self.logger.info(
                "[CMP-AVP] item playback stalled current=\(self.currentTime(), privacy: .public) loadedRanges=\(self.describeRanges(item.loadedTimeRanges), privacy: .public)"
            )
            guard item === self.currentItem else { return }
            self.emitRecoveryObservation(.playbackStalled)
        }

        itemFailedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            guard let self, !self.isDisposed else { return }
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            guard item === self.currentItem else { return }
            let position = self.currentTime()
            Self.logger.info(
                "[CMP-AVP] item failed to play to end current=\(position, privacy: .public) userPaused=\(self.isUserPaused ? 1 : 0, privacy: .public) itemStatus=\(item.status.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            cmpLog(
                "[CMP-AVP] item failedToEnd current=\(position) userPaused=\(self.isUserPaused ? 1 : 0) itemStatus=\(item.status.rawValue) error=\(String(describing: error))"
            )
            self.emitRecoveryObservation(
                .itemFailedToEnd(position: position, userPaused: self.isUserPaused)
            )
            // On an established loopback item the confirmation candidate is the
            // whole response, and the "Playlist File unchanged" tail below must
            // not also run.
            if case .siloLoopback = self.currentSourceStrategy,
               self.didFireFileLoaded {
                return
            }
            // The only live tail of a failed-to-end the confirmation arm did not
            // consume. It reports; the Y rung is `RecoveryPolicy`'s.
            let description = String(describing: error)
            guard description.contains("Playlist File unchanged")
                    || description.contains("-12888") else { return }
            self.emitRecoveryObservation(.playlistUnchanged(userPaused: self.isUserPaused))
        }

        // AVPlayer surfaces HLS-level trouble (404s, playlist parse errors,
        // format rejections) as errorLog entries without ever flipping the
        // item to .failed — the "spinner forever" class. Log every entry;
        // -15628 is CoreMedia's loader-poison signature, after which the
        // item will never post a stall or become ready, so escalate the
        // startup recovery ladder immediately instead of waiting for the
        // fetch-freeze window to notice.
        itemErrorLogObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let self, !self.isDisposed,
                  let item, item === self.currentItem,
                  let event = item.errorLog()?.events.last else { return }
            cmpLog(
                "[CMP-AVP] item errorLog status=\(event.errorStatusCode) domain=\(event.errorDomain) uri=\(event.uri ?? "-") comment=\(event.errorComment ?? "-")"
            )
            // Classification, the established/pre-established split and the
            // `-15628` loader-poison escalation are all `RecoveryPolicy`'s now
            // (`decideItemDeathEvidence`); this observer reports the entry.
            self.emitRecoveryObservation(
                .itemDeathEvidence(
                    statusCode: event.errorStatusCode,
                    description: event.errorComment ?? "",
                    weight: event.errorStatusCode == -15628 ? 2 : 1,
                    position: self.currentTime(),
                    userPaused: self.isUserPaused
                )
            )
        }
    }

    /// Tears down every observer scoped to the current AVPlayerItem (plus
    /// the player-level KVO that `attachItemObservers` re-creates). Shared
    /// by full disposal and the startup watchdog's in-place item reload.
    private func detachPerItemObservers() {
        statusObs?.invalidate(); statusObs = nil
        rateObs?.invalidate(); rateObs = nil
        timeControlObs?.invalidate(); timeControlObs = nil
        bufferFullObs?.invalidate(); bufferFullObs = nil
        bufferEmptyObs?.invalidate(); bufferEmptyObs = nil
        durationObs?.invalidate(); durationObs = nil
        loadedRangesObs?.invalidate(); loadedRangesObs = nil
        seekableRangesObs?.invalidate(); seekableRangesObs = nil
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        if let observer = itemPlaybackStalledObserver {
            NotificationCenter.default.removeObserver(observer)
            itemPlaybackStalledObserver = nil
        }
        if let observer = itemFailedToEndObserver {
            NotificationCenter.default.removeObserver(observer)
            itemFailedToEndObserver = nil
        }
        if let observer = itemErrorLogObserver {
            NotificationCenter.default.removeObserver(observer)
            itemErrorLogObserver = nil
        }
    }

    /// The auto-resume rung's two KVO triggers. The rung itself
    /// (`resumeLocalLoopbackPlaybackIfNeeded`) is `RecoveryPolicy`'s
    /// `.likelyToKeepUp` arm now.
    private func sampleLoopbackAutoResume(for item: AVPlayerItem, trigger: String) {
        guard case .siloLoopback = currentSourceStrategy,
              item === currentItem else { return }
        let playerSeconds = currentTime()
        guard playerSeconds.isFinite else { return }
        lastAutoResumeTrigger = trigger
        emitRecoveryObservation(
            .likelyToKeepUp(
                rate: Double(avPlayer.rate),
                bufferedAhead: playableAheadSeconds(for: item, referenceTime: playerSeconds),
                reachedEnd: hasReachedItemEnd,
                likely: item.isPlaybackLikelyToKeepUp
            )
        )
    }

    // MARK: - Executing recovery actions
    //
    // Every body below is the rung's legacy body, moved verbatim. The
    // preconditions, ladders, cooldowns, budgets and latches that used to sit
    // in front of them are `RecoveryPolicy`'s.

    /// Runs one `RecoveryAction` on this engine. In-route actions only — the
    /// session/transport arms are the shell's and are ignored here.
    func perform(_ action: RecoveryAction) {
        guard !isDisposed else { return }
        switch action {
        case .reassertPlay:
            avPlayer.play()

        case .nudgeStartup:
            nudgeLoopbackStartupConsumer()

        case .reloadStartupItem:
            reloadLoopbackStartupItem()

        case let .reanchor(atMediaSeconds, cause):
            if case .vodStallNudge = cause {
                let anchor = playerTime(forMediaTime: atMediaSeconds)
                // Both emitters of this rung — the playhead watchdog's reanchor
                // and the expired interactive seek deadline — ran the stall
                // recovery one main-actor turn past the trigger, so it never
                // executed inside the `RunLoop.main` timer callback or inside
                // `handleSeekDeadline` itself (which would arm a fresh seek
                // deadline from within the expiring one's own work item). The
                // post-outage kick keeps its synchronous call.
                Task { @MainActor [weak self] in
                    guard let self, !self.isDisposed else { return }
                    self.performVODStallRecovery(anchorPlayerSeconds: anchor, attempt: 1)
                }
            } else {
                performLoopbackReanchor(
                    atMediaSeconds: atMediaSeconds,
                    cause: cause,
                    rebuilding: false
                )
            }

        case let .reloadItem(atMediaSeconds, cause):
            let anchorPlayerSeconds = playerTime(forMediaTime: atMediaSeconds)
            if case .vodStall = cause {
                // Same main-actor hop as the nudge above: attempt ≥ 2 is the
                // same playhead-watchdog `Task { @MainActor }` call, one branch
                // deeper inside `performVODStallRecovery`.
                Task { @MainActor [weak self] in
                    guard let self, !self.isDisposed else { return }
                    self.performVODStallRecovery(
                        anchorPlayerSeconds: anchorPlayerSeconds,
                        attempt: 2
                    )
                }
            } else {
                // The item-death reload was always deferred one main-actor turn
                // past the notification that produced it, and dropped if the
                // item changed in between.
                Task { @MainActor [weak self, weak deferredItem = currentItem] in
                    guard let self, let deferredItem, deferredItem === self.currentItem,
                          !self.isDisposed else { return }
                    self.reloadEstablishedLoopbackItem(
                        deferredItem,
                        at: anchorPlayerSeconds,
                        reason: cause.token
                    )
                }
            }

        case let .rebuildLocalSession(atMediaSeconds, cause):
            performLoopbackReanchor(
                atMediaSeconds: atMediaSeconds,
                cause: cause,
                rebuilding: true
            )

        case let .deferUntilPlay(mediaSeconds):
            deferredRecoveryMediaTime = mediaSeconds
            Self.logger.info(
                "[CMP-AVP] local loopback playlist_unchanged recovery deferred until play media=\(mediaSeconds, privacy: .public) player=\(self.playerTime(forMediaTime: mediaSeconds), privacy: .public)"
            )

        case .resumePlayback:
            // Logged only on the loopback auto-resume rung; the
            // non-loopback seek-deadline entry into the same action never did.
            if case .some(.siloLoopback) = currentSourceStrategy, let item = currentItem {
                let playerSeconds = currentTime()
                let bufferedAhead = playableAheadSeconds(for: item, referenceTime: playerSeconds)
                Self.logger.info(
                    "[CMP-AVP] local loopback auto resume trigger=\(self.lastAutoResumeTrigger, privacy: .public) player=\(playerSeconds, privacy: .public) bufferedAhead=\(bufferedAhead, privacy: .public)"
                )
            }
            avPlayer.play()

        case .endOutageRideThrough:
            kickPlaybackAfterOutage()

        case let .fail(failure):
            // The startup watchdog is cancelled before the report on every path
            // that reports from a ladder.
            cancelLoopbackStartupWatchdog()
            reportFailure(failure)

        case .treatAsNaturalEnd, .requestServerReplan, .switchRoute,
             .renewSourceInBackground, .renewSessionFresh, .rideThroughOutage,
             .recoverFromServerOutage, .waitForServerReady, .autoRecoverInterruption:
            // Session- and transport-level actions: executed by the shell.
            break
        }
    }

    /// Flushes the subtitle plane, moves the extractor, and reloads the loopback
    /// session anchored at the rendered clock — the tail both the reanchor rungs
    /// and the rebuild rung run.
    ///
    /// `rebuilding` is the escalation rung (`.rebuildLocalSession`), which the
    /// policy reaches only by spending a `LoopbackRebuildBudget`. It is the
    /// last resort for a poisoned AVPlayer item or a dead producer, so it logs
    /// at error level and deliberately proceeds without a live `AVPlayerItem`;
    /// the reanchor rungs need one for their runway line and stand down without
    /// it. Both recreate the complete local-HLS pipeline through `load()`, and
    /// the new UUID-backed cache cannot collide with cleanup from the retired
    /// session.
    private func performLoopbackReanchor(
        atMediaSeconds mediaSeconds: Double,
        cause: RecoveryAction.Cause,
        rebuilding: Bool
    ) {
        guard case .some(.siloLoopback(let spec)) = currentSourceStrategy else { return }
        let playerSeconds = playerTime(forMediaTime: mediaSeconds)
        if rebuilding {
            Self.logger.error(
                "[CMP-AVP] rebuilding Silo loopback reason=\(cause.token, privacy: .public) media=\(mediaSeconds, privacy: .public) player=\(playerSeconds, privacy: .public)"
            )
        } else {
            guard let item = currentItem else { return }
            if case .edgeWatchdog = cause { logEdgeWatchdogTrigger() }
            let bufferedAhead = playableAheadSeconds(for: item, referenceTime: playerSeconds)
            let generatedEnd = latestLoopbackGeneratedStats?.playlistVisibleEndSeconds
                ?? segmentStore?.stats().generatedMediaSeconds
                ?? 0
            Self.logger.info(
                "[CMP-AVP] local loopback \(cause.token, privacy: .public) reanchor media=\(mediaSeconds, privacy: .public) player=\(playerSeconds, privacy: .public) generatedAhead=\(generatedEnd - playerSeconds, privacy: .public) bufferedAhead=\(bufferedAhead, privacy: .public)"
            )
        }
        subtitleSession?.flushOnSeek()
        embeddedSubtitleExtractor?.seek(to: mediaSeconds)
        load(strategy: .siloLoopback(spec: spec.reanchored(at: mediaSeconds)), startTime: mediaSeconds)
    }

    /// Proactive recovery when the shell reports an origin outage has ended. An
    /// item whose segment requests died during the outage does not retry them
    /// on its own: the transport and producer recover, but the playhead sits
    /// waiting on an empty buffer until the (no longer suppressed) starvation
    /// rung degrades the route — even though nothing is broken anymore
    /// (sim-validated 2026-07-07). Run the same stall recovery the playhead
    /// watchdog would, immediately.
    private func kickPlaybackAfterOutage() {
        guard !isDisposed,
              let item = currentItem,
              case .some(.siloLoopback) = currentSourceStrategy,
              !isUserPaused,
              avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
        let bufferedAhead = playableAheadSeconds(for: item, referenceTime: currentTime())
        guard bufferedAhead < 2.0 else { return }
        cmpLog("[CMP-OUTAGE] post-outage playback kick pos=\(currentTime()) bufAhead=\(bufferedAhead)")
        let anchor = currentTime()
        MainActor.assumeIsolated {
            performVODStallRecovery(anchorPlayerSeconds: anchor, attempt: 1)
        }
    }

    private func attemptInitialPlaybackStart(for item: AVPlayerItem, trigger: String) {
        guard item === currentItem, !isDisposed, item.status == .readyToPlay else { return }

        let mediaTarget = max(0, pendingStartTime)
        let playerTarget = playerTime(forMediaTime: mediaTarget)
        guard !hasSeekedToStart, !isInitialSeekInFlight else { return }
        guard mediaTarget > 0, playerTarget > 0.05 else {
            startPlaybackIfNeeded(for: item)
            hasSeekedToStart = true
            resyncControlledSubtitlesAfterSeek(mediaSeconds: mediaTarget)
            onTimeChange?(avPlayer.currentTime().seconds)
            return
        }
        guard itemHasSeekableMedia(item, containing: playerTarget) else {
            Self.logger.info(
                "Deferring initial resume seek mediaTarget=\(mediaTarget, privacy: .public) playerTarget=\(playerTarget, privacy: .public) trigger=\(trigger, privacy: .public) because the target is not seekable yet"
            )
            return
        }

        isInitialSeekInFlight = true
        isSeekPending = true
        let seekID = beginSeekDeadline(
            kind: .initial(mediaTarget: mediaTarget),
            item: item
        )
        subtitleSession?.flushOnSeek()
        let time = CMTime(seconds: playerTarget, preferredTimescale: 600)
        Self.logger.info(
            "Attempting initial resume seek mediaTarget=\(mediaTarget, privacy: .public) playerTarget=\(playerTarget, privacy: .public) trigger=\(trigger, privacy: .public)"
        )
        avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self, !self.isDisposed, item === self.currentItem else { return }
            guard self.completeSeekDeadline(seekID) else {
                Self.logger.info(
                    "[CMP-SEEK] ignoring late/superseded initial seek completion id=\(seekID, privacy: .public)"
                )
                return
            }
            self.markSeekSettled()
            self.isInitialSeekInFlight = false

            let landed = self.avPlayer.currentTime().seconds
            let landedMedia = self.mediaTime(for: landed)
            let landedCorrectly = finished && self.isInitialSeekSatisfied(target: mediaTarget, landed: landedMedia)
            Self.logger.info(
                "Initial resume seek completed finished=\(finished, privacy: .public) mediaTarget=\(mediaTarget, privacy: .public) playerTarget=\(playerTarget, privacy: .public) landedPlayer=\(landed, privacy: .public) landedMedia=\(landedMedia, privacy: .public)"
            )

            if landedCorrectly {
                self.hasSeekedToStart = true
                self.resyncControlledSubtitlesAfterSeek(mediaSeconds: landedMedia)
                self.startPlaybackIfNeeded(for: item)
                self.onTimeChange?(landed)
                return
            }

            // No self-driven retry: `hasSeekedToStart` is still false and
            // `isInitialSeekInFlight` was just cleared, so the item's
            // `seekableTimeRanges`/`loadedTimeRanges` observers re-enter
            // `attemptInitialPlaybackStart` the moment the media that would
            // let the target land arrives. Starting here keeps the item from
            // sitting silent if it never does.
            Self.logger.error(
                "Initial resume seek did not land mediaTarget=\(mediaTarget, privacy: .public) landedMedia=\(landedMedia, privacy: .public) landedPlayer=\(landed, privacy: .public) finished=\(finished, privacy: .public)"
            )
            if self.itemHasSeekableMedia(item, containing: playerTarget) {
                self.startPlaybackIfNeeded(for: item)
                self.onTimeChange?(landed)
            }
        }
    }

    private func startPlaybackIfNeeded(for item: AVPlayerItem) {
        armInitialVideoDisplayGateIfNeeded()
        avPlayer.play()
        if isWaitingForInitialVideoDisplay {
            scheduleInitialVideoDisplayFallback(for: item)
            // The surface may have reported readiness before `play()`; nothing
            // else will re-deliver that edge, so evaluate once here.
            evaluateInitialVideoDisplayGate(trigger: "start_playback")
        } else {
            finishInitialLoadIfNeeded(for: item, reason: "not_needed")
        }
    }

    private func armLoopbackStartupWatchdogIfNeeded() {
        guard case .siloLoopback = currentSourceStrategy else { return }
        cancelLoopbackStartupWatchdog()
        // The ladder's stage, its backstop clock, its progress clock and its
        // served-request baseline live in `RecoveryContext.StartupState` now.
        onStartupLadderArmed?(segmentServer?.servedRequestCount ?? 0)
        let timer = Timer(
            timeInterval: Self.loopbackStartupWatchdogTickSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.loopbackStartupWatchdogTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        loopbackStartupWatchdog = timer
    }

    private func loopbackStartupWatchdogTick() {
        guard !isDisposed,
              !didFireFileLoaded,
              case .siloLoopback = currentSourceStrategy,
              let item = currentItem else {
            cancelLoopbackStartupWatchdog()
            return
        }
        guard item.status != .readyToPlay else {
            cancelLoopbackStartupWatchdog()
            return
        }
        // Progress rebasing, the stall verdict, the ladder's stage and the
        // absolute backstop are all `RecoveryPolicy.decideStartupTick`'s.
        emitRecoveryObservation(
            .startupTick(
                servedRequests: segmentServer?.servedRequestCount ?? 0,
                displayModeSwitchInProgress: isTVDisplayModeSwitchInProgress()
            )
        )
    }

    /// Forces AVFoundation to tear down and rebuild its item loader via a
    /// zero-tolerance seek to the startup target — the same recovery a user
    /// gets by exiting the player and re-entering — without touching
    /// transport intent.
    private func nudgeLoopbackStartupConsumer() {
        let target: CMTime
        if case .some(.siloLoopback) = currentSourceStrategy,
           pendingStartTime > 0 {
            target = CMTime(
                seconds: max(0, playerTime(forMediaTime: pendingStartTime)),
                preferredTimescale: 600
            )
        } else {
            target = avPlayer.currentTime()
        }
        avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        rebaseInitialVideoDisplayGateStartTime(to: target.seconds, context: "startup_nudge")
    }

    /// Swap in a fresh AVPlayerItem for the same loopback URL. The producer,
    /// segment store, and server all stay up — only AVFoundation's item-side
    /// loader state is rebuilt. The initial-video-display gate stays armed
    /// from the original prepare, so the fresh item flows through the same
    /// ready → initial-seek → gated-start path as the first one.
    private func reloadLoopbackStartupItem() {
        guard let oldItem = currentItem,
              let asset = oldItem.asset as? AVURLAsset else {
            cancelLoopbackStartupWatchdog()
            reportFailure(.loopbackStartupItemUnreloadable)
            return
        }
        let url = asset.url
        cmpLog("[CMP-AVP] startup watchdog reloading item in place url=\(loggableURLDescription(url))")
        detachPerItemObservers()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        applyLoopbackItemBufferPolicy(to: item, phase: .startup)
        currentItem = item
        attachItemObservers(item)
        // Fresh item: the end-of-item latch belongs to the retired one.
        hasReachedItemEnd = false
        avPlayer.replaceCurrentItem(with: item)
        issueVODResumePreSeekIfNeeded(context: "startup_reload")
    }

    private func isTVDisplayModeSwitchInProgress() -> Bool {
        #if os(tvOS)
        return TVDisplayCriteria.activeTVWindow()?.avDisplayManager
            .isDisplayModeSwitchInProgress ?? false
        #else
        return false
        #endif
    }

    /// Stops the 1 Hz tick. It deliberately does **not** clear the ladder's
    /// stage (`RecoveryContext.startup`): `status.readyToPlay` cancels the timer
    /// while `didFireFileLoaded` is still false, and the item error log's
    /// `-15628` loader-poison signature can still escalate the ladder in that
    /// window — exactly as it could when the stage was a field here that this
    /// function left alone.
    private func cancelLoopbackStartupWatchdog() {
        loopbackStartupWatchdog?.invalidate()
        loopbackStartupWatchdog = nil
    }

    private func beginInitialVideoDisplayGate() {
        initialVideoDisplayFallback?.cancel()
        initialVideoDisplayFallback = nil
        isInitialVideoDisplayGatePrepared = true
        isWaitingForInitialVideoDisplay = false
        initialVideoDisplayGateArmedAt = nil
        didObserveVideoSurfaceReadyForDisplay = false
        didTemporarilyMuteForInitialVideoDisplay = !avPlayer.isMuted
        if didTemporarilyMuteForInitialVideoDisplay {
            avPlayer.isMuted = true
        }
        Self.logger.info("[CMP-AVP] prepared initial video frame gate before startup audio")
        cmpLog("[CMP-AVP] initial video display gate prepared muted=\(didTemporarilyMuteForInitialVideoDisplay ? 1 : 0)")
    }

    private func armInitialVideoDisplayGateIfNeeded() {
        guard isInitialVideoDisplayGatePrepared else { return }
        isInitialVideoDisplayGatePrepared = false
        isWaitingForInitialVideoDisplay = true
        initialVideoDisplayGateStartTime = avPlayer.currentTime().seconds
        initialVideoDisplayGateArmedAt = Date()
        Self.logger.info("[CMP-AVP] waiting for initial video frame before unmuting startup audio")
        cmpLog(
            "[CMP-AVP] initial video display gate armed startTime=\(initialVideoDisplayGateStartTime ?? .nan) startup=\(didCompleteInitialVideoDisplayGate ? 0 : 1) airplay=\(avPlayer.isExternalPlaybackActive ? 1 : 0) audioAnchor=\(loopbackBridgedAudioAnchorSeconds.map { String($0) } ?? "-")"
        )
    }

    /// A seek issued under an armed gate moves the playhead without any of it
    /// being watched picture, so the sustained-advance baseline has to follow
    /// it — otherwise the jump either releases the gate instantly (forward) or
    /// pins it open until the backstop (backward).
    private func rebaseInitialVideoDisplayGateStartTime(to playerSeconds: Double, context: String) {
        guard isWaitingForInitialVideoDisplay || isInitialVideoDisplayGatePrepared else { return }
        guard playerSeconds.isFinite else { return }
        initialVideoDisplayGateStartTime = playerSeconds
        cmpLog("[CMP-AVP] initial video display gate rebased startTime=\(playerSeconds) context=\(context)")
    }

    /// Every gate release funnels through this evaluation, whatever woke it
    /// (surface readiness, the periodic clock, a rate change). Two rules:
    ///
    /// * Permissive — a reanchor gate, or AirPlay. AirPlay renders on the
    ///   receiver, so `videoSurfaceBecameReadyForDisplay()` can never fire for
    ///   it; a reanchor re-arms against a layer that has already displayed
    ///   this player once. Both keep the original clock-advance release.
    /// * Startup — readiness plus sustained clock, no mode switch underway,
    ///   and (on bridged-audio routes) a playhead that has reached the audio
    ///   anchor. See the constants above for why readiness alone is not
    ///   enough on a tvOS display-criteria start.
    private func evaluateInitialVideoDisplayGate(trigger: String) {
        guard isWaitingForInitialVideoDisplay, let item = currentItem else { return }
        let current = avPlayer.currentTime().seconds
        guard current.isFinite else { return }
        let startTime = initialVideoDisplayGateStartTime ?? current

        guard !didCompleteInitialVideoDisplayGate, !avPlayer.isExternalPlaybackActive else {
            guard startTime.isFinite, current - startTime >= 0.05 else { return }
            finishInitialVideoDisplayGate(for: item, reason: "clock_advance", trigger: trigger)
            return
        }

        // A user who pauses under the gate freezes the clock; the sustained
        // signal can never arrive, so stop waiting for it rather than holding
        // a spinner over their deliberate pause until the backstop.
        if isUserPaused {
            finishInitialVideoDisplayGate(for: item, reason: "user_paused", trigger: trigger)
            return
        }

        guard initialVideoDisplayGateBlocker(current: current, startTime: startTime) == nil else { return }
        finishInitialVideoDisplayGate(for: item, reason: "ready_for_display_sustained", trigger: trigger)
    }

    /// The one condition still holding the startup gate, or nil when it is
    /// clear to release. Shared by the release path and the re-check tick so
    /// the console reports blockers in the same vocabulary either way.
    private func initialVideoDisplayGateBlocker(current: Double, startTime: Double) -> String? {
        if !didObserveVideoSurfaceReadyForDisplay { return "ready_for_display" }
        if isTVDisplayModeSwitchInProgress() { return "mode_switch" }
        if let anchor = loopbackBridgedAudioAnchorSeconds,
           anchor.isFinite,
           current < anchor + Self.initialVideoDisplayAudioAnchorLeadSeconds {
            return "audio_anchor"
        }
        guard startTime.isFinite,
              current - startTime >= initialVideoDisplayRequiredAdvanceSeconds else {
            return "clock_advance"
        }
        return nil
    }

    private var initialVideoDisplayRequiredAdvanceSeconds: Double {
        didApplyTVDisplayCriteriaForStart
            ? Self.initialVideoDisplaySustainedAdvanceSeconds
            : Self.initialVideoDisplayMinimumAdvanceSeconds
    }

    private func scheduleInitialVideoDisplayFallback(for item: AVPlayerItem) {
        guard initialVideoDisplayFallback == nil else { return }
        let work = DispatchWorkItem { [weak self, weak item] in
            // Clear the slot before any early return: this is the only
            // scheduler, so a work item that retires without releasing it
            // would leave the gate with no timeout at all.
            guard let self, !self.isDisposed else { return }
            self.initialVideoDisplayFallback = nil
            guard self.isWaitingForInitialVideoDisplay else { return }
            // The startup watchdog reloads the item in place under an open
            // gate, so follow it rather than leaving the new item uncovered.
            guard let item, item === self.currentItem else {
                if let current = self.currentItem {
                    self.scheduleInitialVideoDisplayFallback(for: current)
                }
                return
            }
            self.handleInitialVideoDisplayFallbackTick(for: item)
        }
        initialVideoDisplayFallback = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.initialVideoDisplayFallbackSeconds,
            execute: work
        )
    }

    /// Re-check tick. A start that is visibly progressing toward the real
    /// first frame re-arms; anything else lands on a bounded release, so the
    /// overlay can never strand.
    private func handleInitialVideoDisplayFallbackTick(for item: AVPlayerItem) {
        let armedAt = initialVideoDisplayGateArmedAt ?? Date()
        let elapsed = Date().timeIntervalSince(armedAt)
        // A reanchor gate keeps the flat timeout it has always had.
        guard !didCompleteInitialVideoDisplayGate, !avPlayer.isExternalPlaybackActive else {
            finishInitialVideoDisplayGate(for: item, reason: "ready_for_display_timeout", trigger: "fallback")
            return
        }
        guard elapsed < Self.initialVideoDisplayAbsoluteBackstopSeconds else {
            finishInitialVideoDisplayGate(for: item, reason: "absolute_backstop", trigger: "fallback")
            return
        }
        let current = avPlayer.currentTime().seconds
        let startTime = initialVideoDisplayGateStartTime ?? current
        let blocker = initialVideoDisplayGateBlocker(current: current, startTime: startTime)
        // No readiness at all by now means no surface will report one: an
        // audio-only item, or a host that cannot publish the signal. That is
        // the case this timeout has always covered, so keep covering it
        // instead of holding the overlay to the backstop.
        guard blocker != "ready_for_display" else {
            finishInitialVideoDisplayGate(for: item, reason: "ready_for_display_timeout", trigger: "fallback")
            return
        }
        // A blocker that cleared between the last wake and this tick still
        // needs releasing — nothing else is scheduled to notice.
        guard let blocker else {
            finishInitialVideoDisplayGate(for: item, reason: "ready_for_display_sustained", trigger: "fallback")
            return
        }
        cmpLog(
            "[CMP-AVP] initial video display gate waiting blocked=\(blocker) elapsedMs=\(Int(elapsed * 1000)) clockDelta=\(current - startTime)"
        )
        scheduleInitialVideoDisplayFallback(for: item)
    }

    private func finishInitialVideoDisplayGate(
        for item: AVPlayerItem,
        reason: String,
        trigger: String = "-"
    ) {
        guard item === currentItem, !isDisposed else { return }
        guard isWaitingForInitialVideoDisplay else {
            finishInitialLoadIfNeeded(for: item, reason: "not_needed")
            return
        }
        let armedAt = initialVideoDisplayGateArmedAt
        let startTime = initialVideoDisplayGateStartTime
        let current = avPlayer.currentTime().seconds
        isWaitingForInitialVideoDisplay = false
        didCompleteInitialVideoDisplayGate = true
        initialVideoDisplayGateStartTime = nil
        initialVideoDisplayGateArmedAt = nil
        initialVideoDisplayFallback?.cancel()
        initialVideoDisplayFallback = nil
        finishInitialLoadIfNeeded(for: item, reason: reason)
        if didTemporarilyMuteForInitialVideoDisplay {
            avPlayer.isMuted = false
            didTemporarilyMuteForInitialVideoDisplay = false
        }
        rampLoopbackBufferToSteadyStateIfNeeded(for: item)
        Self.logger.info("[CMP-AVP] initial video display gate released reason=\(reason, privacy: .public)")
        let elapsedMs = armedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        let clockDelta = startTime.map { current - $0 } ?? .nan
        let sinceSettleMs = tvDisplaySettleCompletedAt
            .map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        cmpLog(
            "[CMP-AVP] initial video display gate released reason=\(reason) trigger=\(trigger) elapsedMs=\(elapsedMs) clockDelta=\(clockDelta) advanceTarget=\(initialVideoDisplayRequiredAdvanceSeconds) current=\(current) readyForDisplay=\(didObserveVideoSurfaceReadyForDisplay ? 1 : 0) keepUp=\(item.isPlaybackLikelyToKeepUp ? 1 : 0) criteriaApplied=\(didApplyTVDisplayCriteriaForStart ? 1 : 0) switchInProgress=\(isTVDisplayModeSwitchInProgress() ? 1 : 0) sinceSettleMs=\(sinceSettleMs) audioAnchor=\(loopbackBridgedAudioAnchorSeconds.map { String($0) } ?? "-")"
        )
    }

    private enum LoopbackBufferPhase {
        case startup
        case steadyState
    }

    /// The single place AVPlayer's buffering policy is set for a loopback
    /// item. Remote routes keep AVFoundation's defaults — automatic buffering
    /// is genuinely useful over the WAN — so this returns without touching
    /// anything unless the active strategy is `.siloLoopback`.
    private func applyLoopbackItemBufferPolicy(to item: AVPlayerItem, phase: LoopbackBufferPhase) {
        guard case .some(.siloLoopback) = currentSourceStrategy else { return }
        switch phase {
        case .startup:
            avPlayer.automaticallyWaitsToMinimizeStalling = false
            item.preferredForwardBufferDuration = Self.loopbackStartupForwardBuffer
        case .steadyState:
            avPlayer.automaticallyWaitsToMinimizeStalling = true
            item.preferredForwardBufferDuration = Self.loopbackSteadyStateForwardBufferTarget
        }
        // Do not let AVPlayer poll the local EVENT playlist while paused:
        // under disk pressure the writer may pause appends until playback
        // frees spill capacity, and paused polling can then see an unchanged
        // playlist long enough for CoreMedia to fail the item.
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
    }

    /// Once the first frame is on screen, apply the steady-state target and
    /// re-enable automatic waiting. The mutation itself goes through
    /// `applyLoopbackItemBufferPolicy(to:phase:)` so there is one writer.
    private func rampLoopbackBufferToSteadyStateIfNeeded(for item: AVPlayerItem) {
        guard case .siloLoopback(let spec) = currentSourceStrategy else { return }
        guard canRampLoopbackBufferToSteadyState else { return }
        let generatedStats = latestLoopbackGeneratedStats
        let mediaBitrate = generatedStats?.rollingBitrateBps ?? spec.sourceBitrateBps
        let target = Self.loopbackSteadyStateForwardBufferTarget
        let shouldRaiseForwardBuffer = item.preferredForwardBufferDuration < target
        let shouldEnableAutomaticWaiting = !avPlayer.automaticallyWaitsToMinimizeStalling
        guard shouldRaiseForwardBuffer || shouldEnableAutomaticWaiting else { return }
        applyLoopbackItemBufferPolicy(to: item, phase: .steadyState)
        Self.logger.info(
            "[CMP-AVP] loopback buffer ramp forwardBuffer=\(target, privacy: .public)s automaticallyWaits=1 mediaBitrate=\(mediaBitrate ?? 0, privacy: .public)bps generatedBitrate=\(generatedStats?.rollingBitrateBps ?? 0, privacy: .public)bps declaredBitrate=\(spec.sourceBitrateBps ?? 0, privacy: .public)bps sourceReadBitrate=\(self.loopbackDemuxReadBitrateBps ?? 0, privacy: .public)bps targetDuration=\(generatedStats?.targetDuration ?? 0, privacy: .public) longestSegment=\(generatedStats?.longestSegmentDuration ?? 0, privacy: .public)"
        )
    }

    private var canRampLoopbackBufferToSteadyState: Bool {
        didFireFileLoaded && !isInitialVideoDisplayGatePrepared && !isWaitingForInitialVideoDisplay
    }

    private func itemHasSeekableMedia(_ item: AVPlayerItem, containing target: Double) -> Bool {
        let target = target.isFinite ? max(0, target) : 0
        if item.seekableTimeRanges.contains(where: { range in
            Self.timeRange(range.timeRangeValue, contains: target)
        }) {
            return true
        }

        return item.loadedTimeRanges.contains { range in
            Self.timeRange(range.timeRangeValue, contains: target)
        }
    }

    private static func timeRange(_ range: CMTimeRange, contains target: Double) -> Bool {
        let start = range.start.seconds
        let duration = range.duration.seconds
        let end = (range.start + range.duration).seconds
        guard start.isFinite, duration.isFinite, end.isFinite, duration > 0 else {
            return false
        }
        let tolerance = 0.05
        return target + tolerance >= start && target <= end + tolerance
    }

    private func isInitialSeekSatisfied(target: Double, landed: Double) -> Bool {
        guard target.isFinite, landed.isFinite else { return false }
        return abs(landed - target) <= 1.0
    }

    /// `reason` is the gate's real release reason, forwarded so the view
    /// model's overlay-dismissal line names it instead of a blanket
    /// `first_frame`. `not_needed` means no gate was ever armed for this load.
    private func finishInitialLoadIfNeeded(for item: AVPlayerItem, reason: String) {
        guard !didFireFileLoaded else { return }
        cancelLoopbackStartupWatchdog()
        didFireFileLoaded = true
        onFileLoaded?(reason)
        loadMediaSelections(for: item)
        onChaptersChange?(serverChapters)
        emitPlaybackStats(referenceTime: currentTime(), force: true)
        logReadyItemFormat(item)
        logTVDisplayManagerState(context: "item_ready")
    }

    private func loadMediaSelections(for item: AVPlayerItem) {
        audioSelectionState = nil
        subtitleSelectionState = nil
        emitTrackList()

        let asset = item.asset
        if currentLoopbackAudioTracks.isEmpty {
            asset.loadMediaSelectionGroup(for: .audible) { [weak self, weak item] group, error in
                DispatchQueue.main.async { [weak self, weak item] in
                    guard let self, let item, !self.isDisposed, item === self.currentItem else { return }
                    self.updateMediaSelectionState(group: group, kind: .audio, error: error)
                }
            }
        }
        asset.loadMediaSelectionGroup(for: .legible) { [weak self, weak item] group, error in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item, !self.isDisposed, item === self.currentItem else { return }
                self.updateMediaSelectionState(group: group, kind: .sub, error: error)
            }
        }
    }

    private func updateMediaSelectionState(
        group: AVMediaSelectionGroup?,
        kind: PlayerTrack.Kind,
        error: Error?
    ) {
        if let error {
            Self.logger.warning(
                "Failed loading \(kind.rawValue, privacy: .public) tracks: \(error.localizedDescription, privacy: .public)"
            )
        }

        let state = group.flatMap { makeMediaSelectionState(group: $0, kind: kind) }
        switch kind {
        case .audio:
            audioSelectionState = state
        case .sub:
            subtitleSelectionState = state
        case .video, .unknown:
            break
        }
        emitTrackList()
    }

    private func makeMediaSelectionState(
        group: AVMediaSelectionGroup,
        kind: PlayerTrack.Kind
    ) -> MediaSelectionState? {
        let options = AVMediaSelectionGroup.playableMediaSelectionOptions(from: group.options)
        guard !options.isEmpty else { return nil }

        var optionsByTrackId: [Int64: AVMediaSelectionOption] = [:]
        for (index, option) in options.enumerated() {
            optionsByTrackId[makeTrackId(for: kind, index: index)] = option
        }

        return MediaSelectionState(
            kind: kind,
            group: group,
            optionsByTrackId: optionsByTrackId
        )
    }

    private func emitTrackList() {
        guard let item = currentItem else {
            onTracksChange?([])
            return
        }

        var tracks: [PlayerTrack] = []
        if !currentLoopbackAudioTracks.isEmpty {
            tracks.append(contentsOf: currentLoopbackAudioTracks)
        } else if let audioSelectionState {
            let mediaSelection = item.currentMediaSelection
            tracks.append(
                contentsOf: buildTracks(
                    from: audioSelectionState,
                    selectedOption: mediaSelection.selectedMediaOption(in: audioSelectionState.group)
                )
            )
        }
        let extractedSubtitles = embeddedSubtitleExtractor?
            .playerTracks(selectedPrimaryTrackId: selectedControlledSubtitleTrackId) ?? []
        tracks.append(contentsOf: extractedSubtitles)
        onTracksChange?(tracks)
    }

    private func buildTracks(
        from state: MediaSelectionState,
        selectedOption: AVMediaSelectionOption?
    ) -> [PlayerTrack] {
        state.optionsByTrackId.keys.sorted().compactMap { trackId in
            guard let option = state.optionsByTrackId[trackId] else { return nil }
            let isSelected = selectedOption.map { ObjectIdentifier($0) == ObjectIdentifier(option) } ?? false
            let isHearingImpaired = option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
                || option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
            return PlayerTrack(
                trackId: trackId,
                kind: state.kind,
                title: normalizedTitle(for: option),
                lang: languageCode(for: option),
                codec: codecLabel(for: option),
                audioChannelsLayout: nil,
                audioChannelCount: nil,
                bitrate: nil,
                isDefault: state.group.defaultOption.map { ObjectIdentifier($0) == ObjectIdentifier(option) } ?? false,
                isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
                isHearingImpaired: isHearingImpaired,
                isVisualImpaired: option.hasMediaCharacteristic(.describesVideoForAccessibility),
                isExternal: false,
                isSelected: isSelected,
                ffIndex: nil,
                srcId: nil
            )
        }
    }

    private func makeTrackId(for kind: PlayerTrack.Kind, index: Int) -> Int64 {
        let base: Int64
        switch kind {
        case .audio:
            base = 10_000
        case .sub:
            base = 20_000
        case .video:
            base = 30_000
        case .unknown:
            base = 40_000
        }
        return base + Int64(index)
    }

    private func normalizedTitle(for option: AVMediaSelectionOption) -> String? {
        let value = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func languageCode(for option: AVMediaSelectionOption) -> String? {
        if let localeCode = option.locale?.language.languageCode?.identifier, !localeCode.isEmpty {
            return localeCode
        }
        if let tag = option.extendedLanguageTag?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tag.isEmpty {
            return tag.split(separator: "-").first.map(String.init)
        }
        return nil
    }

    private func codecLabel(for option: AVMediaSelectionOption) -> String? {
        guard let subtype = option.mediaSubTypes.first?.uint32Value else { return nil }
        let bytes: [UInt8] = [
            UInt8((subtype >> 24) & 0xFF),
            UInt8((subtype >> 16) & 0xFF),
            UInt8((subtype >> 8) & 0xFF),
            UInt8(subtype & 0xFF)
        ]
        guard let code = String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !code.isEmpty else {
            return nil
        }
        return code
    }

    private func pumpSubtitleOverlay(referenceTime: Double) {
        guard let session = subtitleSession else { return }
        guard let overlay = subtitleOverlay else { return }
        let renderer = session.underlyingRenderer
        let hasTextTrack = renderer.hasAnyActiveTrack
        let hasBitmapTrack = session.hasActiveBitmapTrack
        guard hasTextTrack || hasBitmapTrack else {
            lastBitmapCueRenderKey = nil
            textOverlayMayHaveFrame = false
            DispatchQueue.main.async {
                overlay.clear()
            }
            return
        }

        // One sync-adjusted clock for both render paths.
        let nowMs = Int64(referenceTime * 1000.0)
        let syncOffsetMs = Int64(session.currentParams.syncOffsetMs)
        let adjustedNowMs = nowMs - syncOffsetMs
        let bounds = overlay.bounds
        let videoInsets = overlay.videoInsets

        if hasTextTrack {
            textOverlayMayHaveFrame = true
            #if os(macOS)
            let scale = overlay.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            #else
            let scale = overlay.window?.screen.scale ?? overlay.traitCollection.displayScale
            #endif
            guard subPumpRendersInFlight < 2 else { return }
            subPumpRendersInFlight += 1
            renderer.sessionQueue.async { [weak overlay, weak self] in
                let out = renderer.renderOnSessionQueue(
                    atMilliseconds: adjustedNowMs,
                    frameSize: bounds.size,
                    scale: scale,
                    videoInsets: videoInsets
                )
                DispatchQueue.main.async {
                    if let self {
                        self.subPumpRendersInFlight = max(0, self.subPumpRendersInFlight - 1)
                    }
                    guard out.isDirty else { return }
                    overlay?.updateContents(out.image, frame: out.imageFrame)
                }
            }
        } else if textOverlayMayHaveFrame {
            // A slot just switched away from libass (e.g. text → bitmap
            // track): don't let the last composited text frame linger.
            // One-shot, and funneled through the render queue so it lands
            // after any render still in flight from the previous tick.
            textOverlayMayHaveFrame = false
            renderer.sessionQueue.async { [weak overlay] in
                DispatchQueue.main.async {
                    overlay?.updateContents(nil)
                }
            }
        }

        if hasBitmapTrack {
            pumpBitmapCues(
                session: session,
                overlay: overlay,
                atSeconds: Double(adjustedNowMs) / 1000.0,
                bounds: bounds,
                videoInsets: videoInsets
            )
        } else if lastBitmapCueRenderKey != nil {
            lastBitmapCueRenderKey = nil
            DispatchQueue.main.async {
                overlay.clearBitmapCues()
            }
        }
    }

    private func pumpBitmapCues(
        session: SubtitleSession,
        overlay: SubtitleOverlayView,
        atSeconds seconds: Double,
        bounds: CGRect,
        videoInsets: SubtitleVideoInsets
    ) {
        let cues = session.activeBitmapCues(at: seconds)
        // Normalized cue rects are relative to the displayed video, not the
        // overlay: on tvOS the overlay covers the full frame (so libass can
        // place text in the letterbox bars) and `videoInsets` marks the
        // video rect inside it; on iOS/macOS the overlay is framed to the
        // video and the insets are zero, so this reduces to `bounds`.
        let videoRect = CGRect(
            x: bounds.minX + videoInsets.left,
            y: bounds.minY + videoInsets.top,
            width: max(0, bounds.width - videoInsets.left - videoInsets.right),
            height: max(0, bounds.height - videoInsets.top - videoInsets.bottom)
        )
        let key = BitmapCueRenderKey(
            videoRect: videoRect,
            images: cues.map { ObjectIdentifier($0.image) }
        )
        guard key != lastBitmapCueRenderKey else { return }
        lastBitmapCueRenderKey = key
        let placements = cues.map { cue in
            Self.bitmapCuePlacement(for: cue, in: videoRect)
        }
        DispatchQueue.main.async {
            overlay.updateBitmapCues(placements)
        }
    }

    /// Lay out one bitmap cue exactly as authored: the normalized frame
    /// mapped onto the displayed video rect. PGS/DVD compositions are
    /// pre-rendered pictures — size, placement, and background are part
    /// of the content, so no appearance preferences are applied.
    private static func bitmapCuePlacement(
        for cue: BitmapSubtitleCue,
        in videoRect: CGRect
    ) -> BitmapCuePlacement {
        BitmapCuePlacement(
            image: cue.image,
            frame: CGRect(
                x: videoRect.minX + cue.normalizedFrame.origin.x * videoRect.width,
                y: videoRect.minY + cue.normalizedFrame.origin.y * videoRect.height,
                width: cue.normalizedFrame.width * videoRect.width,
                height: cue.normalizedFrame.height * videoRect.height
            )
        )
    }

    private func teardownMediaPipeline(
        clearDisplayCriteria: Bool = true,
        deactivateAudioSession: Bool = true
    ) {
        cancelSeekDeadline()
        // Only `handleFirstSegmentReady` consumes this latch, so a session
        // whose writer never reported a first segment would hand it to the
        // next load and suppress that load's HDMI settle wait. `load()`
        // re-sets it right after this teardown, so clearing here is scoped to
        // the retired session.
        isPreservingTVDisplayCriteriaForReload = false
        if clearDisplayCriteria {
            clearTVDisplayCriteria(context: "teardown")
        } else {
            logTVDisplayManagerState(context: "preserve_for_loopback_reload")
        }
        avPlayer.pause()
        if let observer = timeObserver {
            avPlayer.removeTimeObserver(observer)
            timeObserver = nil
        }
        subtitleDisplayLink?.invalidate()
        subtitleDisplayLink = nil
        subPumpRendersInFlight = 0
        loopbackPlayheadWatchdog?.invalidate()
        loopbackPlayheadWatchdog = nil
        detachPerItemObservers()
        audioSelectionState = nil
        subtitleSelectionState = nil
        currentLoopbackAudioTracks = []
        selectedControlledSubtitleTrackId = nil
        selectedSecondaryControlledSubtitleTrackId = nil
        selectedBitmapTapStreamIndex = nil
        bitmapTapAvailableStreams = []
        sidecarDescriptorsByTrackId.removeAll()
        // Stop live forwarding; the cue STORE survives so a reanchor of the
        // same source re-enables instantly (ensureLoopbackSubtitleTap
        // resets it when the source changes).
        loopbackSubtitleTap?.deactivate()
        embeddedSubtitleExtractor?.teardown()
        loopbackPlaylistName = nil
        loopbackPlaybackUsesExternalURL = false
        isInitialSeekInFlight = false
        isInitialVideoDisplayGatePrepared = false
        isWaitingForInitialVideoDisplay = false
        initialVideoDisplayGateStartTime = nil
        initialVideoDisplayGateArmedAt = nil
        didObserveVideoSurfaceReadyForDisplay = false
        loopbackBridgedAudioAnchorSeconds = nil
        tvDisplaySettleCompletedAt = nil
        didApplyTVDisplayCriteriaForStart = false
        initialVideoDisplayFallback?.cancel()
        initialVideoDisplayFallback = nil
        cancelLoopbackStartupWatchdog()
        displayModeSettleTask?.cancel()
        displayModeSettleTask = nil
        if didTemporarilyMuteForInitialVideoDisplay {
            avPlayer.isMuted = false
            didTemporarilyMuteForInitialVideoDisplay = false
        }
        avPlayer.replaceCurrentItem(with: nil)
        if deactivateAudioSession {
            self.deactivateAudioSession()
        }
        currentItem = nil
        subtitleSession?.teardown()
        lastBitmapCueRenderKey = nil
        textOverlayMayHaveFrame = false
        DispatchQueue.main.async { [weak self] in
            self?.subtitleOverlay?.clear()
        }

        latestLoopbackGeneratedStats = nil
        // The producer, the server, the store and the session directory go
        // with the host. Its plan is source-keyed and outlives it: the next
        // session's writer has to be handed the same segment grid. Only a
        // teardown that actually retires a host refreshes the carry — a
        // native-route load must leave the last loopback plan where it was,
        // exactly as the plan fields did when they lived here.
        if let host = loopbackHost {
            carriedVODPlan = host.resolvedVODPlan
            host.teardown()
            loopbackHost = nil
        }
    }

    /// Loopback URLs carry the segment server's per-session access token as
    /// their first path component, and the diagnostics redactor keeps URL
    /// paths — so the raw string would ship the secret in a support bundle.
    private func loggableURLDescription(_ url: URL) -> String {
        redactedLogText(url.absoluteString)
    }

    private func redactedLogText(_ value: String) -> String {
        segmentServer?.redactingAccessToken(in: value) ?? value
    }

    private func reportFailure(_ failure: PlaybackFailure) {
        cmpLog("[CMP-AVP] ERROR: \(failure.legacyMessage)")
        onError?(failure)
    }

    /// Triage a `LoopbackWriterError` into the typed failure channel. Switching
    /// over the writer's own cases keeps the view model out of the business of
    /// re-reading a reflected description.
    private static func writerFailureKind(for error: Error) -> PlaybackFailure.WriterFailureKind {
        guard let writerError = error as? LoopbackWriterError else { return .other }
        switch writerError {
        case .prematureSourceEnd:
            return .prematureSourceEnd
        case .initSegmentMissing:
            return .initSegmentMissing
        case .unsupportedSelectedAudioCodec:
            return .unsupportedSelectedAudioCodec
        case .allocInput, .allocOutput, .allocPacket, .openInput, .seekInput,
             .findStreamInfo, .noStreams:
            return .sourceUnavailable
        case .writeHeader, .audioTranscodeSetup, .bootstrapFailed,
             .profile81ConversionFailed, .profile5ConfigUnusable, .muxWriteFailures,
             .fileWriteFailed, .vodMoovBlocked, .vodStartupConsumerWedge:
            return .remux
        }
    }

    private func logReadyItemFormat(_ item: AVPlayerItem) {
        Task { [item] in
            let videoFormat = await AVFoundationPlaybackIntrospection.videoFormat(for: item)
            let audioFormat = await AVFoundationPlaybackIntrospection.audioStream(for: item)
            cmpLog("[CMP-AVP] item ready format videoCodec=\(videoFormat.stream.codec ?? "nil") videoDetail=\(videoFormat.stream.detail ?? "nil") dynamicRange=\(videoFormat.dynamicRange ?? "nil") audioCodec=\(audioFormat.codec ?? "nil") audioDetail=\(audioFormat.detail ?? "nil")")
        }
    }

    private func logTVDisplayManagerState(context: String) {
        #if os(tvOS)
        guard let displayManager = TVDisplayCriteria.activeTVWindow()?.avDisplayManager else {
            cmpLog("[CMP-AVP] tv display context=\(context) manager=nil")
            return
        }
        cmpLog("[CMP-AVP] tv display context=\(context) matching=\(displayManager.isDisplayCriteriaMatchingEnabled ? 1 : 0) switchInProgress=\(displayManager.isDisplayModeSwitchInProgress ? 1 : 0)")
        #endif
    }

    /// Writes the HDMI display criteria for the upcoming loopback item.
    /// Returns true when a dynamic-range switch was requested and the caller
    /// should wait for it to settle before creating the AVPlayerItem. Both
    /// the gated non-DV HDR path and a fresh DV apply wait: tvOS 26.5
    /// validates a master variant's VIDEO-RANGE against the panel's CURRENT
    /// mode, synchronously, before fetching the init segment — creating the
    /// item mid-switch fails with -11868 (underlying -17223) and drops the
    /// session to the next fallback rung. AetherEngine orders the same way
    /// (criteria apply → settle wait → build player).
    @discardableResult
    private func applyTVDisplayCriteriaForLoopbackIfNeeded(context: String) -> Bool {
        #if os(tvOS)
        guard case .siloLoopback(let spec) = currentSourceStrategy else { return false }
        let selection = HDRDisplayCriteriaPolicy.selection(
            videoMode: spec.videoMode,
            manifestVideoRange: spec.manifestMetadata.videoRange,
            hdrGateEnabled: HDRDisplayCriteriaPolicy.isEnabled()
        )
        let preservedForReload = isPreservingTVDisplayCriteriaForReload
        isPreservingTVDisplayCriteriaForReload = false
        let refreshRate = spec.sourceVideoFrameRate ?? 24.0
        switch selection {
        case .dolbyVision(let baseLayer):
            // `handleFirstSegmentReady` (the only caller) is dispatched onto
            // the main queue by the writer callback. `setCriteria` uses the
            // public format-description initializer with the `dvh1` fourcc.
            let outcome = MainActor.assumeIsolated {
                TVDisplayCriteria.setCriteria(
                    .dolbyVision(baseLayer: baseLayer),
                    refreshRate: refreshRate
                )
            }
            switch outcome {
            case .noDisplayManager:
                cmpLog("[CMP-AVP] tv display apply context=\(context) manager=nil")
            case .matchingDisabled:
                cmpLog("[CMP-AVP] tv display apply context=\(context) matching=0 skipped=matching_disabled")
            case .applied:
                didApplyTVDisplayCriteriaForStart = true
                cmpLog(String(format: "[CMP-AVP] tv display apply context=%@ fps=%.3f format=dolbyVision(%@) matching=1 preservedReload=%d", context, Double(refreshRate), baseLayer == .hlg ? "hlg" : "hdr10", preservedForReload ? 1 : 0))
                // A reload that preserved criteria left the panel in the
                // right mode already; only a fresh apply can start an HDMI
                // negotiation the item creation must not race. The settle
                // helper watches the bounded switch-start window even when
                // EDR is already elevated because HDR10 and Dolby Vision are
                // indistinguishable from headroom alone.
                return !preservedForReload
            case .formatUnavailable:
                break
            }
            return false
        case .hdr10, .hlg:
            let range = selection == .hlg ? "HLG" : "PQ"
            let outcome = MainActor.assumeIsolated {
                TVDisplayCriteria.setCriteria(
                    selection == .hlg ? .hlg : .hdr10,
                    refreshRate: refreshRate
                )
            }
            if outcome.didWrite { didApplyTVDisplayCriteriaForStart = true }
            cmpLog(String(format: "[CMP-AVP] tv display apply hdr context=%@ range=%@ fps=%.3f outcome=%@ preservedReload=%d", context, range, Double(refreshRate), String(describing: outcome), preservedForReload ? 1 : 0))
            // A reload that preserved criteria left the panel in the right
            // mode already; rewriting identical criteria triggers no new
            // negotiation, so only a fresh apply needs the settle wait.
            return outcome.didWrite && !preservedForReload
        case .none:
            return false
        }
        #else
        return false
        #endif
    }

    private func clearTVDisplayCriteria(context: String) {
        #if os(tvOS)
        DispatchQueue.main.async {
            guard let displayManager = TVDisplayCriteria.activeTVWindow()?.avDisplayManager else {
                cmpLog("[CMP-AVP] tv display clear context=\(context) manager=nil")
                return
            }
            displayManager.preferredDisplayCriteria = nil
            cmpLog("[CMP-AVP] tv display clear context=\(context) switchInProgress=\(displayManager.isDisplayModeSwitchInProgress ? 1 : 0)")
        }
        #endif
    }

    private func reportItemFailure(_ item: AVPlayerItem) {
        let nsError = item.error as NSError?
        let domain = nsError?.domain ?? "unknown"
        let code = nsError?.code ?? 0
        let description = nsError?.localizedDescription ?? "AVPlayer item failed"
        let failingURL = (nsError?.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            .map(loggableURLDescription)
        let underlying = (nsError?.userInfo[NSUnderlyingErrorKey] as? NSError).map {
            "\($0.domain)(\($0.code)): \($0.localizedDescription)"
        }
        let latestErrorLog = item.errorLog()?.events.last.map { event in
            let uri = event.uri.map(redactedLogText) ?? "nil"
            let comment = event.errorComment ?? "nil"
            return "uri=\(uri) status=\(event.errorStatusCode) domain=\(event.errorDomain) comment=\(comment)"
        }

        reportFailure(.itemFailed(PlaybackFailure.ItemFailure(
            description: description,
            domain: domain,
            code: code,
            failingURL: failingURL,
            underlying: underlying,
            errorLog: latestErrorLog
        )))
    }

    private static func describe(_ strategy: SourceStrategy) -> String {
        switch strategy {
        case .remoteHLS(let url, _):
            return "remoteHLS(\(url.absoluteString))"
        case .remoteDirect(let url, _):
            return "remoteDirect(\(url.absoluteString))"
        case .siloLoopback(let spec):
            return "siloLoopback(\(spec.sourceURL.absoluteString), videoMode=\(spec.videoMode.logToken), start=\(spec.sourceStartTimeSeconds), audioTrackIndex=\(spec.selectedAudio.trackIndex), audioFfIndex=\(spec.selectedAudio.ffIndex ?? -1))"
        }
    }

    private static func displayRouteLabel(_ strategy: SourceStrategy) -> String {
        switch strategy {
        case .remoteHLS:
            return "Native Player HLS"
        case .remoteDirect:
            return "Native Player Direct"
        case .siloLoopback(let spec):
            switch spec.videoMode {
            case .passthroughH264:
                return "SiloPlayer (H.264)"
            case .passthroughHEVC:
                return "SiloPlayer (HEVC)"
            case .passthroughProfile5, .convertProfile7To81, .passthroughProfile8:
                return "SiloPlayer (Dolby Vision)"
            }
        }
    }

    private static func normalizedLoopbackAudioTracks(for strategy: SourceStrategy) -> [PlayerTrack] {
        switch strategy {
        case .siloLoopback(let spec):
            let audioTracks = spec.availableAudioTracks
            guard !audioTracks.isEmpty else { return [] }
            if audioTracks.contains(where: { $0.isSelected }) {
                return audioTracks
            }
            return audioTracks.enumerated().map { index, track in
                track.selecting(index == 0)
            }
        case .remoteHLS, .remoteDirect:
            return []
        }
    }

    /// The loopback audio decision lives in `ApplePlaybackRoutePlanner` so an
    /// in-place audio-track switch resolves exactly the same output mode (and
    /// Atmos claim) as the initial route plan.
    private static func loopbackAudioOutputMode(for track: PlayerTrack) -> LoopbackSessionSpec.AudioOutputMode {
        ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track)
    }

    private static func loopbackPreservesAtmos(for track: PlayerTrack) -> Bool {
        ApplePlaybackRoutePlanner.loopbackAudioPreservesAtmos(for: track)
    }
}

/// `AVPlayerBackend` already declares every member of `PlaybackBackend`, so
/// this is a declaration-only conformance — no member is added, moved or
/// reworded here. Both the protocol and the class are nonisolated (see
/// `PlaybackBackend` for why), so the extension changes no isolation; it keeps
/// the conformance out of the class body, where nothing else states it.
extension AVPlayerBackend: PlaybackBackend {}

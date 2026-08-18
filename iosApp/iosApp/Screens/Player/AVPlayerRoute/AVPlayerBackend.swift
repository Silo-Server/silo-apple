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

/// Session-scoped budget for full Silo loopback session rebuilds.
///
/// The starvation/exhaustion latch that guards a rebuild (`didEscalateLoopbackStall`)
/// is cleared *by* the rebuild it guards, so on its own it bounds nothing
/// across sessions: a title that wedges the same way every time rebuilds
/// forever. The budget is the outer bound — once it is spent the backend
/// reports the failure and the view model's ladder owns the decision.
struct LoopbackRebuildBudget {
    static let maximumRebuildsPerLoad = 2

    private(set) var used = 0

    var isExhausted: Bool { used >= Self.maximumRebuildsPerLoad }

    /// Spends one rebuild. Returns false when the budget is exhausted, in
    /// which case the caller must not rebuild.
    mutating func consume() -> Bool {
        guard !isExhausted else { return false }
        used += 1
        return true
    }

    mutating func reset() {
        used = 0
    }
}

struct LoopbackItemDeathRecoveryState {
    enum Action: Equatable {
        case waitForConfirmation
        case reload(attempt: Int)
        case escalate
    }

    static let matchingPositionToleranceSeconds = 2.0
    static let evidenceRequired = 2
    static let maximumReloads = 1

    private var anchorPosition: Double?
    private var evidence = 0
    private var reloads = 0

    static func isItemDeath(statusCode: Int?, errorDescription: String) -> Bool {
        statusCode == -12889
            || statusCode == -15628
            || errorDescription.contains("-12889")
            || errorDescription.contains("No response for media file")
    }

    mutating func record(
        position: Double,
        evidenceWeight: Int,
        userPaused: Bool
    ) -> Action {
        guard !userPaused else { return .waitForConfirmation }
        let normalized = position.isFinite ? max(0, position) : 0
        if let anchorPosition,
           abs(anchorPosition - normalized) > Self.matchingPositionToleranceSeconds {
            evidence = 0
            reloads = 0
        }
        anchorPosition = normalized
        evidence += max(evidenceWeight, 1)
        guard evidence >= Self.evidenceRequired else { return .waitForConfirmation }
        evidence = 0
        return confirm(position: normalized, userPaused: userPaused)
    }

    mutating func confirm(position: Double, userPaused: Bool) -> Action {
        guard !userPaused else { return .waitForConfirmation }
        let normalized = position.isFinite ? max(0, position) : 0
        if let anchorPosition,
           abs(anchorPosition - normalized) > Self.matchingPositionToleranceSeconds {
            reloads = 0
        }
        anchorPosition = normalized
        evidence = 0
        guard reloads < Self.maximumReloads else { return .escalate }
        reloads += 1
        return .reload(attempt: reloads)
    }

    mutating func reset() {
        anchorPosition = nil
        evidence = 0
        reloads = 0
    }
}

/// Confirms AVFoundation's terminal-item failure mode without mistaking an
/// intentional pause for a dead item. A failed item can remain `.readyToPlay`
/// while AVPlayer parks at rate 0 / `.paused`, so item status alone is not a
/// useful health signal. The explicit play-intent latch is authoritative.
struct LoopbackItemDeathConfirmationState {
    enum Trigger: String, Equatable {
        case failedToEnd = "failed_to_end"
        case unexpectedPause = "unexpected_pause"
    }

    enum TransportState: Equatable {
        case paused
        case waiting
        case playing
        case unknown
    }

    enum Action: Equatable {
        case none
        case reassertPlay
        case confirmed(trigger: Trigger)
    }

    static let confirmationSeconds = 3.0
    static let progressCancellationThresholdSeconds = 0.5

    private struct Candidate {
        let trigger: Trigger
        let position: Double
        let startedAt: Double
    }

    private var candidate: Candidate?

    mutating func noteExplicitFailure(
        position: Double,
        now: Double,
        playbackEstablished: Bool,
        userPaused: Bool
    ) {
        guard playbackEstablished, !userPaused else {
            candidate = nil
            return
        }
        candidate = Candidate(
            trigger: .failedToEnd,
            position: normalized(position),
            startedAt: now
        )
    }

    mutating func evaluate(
        now: Double,
        position: Double,
        playbackEstablished: Bool,
        userPaused: Bool,
        transportState: TransportState,
        recoverySuppressed: Bool,
        mediaAvailableAhead: Bool
    ) -> Action {
        guard playbackEstablished, !userPaused, !recoverySuppressed else {
            candidate = nil
            return .none
        }

        let currentPosition = normalized(position)
        if let candidate {
            if abs(currentPosition - candidate.position)
                > Self.progressCancellationThresholdSeconds {
                self.candidate = nil
                return .none
            }
            if candidate.trigger == .unexpectedPause, transportState != .paused {
                self.candidate = nil
                return .none
            }
            guard now - candidate.startedAt >= Self.confirmationSeconds else {
                return .none
            }
            self.candidate = nil
            if candidate.trigger == .failedToEnd, transportState == .playing {
                return .none
            }
            return .confirmed(trigger: candidate.trigger)
        }

        guard transportState == .paused, mediaAvailableAhead else { return .none }
        candidate = Candidate(
            trigger: .unexpectedPause,
            position: currentPosition,
            startedAt: now
        )
        return .reassertPlay
    }

    mutating func resetCandidate() {
        candidate = nil
    }

    mutating func reset() {
        candidate = nil
    }

    private func normalized(_ position: Double) -> Double {
        position.isFinite ? max(0, position) : 0
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
    /// segment GETs were flowing the whole time). Ticks at 1 Hz while the
    /// item is not yet ready. Escalates the recovery ladder (nudge seek →
    /// in-place item reload → route fallback) only when the loopback server
    /// has served no request for `loopbackStartupStallWindowSeconds` — a
    /// dead loader stops fetching within seconds, so genuine failures now
    /// fall back *faster* than the old timeout, while slow heavy muxes get
    /// all the time they need. The absolute backstop bounds the pathological
    /// "fetches forever, never ready" consumer.
    private static let loopbackStartupWatchdogTickSeconds: TimeInterval = 1.0
    private static let loopbackStartupStallWindowSeconds: TimeInterval = 6.0
    private static let loopbackStartupAbsoluteBackstopSeconds: TimeInterval = 60.0
    private static let seekCompletionDeadlineSeconds: TimeInterval = 15.0

    /// Local DV loopback playhead watchdog. Driven by an independent wall-clock
    /// timer (AVPlayer's periodic time observer stops firing when the playhead
    /// freezes, so it cannot detect a stationary playhead on its own). When
    /// AVPlayer believes it is playing but the playhead has not advanced for
    /// `playheadWatchdogStallSeconds` while generated media is available ahead,
    /// reanchor the loopback. After `playheadWatchdogMaxReanchors` failed
    /// attempts inside `playheadWatchdogReanchorWindowSeconds`, rebuild the
    /// complete Silo loopback pipeline at the rendered clock.
    private static let playheadWatchdogTickSeconds: TimeInterval = 1.0
    private static let playheadWatchdogStallSeconds: Double = 10.0
    /// Kept above the reanchor path's own steady-state `generatedAhead`
    /// threshold (10 s) so a watchdog trigger never bails inside recovery.
    private static let playheadWatchdogMinGeneratedAhead: Double = 12.0
    private static let playheadWatchdogMaxReanchors = 3
    private static let playheadWatchdogReanchorWindowSeconds: Double = 90.0
    /// Starvation escalation: the reanchor path requires generated media
    /// ahead of the playhead, so a *producer-dead* stall (e.g. the spill
    /// gate deadlock) never qualified and the session froze forever. If
    /// AVPlayer has been waiting on an empty buffer this long while the
    /// store served nothing, rebuild the local pipeline at the rendered
    /// clock. The serve-quiet guard keeps ordinary slow-WAN rebuffers
    /// (segments still flowing) from tripping it.
    private static let playheadWatchdogStarvationEscalateSeconds: Double = 30.0
    private static let playheadWatchdogStarvationServeQuietSeconds: Double = 15.0
    private static let generatedHLSSpillBudgetBytes: Int64 = 4 * 1024 * 1024 * 1024
    private static var loopbackSegmentStoreMemoryBudgetBytes: Int {
        PlaybackSourceCache.isConstrainedMemoryDevice ? 96 * 1024 * 1024 : 128 * 1024 * 1024
    }

    /// Temporary [CMP-MEM] instrumentation: resident footprint as jetsam
    /// accounts it. `phys_footprint` is the number the per-process limit
    /// is enforced against (not `resident_size`), and
    /// `os_proc_available_memory` is the headroom left before the kill —
    /// together they attribute working-set growth directly from a capture
    /// of a memory termination.
    private static func memoryFootprintMiB() -> (footprint: Double, available: Double)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // os_proc_available_memory is iOS/tvOS-only; macOS has no
        // per-process jetsam limit to report headroom against.
        #if os(iOS) || os(tvOS)
        let available = Double(os_proc_available_memory()) / 1_048_576
        #else
        let available = -1.0
        #endif
        return (
            footprint: Double(info.phys_footprint) / 1_048_576,
            available: available
        )
    }

    /// Forward-buffer target for the local DV loopback. The static VOD
    /// playlist keeps AVPlayer's explicit target at one nominal segment;
    /// resilience comes from the disk-backed producer/cache window instead:
    /// AVPlayer stays paced while ten forward segments remain immediately
    /// fetchable. This mirrors AetherEngine's proven loopback-HLS policy.
    static let loopbackSteadyStateForwardBufferTarget = loopbackStartupForwardBuffer

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
    var onFileLoaded: (() -> Void)?
    var onFirstFrame: ((Int) -> Void)?
    var onError: ((PlaybackFailure) -> Void)?
    var onEndOfFile: (() -> Void)?
    var onBufferingChange: ((Bool) -> Void)?
    var onBufferedAheadChange: ((Double) -> Void)?
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
    /// Temporary [CMP-MEM]: source-proxy cache stats for the periodic
    /// footprint log line. The proxy is owned by PlayerViewModel, so it is
    /// injected as a closure rather than held here.
    var proxyStatsProvider: (() -> PlaybackSourceProxyStats?)?
    /// Live query into the source proxy's outage state; handed to writers so
    /// their blocking source reads can park through a flagged outage. Owned
    /// by PlayerViewModel like `proxyStatsProvider`.
    var sourceOutageStateProvider: (() -> Bool)?
    /// Reasons an external owner has asked the backend to hold every in-route
    /// recovery ladder. Reason-keyed because two owners can overlap: the
    /// view model's origin-outage ride-through and a view-model-owned server
    /// replan. While any reason is held the route isn't the thing that broke
    /// — the view model owns the terminal decision — so the backend keeps
    /// observing and logging but takes no recovery action.
    private var recoverySuspensionReasons: Set<String> = []
    /// Reason key for the view model's origin-outage ride-through.
    static let originOutageRecoverySuspensionReason = "origin_outage"
    /// Reason key for a view-model-owned server replan: the view model sets
    /// this for the whole replan round trip so backend ladders cannot
    /// reanchor, reload or rebuild the session mid-negotiation.
    static let serverReplanRecoverySuspensionReason = "server_replan"

    private var isRecoverySuspended: Bool { !recoverySuspensionReasons.isEmpty }

    /// Suspends (or resumes) every in-route recovery ladder for one owner.
    /// Suspension is reference-counted by `reason`, so one owner clearing its
    /// reason does not release another owner's hold.
    func setRecoverySuspended(_ suspended: Bool, reason: String) {
        let changed = suspended
            ? recoverySuspensionReasons.insert(reason).inserted
            : (recoverySuspensionReasons.remove(reason) != nil)
        guard changed else { return }
        cmpLog(
            "[CMP-OUTAGE] recovery suspension \(suspended ? "on" : "off") reason=\(reason) "
            + "held=[\(recoverySuspensionReasons.sorted().joined(separator: ","))]"
        )
    }

    /// The origin-outage ride-through's view of the same latch.
    func setExternalStallSuppression(_ active: Bool) {
        setRecoverySuspended(active, reason: Self.originOutageRecoverySuspensionReason)
    }

    /// Proactive recovery when the view model reports an origin outage has
    /// ended. An item whose segment requests died during the outage does not
    /// retry them on its own: the transport and producer recover, but the
    /// playhead sits waiting on an empty buffer until the (no longer
    /// suppressed) starvation watchdog degrades the route — even though
    /// nothing is broken anymore (sim-validated 2026-07-07). Run the same
    /// stall recovery the playhead watchdog would, immediately.
    @MainActor
    func kickPlaybackAfterExternalStallCleared() {
        guard !isDisposed,
              let item = currentItem,
              case .some(.siloLoopback) = currentSourceStrategy,
              !isUserPaused,
              avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
        let bufferedAhead = bufferedAheadSeconds(for: item, referenceTime: currentTime()) ?? 0
        guard bufferedAhead < 2.0 else { return }
        cmpLog("[CMP-OUTAGE] post-outage playback kick pos=\(currentTime()) bufAhead=\(bufferedAhead)")
        performVODStallRecovery(attempt: 1, frozenPosition: currentTime())
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
    private var loopbackItemDeathRecoveryState = LoopbackItemDeathRecoveryState()
    private var loopbackItemDeathConfirmationState = LoopbackItemDeathConfirmationState()
    private var isInitialSeekInFlight = false
    private var initialSeekRetryCount = 0
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
    private var bufferLoadCount = 0
    private var lastStatsEmitWall: CFTimeInterval = 0
    private var loopbackSourceDownloadBitrateBps: Double?
    private var loopbackHDR10PlusDetected = false
    private var loopbackSourceBytesRead: Int64?
    private var latestLoopbackGeneratedStats: LoopbackSegmentWriter.GeneratedMediaStats?
    private struct LoopbackEdgeWatch {
        var lastLoadedEnd: Double
        var lastLoadedEndAdvancedAt: CFTimeInterval
        var lastPlaylistEnd: Double
        var lastPlaylistHash: UInt64
    }
    private var loopbackEdgeWatch: LoopbackEdgeWatch?
    private var isInitialVideoDisplayGatePrepared = false
    private var isWaitingForInitialVideoDisplay = false
    private var didTemporarilyMuteForInitialVideoDisplay = false
    private var initialVideoDisplayGateStartTime: Double?
    private var initialVideoDisplayFallback: DispatchWorkItem?
    private var loopbackStartupWatchdog: Timer?
    private var loopbackStartupWatchdogStartedAt: Date?
    private var loopbackStartupLastProgressAt: Date = .distantPast
    private var loopbackStartupLastRequestCount: UInt64 = 0
    private enum LoopbackStartupRecoveryStage { case initial, nudged, reloaded }
    private var loopbackStartupRecoveryStage: LoopbackStartupRecoveryStage = .initial
    /// In-flight HDMI mode-switch settle wait (gated non-DV HDR, plus any
    /// fresh DV criteria apply — the master playlist's VIDEO-RANGE is
    /// validated against the panel's current mode on tvOS 26.5). The
    /// AVPlayerItem attach is deferred behind it; teardown cancels it so a
    /// reanchor or dispose can't race a late attach.
    private var displayModeSettleTask: Task<Void, Never>?

    private var segmentWriter: LoopbackSegmentWriter?
    private var segmentServer: LoopbackSegmentServer?
    private var segmentStore: LoopbackSegmentStore?
    private var loopbackPlaylistName: String?
    private var loopbackPlaybackUsesExternalURL = false
    private var sessionDirectory: URL?
    private var activeLoopbackSessionID: String?
    private var loopbackGeneration: UInt64 = 0
    private let loopbackPlaybackClockLock = NSLock()
    private var loopbackPlaybackClockSecondsValue: Double = 0
    private var pendingLocalLoopbackRecoveryMediaTime: Double?
    private var lastLocalLoopbackStallRecoveryAt: CFTimeInterval = 0
    private var loopbackPlayheadWatchdog: Timer?
    private var watchdogLastPlayheadSeconds: Double = -1
    private var watchdogLastAdvanceWall: CFTimeInterval = 0
    private var watchdogLastStateLogWall: CFTimeInterval = 0
    private var watchdogReanchorCount = 0
    private var watchdogReanchorWindowStartWall: CFTimeInterval = 0
    private var didEscalateLoopbackStall = false
    /// Outer bound on full loopback session rebuilds. Reset only when a new
    /// playback is loaded from the outside — never by a rebuild or reanchor,
    /// both of which run through the private `load(strategy:startTime:)`.
    private var loopbackRebuildBudget = LoopbackRebuildBudget()
    private var isUserPaused = false
    /// Guards `reconcileSystemTransportIntent` against the `.initial` KVO
    /// delivery, which reports pre-roll state rather than a transport command.
    private var hasObservedTimeControlStatus = false
    /// True between `AVPlayerItemDidPlayToEndTime` and the next load or seek.
    /// The player parks at rate 0 there, which is not a receiver pause.
    private var hasReachedItemEnd = false
    private var preserveSessionDirectory = false
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
        loopbackRebuildBudget.reset()
        load(
            strategy: .siloLoopback(spec: sessionSpec),
            startTime: startTime
        )
    }

    func loadRemoteHLS(url: URL, headers: [String: String], startTime: Double) {
        isUserPaused = false
        loopbackRebuildBudget.reset()
        load(
            strategy: .remoteHLS(url: url, headers: headers),
            startTime: startTime
        )
    }

    func loadDirectFile(url: URL, headers: [String: String], startTime: Double) {
        isUserPaused = false
        loopbackRebuildBudget.reset()
        load(
            strategy: .remoteDirect(url: url, headers: headers),
            startTime: startTime
        )
    }

    func play() {
        isUserPaused = false
        onPauseChange?(false)
        if case .some(.siloLoopback(let spec)) = currentSourceStrategy,
           let mediaSeconds = pendingLocalLoopbackRecoveryMediaTime {
            pendingLocalLoopbackRecoveryMediaTime = nil
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
        loopbackItemDeathConfirmationState.resetCandidate()
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
        guard let item = currentItem, !isDisposed else { return }
        guard isWaitingForInitialVideoDisplay else { return }
        finishInitialVideoDisplayGate(for: item, reason: "ready_for_display")
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
        }

        let time = CMTime(seconds: playerSeconds, preferredTimescale: 600)
        isSeekPending = true
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
            self.isSeekPending = false
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

    private func cancelSeekDeadline() {
        seekDeadlineWorkItem?.cancel()
        seekDeadlineWorkItem = nil
        releaseSupersededInitialSeekGateIfNeeded()
        activeSeekDeadlineKind = nil
        seekDeadlineState.cancel()
        isSeekPending = false
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
        isSeekPending = false
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
            if case .some(.siloLoopback) = currentSourceStrategy {
                Task { @MainActor [weak self] in
                    guard let self, !self.isDisposed else { return }
                    // Keep the target latched until the recovery helper
                    // reads it; the frozen clock is still pre-seek.
                    self.vodPendingSeekMediaTarget = mediaTarget
                    self.performVODStallRecovery(
                        attempt: 1,
                        frozenPosition: self.playerTime(forMediaTime: mediaTarget)
                    )
                    self.vodPendingSeekMediaTarget = nil
                }
                return
            } else if !isUserPaused {
                avPlayer.play()
            }
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
            initialSeekRetryCount += 1
            let retry = initialSeekRetryCount
            Self.logger.error(
                "[CMP-SEEK] initial AVPlayer seek deadline mediaTarget=\(mediaTarget, privacy: .public) retry=\(retry, privacy: .public)"
            )
            if retry <= 8, let item = currentItem {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak item] in
                    guard let self, let item, !self.isDisposed, item === self.currentItem else { return }
                    self.attemptInitialPlaybackStart(for: item, trigger: "deadline-retry-\(retry)")
                }
            } else if let item = currentItem {
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
            self.isSeekPending = false
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
        bufferLoadCount = 0
        lastStatsEmitWall = 0
        loopbackSourceDownloadBitrateBps = nil
        loopbackHDR10PlusDetected = false
        loopbackSourceBytesRead = nil
        latestLoopbackGeneratedStats = nil
        loopbackEdgeWatch = nil
        pendingLocalLoopbackRecoveryMediaTime = nil
        vodPendingSeekMediaTarget = nil
        lastLocalLoopbackStallRecoveryAt = 0
        // Reset playhead advance-tracking for the new session so a reanchor's
        // pre-reanchor position does not read as instantly stationary. The
        // reanchor retry budget (count/window/escalation) deliberately survives
        // across reanchors and only resets on window expiry.
        watchdogLastPlayheadSeconds = -1
        watchdogLastAdvanceWall = 0
        watchdogLastStateLogWall = 0
        didFireFileLoaded = false
        hasSeekedToStart = false
        hasReachedItemEnd = false
        pendingStartTime = startTime
        initialSeekRetryCount = 0
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

    /// The segment plan resolved by the first producer session for the
    /// current source. Restarted producers receive it so every session
    /// reproduces the same segment grid the static playlist advertises.
    private var loopbackVODPlan: LoopbackSegmentPlan?
    private var loopbackVODPlanSourceURL: URL?

    private func vodPlanForCurrentSource(spec: LoopbackSessionSpec) -> LoopbackSegmentPlan? {
        guard loopbackVODPlanSourceURL == spec.sourceURL else { return nil }
        return loopbackVODPlan
    }

    // MARK: - VOD demand-driven producer restarts (loopback-primary plan, 1e)

    private static let vodSegmentMissWaitSeconds: Double = 8.0
    /// How far past a running producer's base a fetch counts as "covered" —
    /// the producer's forward march will deliver it without a restart.
    private static let vodProducerCoverageWindow = 8

    private var vodRestartCoalescer = LoopbackRestartCoalescer()
    private var activeVODWriterBaseIndex: Int?
    /// Highest segment index the running producer has actually finalized.
    /// Coverage decisions ride the march only when the target is within
    /// `vodProducerMarchAllowance` of THIS, not of the static base — with
    /// 30–70 MB long-GOP segments the march moves at 3–6 s per segment, and
    /// "within 8 of base" left a seek's fetch waiting out the full miss
    /// deadline into a 404 (living-room frozen-video seeks).
    private var activeVODWriterHeadIndex: Int?
    /// How far past the produced head a fetch may ride the running
    /// producer's march. One segment for the natural next-in-line fetch,
    /// plus one for AVPlayer's concurrent lookahead.
    private static let vodProducerMarchAllowance = 2
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

    /// Swaps the producer (writer only — the store, server, and player item
    /// all survive) to anchor at the requested plan segment. Coalesced: one
    /// in-flight swap, newest pending target wins, self-target guarded.
    @MainActor
    private func requestVODProducerRestart(at index: Int, authoritative: Bool = false) {
        guard !isDisposed,
              case .some(.siloLoopback(let spec)) = currentSourceStrategy,
              let plan = vodPlanForCurrentSource(spec: spec),
              plan.segmentCount > 0,
              let store = segmentStore,
              let sessionID = activeLoopbackSessionID,
              let sessionDir = sessionDirectory else { return }
        let target = max(0, min(index, plan.segmentCount - 1))
        if let base = activeVODWriterBaseIndex,
           segmentWriter != nil,
           target >= base,
           target <= base + Self.vodProducerCoverageWindow,
           target <= max(activeVODWriterHeadIndex ?? (base - 1), base - 1)
                        + Self.vodProducerMarchAllowance {
            // The running producer covers it AND is close enough that its
            // forward march delivers before the fetch's miss deadline. The
            // head-proximity bound matters on long-GOP sources: a seek
            // landing 3+ heavy segments past the produced head used to ride
            // "covered by base+8" into an 8 s wait and a 404. This applies
            // to recovery re-bases too: restarting a covering producer
            // discards its march and re-produces the same span — the
            // recovery ladder's player-side nudge/reload is the tool for a
            // consumer wedge, not producer churn. A genuinely wedged
            // producer surfaces separately (source stall → premature EOF /
            // mux failures) and escalates through the watchdog budget.
            return
        }
        var next: Int? = target
        while let current = next {
            guard vodRestartCoalescer.begin(current, authoritative: authoritative) else { return }
            cmpLog("[CMP-AVP] vod producer restart segment=\(current) authoritative=\(authoritative)")
            // Recycle the retiring producer's demuxer: same source URL
            // (reanchored spec only moves the start time), and the open
            // input + warm cue index are the dominant fixed cost of a
            // seek-triggered restart.
            var handoff: LoopbackInputHandoff?
            if let retiring = segmentWriter {
                let h = LoopbackInputHandoff()
                handoff = h
                retiring.stop(recyclingInputInto: h)
            }
            startSiloLoopbackWriter(
                sessionID: sessionID,
                sessionSpec: spec.reanchored(at: plan.sourceStartSeconds(ofSegment: current)),
                sessionDir: sessionDir,
                segmentStore: store,
                vodBaseIndex: current,
                recycledInput: handoff
            )
            next = vodRestartCoalescer.next(justRan: current)
        }
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
    private func performVODStallRecovery(attempt: Int, frozenPosition: Double) {
        let anchorPlayer = vodPendingSeekMediaTarget.map(playerTime(forMediaTime:))
            ?? frozenPosition
        if let plan = loopbackVODPlan {
            requestVODProducerRestart(
                at: plan.segmentIndex(forPlaylistSeconds: anchorPlayer),
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
        item.preferredForwardBufferDuration = max(
            oldItem.preferredForwardBufferDuration,
            Self.loopbackStartupForwardBuffer
        )
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
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
        activeLoopbackSessionID = sessionID
        installLoopbackPlayheadWatchdog()
        loopbackGeneration &+= 1
        let generation = loopbackGeneration
        let debugBaseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("silo-dv-hls-debug", isDirectory: true)
        let sessionDir = debugBaseDir.appendingPathComponent(sessionID, isDirectory: true)
        sessionDirectory = sessionDir
        preserveSessionDirectory = Self.keepLoopbackArtifacts

        let debugDirectory = preserveSessionDirectory ? sessionDir : nil
        let store = LoopbackSegmentStore(
            generation: generation,
            memoryBudgetBytes: Self.loopbackSegmentStoreMemoryBudgetBytes,
            spillPolicy: Self.generatedHLSSpillPolicy(for: sessionSpec),
            debugDirectory: debugDirectory
        )
        let retentionBudget = Self.vodRetentionBudgetBytes()
        cmpLog("[CMP-HLS-STORE] vod retention budgetBytes=\(retentionBudget)")
        store.configureVODRetention(budgetBytes: retentionBudget)
        segmentStore = store
        if preserveSessionDirectory {
            cmpLog("[CMP-AVP] preserving local DV artifacts due to SILO_KEEP_DV_HLS=1 dir=\(sessionDir.path)")
        }

        #if os(iOS)
        let server = LoopbackSegmentServer(segmentStore: store, exposure: .localNetwork)
        #else
        let server = LoopbackSegmentServer(segmentStore: store)
        #endif
        // A miss under the static VOD playlist means "not produced (yet) or
        // pruned": request a coalesced producer restart on main, then wait —
        // bounded — for the bytes. Runs on the server's resolver queue; the
        // store is thread-safe.
        server.vodSegmentMissResolver = { [weak self, weak store] index in
            guard let store else { return .missing }
            Task { @MainActor [weak self] in
                self?.requestVODProducerRestart(at: index)
            }
            return store.waitForSegment(
                named: String(format: "seg_%06d.m4s", index),
                deadline: Date().addingTimeInterval(Self.vodSegmentMissWaitSeconds)
            )
        }
        // Stash the server immediately so a synchronous teardown (e.g. fast
        // user dismiss) can find and cancel the still-binding listener.
        segmentServer = server

        // Server bind goes through `withCheckedThrowingContinuation` rather
        // than blocking the main actor on a 2 s semaphore. Defer writer setup
        // until bind completes; if the user disposes the backend or switches
        // sessions in the meantime, bail before touching state.
        Task { @MainActor [weak self] in
            do {
                try await server.start()
            } catch {
                guard let self else { return }
                // The server's catch arm already cancelled the listener; null
                // out our reference so callers don't trip on a cancelled
                // server still hanging off `segmentServer`.
                if self.segmentServer === server {
                    self.segmentServer = nil
                }
                guard !self.isDisposed,
                      self.activeLoopbackSessionID == sessionID else {
                    return
                }
                self.reportFailure(
                    .loopbackServerBindFailed(detail: String(describing: error))
                )
                return
            }
            guard let self, !self.isDisposed else {
                server.stop()
                return
            }
            guard self.activeLoopbackSessionID == sessionID else {
                server.stop()
                return
            }
            self.startSiloLoopbackWriter(sessionID: sessionID,
                                             sessionSpec: sessionSpec,
                                             sessionDir: sessionDir,
                                             segmentStore: store)
        }
    }

    @MainActor
    private func startSiloLoopbackWriter(
        sessionID: String,
        sessionSpec: LoopbackSessionSpec,
        sessionDir: URL,
        segmentStore: LoopbackSegmentStore,
        vodBaseIndex: Int = 0,
        recycledInput: LoopbackInputHandoff? = nil
    ) {
        let writer = LoopbackSegmentWriter(
            sessionSpec: sessionSpec,
            outputDirectory: sessionDir,
            segmentStore: segmentStore,
            vodPlan: vodPlanForCurrentSource(spec: sessionSpec),
            vodBaseIndex: vodBaseIndex,
            recycledInputHandoff: recycledInput
        )
        let tap = ensureLoopbackSubtitleTap(for: sessionSpec.sourceURL)
        writer.isSourceOutageActive = { [weak self] in
            self?.sourceOutageStateProvider?() ?? false
        }
        writer.onSubtitleTapTracks = { [weak tap] infos in
            tap?.registerTracks(infos)
        }
        writer.onSubtitleTapCue = { [weak tap] cue in
            tap?.ingest(cue)
        }
        writer.onBitmapSubtitleTapTracks = { [weak self] indices in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed,
                      self.activeLoopbackSessionID == sessionID else { return }
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
        }
        // Mux thread; the writer only decodes (and therefore only emits)
        // while a stream is selected, and SubtitleSession serialises feeds
        // on its own queue — same pattern as the extractor's decode thread.
        writer.onBitmapSubtitleTapCue = { [weak self] _, cues, trimActiveAt in
            self?.subtitleSession?.feedBitmapCues(
                slot: .primary,
                cues: cues,
                trimActiveAt: trimActiveAt
            )
        }
        // Selection survives producer restarts: every new writer inherits it.
        writer.setBitmapSubtitleTapStream(selectedBitmapTapStreamIndex)
        activeVODWriterBaseIndex = vodBaseIndex
        activeVODWriterHeadIndex = vodBaseIndex - 1
        // Seed the consumer window at the producer's base so a resumed
        // or restarted session isn't parked by backpressure before the
        // player's first fetch declares a real target.
        segmentStore.declareVODTarget(vodBaseIndex)
        // A resume-first session anchors itself once the plan resolves;
        // re-seed from the writer's TRUE base or the producer parks
        // against a window still sitting at 0 while AVPlayer's resume
        // fetches strand (the living-room resume startup timeout).
        writer.onVODProducerAnchored = { [weak self, weak segmentStore] base in
            segmentStore?.declareVODTarget(base)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed,
                      self.activeLoopbackSessionID == sessionID else { return }
                self.activeVODWriterBaseIndex = base
                self.activeVODWriterHeadIndex = base - 1
            }
        }
        // Produced-head tracking for the restart coverage decision:
        // a fetch may only ride the running march when it's within
        // vodProducerMarchAllowance of what has actually been written.
        writer.onSegmentAppended = { [weak self] segmentIndex, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed,
                      self.activeLoopbackSessionID == sessionID else { return }
                self.activeVODWriterHeadIndex = max(
                    self.activeVODWriterHeadIndex ?? segmentIndex,
                    segmentIndex
                )
            }
        }
        writer.onSegmentPlanResolved = { [weak self] plan in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                guard self.activeLoopbackSessionID == sessionID else { return }
                self.loopbackVODPlan = plan
                self.loopbackVODPlanSourceURL = sessionSpec.sourceURL
                self.segmentServer?.setVODSegmentCount(plan.segmentCount)
                // The item timeline's origin is the plan anchor; the initial
                // media-time seek (pendingStartTime) converts through this
                // offset, and plan resolution always precedes item creation.
                self.setMediaTimelineOffset(plan.anchorSourceSeconds)
            }
        }
        writer.onFirstSegmentReady = { [weak self] playlistName in
            DispatchQueue.main.async {
                self?.handleFirstSegmentReady(playlistName: playlistName, sessionID: sessionID)
            }
        }
        writer.onFinished = { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isDisposed else { return }
                guard self.activeLoopbackSessionID == sessionID else { return }
                if let error {
                    self.reportFailure(.writerFailed(
                        kind: Self.writerFailureKind(for: error),
                        detail: String(describing: error)
                    ))
                }
            }
        }
        writer.playbackPositionProvider = { [weak self] in
            self?.loopbackPlaybackClockSeconds()
        }
        writer.onSourceDownloadStats = { [weak self] bitsPerSecond, totalBytesRead in
            DispatchQueue.main.async {
                guard let self, !self.isDisposed else { return }
                guard self.activeLoopbackSessionID == sessionID else { return }
                let previousBitrate = self.loopbackSourceDownloadBitrateBps
                self.loopbackSourceDownloadBitrateBps = bitsPerSecond
                self.loopbackSourceBytesRead = totalBytesRead
                self.emitPlaybackStats(referenceTime: self.currentTime(), force: true)
                if let bitsPerSecond {
                    let mbps = bitsPerSecond / 1_000_000
                    let mib = totalBytesRead.map { Double($0) / 1_048_576 } ?? 0
                    Self.logger.info(
                        "[CMP-AVP] loopback source rate=\(String(format: "%.1f", mbps), privacy: .public)Mbps totalRead=\(String(format: "%.1f", mib), privacy: .public)MiB"
                    )
                }
                // First measurable bitrate (or a meaningful change) — re-
                // evaluate the steady-state forward buffer so a high-
                // bitrate source doesn't sit on the conservative 30 s
                // default after the gate has already been released.
                if previousBitrate == nil, bitsPerSecond != nil,
                   let item = self.currentItem,
                   self.canRampLoopbackBufferToSteadyState {
                    self.rampLoopbackBufferToSteadyStateIfNeeded(for: item)
                }
            }
        }
        writer.onGeneratedMediaStats = { [weak self] generatedStats in
            DispatchQueue.main.async {
                guard let self, !self.isDisposed else { return }
                guard self.activeLoopbackSessionID == sessionID else { return }
                self.latestLoopbackGeneratedStats = generatedStats
                self.emitPlaybackStats(referenceTime: self.currentTime(), force: true)
                if let item = self.currentItem,
                   self.canRampLoopbackBufferToSteadyState {
                    self.rampLoopbackBufferToSteadyStateIfNeeded(for: item)
                    self.sampleLocalLoopbackEdge(item: item, referenceTime: self.currentTime(), trigger: "generated_stats")
                }
            }
        }
        // HDR10+ badge: install the one-shot SEI scan only for plain HEVC PQ
        // sessions whose label currently reads "HDR10" and has not flipped.
        // DV Profile 8 sources keep their validated labels (scan not installed).
        if sessionSpec.videoMode == .passthroughHEVC,
           sessionSpec.manifestMetadata.videoRange != "HLG",
           sessionSpec.manifestMetadata.videoRange != "SDR",
           !loopbackHDR10PlusDetected {
            writer.onHDR10PlusMetadataDetected = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, !self.isDisposed else { return }
                    guard self.activeLoopbackSessionID == sessionID else { return }
                    self.loopbackHDR10PlusDetected = true
                    cmpLog("[CMP-AVP] hdr10+ dynamic metadata detected — badge flips HDR10 → HDR10+")
                    self.emitPlaybackStats(referenceTime: self.currentTime(), force: true)
                }
            }
        }
        segmentWriter = writer
        writer.start()
    }

    private func handleFirstSegmentReady(playlistName: String, sessionID: String) {
        guard activeLoopbackSessionID == sessionID else { return }
        guard !isDisposed, currentItem == nil, let server = segmentServer else { return }
        // Starting up with AirPlay already engaged: prefer the LAN address, but
        // a session that cannot reach one still plays here rather than failing.
        var useExternalURL = avPlayer.isExternalPlaybackActive
        var externalURL: URL?
        if useExternalURL {
            externalURL = server.resourceURL(for: playlistName, reachableFromExternalDevice: true)
            if externalURL == nil {
                useExternalURL = false
                abandonExternalPlaybackHandoff()
            }
        }
        guard let url = externalURL ?? server.resourceURL(for: playlistName) else {
            reportFailure(.loopbackPlaylistURLUnavailable)
            return
        }
        loopbackPlaylistName = playlistName
        loopbackPlaybackUsesExternalURL = useExternalURL
        server.setAcceptsExternalClients(useExternalURL)
        cmpLog("[CMP-AVP] local playlist ready host=\(url.host ?? "unknown") external=\(useExternalURL ? 1 : 0)")
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
            attachLoopbackItem(url: url)
            return
        }
        #if os(tvOS)
        displayModeSettleTask?.cancel()
        displayModeSettleTask = Task { @MainActor [weak self] in
            let hosted = await TVDisplayCriteria.waitForModeSwitchSettle()
            guard let self, !self.isDisposed, !Task.isCancelled,
                  self.activeLoopbackSessionID == sessionID,
                  self.currentItem == nil else { return }
            // Panel-readiness snapshot. The loopback route now serves the
            // VIDEO-RANGE-claiming master playlist (Atmos claims are
            // master-level grants), so this wait is what keeps the item's
            // synchronous VIDEO-RANGE validation from racing the HDMI mode
            // switch. hdrHosted=0 after the wait means the panel stayed
            // SDR; AetherEngine ships the same master shape to such panels
            // in production, so the attach proceeds either way.
            cmpLog("[CMP-AVP] tv display settle hdrHosted=\(hosted ? 1 : 0)")
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
        // (~30s, one per GOP) fragments before declaring readyToPlay. Tell
        // it to start as soon as the first fragment is decodable and cap
        // forward buffer at one fragment-equivalent for *startup only*.
        //
        // After the initial-video-display gate releases (see
        // `finishInitialVideoDisplayGate`) we ramp the forward buffer up
        // to `loopbackSteadyStateForwardBuffer` and re-enable
        // `automaticallyWaitsToMinimizeStalling` so AVPlayer can ride out
        // network jitter on high-bitrate sources where the WAN headroom
        // over the source's bitrate is small (e.g. 4K DV at 72 Mbps over
        // 80 Mbps).
        //
        // Remote routes keep AVPlayer's defaults since automatic buffering
        // is genuinely useful over the WAN.
        if case .siloLoopback = currentSourceStrategy {
            avPlayer.automaticallyWaitsToMinimizeStalling = false
            item.preferredForwardBufferDuration = Self.loopbackStartupForwardBuffer
            // Do not let AVPlayer poll the local EVENT playlist while paused.
            // Under disk pressure the writer may pause appends until playback
            // frees spill capacity; paused polling can therefore see an
            // unchanged playlist long enough for CoreMedia to fail the item.
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        }
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
            self.releaseInitialVideoDisplayGateIfPlaybackAdvanced(currentTime: time.seconds)
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

    private func emitBufferedAhead(referenceTime: Double) {
        guard let item = currentItem, referenceTime.isFinite else { return }
        let ranges = item.loadedTimeRanges.map { $0.timeRangeValue }
        guard !ranges.isEmpty else {
            onBufferedAheadChange?(0)
            return
        }

        let aheadEnd = ranges
            .compactMap { range -> Double? in
                let start = range.start.seconds
                let end = (range.start + range.duration).seconds
                guard start.isFinite, end.isFinite, end > referenceTime else {
                    return nil
                }
                return start <= referenceTime ? end : nil
            }
            .max() ?? referenceTime

        onBufferedAheadChange?(max(0, aheadEnd - referenceTime))
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
        stats.bufferedAheadSeconds = bufferedAheadSeconds(for: item, referenceTime: referenceTime)
        stats.bufferLoadCount = bufferLoadCount
        stats.observedBitrateBps = observedBitrate
        stats.indicatedBitrateBps = indicatedBitrate
        stats.currentDownloadBitrateBps = observedBitrate ?? loopbackSourceDownloadBitrateBps
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
        if let observedBitrate, let indicatedBitrate, indicatedBitrate > 0 {
            stats.streamSpeed = observedBitrate / indicatedBitrate
        } else if let loopbackSourceDownloadBitrateBps,
                  let averageFileBitrateBps = stats.averageFileBitrateBps,
                  averageFileBitrateBps > 0 {
            stats.streamSpeed = loopbackSourceDownloadBitrateBps / averageFileBitrateBps
        }
        if shouldPublishNetworkStats,
           let bytes = accessEvent?.numberOfBytesTransferred,
           bytes > 0 {
            stats.bytesTransferred = bytes
        } else if !shouldPublishNetworkStats {
            stats.bytesTransferred = loopbackSourceBytesRead
        }
        stats.deviceInfo = Self.deviceInfo()
        stats.freeDiskSpaceBytes = Self.freeDiskSpaceBytes()
        stats.volumeAvailableCapacityBytes = Self.volumeAvailableCapacityBytes()
        onPlaybackStatsChange?(stats)
    }

    private var publishesRemoteAccessLogNetworkStats: Bool {
        switch currentSourceStrategy {
        case .siloLoopback:
            return false
        case .remoteHLS, .remoteDirect:
            return true
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

    private func bufferedAheadSeconds(for item: AVPlayerItem, referenceTime: Double) -> Double? {
        loadedRangeEnd(for: item, referenceTime: referenceTime).map { max(0, $0 - referenceTime) }
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

    private func describeLoadedRanges(_ item: AVPlayerItem) -> String {
        let ranges = item.loadedTimeRanges.map(\.timeRangeValue)
        guard !ranges.isEmpty else { return "[]" }
        return ranges.map { range in
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            return String(format: "%.2f-%.2f", start, end)
        }.joined(separator: ",")
    }

    private func describeSeekableRanges(_ item: AVPlayerItem) -> String {
        let ranges = item.seekableTimeRanges.map(\.timeRangeValue)
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

        // Movement in EITHER direction counts as alive. Comparing with `>`
        // alone left the high-water mark stale across backward in-item
        // seeks: after a back-scrub the playhead sits below the pre-scrub
        // mark for tens of seconds of healthy playback, `stationaryFor`
        // climbs the whole time, and the watchdog "recovers" a route that
        // was never wedged (nudge → item reloads that reset a full buffer →
        // reanchor budget exhausted → spurious route fallback).
        if watchdogLastPlayheadSeconds < 0 || abs(position - watchdogLastPlayheadSeconds) > 0.05 {
            watchdogLastPlayheadSeconds = position
            watchdogLastAdvanceWall = now
        }
        let stationaryFor = watchdogLastAdvanceWall > 0 ? now - watchdogLastAdvanceWall : 0

        let timeControlStatus = avPlayer.timeControlStatus
        let bufferedAhead = bufferedAheadSeconds(for: item, referenceTime: position) ?? 0
        let generatedEnd = latestLoopbackGeneratedStats?.playlistVisibleEndSeconds
            ?? segmentStore?.stats().generatedMediaSeconds
            ?? 0
        let generatedAhead = max(0, generatedEnd - position)

        let statusLabel: String
        let transportState: LoopbackItemDeathConfirmationState.TransportState
        switch timeControlStatus {
        case .paused:
            statusLabel = "paused"
            transportState = .paused
        case .waitingToPlayAtSpecifiedRate:
            statusLabel = "waiting"
            transportState = .waiting
        case .playing:
            statusLabel = "playing"
            transportState = .playing
        @unknown default:
            statusLabel = "unknown"
            transportState = .unknown
        }

        // Periodic transport-state telemetry so a captured stall can be
        // classified (pause vs. wedge) directly from the log.
        if now - watchdogLastStateLogWall >= 3 {
            watchdogLastStateLogWall = now
            // Temporary [CMP-MEM]: attribute footprint growth per tick —
            // jetsam-accounted footprint + remaining headroom, alongside the
            // app-managed pools (segment store RAM, source proxy cache) so a
            // memory termination capture shows which pool was growing.
            let mem = Self.memoryFootprintMiB()
            let storeMiB = Double(segmentStore?.stats().memoryBytes ?? 0) / 1_048_576
            let proxyMiB = Double(proxyStatsProvider?()?.cachedBytes ?? 0) / 1_048_576
            let memSuffix: String
            if let mem {
                memSuffix = String(
                    format: " footprint=%.1fMiB avail=%.1fMiB store=%.1fMiB proxy=%.1fMiB",
                    mem.footprint, mem.available, storeMiB, proxyMiB
                )
            } else {
                memSuffix = String(
                    format: " footprint=? avail=? store=%.1fMiB proxy=%.1fMiB",
                    storeMiB, proxyMiB
                )
            }
            let suspendedSuffix = isRecoverySuspended
                ? " suspended=[\(recoverySuspensionReasons.sorted().joined(separator: ","))]"
                : ""
            cmpLog(
                "[CMP-AVP] loopback playhead state pos=\(position) tc=\(statusLabel) rate=\(avPlayer.rate) paused=\(isUserPaused ? 1 : 0) bufAhead=\(bufferedAhead) generatedAhead=\(generatedAhead) stationaryFor=\(stationaryFor)\(memSuffix)\(suspendedSuffix)"
            )
        }

        let itemDeathAction = loopbackItemDeathConfirmationState.evaluate(
            now: now,
            position: position,
            playbackEstablished: didFireFileLoaded,
            userPaused: isUserPaused,
            transportState: transportState,
            recoverySuppressed: isRecoverySuspended
                || isWaitingForInitialVideoDisplay,
            mediaAvailableAhead: bufferedAhead >= 0.5 || generatedAhead >= 2.0
        )
        switch itemDeathAction {
        case .none:
            break
        case .reassertPlay:
            cmpLog(
                "[CMP-AVP] unexpected AVPlayer pause; reasserting play pos=\(position) bufAhead=\(bufferedAhead) generatedAhead=\(generatedAhead)"
            )
            avPlayer.play()
        case .confirmed(let trigger):
            let action = loopbackItemDeathRecoveryState.confirm(
                position: position,
                userPaused: isUserPaused
            )
            performLoopbackItemDeathRecoveryAction(
                action,
                item: item,
                position: position,
                trigger: trigger.rawValue,
                statusCode: nil,
                errorDescription: "confirmed terminal AVPlayer transport state"
            )
            return
        }

        // Observation above (advance tracking, telemetry, item-death
        // evidence) keeps running while an external owner holds the recovery
        // latch, but no rung below may act: the route isn't what broke (the
        // origin is down, or the view model is renegotiating the plan) and
        // the view model owns the terminal decision.
        if isRecoverySuspended { return }

        // Producer-dead starvation: waiting on an empty buffer with no
        // successful segment serves for a sustained stretch. Rebuild the
        // Silo loopback session at the rendered clock; changing playback
        // engines would hide the fault and lose SiloPlayer capabilities.
        if !isUserPaused,
           timeControlStatus == .waitingToPlayAtSpecifiedRate,
           bufferedAhead < 2.0,
           stationaryFor >= Self.playheadWatchdogStarvationEscalateSeconds,
           (segmentStore?.secondsSinceLastSegmentServe() ?? .infinity)
               >= Self.playheadWatchdogStarvationServeQuietSeconds,
           !didEscalateLoopbackStall {
            didEscalateLoopbackStall = true
            cmpLog(
                "[CMP-AVP] loopback starvation: playhead frozen \(Int(stationaryFor))s with empty buffer and no segment serves; rebuilding Silo loopback"
            )
            rebuildSiloLoopbackSession(at: position, reason: "loopback_starvation")
            return
        }

        // Only a wedge qualifies: AVPlayer should be playing (not user-paused,
        // not legitimately waiting on an empty buffer) yet the playhead is
        // stationary while media is generated ahead of it.
        let believesPlayable = timeControlStatus == .playing
            || (timeControlStatus == .waitingToPlayAtSpecifiedRate && bufferedAhead >= 2.0)
        guard !isUserPaused,
              believesPlayable,
              stationaryFor >= Self.playheadWatchdogStallSeconds,
              generatedAhead >= Self.playheadWatchdogMinGeneratedAhead else {
            return
        }

        // Bound lightweight reanchors within a rolling window. Once exhausted,
        // rebuild the Silo loopback session (producer, cache, server, item) at
        // the rendered clock instead of changing playback engines.
        if watchdogReanchorWindowStartWall == 0
            || now - watchdogReanchorWindowStartWall > Self.playheadWatchdogReanchorWindowSeconds {
            watchdogReanchorWindowStartWall = now
            watchdogReanchorCount = 0
            didEscalateLoopbackStall = false
        }

        if watchdogReanchorCount >= Self.playheadWatchdogMaxReanchors {
            guard !didEscalateLoopbackStall else { return }
            didEscalateLoopbackStall = true
            Self.logger.error(
                "[CMP-AVP] local loopback playhead_watchdog exhausted reanchors=\(self.watchdogReanchorCount, privacy: .public) pos=\(position, privacy: .public) stationaryFor=\(stationaryFor, privacy: .public); rebuilding Silo loopback"
            )
            rebuildSiloLoopbackSession(at: position, reason: "playhead_watchdog")
            return
        }

        if case .some(.siloLoopback) = currentSourceStrategy,
           let sinceServe = segmentStore?.secondsSinceLastSegmentServe(),
           sinceServe < 4.0 {
            // The consumer is actively pulling segments — a post-seek buffer
            // fill, not a wedge (the fetch-high-water signal). Recovery here
            // would kill the producer mid-march and reset AVPlayer's buffer,
            // looping the fill forever (living-room bug 3).
            return
        }

        watchdogReanchorCount += 1
        Self.logger.error(
            "[CMP-AVP] local loopback playhead_watchdog trigger attempt=\(self.watchdogReanchorCount, privacy: .public) pos=\(position, privacy: .public) tc=\(statusLabel, privacy: .public) bufAhead=\(bufferedAhead, privacy: .public) generatedAhead=\(generatedAhead, privacy: .public) stationaryFor=\(stationaryFor, privacy: .public)"
        )
        let attempt = watchdogReanchorCount
        Task { @MainActor [weak self] in
            self?.performVODStallRecovery(attempt: attempt, frozenPosition: position)
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
        let now = CACurrentMediaTime()
        let loadedEnd = loadedRangeEnd(for: item, referenceTime: referenceTime) ?? referenceTime
        if loopbackEdgeWatch == nil {
            loopbackEdgeWatch = LoopbackEdgeWatch(
                lastLoadedEnd: loadedEnd,
                lastLoadedEndAdvancedAt: now,
                lastPlaylistEnd: generatedStats.playlistVisibleEndSeconds,
                lastPlaylistHash: generatedStats.playlistBodyHash
            )
            return
        }

        guard var watch = loopbackEdgeWatch else { return }
        let loadedAdvanced = loadedEnd > watch.lastLoadedEnd + 0.25
        if loadedAdvanced {
            watch.lastLoadedEnd = loadedEnd
            watch.lastLoadedEndAdvancedAt = now
        }
        let playlistAdvanced = generatedStats.playlistVisibleEndSeconds > watch.lastPlaylistEnd + 0.25
            || generatedStats.playlistBodyHash != watch.lastPlaylistHash
        watch.lastPlaylistEnd = max(watch.lastPlaylistEnd, generatedStats.playlistVisibleEndSeconds)
        watch.lastPlaylistHash = generatedStats.playlistBodyHash
        loopbackEdgeWatch = watch

        let targetDuration = max(1.0, Double(generatedStats.targetDuration))
        let watchdogDelay = max(3.0, targetDuration * 2.0 + 1.0)
        let loadedAhead = max(0, loadedEnd - referenceTime)
        let visibleAhead = max(0, generatedStats.playlistVisibleEndSeconds - referenceTime)
        guard playlistAdvanced,
              !loadedAdvanced,
              loadedAhead <= 1.0,
              visibleAhead >= max(6.0, targetDuration + generatedStats.longestSegmentDuration),
              now - watch.lastLoadedEndAdvancedAt >= watchdogDelay else {
            return
        }

        Self.logger.info(
            "[CMP-AVP] edge_watchdog trigger=\(trigger, privacy: .public) player=\(referenceTime, privacy: .public) loadedEnd=\(loadedEnd, privacy: .public) loadedAhead=\(loadedAhead, privacy: .public) playlistStart=\(generatedStats.playlistVisibleStartSeconds, privacy: .public) playlistEnd=\(generatedStats.playlistVisibleEndSeconds, privacy: .public) visibleAhead=\(visibleAhead, privacy: .public) mediaSeq=\(generatedStats.firstMediaSequence, privacy: .public)-\(generatedStats.lastMediaSequence, privacy: .public) targetDuration=\(generatedStats.targetDuration, privacy: .public) longestSegment=\(generatedStats.longestSegmentDuration, privacy: .public) playlistBytes=\(generatedStats.playlistBodyBytes, privacy: .public) playlistHash=\(generatedStats.playlistBodyHash, privacy: .public) forwardBuffer=\(item.preferredForwardBufferDuration, privacy: .public) loadedRanges=\(self.describeLoadedRanges(item), privacy: .public) seekableRanges=\(self.describeSeekableRanges(item), privacy: .public)"
        )
        recoverLocalLoopbackStallIfNeeded(item: item, requireBufferedEdge: true, reason: "edge_watchdog")
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
                let status: String
                switch player.timeControlStatus {
                case .paused:
                    status = "paused"
                case .waitingToPlayAtSpecifiedRate:
                    status = "waiting"
                case .playing:
                    status = "playing"
                @unknown default:
                    status = "unknown"
                }
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
                    self.bufferLoadCount += 1
                    if case .siloLoopback = self.currentSourceStrategy {
                        Self.logger.info(
                            "[CMP-AVP] item buffer empty current=\(self.currentTime(), privacy: .public) loadedRanges=\(self.describeLoadedRanges(item), privacy: .public)"
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
                    self.resumeLocalLoopbackPlaybackIfNeeded(for: item, trigger: "likely_to_keep_up")
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
                self.resumeLocalLoopbackPlaybackIfNeeded(for: item, trigger: "loaded_ranges")
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
                "[CMP-AVP] item playback stalled current=\(self.currentTime(), privacy: .public) loadedRanges=\(self.describeLoadedRanges(item), privacy: .public)"
            )
            self.recoverLocalLoopbackStallIfNeeded(item: item)
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
            if case .siloLoopback = self.currentSourceStrategy,
               self.didFireFileLoaded {
                self.loopbackItemDeathConfirmationState.noteExplicitFailure(
                    position: position,
                    now: CACurrentMediaTime(),
                    playbackEstablished: true,
                    userPaused: self.isUserPaused
                )
                return
            }
            self.recoverLocalLoopbackFailureIfNeeded(item: item, error: error)
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
            if self.didFireFileLoaded,
               LoopbackItemDeathRecoveryState.isItemDeath(
                    statusCode: event.errorStatusCode,
                    errorDescription: event.errorComment ?? ""
               ) {
                self.handleLoopbackItemDeathEvidence(
                    item: item,
                    statusCode: event.errorStatusCode,
                    errorDescription: event.errorComment ?? "",
                    evidenceWeight: event.errorStatusCode == -15628 ? 2 : 1,
                    trigger: "error_log"
                )
                return
            }
            if event.errorStatusCode == -15628,
               !self.didFireFileLoaded,
               case .siloLoopback = self.currentSourceStrategy {
                self.escalateLoopbackStartupRecovery(trigger: "errorLog_-15628")
            }
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

    private func recoverLocalLoopbackFailureIfNeeded(item: AVPlayerItem, error: Error?) {
        let description = String(describing: error)
        let statusCode = item.errorLog()?.events.last?.errorStatusCode
        if didFireFileLoaded,
           LoopbackItemDeathRecoveryState.isItemDeath(
                statusCode: statusCode,
                errorDescription: description
           ) {
            handleLoopbackItemDeathEvidence(
                item: item,
                statusCode: statusCode,
                errorDescription: description,
                evidenceWeight: 2,
                trigger: "failed_to_end"
            )
            return
        }
        guard description.contains("Playlist File unchanged") || description.contains("-12888") else {
            return
        }
        if isUserPaused {
            let playerSeconds = currentTime()
            guard playerSeconds.isFinite else { return }
            let mediaSeconds = mediaTime(for: playerSeconds)
            pendingLocalLoopbackRecoveryMediaTime = mediaSeconds
            Self.logger.info(
                "[CMP-AVP] local loopback playlist_unchanged recovery deferred until play media=\(mediaSeconds, privacy: .public) player=\(playerSeconds, privacy: .public)"
            )
            return
        }
        recoverLocalLoopbackStallIfNeeded(item: item, requireBufferedEdge: false, reason: "playlist_unchanged")
    }

    private func handleLoopbackItemDeathEvidence(
        item: AVPlayerItem,
        statusCode: Int?,
        errorDescription: String,
        evidenceWeight: Int,
        trigger: String
    ) {
        guard case .some(.siloLoopback) = currentSourceStrategy,
              item === currentItem,
              didFireFileLoaded,
              !isRecoverySuspended else { return }
        let position = currentTime()
        let action = loopbackItemDeathRecoveryState.record(
            position: position,
            evidenceWeight: evidenceWeight,
            userPaused: isUserPaused
        )
        performLoopbackItemDeathRecoveryAction(
            action,
            item: item,
            position: position,
            trigger: trigger,
            statusCode: statusCode,
            errorDescription: errorDescription
        )
    }

    private func performLoopbackItemDeathRecoveryAction(
        _ action: LoopbackItemDeathRecoveryState.Action,
        item: AVPlayerItem,
        position: Double,
        trigger: String,
        statusCode: Int?,
        errorDescription: String
    ) {
        switch action {
        case .waitForConfirmation:
            cmpLog(
                "[CMP-AVP] loopback item-death evidence waiting trigger=\(trigger) status=\(statusCode ?? 0) userPaused=\(isUserPaused ? 1 : 0) pos=\(position) error=\(errorDescription)"
            )
        case .reload(let attempt):
            loopbackItemDeathConfirmationState.resetCandidate()
            cmpLog(
                "[CMP-AVP] loopback item-death confirmed; reloading item trigger=\(trigger) status=\(statusCode ?? 0) attempt=\(attempt) pos=\(position)"
            )
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, item === self.currentItem, !self.isDisposed else { return }
                self.reloadEstablishedLoopbackItem(
                    item,
                    at: position,
                    reason: "item_death_\(trigger)_\(attempt)"
                )
            }
        case .escalate:
            loopbackItemDeathConfirmationState.resetCandidate()
            cmpLog(
                "[CMP-AVP] loopback item-death repeated at same position; rebuilding Silo loopback trigger=\(trigger) status=\(statusCode ?? 0) pos=\(position)"
            )
            rebuildSiloLoopbackSession(at: position, reason: "loopback_item_death")
        }
    }

    /// Last-resort recovery for a poisoned AVPlayer item or dead producer.
    /// Recreate the complete local-HLS pipeline at the rendered media clock,
    /// but keep the selected route in SiloPlayer. The new UUID-backed cache
    /// cannot collide with cleanup from the retired session.
    private func rebuildSiloLoopbackSession(at playerSeconds: Double, reason: String) {
        guard case .some(.siloLoopback(let spec)) = currentSourceStrategy,
              playerSeconds.isFinite,
              !isUserPaused else { return }
        guard loopbackRebuildBudget.consume() else {
            // Every rebuild resets the latches that decided to rebuild, so
            // without this bound the same wedge rebuilds forever. Hand the
            // failure to the view model's ladder instead.
            reportFailure(.loopbackRebuildBudgetExhausted(
                reason: reason,
                rebuilds: loopbackRebuildBudget.used
            ))
            return
        }
        let mediaSeconds = max(0, mediaTime(for: playerSeconds))
        loopbackItemDeathRecoveryState.reset()
        loopbackItemDeathConfirmationState.resetCandidate()
        watchdogReanchorCount = 0
        watchdogReanchorWindowStartWall = CACurrentMediaTime()
        didEscalateLoopbackStall = false
        Self.logger.error(
            "[CMP-AVP] rebuilding Silo loopback reason=\(reason, privacy: .public) media=\(mediaSeconds, privacy: .public) player=\(playerSeconds, privacy: .public)"
        )
        subtitleSession?.flushOnSeek()
        embeddedSubtitleExtractor?.seek(to: mediaSeconds)
        load(
            strategy: .siloLoopback(spec: spec.reanchored(at: mediaSeconds)),
            startTime: mediaSeconds
        )
    }

    private func recoverLocalLoopbackStallIfNeeded(
        item: AVPlayerItem,
        requireBufferedEdge: Bool = true,
        reason: String = "stall"
    ) {
        guard case .some(.siloLoopback(let spec)) = currentSourceStrategy,
              item === currentItem,
              didFireFileLoaded,
              !isUserPaused,
              !isRecoverySuspended else { return }
        let now = CACurrentMediaTime()
        guard now - lastLocalLoopbackStallRecoveryAt >= 10 else { return }
        let playerSeconds = currentTime()
        guard playerSeconds.isFinite else { return }
        let bufferedAhead = bufferedAheadSeconds(for: item, referenceTime: playerSeconds) ?? 0
        guard !requireBufferedEdge || bufferedAhead <= 0.5 else { return }
        let generatedEnd = latestLoopbackGeneratedStats?.playlistVisibleEndSeconds
            ?? segmentStore?.stats().generatedMediaSeconds
            ?? 0
        let generatedAhead = generatedEnd - playerSeconds
        let minimumGeneratedAhead = playerSeconds < 10 ? Self.loopbackStartupForwardBuffer : 10
        guard generatedAhead > minimumGeneratedAhead else { return }
        lastLocalLoopbackStallRecoveryAt = now
        let mediaSeconds = mediaTime(for: playerSeconds)
        Self.logger.info(
            "[CMP-AVP] local loopback \(reason, privacy: .public) reanchor media=\(mediaSeconds, privacy: .public) player=\(playerSeconds, privacy: .public) generatedAhead=\(generatedAhead, privacy: .public) bufferedAhead=\(bufferedAhead, privacy: .public)"
        )
        subtitleSession?.flushOnSeek()
        embeddedSubtitleExtractor?.seek(to: mediaSeconds)
        load(strategy: .siloLoopback(spec: spec.reanchored(at: mediaSeconds)), startTime: mediaSeconds)
    }

    private func resumeLocalLoopbackPlaybackIfNeeded(for item: AVPlayerItem, trigger: String) {
        guard case .siloLoopback = currentSourceStrategy,
              item === currentItem,
              didFireFileLoaded,
              !isUserPaused,
              // The item played to its end: a buffer KVO arriving afterwards
              // must not restart transport behind the end-of-file handoff.
              !hasReachedItemEnd,
              !isRecoverySuspended,
              avPlayer.rate == 0 else { return }
        let playerSeconds = currentTime()
        guard playerSeconds.isFinite else { return }
        let bufferedAhead = bufferedAheadSeconds(for: item, referenceTime: playerSeconds) ?? 0
        guard item.isPlaybackLikelyToKeepUp || bufferedAhead > 0.5 else { return }
        Self.logger.info(
            "[CMP-AVP] local loopback auto resume trigger=\(trigger, privacy: .public) player=\(playerSeconds, privacy: .public) bufferedAhead=\(bufferedAhead, privacy: .public)"
        )
        avPlayer.play()
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
            self.isSeekPending = false
            self.isInitialSeekInFlight = false

            let landed = self.avPlayer.currentTime().seconds
            let landedMedia = self.mediaTime(for: landed)
            let landedCorrectly = finished && self.isInitialSeekSatisfied(target: mediaTarget, landed: landedMedia)
            Self.logger.info(
                "Initial resume seek completed finished=\(finished, privacy: .public) mediaTarget=\(mediaTarget, privacy: .public) playerTarget=\(playerTarget, privacy: .public) landedPlayer=\(landed, privacy: .public) landedMedia=\(landedMedia, privacy: .public)"
            )

            if landedCorrectly {
                self.hasSeekedToStart = true
                self.initialSeekRetryCount = 0
                self.resyncControlledSubtitlesAfterSeek(mediaSeconds: landedMedia)
                self.startPlaybackIfNeeded(for: item)
                self.onTimeChange?(landed)
                return
            }

            self.initialSeekRetryCount += 1
            if self.initialSeekRetryCount <= 8 {
                let retry = self.initialSeekRetryCount
                Self.logger.warning(
                    "Initial resume seek did not land mediaTarget=\(mediaTarget, privacy: .public) landedMedia=\(landedMedia, privacy: .public) landedPlayer=\(landed, privacy: .public) finished=\(finished, privacy: .public) retry=\(retry, privacy: .public)"
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, !self.isDisposed else { return }
                    self.attemptInitialPlaybackStart(for: item, trigger: "retry-\(retry)")
                }
            } else {
                Self.logger.error(
                    "Initial resume seek failed after retries mediaTarget=\(mediaTarget, privacy: .public) landedMedia=\(landedMedia, privacy: .public) landedPlayer=\(landed, privacy: .public)"
                )
                if self.itemHasSeekableMedia(item, containing: playerTarget) {
                    self.startPlaybackIfNeeded(for: item)
                    self.onTimeChange?(landed)
                }
            }
        }
    }

    private func startPlaybackIfNeeded(for item: AVPlayerItem) {
        armInitialVideoDisplayGateIfNeeded()
        avPlayer.play()
        if isWaitingForInitialVideoDisplay {
            scheduleInitialVideoDisplayFallback(for: item)
        } else {
            finishInitialLoadIfNeeded(for: item)
        }
    }

    private func armLoopbackStartupWatchdogIfNeeded() {
        guard case .siloLoopback = currentSourceStrategy else { return }
        cancelLoopbackStartupWatchdog()
        let now = Date()
        loopbackStartupWatchdogStartedAt = now
        loopbackStartupLastProgressAt = now
        loopbackStartupLastRequestCount = segmentServer?.servedRequestCount ?? 0
        loopbackStartupRecoveryStage = .initial
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
              let item = currentItem,
              let startedAt = loopbackStartupWatchdogStartedAt else {
            cancelLoopbackStartupWatchdog()
            return
        }
        guard item.status != .readyToPlay else {
            cancelLoopbackStartupWatchdog()
            return
        }
        let now = Date()
        let served = segmentServer?.servedRequestCount ?? 0
        if served != loopbackStartupLastRequestCount {
            loopbackStartupLastRequestCount = served
            loopbackStartupLastProgressAt = now
        }
        let displaySwitching = isTVDisplayModeSwitchInProgress()
        if displaySwitching {
            // Don't let the stall window expire the instant an HDMI mode
            // switch completes — restart it from the switch's end.
            loopbackStartupLastProgressAt = now
        }
        let verdict = LoopbackStartupRecoveryPolicy.verdict(
            secondsSinceProgress: now.timeIntervalSince(loopbackStartupLastProgressAt),
            secondsSinceStart: now.timeIntervalSince(startedAt),
            displayModeSwitchInProgress: displaySwitching,
            stallWindow: Self.loopbackStartupStallWindowSeconds,
            absoluteBackstop: Self.loopbackStartupAbsoluteBackstopSeconds
        )
        switch verdict {
        case .wait:
            return
        case .escalate:
            escalateLoopbackStartupRecovery(trigger: "fetches_frozen")
        case .failBackstop:
            cancelLoopbackStartupWatchdog()
            reportFailure(.loopbackStartupBackstop(
                seconds: Int(Self.loopbackStartupAbsoluteBackstopSeconds),
                requestsServed: served,
                stage: "\(loopbackStartupRecoveryStage)"
            ))
        }
    }

    /// Startup recovery ladder (AetherEngine consumer re-engage pattern):
    /// stage 1 nudges AVFoundation's loader with a zero-tolerance seek,
    /// stage 2 swaps in a fresh AVPlayerItem against the same loopback
    /// session, stage 3 reports the error, which hands the decision to
    /// `PlayerViewModel`'s ladder (`attemptSiloRouteHLSFallback` → server-HLS
    /// replan). Also driven directly by the item errorLog observer on
    /// loader-poison signatures.
    private func escalateLoopbackStartupRecovery(trigger: String) {
        guard !isDisposed, !didFireFileLoaded, currentItem != nil,
              !isRecoverySuspended else { return }
        switch loopbackStartupRecoveryStage {
        case .initial:
            loopbackStartupRecoveryStage = .nudged
            loopbackStartupLastProgressAt = Date()
            cmpLog("[CMP-AVP] startup watchdog stage=nudge trigger=\(trigger)")
            nudgeLoopbackStartupConsumer()
        case .nudged:
            loopbackStartupRecoveryStage = .reloaded
            loopbackStartupLastProgressAt = Date()
            cmpLog("[CMP-AVP] startup watchdog stage=reload trigger=\(trigger)")
            reloadLoopbackStartupItem()
        case .reloaded:
            cancelLoopbackStartupWatchdog()
            reportFailure(.loopbackStartupStalled(trigger: trigger))
        }
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
        if case .siloLoopback = currentSourceStrategy {
            item.preferredForwardBufferDuration = Self.loopbackStartupForwardBuffer
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        }
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

    private func cancelLoopbackStartupWatchdog() {
        loopbackStartupWatchdog?.invalidate()
        loopbackStartupWatchdog = nil
        loopbackStartupWatchdogStartedAt = nil
    }

    private func beginInitialVideoDisplayGate() {
        initialVideoDisplayFallback?.cancel()
        initialVideoDisplayFallback = nil
        isInitialVideoDisplayGatePrepared = true
        isWaitingForInitialVideoDisplay = false
        didTemporarilyMuteForInitialVideoDisplay = !avPlayer.isMuted
        if didTemporarilyMuteForInitialVideoDisplay {
            avPlayer.isMuted = true
        }
        Self.logger.info("[CMP-AVP] prepared initial video frame gate before startup audio")
    }

    private func armInitialVideoDisplayGateIfNeeded() {
        guard isInitialVideoDisplayGatePrepared else { return }
        isInitialVideoDisplayGatePrepared = false
        isWaitingForInitialVideoDisplay = true
        initialVideoDisplayGateStartTime = avPlayer.currentTime().seconds
        Self.logger.info("[CMP-AVP] waiting for initial video frame before unmuting startup audio")
    }

    private func releaseInitialVideoDisplayGateIfPlaybackAdvanced(currentTime: Double) {
        guard isWaitingForInitialVideoDisplay, let item = currentItem else { return }
        let startTime = initialVideoDisplayGateStartTime ?? currentTime
        guard currentTime.isFinite, startTime.isFinite, currentTime - startTime >= 0.05 else { return }
        finishInitialVideoDisplayGate(for: item, reason: "playback_clock_advanced")
    }

    private func scheduleInitialVideoDisplayFallback(for item: AVPlayerItem) {
        guard initialVideoDisplayFallback == nil else { return }
        let work = DispatchWorkItem { [weak self, weak item] in
            guard let self, let item, !self.isDisposed, item === self.currentItem else { return }
            self.finishInitialVideoDisplayGate(for: item, reason: "ready_for_display_timeout")
        }
        initialVideoDisplayFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func finishInitialVideoDisplayGate(for item: AVPlayerItem, reason: String) {
        guard item === currentItem, !isDisposed else { return }
        guard isWaitingForInitialVideoDisplay else {
            finishInitialLoadIfNeeded(for: item)
            return
        }
        isWaitingForInitialVideoDisplay = false
        initialVideoDisplayGateStartTime = nil
        initialVideoDisplayFallback?.cancel()
        initialVideoDisplayFallback = nil
        finishInitialLoadIfNeeded(for: item)
        if didTemporarilyMuteForInitialVideoDisplay {
            avPlayer.isMuted = false
            didTemporarilyMuteForInitialVideoDisplay = false
        }
        rampLoopbackBufferToSteadyStateIfNeeded(for: item)
        Self.logger.info("[CMP-AVP] initial video display gate released reason=\(reason, privacy: .public)")
    }

    /// Once the first frame is on screen, apply the steady-state target and
    /// re-enable automatic waiting. Static VOD playlists stay near one segment
    /// so AVPlayer cannot outrun the bounded producer window.
    private func rampLoopbackBufferToSteadyStateIfNeeded(for item: AVPlayerItem) {
        guard case .siloLoopback(let spec) = currentSourceStrategy else { return }
        guard canRampLoopbackBufferToSteadyState else { return }
        let generatedStats = latestLoopbackGeneratedStats
        let mediaBitrate = generatedStats?.rollingBitrateBps ?? spec.sourceBitrateBps
        let target = Self.loopbackSteadyStateForwardBufferTarget
        let shouldRaiseForwardBuffer = item.preferredForwardBufferDuration < target
        let shouldEnableAutomaticWaiting = !avPlayer.automaticallyWaitsToMinimizeStalling
        guard shouldRaiseForwardBuffer || shouldEnableAutomaticWaiting else { return }
        if shouldRaiseForwardBuffer {
            item.preferredForwardBufferDuration = target
        }
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        Self.logger.info(
            "[CMP-AVP] loopback buffer ramp forwardBuffer=\(target, privacy: .public)s automaticallyWaits=1 mediaBitrate=\(mediaBitrate ?? 0, privacy: .public)bps generatedBitrate=\(generatedStats?.rollingBitrateBps ?? 0, privacy: .public)bps declaredBitrate=\(spec.sourceBitrateBps ?? 0, privacy: .public)bps sourceReadBitrate=\(self.loopbackSourceDownloadBitrateBps ?? 0, privacy: .public)bps targetDuration=\(generatedStats?.targetDuration ?? 0, privacy: .public) longestSegment=\(generatedStats?.longestSegmentDuration ?? 0, privacy: .public)"
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

    private func finishInitialLoadIfNeeded(for item: AVPlayerItem) {
        guard !didFireFileLoaded else { return }
        cancelLoopbackStartupWatchdog()
        didFireFileLoaded = true
        onFileLoaded?()
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
        loopbackItemDeathRecoveryState.reset()
        loopbackItemDeathConfirmationState.reset()
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
        activeLoopbackSessionID = nil
        loopbackPlaylistName = nil
        loopbackPlaybackUsesExternalURL = false
        isInitialSeekInFlight = false
        initialSeekRetryCount = 0
        isInitialVideoDisplayGatePrepared = false
        isWaitingForInitialVideoDisplay = false
        initialVideoDisplayGateStartTime = nil
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

        let writer = segmentWriter
        segmentWriter = nil
        writer?.onFirstSegmentReady = nil
        writer?.onSegmentAppended = nil
        writer?.onSourceDownloadStats = nil
        writer?.onGeneratedMediaStats = nil
        writer?.onHDR10PlusMetadataDetected = nil
        writer?.onFinished = nil
        segmentServer?.stop()
        segmentServer = nil
        segmentStore = nil
        latestLoopbackGeneratedStats = nil
        loopbackEdgeWatch = nil

        let dir = sessionDirectory
        let preserveDir = preserveSessionDirectory
        sessionDirectory = nil
        preserveSessionDirectory = false
        writer?.stop {
            if let dir, preserveDir {
                cmpLog("[CMP-AVP] retained local DV artifacts dir=\(dir.path)")
            } else if let dir {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        if writer == nil, let dir {
            if preserveDir {
                cmpLog("[CMP-AVP] retained local DV artifacts dir=\(dir.path)")
            } else {
                try? FileManager.default.removeItem(at: dir)
            }
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
        preserveLoopbackArtifactsIfDebugEnabled(reason: "avplayer_item_failed")
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

    private func preserveLoopbackArtifactsIfDebugEnabled(reason: String) {
        guard Self.keepLoopbackArtifacts else { return }
        guard let dir = sessionDirectory else { return }
        if !preserveSessionDirectory {
            cmpLog("[CMP-AVP] preserving local DV artifacts after \(reason) dir=\(dir.path)")
        }
        preserveSessionDirectory = true
    }

    private static var keepLoopbackArtifacts: Bool {
        let raw = ProcessInfo.processInfo.environment["SILO_KEEP_DV_HLS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "1" || raw == "true" || raw == "yes"
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

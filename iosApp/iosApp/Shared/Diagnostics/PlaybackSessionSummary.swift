import Foundation

/// How one playback session went: startup time, waits for data, plan and
/// bitrate changes, and errors. Fixed-size by construction; it holds counts
/// and one failure token, never titles, URLs or identifiers.
struct PlaybackSessionSummary: Equatable {
    enum Outcome: String {
        case inProgress = "in_progress"
        case ended
        case stopped
    }

    /// Server plan delivery token, such as `original_http`.
    var playMethod: String
    var startedAt: TimeInterval
    var endedAt: TimeInterval?
    var outcome: Outcome = .inProgress
    var firstFrameMs: Int?
    /// Every wait for data after the first frame.
    var stallCount = 0
    var stallTotalMs = 0
    /// The waits no seek or reload explains.
    var rebufferCount = 0
    var rebufferTotalMs = 0
    var rebufferMaxMs = 0
    var bitrateKbps: Int?
    var bitrateChangeCount = 0
    var planChangeCount = 0
    var errorCount = 0
    /// `PlaybackErrorKind` raw value of the latest failure.
    var failureCode: String?

    func sessionMs(at now: TimeInterval) -> Int {
        Self.milliseconds(from: startedAt, to: endedAt ?? now)
    }

    static func milliseconds(from start: TimeInterval, to end: TimeInterval) -> Int {
        max(0, Int(((end - start) * 1000).rounded()))
    }

    mutating func recordWait(ms: Int, isRebuffer: Bool) {
        stallCount += 1
        stallTotalMs += ms
        if isRebuffer {
            rebufferCount += 1
            rebufferTotalMs += ms
            rebufferMaxMs = max(rebufferMaxMs, ms)
        }
    }
}

/// Builds a `PlaybackSessionSummary` from the playback controller's events.
///
/// The controller calls in on the main thread; each call only updates memory
/// under `lock`. A summary leaves the recorder through `emit` at a few points
/// (first frame, failure, session end, and at most once a minute after a
/// wait), and the default `emit` writes it on a background queue so the
/// diagnostics I/O never runs on the main thread.
final class PlaybackSessionSummaryRecorder {
    /// A wait that starts this soon after a seek or a load is explained by it.
    static let seekGrace: TimeInterval = 2
    static let checkpointInterval: TimeInterval = 60

    private let lock = NSLock()
    private let now: () -> TimeInterval
    /// Receives each summary, the time it was taken, and the session's owner.
    private let emit: (PlaybackSessionSummary, TimeInterval, String?) -> Void
    private let currentOwner: () -> String?
    private var sessionID: String?
    /// Who was signed in when the session began (see `currentOwner`).
    private var owner: String?
    private var planID: String?
    private var summary: PlaybackSessionSummary?
    private var waitStartedAt: TimeInterval?
    private var waitIsRebuffer = false
    private var lastSeekOrLoadAt: TimeInterval = 0
    private var lastEmitAt: TimeInterval = 0

    /// `currentOwner` names the server account and profile playing, in the
    /// form `diagnosticsOwner(binding:profileID:)` builds; nil when unknown.
    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        emit: @escaping (PlaybackSessionSummary, TimeInterval, String?) -> Void = PlaybackSessionSummaryRecorder.recordDiagnostics,
        currentOwner: @escaping () -> String? = PlaybackSessionSummaryRecorder.currentDiagnosticsOwner
    ) {
        self.now = now
        self.emit = emit
        self.currentOwner = currentOwner
    }

    /// A load began. A new server session starts a new summary (finishing the
    /// previous one); a new plan in the same session is a plan change.
    func loadBegan(sessionID: String, planID: String, playMethod: String) {
        let time = now()
        update { recorder in
            if recorder.sessionID != sessionID || recorder.summary == nil {
                recorder.finishLocked(.stopped, at: time)
                recorder.sessionID = sessionID
                recorder.owner = recorder.currentOwner()
                recorder.summary = PlaybackSessionSummary(playMethod: playMethod, startedAt: time)
            } else if recorder.planID != planID {
                recorder.summary?.planChangeCount += 1
                recorder.summary?.playMethod = playMethod
            }
            recorder.planID = planID
            recorder.waitStartedAt = nil
            recorder.lastSeekOrLoadAt = time
        }
    }

    func firstFrame(bitrateBps: Int64) {
        let time = now()
        update { recorder in
            guard var summary = recorder.summary else { return }
            var startupMeasured = false
            if summary.firstFrameMs == nil {
                summary.firstFrameMs = PlaybackSessionSummary.milliseconds(from: summary.startedAt, to: time)
                startupMeasured = true
            }
            if bitrateBps > 0 {
                let kbps = Int(bitrateBps / 1000)
                if let previous = summary.bitrateKbps, previous != kbps {
                    summary.bitrateChangeCount += 1
                }
                summary.bitrateKbps = kbps
            }
            recorder.summary = summary
            if startupMeasured {
                recorder.emitLocked(at: time)
            }
        }
    }

    func bufferingChanged(_ isBuffering: Bool) {
        let time = now()
        update { recorder in
            guard var summary = recorder.summary, summary.firstFrameMs != nil else { return }
            if isBuffering {
                guard recorder.waitStartedAt == nil else { return }
                recorder.waitStartedAt = time
                recorder.waitIsRebuffer = time - recorder.lastSeekOrLoadAt > Self.seekGrace
                // Checkpoint as the wait begins too, so a run killed during
                // a long wait still has it on record.
                if time - recorder.lastEmitAt >= Self.checkpointInterval {
                    recorder.emitLocked(at: time)
                }
                return
            }
            guard let started = recorder.waitStartedAt else { return }
            recorder.waitStartedAt = nil
            summary.recordWait(
                ms: PlaybackSessionSummary.milliseconds(from: started, to: time),
                isRebuffer: recorder.waitIsRebuffer
            )
            recorder.summary = summary
            if time - recorder.lastEmitAt >= Self.checkpointInterval {
                recorder.emitLocked(at: time)
            }
        }
    }

    func seekRequested() {
        let time = now()
        update { $0.lastSeekOrLoadAt = time }
    }

    func failed(code: String) {
        let time = now()
        update { recorder in
            guard recorder.summary != nil else { return }
            recorder.summary?.errorCount += 1
            recorder.summary?.failureCode = code
            recorder.emitLocked(at: time)
        }
    }

    func ended() {
        let time = now()
        update { $0.finishLocked(.ended, at: time) }
    }

    func stopped() {
        let time = now()
        update { $0.finishLocked(.stopped, at: time) }
    }

    // MARK: - Latest summary

    /// A wait for data that has begun and not yet ended.
    private typealias OpenWait = (startedAt: TimeInterval, isRebuffer: Bool)

    private struct Latest {
        var summary: PlaybackSessionSummary
        var openWait: OpenWait?
        var owner: String?
    }

    private static let latestLock = NSLock()
    private static var latest: Latest?

    /// The most recent session's summary in this process, open or finished,
    /// if it was played by `owner`. An open session's `sessionMs` and any
    /// wait still in progress are measured at `now`. Reports captured in this
    /// run attach it.
    static func latestSummary(
        owner: String?,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> (summary: PlaybackSessionSummary, now: TimeInterval)? {
        latestLock.lock()
        defer { latestLock.unlock() }
        guard let latest, let owner, latest.owner == owner else { return nil }
        return (folding(latest.openWait, into: latest.summary, at: now), now)
    }

    static func resetLatestForTesting() {
        latestLock.lock()
        latest = nil
        latestLock.unlock()
    }

    // MARK: - Private

    private func update(_ change: (PlaybackSessionSummaryRecorder) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(self)
        publishLatestLocked()
    }

    private func publishLatestLocked() {
        guard let summary else { return }
        let published = Latest(summary: summary, openWait: openWaitLocked, owner: owner)
        Self.latestLock.lock()
        Self.latest = published
        Self.latestLock.unlock()
    }

    private var openWaitLocked: OpenWait? {
        waitStartedAt.map { ($0, waitIsRebuffer) }
    }

    /// `summary` with a wait still in progress counted as if it ended at `time`.
    private static func folding(
        _ openWait: OpenWait?,
        into summary: PlaybackSessionSummary,
        at time: TimeInterval
    ) -> PlaybackSessionSummary {
        guard let openWait else { return summary }
        var folded = summary
        folded.recordWait(
            ms: PlaybackSessionSummary.milliseconds(from: openWait.startedAt, to: time),
            isRebuffer: openWait.isRebuffer
        )
        return folded
    }

    private func finishLocked(_ outcome: PlaybackSessionSummary.Outcome, at time: TimeInterval) {
        guard let current = summary else { return }
        // A wait still open when the session ends lasted until now.
        var finished = Self.folding(openWaitLocked, into: current, at: time)
        finished.outcome = outcome
        finished.endedAt = time
        summary = finished
        waitStartedAt = nil
        emitLocked(at: time)
        publishLatestLocked()
        summary = nil
        sessionID = nil
        owner = nil
        planID = nil
    }

    private func emitLocked(at time: TimeInterval) {
        guard let summary else { return }
        lastEmitAt = time
        emit(Self.folding(openWaitLocked, into: summary, at: time), time, owner)
    }
}

#if os(iOS) || os(tvOS)
extension PlaybackSessionSummaryRecorder {
    /// The identity a summary is attributed to: the diagnostics binding and
    /// capturing profile, as `DiagnosticsCaptureContext` carries them.
    static func diagnosticsOwner(binding: DiagnosticsBinding, profileID: String?) -> String {
        "\(binding.storageKey)|\(profileID ?? "")"
    }

    static func currentDiagnosticsOwner() -> String? {
        DiagnosticsCoordinator.currentDiagnosticsBinding.map {
            diagnosticsOwner(binding: $0, profileID: AuthService.shared.profileId)
        }
    }
}

extension PlaybackSessionSummary {
    func diagnosticsAttributes(at now: TimeInterval) -> [String: DiagLogAttributeValue] {
        var attrs: [String: DiagLogAttributeValue] = [
            "reason": .string(outcome.rawValue),
            "play_method": .string(playMethod),
            "stall_count": .int(stallCount),
            "stall_total_ms": .int(stallTotalMs),
            "rebuffer_count": .int(rebufferCount),
            "rebuffer_total_ms": .int(rebufferTotalMs),
            "rebuffer_max_ms": .int(rebufferMaxMs),
            "bitrate_change_count": .int(bitrateChangeCount),
            "plan_change_count": .int(planChangeCount),
            "error_count": .int(errorCount),
            "session_ms": .int(sessionMs(at: now)),
        ]
        attrs["first_frame_ms"] = firstFrameMs.map(DiagLogAttributeValue.int)
        attrs["bitrate_kbps"] = bitrateKbps.map(DiagLogAttributeValue.int)
        attrs["failure_code"] = failureCode.map(DiagLogAttributeValue.string)
        return attrs
    }

    static let diagnosticsTag = "PlaybackSummary"
    static let diagnosticsMessage = "playback session summary"

    /// The summary as one rendered diagnostics line, for attaching to a report.
    func renderedDiagnosticsLine(at now: TimeInterval) -> String? {
        DiagLog.renderedLine(
            level: .info,
            category: .playback,
            tag: Self.diagnosticsTag,
            message: Self.diagnosticsMessage,
            attrs: diagnosticsAttributes(at: now)
        )
    }
}

extension PlaybackSessionSummaryRecorder {
    private static let diagnosticsQueue = DispatchQueue(
        label: "org.siloserver.silo.playback-summary",
        qos: .utility
    )

    /// Record the summary as a playback breadcrumb, which the journal keeps
    /// across launches so an abnormal-exit report carries the crashed run's
    /// latest summary.
    static func recordDiagnostics(_ summary: PlaybackSessionSummary, at now: TimeInterval, owner: String?) {
        diagnosticsQueue.async(execute: diagnosticsWrite(for: summary, at: now, owner: owner))
    }

    /// The breadcrumb write for a summary that `owner`'s session produced.
    /// It runs later on `diagnosticsQueue`, and writes nothing if by then the
    /// active owner changed or evidence was erased: a profile purge must not
    /// be followed by the old profile's summary landing under the new one.
    static func diagnosticsWrite(
        for summary: PlaybackSessionSummary,
        at now: TimeInterval,
        owner: String?,
        currentEpoch: @escaping () -> DiagnosticsEvidenceEpoch = DiagnosticsCoordinator.currentEvidenceEpoch,
        write: @escaping (DiagnosticsLogLevel, [String: DiagLogAttributeValue]) -> Void = { level, attrs in
            DiagTrace.breadcrumb(
                .essential,
                level: level,
                category: .playback,
                tag: PlaybackSessionSummary.diagnosticsTag,
                message: PlaybackSessionSummary.diagnosticsMessage,
                attrs: attrs
            )
        }
    ) -> () -> Void {
        let attrs = summary.diagnosticsAttributes(at: now)
        let level: DiagnosticsLogLevel = summary.errorCount > 0 || summary.rebufferCount > 0 ? .warning : .info
        let epoch = DiagnosticsEvidenceEpoch(owner: owner, erasureGeneration: currentEpoch().erasureGeneration)
        return {
            guard currentEpoch() == epoch else { return }
            write(level, attrs)
        }
    }
}
#else
extension PlaybackSessionSummaryRecorder {
    static func recordDiagnostics(_ summary: PlaybackSessionSummary, at now: TimeInterval, owner: String?) {}
    static func currentDiagnosticsOwner() -> String? { nil }
}
#endif

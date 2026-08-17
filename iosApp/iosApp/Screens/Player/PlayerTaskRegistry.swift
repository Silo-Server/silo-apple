import Foundation

/// Scope-tagged storage for `PlayerViewModel`'s background tasks.
///
/// Every teardown path in the view model — `cleanup()`, `deinit`,
/// `resetPublishedLoadState`, `suspendForBackground`,
/// `finalizeTerminalPlaybackError` — used to carry its own hand-maintained
/// list of `task?.cancel()` lines, and the lists had drifted apart: background
/// suspend, for instance, left the V3 replan, session renewal, outage
/// recovery, Next Up countdown, and auto-skip countdown tasks running against
/// a session it was about to stop.
///
/// Tasks now live here under a `Key` that declares which sweeps they belong
/// to, so a teardown path cancels by scope and a newly added task joins every
/// relevant sweep by declaring its scopes once, in `Key.scopes`.
///
/// The view model keeps a named accessor per key (`freshLoadTask`, …) so call
/// sites read the same as before; only the storage and the sweeps moved.
final class PlayerTaskRegistry {

    /// A teardown sweep. A key may belong to several.
    enum Scope {
        /// The view model is going away. Cancels everything except the
        /// cleanup-completion task, which *is* the teardown.
        case teardown
        /// Transient UI affordances: control auto-hide, notice dismissal,
        /// seek debouncing and filtering, the hold-seek session.
        case interaction
        /// Work bound to the stream that is currently loaded — it becomes
        /// meaningless the moment that stream is replaced or suspended.
        case activeStream
        /// Server-facing recovery for the *current* playback session:
        /// renewal, stale-session repair, and outage ride-through.
        case sessionRecovery
    }

    enum Key: CaseIterable {
        case cleanupCompletion
        case suspendStopSession
        case settingsRefresh

        case freshLoad
        case protocolV3Replan
        case progress
        case nextUpCountdown
        case autoSkipIntroCountdown

        case staleSessionRecovery
        case backgroundRenewal
        case sourceOutageRideThrough
        case serverOutageRecovery
        case interruptionRecovery

        case nextUpLookup
        case nextUpOnDeck
        case deferredLiveSubtitleClose
        case pictureInPictureBackgroundGrace

        case hideControls
        case noticeDismiss
        case remoteDismiss
        case skipDebounce
        case seekFilterTimeout
        case holdSeek
        case holdSeekAutoRamp

        var scopes: Set<Scope> {
            switch self {
            // The final progress flush. Teardown installs it, so no sweep may
            // cancel it.
            case .cleanupCompletion:
                return []
            // The tvOS background-suspend stop. Suspend itself installs it
            // (after its own sweeps), and the bridge's identity guard is what
            // makes a resume that overtakes it safe — so no sweep may cancel
            // it either. Registered purely so it is observable rather than
            // unstructured.
            case .suspendStopSession:
                return []
            // Awaited by `beginFreshLoad` instead of being reissued, so it
            // only dies with the view model.
            case .settingsRefresh:
                return [.teardown]

            case .freshLoad, .protocolV3Replan, .progress,
                 .nextUpCountdown, .autoSkipIntroCountdown:
                return [.teardown, .activeStream]

            case .staleSessionRecovery, .backgroundRenewal, .sourceOutageRideThrough,
                 .serverOutageRecovery, .interruptionRecovery:
                return [.teardown, .sessionRecovery]

            case .nextUpLookup, .nextUpOnDeck, .deferredLiveSubtitleClose,
                 .pictureInPictureBackgroundGrace:
                return [.teardown]

            case .hideControls, .noticeDismiss, .remoteDismiss, .skipDebounce,
                 .seekFilterTimeout, .holdSeek, .holdSeekAutoRamp:
                return [.teardown, .interaction]
            }
        }
    }

    private var tasks: [Key: Task<Void, Never>] = [:]

    subscript(key: Key) -> Task<Void, Never>? {
        get { tasks[key] }
        set { tasks[key] = newValue }
    }

    /// Cancel and drop every task in `scopes`.
    func cancelAll(in scopes: Scope...) {
        for key in Key.allCases where scopes.contains(where: key.scopes.contains) {
            tasks[key]?.cancel()
            tasks[key] = nil
        }
    }
}

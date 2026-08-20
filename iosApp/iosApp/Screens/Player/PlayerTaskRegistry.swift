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
        /// The registry's owner is going away. Cancels everything except the
        /// two keys whose task *is* the teardown.
        case teardown
        /// Transient UI affordances: control auto-hide, notice dismissal,
        /// seek debouncing and filtering, the hold-seek session.
        case interaction
    }

    enum Key: CaseIterable {
        case cleanupCompletion
        case suspendStopSession
        case settingsRefresh

        case engineEvents
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
            case .hideControls, .noticeDismiss, .remoteDismiss, .skipDebounce,
                 .seekFilterTimeout, .holdSeek, .holdSeekAutoRamp:
                return [.teardown, .interaction]
            // Everything else lives as long as the object that owns the
            // registry. The control plane cancels its own timers one key at a
            // time (`Effect.cancelTimer`, e.g. the suspend sweep) and the shell
            // does the same for its UI work, so the only sweep these belong to
            // is the final one. `.engineEvents` in particular must never be
            // cancelled earlier than that: it ends on its own when the session
            // owning the stream is disposed, and cutting it short would drop
            // the events a dying load still owes (`.failed`, the terminal
            // `.endOfFile`). `.settingsRefresh` is awaited by `beginFreshLoad`
            // rather than reissued.
            case .settingsRefresh, .engineEvents, .freshLoad, .protocolV3Replan,
                 .progress, .nextUpCountdown, .autoSkipIntroCountdown,
                 .staleSessionRecovery, .backgroundRenewal, .sourceOutageRideThrough,
                 .serverOutageRecovery, .interruptionRecovery, .nextUpLookup,
                 .nextUpOnDeck, .pictureInPictureBackgroundGrace:
                return [.teardown]
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

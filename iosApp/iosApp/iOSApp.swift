import SwiftUI

@main
struct SiloApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(SiloAppDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(tvOS)
        ExitSentinel.shared.appDidLaunch()
        // No-op unless launched with `-perfHitchLog`.
        TVFrameHitchMonitor.installIfRequested()
        #endif

        // Install the shared Nuke-backed image cache before any SwiftUI view
        // runs so poster/backdrop-heavy screens reuse the same pipeline on
        // both iOS and tvOS.
        PosterImageCache.install()

        #if os(iOS) || os(tvOS)
        // Aether's optional host stream enters Silo diagnostics only through a
        // media-specific redactor and the existing consent/debug-logging gate.
        // General Apple unified logs are never collected into a Silo report.
        AetherDiagnosticsBridge.install()

        // Opens the launch phase timeline. This runs before any consent
        // context exists, so the line lands in `EarlyBootBuffer` and only
        // reaches disk if this launch's first consent establish permits it —
        // that staging is exactly what makes a launch-path crash reportable.
        LaunchTimeline.recordProcessStart()
        #endif

        #if os(iOS)
        MetricKitCapture.shared.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    // The browser sign-in's app redirect is never a deep
                    // link: it goes to the flow in progress, or nowhere.
                    if NativeSignIn.isCallback(url) {
                        #if !os(tvOS)
                        SystemWebAuthenticationRunner.shared.receiveExternalCallback(url)
                        #endif
                        return
                    }
                    SiloDeepLinkCoordinator.shared.receive(url)
                }
                #if os(macOS)
                // Deliver URLs to this window instead of opening a new one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .background(MacWindowPlacement())
                #endif
        }
    }
}

#if os(iOS) || os(tvOS)
/// Launch and lifecycle breadcrumbs (category `.lifecycle`) written to the
/// breadcrumb journal, which survives the process, so a launch that dies leaves
/// the chain truncated where it stopped. `duration_ms` is the gap since the
/// previous phase. Tags: `App` (process), `Startup` (cold-launch chain),
/// `Scene` (scene phase). Keep this path allocation-light.
@MainActor
enum LaunchTimeline {
    /// Monotonic, so a wall-clock correction right after boot cannot produce a
    /// negative or inflated `duration_ms`.
    private static var lastMark = DispatchTime.now()
    /// Set on `.background` and consumed by the next `.active`, so an
    /// `.inactive → .active` blip (Control Center, app switcher) is not logged
    /// as a warm return, and the warm return is timed from the real
    /// background edge.
    private static var backgroundedAt: DispatchTime?
    private static var didRecordRootView = false
    private static var didRecordFirstContent = false

    // MARK: - Marks

    /// A monotonic point for callers that time their own work (prefetches,
    /// foreground refreshes) rather than advancing the phase chain.
    nonisolated static func mark() -> DispatchTime { .now() }

    nonisolated static func milliseconds(since mark: DispatchTime) -> Int {
        milliseconds(from: mark, to: .now())
    }

    /// Unsigned subtraction traps on underflow, so the order is checked.
    nonisolated private static func milliseconds(from start: DispatchTime, to end: DispatchTime) -> Int {
        let startNanos = start.uptimeNanoseconds
        let endNanos = end.uptimeNanoseconds
        guard endNanos > startNanos else { return 0 }
        return Int((endNanos - startNanos) / 1_000_000)
    }

    // MARK: - Launch chain

    /// `SiloApp.init`. Runs before any consent context exists, so the line
    /// stages in `EarlyBootBuffer` until the first consent establish permits
    /// it. Always `cold`: the warm counterpart is `recordScenePhase`.
    static func recordProcessStart() {
        lastMark = .now()
        record(
            tag: "App",
            phase: "process_start",
            message: "app launched",
            state: "launch",
            launchType: "cold",
            includesDuration: false
        )
    }

    /// The root view's first `onAppear`. A launch that logs `process_start`
    /// and nothing else died in static setup or scene creation.
    static func recordRootViewAppeared() {
        guard !didRecordRootView else { return }
        didRecordRootView = true
        record(phase: "root_view", message: "root view appeared")
    }

    /// Separates "never started the stored-session check" from "started it
    /// and hung".
    static func recordInitialStateCheckStarted() {
        record(.verbose, phase: "initial_state", message: "initial state check started")
    }

    /// A route committed under the splash: the stored session's, then the
    /// validated one if it differs. `state` is the auth-state token.
    static func recordInitialStateResolved(state: String) {
        record(phase: "initial_state", message: "initial state resolved", state: state)
    }

    /// The startup splash animation finished.
    static func recordSplashFinished() {
        record(phase: "splash", message: "startup splash finished")
    }

    /// The splash lifted over a committed route: the first usable frame.
    /// Closes the cold-launch chain; its absence means the user never got a
    /// usable app.
    static func recordFirstContent(state: String) {
        guard !didRecordFirstContent else { return }
        didRecordFirstContent = true
        record(
            phase: "first_content",
            message: "startup content revealed",
            state: state,
            outcome: "success"
        )
    }

    // MARK: - Run lifecycle

    /// Every scene-phase edge. `.inactive` is verbose: it fires for every
    /// Control Center pull, banner, and app-switcher peek.
    static func recordScenePhase(_ state: String) {
        switch state {
        case "active":
            let backgroundStart = backgroundedAt
            backgroundedAt = nil
            if let backgroundStart {
                // The time spent backgrounded, measured from the background
                // edge rather than the chain's last mark.
                record(
                    tag: "Scene",
                    phase: "foreground",
                    message: "app foregrounded",
                    state: state,
                    launchType: "warm",
                    duration: milliseconds(since: backgroundStart)
                )
            } else {
                record(tag: "Scene", phase: "scene", message: "scene became active", state: state)
            }
        case "background":
            backgroundedAt = .now()
            record(tag: "Scene", phase: "background", message: "app backgrounded", state: state)
        default:
            record(.verbose, tag: "Scene", phase: "scene", message: "scene phase changed", state: state)
        }
    }

    /// Warning level: the usual next event is a jetsam kill, which leaves no
    /// other trace.
    static func recordMemoryWarning(state: String) {
        record(
            level: .warning,
            tag: "App",
            phase: "memory_warning",
            message: "memory warning",
            state: state
        )
    }

    /// A clean termination; an abnormal-exit report without this line did not
    /// shut down through the normal path.
    static func recordTermination(state: String) {
        record(tag: "App", phase: "terminate", message: "app terminating", state: state)
    }

    // MARK: - Off-chain outcomes

    /// Outcome of a server refresh that is not a phase transition, timed from
    /// the caller's own `mark()`. Failures are essential and successes verbose,
    /// so the happy path does not spend the report's breadcrumb budget.
    static func recordRefreshOutcome(
        phase: String,
        since mark: DispatchTime,
        failureReason: String?
    ) {
        var attrs: [String: DiagLogAttributeValue] = [
            "phase": .string(phase),
            "duration_ms": .int(milliseconds(since: mark)),
            "outcome": .string(failureReason == nil ? "success" : "failure"),
        ]
        if let failureReason {
            attrs["reason"] = .string(failureReason)
        }
        DiagTrace.breadcrumb(
            failureReason == nil ? .verbose : .essential,
            level: failureReason == nil ? .info : .warning,
            category: .lifecycle,
            tag: "Startup",
            message: "content refresh finished",
            attrs: attrs
        )
    }

    // MARK: - Emission

    private static func record(
        _ verbosity: DiagnosticsVerbosity = .essential,
        level: DiagnosticsLogLevel = .info,
        tag: String = "Startup",
        phase: String,
        message: String,
        state: String? = nil,
        outcome: String? = nil,
        launchType: String? = nil,
        includesDuration: Bool = true,
        duration: Int? = nil
    ) {
        // The chain advances even when the tier suppresses the line, so a
        // suppressed step cannot fold its time into the next one. `duration`
        // overrides only what is reported (the background dwell).
        var attrs: [String: DiagLogAttributeValue] = ["phase": .string(phase)]
        if includesDuration {
            let now = DispatchTime.now()
            let previous = lastMark
            lastMark = now
            attrs["duration_ms"] = .int(duration ?? milliseconds(from: previous, to: now))
        }
        if let state { attrs["state"] = .string(state) }
        if let outcome { attrs["outcome"] = .string(outcome) }
        if let launchType { attrs["launch_type"] = .string(launchType) }
        DiagTrace.breadcrumb(
            verbosity,
            level: level,
            category: .lifecycle,
            tag: tag,
            message: message,
            attrs: attrs
        )
    }
}
#endif

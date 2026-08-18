#if os(iOS) || os(tvOS)
import Foundation

/// The two-tier verbosity contract shared by every instrumented subsystem
/// (playback, focus, network, lifecycle).
///
/// `essential` covers phase transitions, errors, failures, and state changes:
/// the lines a crash bundle is useless without. `verbose` covers
/// high-frequency detail (per-request traces, 1 Hz telemetry) that is only
/// worth its log volume when the user has explicitly turned on Debug Logging.
enum DiagnosticsVerbosity {
    case essential
    case verbose

    var isVerbose: Bool { self == .verbose }
}

/// Single decision point for "should this diagnostic line be recorded?", plus
/// thin emitters so call sites stay one-liners instead of each re-deriving the
/// predicate from `DiagnosticsConsentStore` / `DiagnosticsCoordinator`.
///
/// Gating differs by destination, and the difference is deliberate:
///
/// * `DiagTrace.log` writes to `DiagLog.ring`, the in-memory ring. `DiagLog`
///   itself performs **no** consent check — the capture gate has always lived
///   at the call site (this is exactly what `cmpLog` did before this helper
///   existed), so it lives here.
/// * `DiagTrace.breadcrumb` writes to the on-disk `BreadcrumbJournal`, whose
///   consent gate lives inside `appendRenderedLine` and purges the journal
///   directory when capture is off. Pre-checking the capture gate here would
///   skip that purge, so this path applies the verbosity tier only and lets
///   `DiagnosticsCoordinator.recordBreadcrumb` route the line — to the journal
///   once the launch's consent decision is in effect, and to `EarlyBootBuffer`
///   before then, when a journal refusal would purge the previous run's
///   evidence rather than enforce a denial.
///
/// Do not "unify" those two by adding a capture check to the breadcrumb path or
/// removing it from the ring path; that changes what is gated, not how it is
/// tiered.
enum DiagTrace {
    // MARK: - Predicates

    /// Pure, injectable form of the tiering decision for ring capture.
    /// Semantics are the historical `shouldCaptureCMPLog` predicate verbatim:
    /// capture must be on, and verbose lines additionally require the user's
    /// Debug Logging toggle.
    static func shouldCapture(
        _ verbosity: DiagnosticsVerbosity,
        debugLoggingEnabled: Bool,
        captureEnabled: Bool
    ) -> Bool {
        captureEnabled && (!verbosity.isVerbose || debugLoggingEnabled)
    }

    /// The verbosity half of the predicate on its own, for destinations that
    /// already own their consent gate (the breadcrumb journal).
    static func isTierEnabled(
        _ verbosity: DiagnosticsVerbosity,
        debugLoggingEnabled: Bool
    ) -> Bool {
        !verbosity.isVerbose || debugLoggingEnabled
    }

    /// Live-state form of `shouldCapture`, reading the user's Debug Logging
    /// toggle and the diagnostics capture gate.
    ///
    /// This runs on *every* instrumented call, including the verbose lines it
    /// then suppresses (`perform()` emits one per HTTP response), so both reads
    /// must stay cheap. `debugLoggingEnabled` is a single `UserDefaults` bool;
    /// `isDiagnosticsCaptureEnabled` is memoized by
    /// `DiagnosticsCaptureGateCache` in the coordinator, which invalidates on
    /// every consent/destination/profile boundary and fails closed. Neither read
    /// may write to `UserDefaults` — see `persistentCaptureEnabled`, which
    /// deliberately resolves the notice-version migration in memory instead of
    /// persisting it, so asking "should I log?" cannot mutate consent state.
    static func shouldCapture(_ verbosity: DiagnosticsVerbosity) -> Bool {
        shouldCapture(
            verbosity,
            debugLoggingEnabled: debugLoggingEnabled,
            captureEnabled: DiagnosticsCoordinator.isDiagnosticsCaptureEnabled
        )
    }

    /// Live-state form of `isTierEnabled`.
    static func isTierEnabled(_ verbosity: DiagnosticsVerbosity) -> Bool {
        isTierEnabled(verbosity, debugLoggingEnabled: debugLoggingEnabled)
    }

    private static var debugLoggingEnabled: Bool {
        DiagnosticsConsentStore.shared.debugLoggingEnabled
    }

    // MARK: - Emission

    /// Records a line in the in-memory diagnostics ring when the tier and the
    /// capture gate allow it. `message` and `attrs` are autoclosures so a
    /// suppressed verbose line costs nothing to skip.
    ///
    /// Every key in `attrs` must exist in `DiagLogAttributeRegistry` for
    /// `category`; unregistered keys are dropped by the self-hosted collector,
    /// rejected outright by the hosted one, and `assertionFailure` in DEBUG.
    /// Encode unregistered concepts in `message` instead.
    static func log(
        _ verbosity: DiagnosticsVerbosity,
        level: DiagnosticsLogLevel = .info,
        category: DiagnosticsLogCategory,
        tag: String,
        message: @autoclosure () -> String,
        attrs: @autoclosure () -> [String: DiagLogAttributeValue] = [:]
    ) {
        guard shouldCapture(verbosity) else { return }
        switch level {
        case .verbose, .debug:
            DiagLog.d(category, tag, message(), attrs())
        case .info:
            DiagLog.i(category, tag, message(), attrs())
        case .warning:
            DiagLog.w(category, tag, message(), attrs())
        case .error:
            DiagLog.e(category, tag, message(), attrs())
        }
    }

    /// Records a line in the persistent breadcrumb journal when the tier allows
    /// it. The journal applies the consent gate (and its purge-on-disabled side
    /// effect) itself, so this path deliberately does not pre-check capture.
    ///
    /// Only `.lifecycle`, `.playback`, and `.focus` are breadcrumb categories;
    /// anything else is rejected by the journal. Network lines belong in `log`.
    @discardableResult
    static func breadcrumb(
        _ verbosity: DiagnosticsVerbosity,
        level: DiagnosticsLogLevel = .info,
        category: DiagnosticsLogCategory,
        tag: String,
        message: @autoclosure () -> String,
        attrs: @autoclosure () -> [String: DiagLogAttributeValue] = [:],
        timestamp: Date = Date()
    ) -> Bool {
        guard isTierEnabled(verbosity) else { return false }
        return DiagnosticsCoordinator.recordBreadcrumb(
            level: level,
            category: category,
            tag: tag,
            message: message(),
            attrs: attrs(),
            timestamp: timestamp
        )
    }
}
#endif

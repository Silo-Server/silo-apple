#if os(tvOS)
import Foundation
import OSLog

/// Privacy-safe focus tracing for the tvOS detail page.
///
/// Callers pass only closed control names, season numbers, counts, and
/// booleans. Never include content IDs, titles, URLs, or server values here.
/// Essential transitions reach basic diagnostics; verbose movement is kept
/// behind the Debug Logging toggle. Debug builds mirror both to stdout because
/// physical-tvOS unified logging is not consistently forwarded by devicectl.
enum TVDetailFocusDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "TVDetailFocus"
    )

    static func record(
        _ event: String,
        target: String,
        action: String,
        state: String,
        essential: Bool = false
    ) {
        let message = state.isEmpty ? event : "\(event) \(state)"

        if essential {
            logger.notice("\(message, privacy: .public)")
        } else {
            logger.debug("\(message, privacy: .public)")
        }

        #if DEBUG
        print("[DetailFocus] \(message)")
        #endif

        DiagTrace.log(
            essential ? .essential : .verbose,
            level: essential ? .info : .debug,
            category: .focus,
            tag: "DetailFocus",
            message: message,
            attrs: [
                "target": .string(target),
                "action": .string(action),
            ]
        )
    }
}
#endif

#if os(iOS) || os(tvOS)
import AetherEngine
import Foundation

/// Mirrors Aether's host diagnostics into Silo's consent-gated log ring.
///
/// Upstream Aether also writes its original messages to Apple unified logging.
/// Silo deliberately never harvests that store for a diagnostics bundle. This
/// bridge handles only the optional host callback and applies the media
/// privacy boundary before a line can enter Silo-owned diagnostics.
enum AetherDiagnosticsBridge {
    private static let installLock = NSLock()
    nonisolated(unsafe) private static var installed = false

    static func install() {
        installLock.lock()
        defer { installLock.unlock() }
        guard !installed else { return }

        EngineLog.handler = makeHandler { line in
            DiagTrace.log(
                .verbose,
                level: .debug,
                category: .playback,
                tag: "Aether",
                message: line
            )
        }
        installed = true
    }

    /// Injectable composition seam: tests prove the actual handler redacts
    /// before invoking its destination, while `DiagTraceTests` separately pin
    /// the consent and Debug Logging gate used by the production destination.
    static func makeHandler(
        sink: @escaping (String) -> Void
    ) -> (String) -> Void {
        { line in sink(sanitizedLine(line)) }
    }

    static func sanitizedLine(_ line: String) -> String {
        MediaLogRedactor.sanitize(line, maxLength: 2_048)
    }
}
#endif

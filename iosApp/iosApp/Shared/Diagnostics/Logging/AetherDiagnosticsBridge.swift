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
    /// A static initializer runs exactly once, thread-safely.
    private static let installOnce: Void = {
        EngineLog.handler = makeHandler { verbosity, level, redactedLine in
            DiagTrace.log(
                verbosity,
                level: level,
                category: .playback,
                tag: "Aether",
                message: redactedLine()
            )
        }
    }()

    static func install() {
        _ = installOnce
    }

    /// Injectable composition seam: tests prove the actual handler redacts
    /// before invoking its destination, while `DiagTraceTests` separately pin
    /// the consent and Debug Logging gate used by the production destination.
    ///
    /// The sink receives a provider rather than a string so the redaction pass
    /// lands inside `DiagTrace.log`'s `@autoclosure`. Aether emits verbose host
    /// lines continuously, and the capture gate rejects nearly all of them; a
    /// suppressed line must not pay for a full regex sweep it will never use.
    static func makeHandler(
        sink: @escaping (DiagnosticsVerbosity, DiagnosticsLogLevel, () -> String) -> Void
    ) -> (String) -> Void {
        { line in
            let verbosity = verbosity(for: line)
            sink(verbosity, level(for: line, verbosity: verbosity), { sanitizedLine(line) })
        }
    }

    /// The few engine lines a report needs without Debug Logging. They place a
    /// report that TrueHD Atmos heights or the LFE are missing: which audio
    /// path the engine built, the bed levels it handed AVPlayer, what the
    /// playlist said about the audio, the output route with its rendering mode
    /// and speaker labels, and the engine's own warning when the route has
    /// fewer channels than the track. Each is written a handful of times a
    /// session, not continuously, so the essential tier can afford them.
    ///
    /// The engine hands the host text only, so these match its wording; the
    /// tests hold that wording to lines the engine actually writes.
    static func verbosity(for line: String) -> DiagnosticsVerbosity {
        if line.hasPrefix("[SpatialAudioBridge]") { return .essential }
        if line.hasPrefix("[HLSVideoEngine]") {
            let essential = line.contains("TrueHD") || line.contains("APAC") || line.contains("master audio:")
            return essential ? .essential : .verbose
        }
        if line.hasPrefix("[NativeAVPlayerHost]") || line.hasPrefix("[SoftwarePlaybackHost]")
            || line.hasPrefix("[AetherEngine]") {
            let essential = line.contains(" audioRoute ")
                || line.contains(" item.audioTrack ")
                || line.contains(" item.allowedAudioSpatializationFormats=")
                || line.contains("-channel route")
                || line.contains("LPCM but active audio route")
            return essential ? .essential : .verbose
        }
        return .verbose
    }

    /// Essential lines keep the engine's own severity, so an `ERROR:` or
    /// `WARNING:` still reads as one in a report. Verbose lines stay debug.
    static func level(for line: String, verbosity: DiagnosticsVerbosity) -> DiagnosticsLogLevel {
        guard verbosity == .essential else { return .debug }
        if line.contains(" ERROR:") { return .error }
        if line.contains(" WARNING:") { return .warning }
        return .info
    }

    /// Audio route lines name ports by type, never by the user's name for
    /// the device, so the media redaction is the whole boundary here too.
    static func sanitizedLine(_ line: String) -> String {
        MediaLogRedactor.sanitize(line, maxLength: 2_048)
    }
}
#endif

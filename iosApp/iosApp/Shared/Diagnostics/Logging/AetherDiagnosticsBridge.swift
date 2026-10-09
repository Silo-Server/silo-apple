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

    static func sanitizedLine(_ line: String) -> String {
        MediaLogRedactor.sanitize(withoutPortNames(line), maxLength: 2_048)
    }

    /// An audio route line names each output port, and for AirPods, AirPlay
    /// and Bluetooth that is whatever the user called the device ("Alex's
    /// AirPods Pro"). Those names become `port`. An HDMI port keeps its name:
    /// it is the sink's EDID model name, and whether the Apple TV feeds an AVR
    /// or a TV is the first question a missing-heights report asks.
    ///
    /// Each port is `name[type, ch=n…]`, so the name is everything between
    /// `ports=[` (or the previous port's `], `) and the next `[<type>, ch=`,
    /// whatever brackets the name itself contains.
    static func withoutPortNames(_ line: String) -> String {
        guard line.contains("ports=[") else { return line }
        let nsLine = line as NSString
        var result = ""
        var copied = 0
        for match in portNamePattern.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) {
            let name = match.range(at: 1)
            let type = nsLine.substring(with: match.range(at: 2))
            result += nsLine.substring(with: NSRange(location: copied, length: name.location - copied))
            result += type == "HDMIOutput" ? nsLine.substring(with: name) : "port"
            copied = name.location + name.length
        }
        return result + nsLine.substring(from: copied)
    }

    private static let portNamePattern = try! NSRegularExpression(
        pattern: #"(?:ports=\[|\], )((?:(?!\[[A-Za-z0-9]+, ch=-?\d).)*)\[([A-Za-z0-9]+), ch=-?\d"#
    )
}
#endif

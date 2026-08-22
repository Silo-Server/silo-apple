#if os(iOS) || os(tvOS)
import Foundation

enum DiagLogAttributeValue {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case url(URL)
    case error(any Error)
}

enum DiagLog {
    typealias Category = DiagnosticsLogCategory

    static let captureSessionID = UUID().uuidString.lowercased()
    static let ring = LogRing()

    /// Registers a server hostname to be replaced with its hashed token in
    /// every future log line, even when it appears outside URL syntax.
    static func registerSensitiveHost(_ host: String) {
        DiagnosticsRedactor.registerSensitiveHost(host)
    }

    /// Test hook: clears the registered sensitive hosts. The registry is
    /// process-wide, so a test that registers a pathological host must reset it
    /// afterward or the host leaks into later tests' redaction output.
    static func resetSensitiveHostsForTesting() {
        DiagnosticsRedactor.resetSensitiveHostsForTesting()
    }

    static func d(_ category: Category, _ tag: String, _ message: String, _ attrs: [String: DiagLogAttributeValue] = [:]) {
        append(level: .debug, category: category, tag: tag, message: message, attrs: attrs)
    }

    static func i(_ category: Category, _ tag: String, _ message: String, _ attrs: [String: DiagLogAttributeValue] = [:]) {
        append(level: .info, category: category, tag: tag, message: message, attrs: attrs)
    }

    static func w(_ category: Category, _ tag: String, _ message: String, _ attrs: [String: DiagLogAttributeValue] = [:]) {
        append(level: .warning, category: category, tag: tag, message: message, attrs: attrs)
    }

    static func e(_ category: Category, _ tag: String, _ message: String, _ attrs: [String: DiagLogAttributeValue] = [:]) {
        append(level: .error, category: category, tag: tag, message: message, attrs: attrs)
    }

    static func renderedLine(
        level: DiagnosticsLogLevel,
        category: Category,
        tag: String,
        message: String,
        attrs: [String: DiagLogAttributeValue] = [:],
        timestamp: Date = Date(),
        captureSessionID: String = DiagLog.captureSessionID
    ) -> String? {
        let line = DiagnosticsLogLine(
            ts: DiagnosticsTimestamp.string(from: timestamp),
            run: captureSessionID,
            lvl: level,
            cat: category,
            tag: DiagnosticsRedactor.sanitize(tag, maxLength: 128),
            msg: DiagnosticsRedactor.sanitize(message, maxLength: 2048),
            attrs: renderAttrs(attrs, category: category)
        )
        do {
            try line.validate()
            let data = try DiagnosticsJSONCoding.makeEncoder().encode(line)
            return String(data: data, encoding: .utf8)
        } catch {
            assertionFailure("Invalid diagnostics log line: \(error)")
            return nil
        }
    }

    private static func append(
        level: DiagnosticsLogLevel,
        category: Category,
        tag: String,
        message: String,
        attrs: [String: DiagLogAttributeValue]
    ) {
        guard let line = renderedLine(level: level, category: category, tag: tag, message: message, attrs: attrs) else {
            return
        }
        ring.append(line)
    }

    private static func renderAttrs(_ attrs: [String: DiagLogAttributeValue], category: Category) -> [String: DiagnosticsJSONValue] {
        var rendered: [String: DiagnosticsJSONValue] = [:]
        for (key, value) in attrs {
            guard let expectedType = DiagLogAttributeRegistry.type(for: key, category: category) else {
                DiagLogAttributeRegistry.reject("Unregistered diagnostics attribute \(category.rawValue).\(key)")
                continue
            }
            guard expectedType.accepts(value) else {
                DiagLogAttributeRegistry.reject("Diagnostics attribute \(category.rawValue).\(key) has wrong value type")
                continue
            }
            rendered[key] = value.diagnosticsJSONValue
        }
        return rendered
    }
}

// Internal rather than private so DiagnosticsAttributeRegistryParityTests can
// compare this table against the vendored canonical attr-registry.json fixture.
// The registry is the emission-side contract with the collectors; a drifting
// copy is exactly the failure this visibility exists to catch.
enum DiagLogAttributeRegistry {
    enum ValueType: Equatable {
        case string
        case integer
        case number
        case bool

        func accepts(_ value: DiagLogAttributeValue) -> Bool {
            switch (self, value) {
            case (.string, .string), (.string, .url), (.string, .error):
                return true
            case (.integer, .int):
                return true
            case (.number, .int), (.number, .double):
                return true
            case (.bool, .bool):
                return true
            default:
                return false
            }
        }
    }

    // Mirrors silo-server docs/design/schemas/client-diagnostics/v1/attr-registry.json,
    // vendored at Tests/Fixtures/DiagnosticsContract/attr-registry.json. Re-vendor the
    // fixture and update this table together; never edit one alone.
    static let registry: [DiagnosticsLogCategory: [String: ValueType]] = [
        .playback: [
            "sink": .string,
            "fmt": .string,
            "decoder": .string,
            "width": .integer,
            "height": .integer,
            "hdr_mode": .string,
            "bitrate_kbps": .integer,
            "dropped_frames": .integer,
            "audio_underruns": .integer,
            "session_id": .string,
            "play_method": .string,
            "reason": .string,
            "position_ms": .integer,
        ],
        .focus: [
            "target": .string,
            "action": .string,
        ],
        .network: [
            "method": .string,
            "path": .string,
            "status": .integer,
            "duration_ms": .integer,
            "outcome": .string,
            "error_code": .string,
            "attempt": .integer,
        ],
        .lifecycle: [
            "state": .string,
            "phase": .string,
            "duration_ms": .integer,
            "outcome": .string,
            "reason": .string,
            "launch_type": .string,
        ],
        .crash: [
            "fingerprint": .string,
            "source": .string,
        ],
    ]

    static func type(for key: String, category: DiagnosticsLogCategory) -> ValueType? {
        registry[category]?[key]
    }

    static func reject(_ message: String) {
        #if DEBUG
        assertionFailure(message)
        #endif
    }
}

private extension DiagLogAttributeValue {
    var diagnosticsJSONValue: DiagnosticsJSONValue {
        switch self {
        case .string(let value):
            return .string(DiagnosticsRedactor.sanitize(value, maxLength: 512))
        case .int(let value):
            return .int(value)
        case .double(let value):
            return .double(value)
        case .bool(let value):
            return .bool(value)
        case .url(let value):
            return .string(DiagnosticsRedactor.normalizedURLString(value))
        case .error(let value):
            return .string(DiagnosticsRedactor.sanitizedError(value))
        }
    }
}

private enum DiagnosticsRedactor {
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?:https?|wss?)://[A-Za-z0-9._~:/?#@!$&'()*+,;=%\[\]-]+"#,
        options: [.caseInsensitive]
    )
    private static let emailRegex = try! NSRegularExpression(
        pattern: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#,
        options: []
    )
    private static let authorizationRegex = try! NSRegularExpression(
        pattern: #"(?i)\bAuthorization\s*[:=]\s*(?:Bearer|Basic)?\s*[A-Za-z0-9._~+/=-]+"#,
        options: []
    )
    private static let cookieRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:Cookie|Set-Cookie)\s*[:=]\s*[^\r\n]+"#,
        options: []
    )
    private static let bearerRegex = try! NSRegularExpression(
        pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
        options: []
    )
    private static let jwtRegex = try! NSRegularExpression(
        pattern: #"\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#,
        options: []
    )
    private static let secretKeyValueRegex = try! NSRegularExpression(
        // Accept plain key=value as well as raw or escaped JSON strings. Error
        // descriptions often quote their associated response bodies, so a
        // closing quote between the key and colon must not bypass redaction.
        pattern: #"(?i)(?:\\?[\"'])?\b(access_token|accessToken|profile_token|profileToken|refresh_token|refreshToken|profile_id|profileId|token|jwt|signature|sig|api_key|apikey|key|username|user_name|login|email|user)\b(?:\\?[\"'])?\s*[:=]\s*(?:\"(?:\\.|[^\"\\\r\n])*\"|\\\"(?:\\.|[^\\\r\n])*\\\"|'[^'\r\n]*'|[^\s&;,}\]]+)"#,
        options: []
    )
    // Defense in depth for legacy or third-party messages that wrap token
    // suffixes in parentheses instead of using key=value syntax.
    private static let tokenWrapperRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(auth|accessToken|access_token|profileToken|profile_token|refreshToken|refresh_token)\(…?[^)\r\n]*\)"#,
        options: []
    )
    // URL path components that are opaque handles rather than API vocabulary:
    // bare 32-hex item ids, dashed UUIDs, and long base64url blobs. Short,
    // wordy components (`api`, `v1`, `card_overlays`) stay literal so the log
    // line still says which endpoint was involved.
    private static let opaqueIdentifierRegex = try! NSRegularExpression(
        pattern: #"\A(?:[0-9a-f]{32}"#
            + #"|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
            + #"|[A-Za-z0-9_-]{22,})\z"#,
        options: [.caseInsensitive]
    )

    // The active/remembered server hostnames, registered by ServerRegistry.
    // These are the identifiers most likely to leak as bare text (outside
    // URL syntax), and matching known strings avoids false positives that a
    // generic domain regex would hit (bundle ids, file names, versions).
    private static let knownHostsLock = NSLock()
    private static var knownSensitiveHosts: [String] = []

    static func registerSensitiveHost(_ host: String) {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, !isLoopbackHost(normalized) else { return }
        knownHostsLock.lock()
        defer { knownHostsLock.unlock() }
        if !knownSensitiveHosts.contains(normalized) {
            // Longest first so "media.example.com" wins over "example.com".
            knownSensitiveHosts.append(normalized)
            knownSensitiveHosts.sort { $0.count > $1.count }
        }
    }

    static func resetSensitiveHostsForTesting() {
        knownHostsLock.lock()
        knownSensitiveHosts.removeAll()
        knownHostsLock.unlock()
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private static func hostToken(_ host: String) -> String {
        "[host:" + DiagnosticsSHA256.shortHex(data: Data(host.lowercased().utf8), count: 12) + "]"
    }

    private static func replaceKnownHosts(in value: String) -> String {
        knownHostsLock.lock()
        let hosts = knownSensitiveHosts
        knownHostsLock.unlock()
        guard !hosts.isEmpty else { return value }
        // Single forward pass over the original text. At each position we try
        // the registered hosts (already sorted longest-first, so the longest
        // match wins) and, on a match, emit that host's token and jump past the
        // matched span. Emitted tokens are appended to `result` and never
        // re-scanned, so a host that is a substring of its own replacement
        // token — e.g. "host" inside "[host:…]" — cannot re-match and spin the
        // way an in-place `while range` replace would.
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            var matched = false
            for host in hosts {
                guard let end = value.index(index, offsetBy: host.count, limitedBy: value.endIndex) else {
                    continue
                }
                // `host` is normalized to lowercase at registration; compare a
                // lowercased candidate of equal length for a case-insensitive
                // match. Hosts are non-empty, so `index` always advances.
                if value[index..<end].lowercased() == host {
                    result += hostToken(host)
                    index = end
                    matched = true
                    break
                }
            }
            if !matched {
                result.append(value[index])
                index = value.index(after: index)
            }
        }
        return result
    }

    static func sanitizedError(_ error: any Error) -> String {
        // HTTPError intentionally retains response bodies for typed callers,
        // but those bodies are never safe diagnostic text. Its description is
        // a body-free summary; UI-facing localizedDescription remains intact.
        let rawMessage: String
        if let httpError = error as? HTTPError {
            rawMessage = httpError.description
        } else {
            let message = (error as NSError).localizedDescription
            let fallback = String(describing: error)
            rawMessage = message.isEmpty ? fallback : message
        }
        let typedMessage = "\(String(reflecting: Swift.type(of: error))): \(rawMessage)"
        return sanitize(typedMessage, maxLength: 512)
    }

    static func sanitize(_ value: String, maxLength: Int) -> String {
        let urlNormalized = replaceURLs(in: value)
        var result = replaceMatches(in: urlNormalized, regex: authorizationRegex, replacement: "Authorization: [redacted]")
        result = replaceMatches(in: result, regex: cookieRegex, replacement: "Cookie: [redacted]")
        result = replaceMatches(in: result, regex: bearerRegex, replacement: "Bearer [redacted]")
        result = replaceMatches(in: result, regex: jwtRegex, replacement: "[redacted_token]")
        result = replaceMatches(in: result, regex: emailRegex, replacement: "[redacted_email]")
        result = replaceSecretKeyValues(in: result)
        result = replaceMatches(in: result, regex: tokenWrapperRegex, replacement: "$1(…[redacted])")
        result = replaceKnownHosts(in: result)
        // Filesystem paths and bare media filenames are the one class this
        // layer never covered on its own, and every DiagTrace, breadcrumb, and
        // early-boot line lands here. Compose the OSLog boundary's rules for
        // that class only: its URL and credential rules are deliberately not
        // reused, because hashing the host while keeping the API path is what
        // makes these lines correlatable.
        result = houseStyleMarkers(MediaLogRedactor.sanitizeFilesystemAndMediaIdentity(result))
        return trim(result, maxLength: maxLength)
    }

    static func normalizedURLString(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme else {
            return "[redacted_url]"
        }
        // Drop credentials, port, query, and fragment; hash the host so log
        // lines stay correlatable without exposing the server's domain.
        // Loopback hosts carry no PII and stay literal for playback debugging.
        let host = components.host ?? ""
        let renderedHost = host.isEmpty || isLoopbackHost(host.lowercased()) ? host : hostToken(host)
        return scheme + "://" + renderedHost + redactedPath(components.percentEncodedPath)
    }

    /// Hashing the host is not enough: `/Videos/<id>/Movie.Name.2019.mkv` names
    /// the title and the item outright. Redact per component so the API shape
    /// of the path survives while media names and opaque handles do not.
    private static func redactedPath(_ percentEncodedPath: String) -> String {
        guard percentEncodedPath.contains("/") else { return percentEncodedPath }
        return percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { component -> String in
                let text = String(component)
                if MediaLogRedactor.isMediaFilenameComponent(text) { return "[redacted_media_name]" }
                if isOpaqueIdentifier(text) { return "[redacted_id]" }
                return text
            }
            .joined(separator: "/")
    }

    /// `MediaLogRedactor` spells its markers for OSLog (`[redacted-path]`); the
    /// diagnostics ring and its hosted upload path speak snake case
    /// (`[redacted_url]`, `[redacted_path]`). Translate at the seam so a line
    /// carries one vocabulary no matter which layer redacted it.
    private static func houseStyleMarkers(_ value: String) -> String {
        value
            .replacingOccurrences(of: "[redacted-path]", with: "[redacted_path]")
            .replacingOccurrences(of: "[redacted-media-name]", with: "[redacted_media_name]")
    }

    private static func isOpaqueIdentifier(_ component: String) -> Bool {
        let range = NSRange(location: 0, length: (component as NSString).length)
        return opaqueIdentifierRegex.firstMatch(in: component, options: [], range: range) != nil
    }

    private static func replaceURLs(in value: String) -> String {
        let source = value as NSString
        let matches = urlRegex.matches(in: value, range: NSRange(location: 0, length: source.length))
        var result = value
        for match in matches.reversed() {
            let raw = source.substring(with: match.range)
            let (candidate, suffix) = splitTrailingPunctuation(raw)
            let normalized = URL(string: candidate).map(normalizedURLString) ?? "[redacted_url]"
            result = (result as NSString).replacingCharacters(in: match.range, with: normalized + suffix)
        }
        return result
    }

    private static func splitTrailingPunctuation(_ value: String) -> (String, String) {
        var candidate = value
        var suffix = ""
        while let last = candidate.last, [".", ",", ")", "]"].contains(String(last)) {
            suffix.insert(last, at: suffix.startIndex)
            candidate.removeLast()
        }
        return (candidate, suffix)
    }

    private static func replaceMatches(in value: String, regex: NSRegularExpression, replacement: String) -> String {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: replacement)
    }

    private static func replaceSecretKeyValues(in value: String) -> String {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return secretKeyValueRegex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: "$1=[redacted]"
        )
    }

    private static func trim(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else {
            return value
        }
        return String(value.prefix(maxLength - 3)) + "..."
    }
}
#endif

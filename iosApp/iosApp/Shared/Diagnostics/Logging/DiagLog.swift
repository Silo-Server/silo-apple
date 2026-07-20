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

private enum DiagLogAttributeRegistry {
    enum ValueType {
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

    private static let registry: [DiagnosticsLogCategory: [String: ValueType]] = [
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
            "position_seconds": .number,
            "reason": .string,
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
        ],
        .lifecycle: [
            "state": .string,
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
        pattern: #"https?://[A-Za-z0-9._~:/?#@!$&'()*+,;=%-]+"#,
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
        pattern: #"(?i)\b(access_token|profile_token|refresh_token|token|jwt|signature|sig|api_key|apikey|key)\s*=\s*[^\s&;,]+"#,
        options: []
    )

    static func sanitizedError(_ error: any Error) -> String {
        let message = (error as NSError).localizedDescription
        let fallback = String(describing: error)
        let rawMessage = message.isEmpty ? fallback : message
        let typedMessage = "\(String(reflecting: Swift.type(of: error))): \(rawMessage)"
        return sanitize(typedMessage, maxLength: 512)
    }

    static func sanitize(_ value: String, maxLength: Int) -> String {
        let urlNormalized = replaceURLs(in: value)
        var result = replaceMatches(in: urlNormalized, regex: authorizationRegex, replacement: "Authorization: [redacted]")
        result = replaceMatches(in: result, regex: cookieRegex, replacement: "Cookie: [redacted]")
        result = replaceMatches(in: result, regex: bearerRegex, replacement: "Bearer [redacted]")
        result = replaceMatches(in: result, regex: jwtRegex, replacement: "[redacted_token]")
        result = replaceSecretKeyValues(in: result)
        return trim(result, maxLength: maxLength)
    }

    static func normalizedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "[redacted_url]"
        }
        components.user = nil
        components.password = nil
        components.port = nil
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? "[redacted_url]"
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
        let source = value as NSString
        let matches = secretKeyValueRegex.matches(in: value, range: NSRange(location: 0, length: source.length))
        var result = value
        for match in matches.reversed() {
            let raw = source.substring(with: match.range)
            let key = raw.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "token"
            result = (result as NSString).replacingCharacters(in: match.range, with: "\(key)=[redacted]")
        }
        return result
    }

    private static func trim(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else {
            return value
        }
        return String(value.prefix(maxLength - 3)) + "..."
    }
}
#endif

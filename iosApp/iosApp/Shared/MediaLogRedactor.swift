import Foundation

/// Last-mile privacy boundary for public playback OSLog fields.
///
/// Aether and AVFoundation error descriptions can include the source URL,
/// local file path, or request headers. Product code may retain the original
/// message for typed recovery and UI, but anything deliberately marked public
/// in OSLog passes through this bounded redactor first.
enum MediaLogRedactor {
    private struct Rule {
        let regex: NSRegularExpression
        let replacement: String

        init(_ pattern: String, replacement: String) {
            regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.replacement = replacement
        }
    }

    private static let rules = [
        Rule(
            #"\b(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key)\s*[:=]\s*[^,\]\}\r\n]+"#,
            replacement: "$1=[redacted]"
        ),
        Rule(
            #"\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            replacement: "Bearer [redacted]"
        ),
        Rule(
            #"\b(?:https?|wss?|file|smb)://[^\s'\"<>]+"#,
            replacement: "[redacted-url]"
        ),
        Rule(
            #"(?:^|[\s=:'\"])/(?:private|var|Users|Volumes|tmp)/[^\s,'\"\]\}]+"#,
            replacement: " [redacted-path]"
        ),
        Rule(
            #"\b(st|token|access_token|profile_token|refresh_token|auth|authorization|signature|sig|jwt|credential|api_key)\s*=\s*[^&\s,;\]\}]+"#,
            replacement: "$1=[redacted]"
        ),
        Rule(
            #"\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#,
            replacement: "[redacted-token]"
        ),
    ]

    static func sanitize(_ value: String, maxLength: Int = 1_024) -> String {
        let redacted = rules.reduce(value) { partial, rule in
            let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
            return rule.regex.stringByReplacingMatches(
                in: partial,
                range: range,
                withTemplate: rule.replacement
            )
        }
        guard redacted.count > maxLength else { return redacted }
        return String(redacted.prefix(max(0, maxLength - 3))) + "..."
    }

    static func sanitize(_ error: any Error, maxLength: Int = 1_024) -> String {
        sanitize(String(describing: error), maxLength: maxLength)
    }
}

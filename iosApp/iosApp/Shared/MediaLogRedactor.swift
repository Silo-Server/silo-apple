import Foundation

/// Last-mile privacy boundary for public playback OSLog fields.
///
/// Aether and AVFoundation error descriptions can include the source URL,
/// local file path, or request headers. Product code may retain the original
/// message for typed recovery and UI, but anything deliberately marked public
/// in OSLog passes through this bounded redactor first.
enum MediaLogRedactor {
    private static let workingInputLimit = 16_384

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
            #"\b([a-z0-9_-]*(?:authorization|auth|cookie|token|secret|credential|api[-_]?key|session)[a-z0-9_-]*)([\"']?\s*[:=]\s*[\"']?)[^,\]\}\r\n]+"#,
            replacement: "$1$2[redacted]"
        ),
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
            #"([\"'])/(?:private|var|Users|Volumes|tmp)/[^\r\n]*?\1"#,
            replacement: "$1[redacted-path]$1"
        ),
        Rule(
            #"/(?:private|var|Users|Volumes|tmp)/[^\r\n,;\]\}]*?\.(?:m3u8|mpd|mkv|mp4|m4v|mov|avi|webm|wmv|ts|m2ts|mts|m4s|mp3|m4a|m4b|aac|ac3|eac3|flac|alac|wav|ogg|opus|srt|ass|ssa|vtt|sub|idx|sup|pgs)\b"#,
            replacement: "[redacted-path]"
        ),
        Rule(
            #"(?:^|[\s=:'\"])/(?:private|var|Users|Volumes|tmp)/[^\s,'\"\]\}]+"#,
            replacement: " [redacted-path]"
        ),
        Rule(
            #"[A-Za-z0-9][A-Za-z0-9 _().,'&%+\-\[\]]{0,240}\.(?:m3u8|mpd|mkv|mp4|m4v|mov|avi|webm|wmv|ts|m2ts|mts|m4s|mp3|m4a|m4b|aac|ac3|eac3|flac|alac|wav|ogg|opus|srt|ass|ssa|vtt|sub|idx|sup|pgs)\b"#,
            replacement: "[redacted-media-name]"
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
        let boundedMaxLength = max(0, maxLength)
        let workingPrefix = value.prefix(workingInputLimit + 1)
        let workingValue = workingPrefix.count > workingInputLimit
            ? String(workingPrefix.prefix(workingInputLimit))
            : value
        let redacted = rules.reduce(workingValue) { partial, rule in
            let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
            return rule.regex.stringByReplacingMatches(
                in: partial,
                range: range,
                withTemplate: rule.replacement
            )
        }
        guard redacted.count > boundedMaxLength else { return redacted }
        guard boundedMaxLength > 3 else { return String(redacted.prefix(boundedMaxLength)) }
        return String(redacted.prefix(boundedMaxLength - 3)) + "..."
    }

    static func sanitize(_ error: any Error, maxLength: Int = 1_024) -> String {
        sanitize(String(describing: error), maxLength: maxLength)
    }
}

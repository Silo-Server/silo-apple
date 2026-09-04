import Foundation

/// Last-mile privacy boundary for public playback OSLog fields.
///
/// Aether and AVFoundation error descriptions can include the source URL,
/// local file path, or request headers. Product code may retain the original
/// message for typed recovery and UI, but anything deliberately marked public
/// in OSLog passes through this bounded redactor first.
///
/// Every rule is idempotent: applying `sanitize` to its own output is a no-op.
/// Rules that consume a value therefore refuse to start on `[`, a quote, or
/// whitespace, which is exactly how each replacement token begins or is
/// introduced, so no rule can re-consume another rule's `[redacted…]` marker.
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

    // MARK: - Shared pattern fragments

    /// Container and subtitle extensions that mark a token as a media filename.
    private static let mediaExtensions = "m3u8|mpd|mkv|mp4|m4v|mov|avi|webm|wmv|ts|m2ts|mts|m4s"
        + "|mp3|m4a|m4b|aac|ac3|eac3|flac|alac|wav|ogg|opus"
        + "|srt|ass|ssa|vtt|sub|idx|sup|pgs"

    /// Streaming filenames fixed by the protocol rather than chosen by a user.
    /// `master.m3u8` or `init.mp4` name a manifest position, not a title, so
    /// redacting them costs playback debugging without buying any privacy.
    private static let genericMediaStems =
        "master|index|manifest|playlist|prog_index|init|main|stream|chunk|segment|media|output"

    /// Filesystem roots an Apple client can legitimately reference. `~` covers
    /// the tilde-abbreviated home paths that `FileManager` descriptions emit.
    private static let pathRoot = #"(?:~|/(?:private|var|Users|Volumes|tmp|Library|Applications"#
        + #"|System|Network|Developer|opt|usr|etc|mnt|home|data))"#

    /// Credential-bearing key names, matched case-insensitively as a substring
    /// of the surrounding header or parameter name (`X-Silo-Auth`, `st`, …).
    private static let credentialKey =
        #"[a-z0-9_-]*(?:authorization|auth|cookie|token|secret|credential|api[-_]?key|session)[a-z0-9_-]*"#

    /// A value run that may not open with `[`, a quote, or whitespace. This is
    /// what keeps the credential rules idempotent: `token=[redacted]` and
    /// `token: "[redacted]"` both fail to re-match however the optional quote
    /// and whitespace in the separator backtrack.
    private static let opaqueValue = #"[^\s,;\]\}\r\n\["'][^,\]\}\r\n]*"#

    // MARK: - Rule groups

    private static let credentialAndURLRules: [Rule] = [
        Rule(
            #"\b(\#(credentialKey))(["']?\s*[:=]\s*["']?)\#(opaqueValue)"#,
            replacement: "$1$2[redacted]"
        ),
        Rule(
            #"\b(authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key)\s*[:=]\s*\#(opaqueValue)"#,
            replacement: "$1=[redacted]"
        ),
        Rule(
            #"\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            replacement: "Bearer [redacted]"
        ),
        Rule(
            #"\b(?:https?|wss?|file|smb)://[^\s'"<>]+"#,
            replacement: "[redacted-url]"
        ),
        // Scheme-less `host:port/path`. Aether and AVFoundation both log
        // origins without a scheme. The trailing `/` is required so ordinary
        // `File.swift:42` source references are not mistaken for an origin.
        Rule(
            #"(?:\[[0-9a-f:]{2,}\]|\b\d{1,3}(?:\.\d{1,3}){3}|\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,})"#
                + #":\d{1,5}/[^\s'"<>,;\]\}]*"#,
            replacement: "[redacted-url]"
        ),
        // Space-delimited credential headers (`X-Emby-Token 9f83ba21c0de44aa`).
        // The value must be long and contain a digit so ordinary prose after a
        // credential-shaped word ("session started successfully") survives.
        Rule(
            #"\b(\#(credentialKey))\s+(?:Bearer\s+)?(?=[A-Za-z0-9._~+/=-]*\d)[A-Za-z0-9._~+/=-]{12,}"#,
            replacement: "$1 [redacted]"
        ),
    ]

    /// Filesystem and media-identity rules, shared with `DiagnosticsRedactor`
    /// so the diagnostics ring covers the same ground as the OSLog boundary.
    private static let filesystemAndMediaRules: [Rule] = [
        Rule(
            #"(["'])\#(pathRoot)/[^\r\n]*?\1"#,
            replacement: "$1[redacted-path]$1"
        ),
        Rule(
            #"\#(pathRoot)/[^\r\n,;\]\}]*?\.(?:\#(mediaExtensions))\b"#,
            replacement: "[redacted-path]"
        ),
        Rule(
            #"(^|[\s=:'"])\#(pathRoot)/[^\s,'"\]\}]+"#,
            replacement: "$1[redacted-path]"
        ),
        // UNC shares leak the server and share name alongside the title.
        Rule(
            #"\\\\[A-Za-z0-9._$-]+\\[^\s'"<>,;]*"#,
            replacement: "[redacted-path]"
        ),
        // Bare media filenames. The match may neither start inside nor span a
        // `[redacted…]` marker, so `playing [redacted-url] Movie.mkv` loses
        // only the filename instead of collapsing the whole line.
        Rule(
            #"(?<![A-Za-z0-9._~-])(?!redacted[a-z0-9-]*\])"#
                + #"(?!(?:\#(genericMediaStems))\.(?:\#(mediaExtensions))\b)"#
                + #"[A-Za-z0-9](?:(?!\[redacted)[A-Za-z0-9 _().,'&%+\-\[\]]){0,240}\.(?:\#(mediaExtensions))\b"#,
            replacement: "[redacted-media-name]"
        ),
    ]

    private static let trailingCredentialRules: [Rule] = [
        Rule(
            #"\b(st|token|access_token|profile_token|refresh_token|auth|authorization|signature|sig|jwt|credential|api_key)"#
                + #"\s*=\s*[^&\s,;\]\}\[][^&\s,;\]\}]*"#,
            replacement: "$1=[redacted]"
        ),
        Rule(
            #"\b[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#,
            replacement: "[redacted-token]"
        ),
    ]

    private static let rules: [Rule] =
        credentialAndURLRules + filesystemAndMediaRules + trailingCredentialRules

    /// Anchored form of the bare-media-name rule, used to classify a single URL
    /// path component. Generic manifest names are deliberately preserved.
    private static let mediaFilenameRegex = try! NSRegularExpression(
        pattern: #"\A(?!(?:\#(genericMediaStems))\.(?:\#(mediaExtensions))\z).+\.(?:\#(mediaExtensions))\z"#,
        options: [.caseInsensitive]
    )

    // MARK: - Entry points

    static func sanitize(_ value: String, maxLength: Int = 1_024) -> String {
        let boundedMaxLength = max(0, maxLength)
        let redacted = apply(rules, to: value)
        guard redacted.count > boundedMaxLength else { return redacted }
        guard boundedMaxLength > 3 else { return String(redacted.prefix(boundedMaxLength)) }
        return String(redacted.prefix(boundedMaxLength - 3)) + "..."
    }

    static func sanitize(_ error: any Error, maxLength: Int = 1_024) -> String {
        sanitize(String(describing: error), maxLength: maxLength)
    }

    /// Applies only the filesystem-path and media-filename rules, leaving URL
    /// and credential handling to the caller. `DiagnosticsRedactor` composes
    /// this because its URL treatment (hashed host, surviving API path) is
    /// deliberately different from the OSLog boundary's blanket redaction.
    static func sanitizeFilesystemAndMediaIdentity(_ value: String) -> String {
        apply(filesystemAndMediaRules, to: value)
    }

    /// True when a single filename or URL path component names user media
    /// rather than a protocol-fixed manifest or segment.
    static func isMediaFilenameComponent(_ component: String) -> Bool {
        let range = NSRange(location: 0, length: (component as NSString).length)
        return mediaFilenameRegex.firstMatch(in: component, options: [], range: range) != nil
    }

    private static func apply(_ rules: [Rule], to value: String) -> String {
        let workingPrefix = value.prefix(workingInputLimit + 1)
        let workingValue = workingPrefix.count > workingInputLimit
            ? String(workingPrefix.prefix(workingInputLimit))
            : value
        return rules.reduce(workingValue) { partial, rule in
            let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
            return rule.regex.stringByReplacingMatches(
                in: partial,
                range: range,
                withTemplate: rule.replacement
            )
        }
    }
}

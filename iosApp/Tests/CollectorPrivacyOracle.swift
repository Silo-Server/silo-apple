import Foundation
import XCTest

/// The hosted collector's privacy rules, transcribed once.
///
/// `silo-diagnostics/src/privacy.ts` is a whole-report gate: one raw identifier
/// in one line and the user's entire uploaded bundle is discarded, silently,
/// after upload. Every diagnostics test that produces a `path` or a `msg`
/// therefore asserts its *output* against these rules rather than against the
/// helper that produced it — checking a helper against a copy of its own logic
/// would prove nothing.
///
/// One transcription, not one per test file: a token added to privacy.ts that
/// reaches only some of the copies leaves the weaker copy passing on exactly
/// the report-destroying case the stricter one would have caught.
///
/// Two scanners are modelled, and the distinction matters. ``assertPathAccepted``
/// mirrors `hasPrivatePathSegment`, applied to `attrs.path`.
/// ``assertMessageAccepted`` mirrors the text-context rules applied to `msg`
/// and to string attribute values — `PRIVATE_ID_IN_TEXT` matches unanchored
/// there, so a value that is a legal path segment can still be rejected from
/// inside a message.
enum CollectorPrivacyOracle {
    /// Asserts the collector's `hasPrivatePathSegment` would accept `path`.
    ///
    /// `source` names the input that produced it, so a failure reads as the
    /// case that broke rather than as a bare string.
    static func assertPathAccepted(
        _ path: String,
        source: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let origin = source.map { " (from \($0))" } ?? ""
        XCTAssertFalse(path.contains("?"), "query marker survived\(origin): \(path)", file: file, line: line)
        XCTAssertFalse(path.contains("#"), "fragment survived\(origin): \(path)", file: file, line: line)

        let lowercased = path.lowercased()
        for prefix in rejectedPrefixes {
            XCTAssertFalse(
                lowercased.hasPrefix(prefix),
                "path keeps collector-rejected prefix \(prefix)\(origin): \(path)",
                file: file,
                line: line
            )
        }

        for rawSegment in path.split(separator: "/", omittingEmptySubsequences: true) {
            let segment = String(rawSegment)
            // Stricter than the collector, deliberately: it percent-decodes
            // before matching, so an encoded id — or an encoded `/` — is
            // rejected even though the literal form looks harmless. Both
            // templaters answer that by templating any segment containing `%`,
            // so a surviving `%` is a bug in the templater, not a case to
            // decode and re-check.
            XCTAssertFalse(segment.contains("%"), "encoded segment\(origin): \(path)", file: file, line: line)
            XCTAssertNotEqual(segment, ".", "relative segment survived\(origin): \(path)", file: file, line: line)
            XCTAssertNotEqual(segment, "..", "relative segment survived\(origin): \(path)", file: file, line: line)

            // The collector trims surrounding punctuation before applying its
            // segment rules, so everything below works from the trimmed form.
            let normalized = trimmingPunctuation(segment)
            if normalized.isEmpty
                || matches(templateSegment, normalized)
                || matches(safeVersionSegment, normalized) {
                continue
            }
            // It tests the whole segment and each dotted/bracketed sub-part, so
            // `12345.json` is rejected on its `12345` part.
            let candidates = [normalized] + normalized.components(separatedBy: subPartSeparators)
            for candidate in candidates where !candidate.isEmpty {
                for (name, regex) in privateSegmentRules {
                    XCTAssertFalse(
                        matches(regex, candidate),
                        "segment \(candidate) matches collector rule \(name) in \(path)\(origin)",
                        file: file,
                        line: line
                    )
                }
            }
        }
    }

    /// Asserts the collector's text-context scan would accept `message`.
    static func assertMessageAccepted(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (name, regex) in textRules {
            XCTAssertFalse(
                matches(regex, message),
                "message matches collector rule \(name): \(message)",
                file: file,
                line: line
            )
        }
        // The dotted hostname/route scan: any `a.b` token in text is treated as
        // a hostname or route candidate unless it is on a hand-curated
        // allowlist we deliberately do not depend on.
        XCTAssertFalse(
            matches(dottedToken, message),
            "message contains a dotted token: \(message)",
            file: file,
            line: line
        )
    }

    // MARK: - Rules

    private static let rejectedPrefixes = ["/users/", "/private/", "/var/mobile/", "/data/user/"]
    private static let subPartSeparators = CharacterSet(charactersIn: ".,;:()[]")

    /// privacy.ts `UUID_VALUE`, numeric, `PRIVATE_ID_SEGMENT`,
    /// `HEX_ID_SEGMENT`, `OPAQUE_ID_SEGMENT`.
    private static let privateSegmentRules: [(String, NSRegularExpression)] = [
        ("UUID_VALUE", regex(#"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#)),
        ("NUMERIC", regex(#"^[0-9]+$"#)),
        ("PRIVATE_ID_SEGMENT", regex(#"(?i)^(?:ps|playback|session|file|item|media|plan|attempt|profile|account|user|device|content|library|request|req|correlation|server|subtitle|track|run)[_-][a-z0-9_-]{4,}$"#)),
        ("HEX_ID_SEGMENT", regex(#"(?i)^[0-9a-f]{16,}$"#)),
        ("OPAQUE_ID_SEGMENT", regex(#"(?i)^[A-Za-z0-9_-]{20,}$"#)),
    ]

    /// privacy.ts text-context rules.
    private static let textRules: [(String, NSRegularExpression)] = [
        ("PRIVATE_ID_IN_TEXT", regex(#"(?i)(?:^|[^A-Za-z0-9])(?:ps|playback|session|file|item|media|plan|attempt|profile|account|user|device|content|library|request|req|correlation|server|subtitle|track|run)[_-](?:[0-9]+|[A-Za-z0-9][A-Za-z0-9_-]{7,})(?=$|[^A-Za-z0-9_-])"#)),
        ("UUID_VALUE", regex(#"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#)),
        ("COMPACT_UUID_VALUE", regex(#"(?i)(?:^|[^0-9a-f])[0-9a-f]{32}(?=$|[^0-9a-f])"#)),
        ("MAC_ADDRESS", regex(#"(?i)(?:^|[^0-9a-f-])[0-9a-f]{12}(?=$|[^0-9a-f-])"#)),
    ]

    /// privacy.ts `TEMPLATE_SEGMENT` — an already-templated segment.
    private static let templateSegment = regex(#"^\{[a-z][a-z0-9_]*\}$"#)
    /// privacy.ts `SAFE_VERSION_SEGMENT` — `v1`, `v2`, …
    private static let safeVersionSegment = regex(#"(?i)^v[0-9]+$"#)
    private static let dottedToken = regex(#"[A-Za-z0-9][A-Za-z0-9_-]*\.[A-Za-z0-9][A-Za-z0-9_.-]*"#)

    private static func trimmingPunctuation(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: #"([]"'.,;!:)"#))
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        regex.firstMatch(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length)
        ) != nil
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }
}

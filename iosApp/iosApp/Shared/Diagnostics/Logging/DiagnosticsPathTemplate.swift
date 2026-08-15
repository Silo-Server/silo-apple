#if os(iOS) || os(tvOS)
import Foundation

/// Replaces private-looking URL path segments with `{id}`.
///
/// This started life as two private helpers inside `DiagnosticsBundleBuilder`,
/// applied to hosted bundles at *build* time. Network instrumentation needs the
/// same transform at *emission* time, for both destinations: the hosted
/// collector's privacy scanner rejects an entire report when any `network.path`
/// attribute carries a numeric, UUID, hex, or opaque segment, and self-hosted
/// evidence full of raw ids cannot be correlated by route either.
///
/// Two entry points, deliberately not the same:
///
/// * ``template(_:)`` / ``isPrivateSegment(_:)`` are the *hosted bundle* rules,
///   byte-for-byte the four regexes `DiagnosticsBundleBuilder` has always used.
///   Its output is already-accepted evidence; do not change these.
/// * ``templatedPath(for:)`` / ``templatedPath(forRawPath:)`` are the
///   *emission* rules. They are strictly more aggressive, because a path this
///   app writes into `network.path` has to pass
///   `silo-diagnostics/src/privacy.ts` `hasPrivatePathSegment` on the first try
///   — one raw id rejects the whole bundle. Everything the collector treats as
///   private is templated here, including cases the bundle-builder regexes
///   miss: unanchored/any-version UUIDs, dotted sub-parts (`12345.json`),
///   `PRIVATE_ID_SEGMENT` prefixes (`session_…`, `item_…`), percent-encoding,
///   and `.`/`..`.
///
/// Mirrors privacy.ts `UUID_VALUE`, `PRIVATE_ID_SEGMENT`, `HEX_ID_SEGMENT`,
/// `OPAQUE_ID_SEGMENT`, `TEMPLATE_SEGMENT`, and `SAFE_VERSION_SEGMENT`. When
/// that file changes, change this one with it.
enum DiagnosticsPathTemplate {
    /// The placeholder emitted for a private segment. Matches the collector's
    /// `TEMPLATE_SEGMENT` (`^\{[a-z][a-z0-9_]*\}$`), which is always accepted.
    static let placeholder = "{id}"

    // MARK: - Hosted bundle rules (unchanged behavior)

    /// Templates every private segment of an already-clean path, using the
    /// hosted bundle builder's historical segment rules.
    ///
    /// The input must not contain a query or fragment —
    /// `DiagnosticsBundleBuilder` feeds it a `percentEncodedPath`. Emission-time
    /// callers want ``templatedPath(for:)`` instead.
    static func template(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                let candidate = String(segment)
                return isPrivateSegment(candidate) ? placeholder : candidate
            }
            .joined(separator: "/")
    }

    /// Whether a single path segment looks like a private identifier under the
    /// hosted bundle builder's historical rules.
    static func isPrivateSegment(_ value: String) -> Bool {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return anchoredUUIDSegmentRegex.firstMatch(in: value, range: range) != nil
            || numericSegmentRegex.firstMatch(in: value, range: range) != nil
            || hexSegmentRegex.firstMatch(in: value, range: range) != nil
            || opaqueSegmentRegex.firstMatch(in: value, range: range) != nil
    }

    // MARK: - Emission rules

    /// Emission-time entry point: the templated path of `url`, with any query
    /// and fragment discarded. Never returns a string containing `?` or `#`.
    static func templatedPath(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return templatedPath(forRawPath: url.path)
        }
        return templatedEmissionPath(components.percentEncodedPath)
    }

    /// Emission-time entry point for a path that may still carry a query string
    /// or fragment (e.g. a route assembled as text). Everything from the first
    /// `?` or `#` onward is dropped before templating: a query string must never
    /// reach a log line, and its presence alone fails the hosted privacy scan.
    static func templatedPath(forRawPath rawPath: String) -> String {
        let pathOnly = rawPath.prefix { $0 != "?" && $0 != "#" }
        return templatedEmissionPath(String(pathOnly))
    }

    /// Whether the collector would consider this segment private. Exposed for
    /// tests and for callers assembling a path segment by segment.
    static func isEmissionPrivateSegment(_ value: String) -> Bool {
        if value.isEmpty { return false }
        if matches(templateSegmentRegex, value) || matches(safeVersionSegmentRegex, value) {
            return false
        }
        // Percent-encoding is templated unconditionally: the collector decodes
        // before matching, so an encoded id (or an encoded `/`) is rejected even
        // though the literal form looks harmless here.
        if value.contains("%") || value == "." || value == ".." { return true }
        // The collector tests the whole segment and each dotted/bracketed
        // sub-part, so `12345.json` is rejected on its `12345` part.
        let candidates = [value] + value.components(separatedBy: candidateSeparators)
        return candidates.contains { candidate in
            !candidate.isEmpty && (
                matches(unanchoredUUIDRegex, candidate)
                    || matches(numericSegmentRegex, candidate)
                    || matches(privateIDSegmentRegex, candidate)
                    || matches(hexSegmentRegex, candidate)
                    || matches(opaqueSegmentRegex, candidate)
                    || matches(alphanumericIDSegmentRegex, candidate)
            )
        }
    }

    private static func templatedEmissionPath(_ path: String) -> String {
        let templated = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                let candidate = String(segment)
                return isEmissionPrivateSegment(candidate) ? placeholder : candidate
            }
            .joined(separator: "/")
        return templatingReservedLeadingSegment(of: templated)
    }

    /// The collector rejects any path under `/users/`, `/private/`,
    /// `/var/mobile/`, or `/data/user/` — on-device filesystem prefixes, not API
    /// routes. It rejects on the prefix alone, regardless of what follows, so
    /// templating only the private-looking tail segments would not save the
    /// report.
    ///
    /// A filesystem path reaching `network.path` is a call-site bug, and none of
    /// it is correlatable as a route, so template every segment: that both
    /// breaks the rejected prefix and guarantees the home directory name or
    /// container UUID sitting in the tail never ships. Failing closed here keeps
    /// one bad call site from rejecting the whole bundle.
    private static func templatingReservedLeadingSegment(of path: String) -> String {
        let lowercased = path.lowercased()
        let reservedPrefixes = ["/users/", "/private/", "/var/mobile/", "/data/user/"]
        guard reservedPrefixes.contains(where: lowercased.hasPrefix) else { return path }
        // A leading "/" yields an empty first element, which must stay empty so
        // the rejoined path keeps its leading slash.
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, segment in
                index == 0 && segment.isEmpty ? "" : placeholder
            }
        return segments.joined(separator: "/")
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(location: 0, length: (value as NSString).length)
        return regex.firstMatch(in: value, range: range) != nil
    }

    private static let candidateSeparators = CharacterSet(charactersIn: ".,;:()[]")

    // MARK: - Segment patterns

    /// The bundle builder's historical UUID rule: anchored, RFC-version-shaped.
    private static let anchoredUUIDSegmentRegex = try! NSRegularExpression(
        pattern: #"(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#
    )
    /// privacy.ts `UUID_VALUE`: unanchored and version-agnostic, so a UUID
    /// embedded in a longer segment still rejects the report.
    private static let unanchoredUUIDRegex = try! NSRegularExpression(
        pattern: #"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
    )
    private static let numericSegmentRegex = try! NSRegularExpression(
        pattern: #"^[0-9]+$"#
    )
    private static let hexSegmentRegex = try! NSRegularExpression(
        pattern: #"(?i)^[0-9a-f]{16,}$"#
    )
    private static let opaqueSegmentRegex = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9_-]{20,}$"#
    )
    /// privacy.ts `PRIVATE_ID_SEGMENT`.
    private static let privateIDSegmentRegex = try! NSRegularExpression(
        pattern: #"(?i)^(?:ps|playback|session|file|item|media|plan|attempt|profile|account|user|device|content|library|request|req|correlation|server|subtitle|track|run)[_-][a-z0-9_-]{4,}$"#
    )
    /// Not a collector rule — an emission-side tightening. ULIDs and other
    /// short base32/base36 ids (`/v1/reports/01H8XK3P2Q`) are too short for
    /// `OPAQUE_ID_SEGMENT` and not hex, so the collector would accept them, but
    /// they are still raw identifiers and a route templated inconsistently
    /// cannot be correlated. Requires both a digit and a letter, which no real
    /// Silo route segment has (`v1` is handled by `SAFE_VERSION_SEGMENT`).
    private static let alphanumericIDSegmentRegex = try! NSRegularExpression(
        pattern: #"^(?=[A-Za-z0-9_-]*[0-9])(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{8,}$"#
    )
    /// privacy.ts `TEMPLATE_SEGMENT` — an already-templated segment.
    private static let templateSegmentRegex = try! NSRegularExpression(
        pattern: #"^\{[a-z][a-z0-9_]*\}$"#
    )
    /// privacy.ts `SAFE_VERSION_SEGMENT` — `v1`, `v2`, …
    private static let safeVersionSegmentRegex = try! NSRegularExpression(
        pattern: #"(?i)^v[0-9]+$"#
    )
}
#endif

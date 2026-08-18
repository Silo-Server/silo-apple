import XCTest
@testable import Silo

/// Emission-time path templating for the `network.path` attribute.
///
/// The bar these tests hold the helper to is the hosted collector's own
/// scanner: `silo-diagnostics/src/privacy.ts` `hasPrivatePathSegment`. That
/// function is a whole-report gate — one raw id in one line rejects the entire
/// bundle — so `assertCollectorWouldAccept` reimplements its rules and every
/// case asserts the *output* passes them, not merely that it changed.
final class DiagnosticsPathTemplateTests: XCTestCase {
    // MARK: - Real Silo routes

    func testStaticRoutesArePreserved() {
        // Readable routes are the entire point of templating; over-templating a
        // static route destroys the correlation it exists to provide.
        assertTemplated("/api/v1/health", equals: "/api/v1/health")
        assertTemplated("/api/v1/settings/values/effective", equals: "/api/v1/settings/values/effective")
        assertTemplated("/api/v1/playback/start", equals: "/api/v1/playback/start")
        assertTemplated("/api/v1/catalog/filters", equals: "/api/v1/catalog/filters")
        assertTemplated("/api/v1/collections/groups/order", equals: "/api/v1/collections/groups/order")
    }

    func testSettingsKeySegmentSurvivesWhenTheCollectorAllowsIt() {
        // `nav_shortcuts` is 13 chars, so it misses OPAQUE_ID_SEGMENT (20+),
        // and `nav` is not a PRIVATE_ID_SEGMENT prefix. The collector accepts
        // it, so it stays legible rather than collapsing to {id}.
        assertTemplated(
            "/api/v1/settings/values/nav_shortcuts",
            equals: "/api/v1/settings/values/nav_shortcuts"
        )
    }

    func testIdentifierSegmentsAreTemplated() {
        assertTemplated("/v1/reports/01H8XK3P2Q", equals: "/v1/reports/{id}")
        assertTemplated("/api/v1/items/12345", equals: "/api/v1/items/{id}")
        assertTemplated(
            "/api/v1/catalog/items/550e8400-e29b-41d4-a716-446655440000",
            equals: "/api/v1/catalog/items/{id}"
        )
        assertTemplated("/api/v1/home/dismissals/continue_watching/9", equals: "/api/v1/home/dismissals/continue_watching/{id}")
    }

    func testStaticRoutesTheCollectorWouldRejectAreTemplated() {
        // These are real, fully static Silo routes whose segments happen to
        // match PRIVATE_ID_SEGMENT (`library-…`, `subtitle-…`). The collector
        // cannot tell them from ids, so the helper must template them or the
        // whole report is lost to a route name.
        assertTemplated("/api/v1/library-playback-prefs", equals: "/api/v1/{id}")
        assertTemplated("/api/v1/subtitle-prefs", equals: "/api/v1/{id}")
        assertTemplated(
            "/api/v1/settings/subtitle_appearance/effective",
            equals: "/api/v1/settings/{id}/effective"
        )
    }

    // MARK: - Collector rule coverage (mirrors privacy.ts)

    func testUUIDSegmentsOfAnyVersionAreTemplated() {
        // privacy.ts UUID_VALUE is version-agnostic and unanchored, unlike the
        // hosted bundle builder's stricter anchored RFC-shaped pattern.
        assertTemplated("/x/550e8400-e29b-41d4-a716-446655440000", equals: "/x/{id}")
        assertTemplated("/x/00000000-0000-0000-0000-000000000000", equals: "/x/{id}")
        assertTemplated("/x/pre-550e8400-e29b-91d4-c716-446655440000", equals: "/x/{id}")
    }

    func testNumericHexAndOpaqueSegmentsAreTemplated() {
        assertTemplated("/x/12345", equals: "/x/{id}")
        assertTemplated("/x/0", equals: "/x/{id}")
        assertTemplated("/x/abcdef0123456789", equals: "/x/{id}")        // HEX_ID_SEGMENT, 16+
        assertTemplated("/x/abcdefghijklmnopqrst", equals: "/x/{id}")    // OPAQUE_ID_SEGMENT, 20+
    }

    func testPrivateIDPrefixSegmentsAreTemplated() {
        // privacy.ts PRIVATE_ID_SEGMENT: a known prefix plus `_`/`-` plus 4+.
        assertTemplated("/x/session_abcd", equals: "/x/{id}")
        assertTemplated("/x/item-90210", equals: "/x/{id}")
        assertTemplated("/x/ps_12ab34cd", equals: "/x/{id}")
    }

    func testDottedSubPartsAreTemplated() {
        // The collector splits each segment on `.,;:()[]` and tests the parts,
        // so a numeric stem rejects the report even with a file extension.
        assertTemplated("/x/12345.json", equals: "/x/{id}")
        assertTemplated("/x/(4242)", equals: "/x/{id}")
    }

    func testVersionAndAlreadyTemplatedSegmentsAreLeftAlone() {
        // SAFE_VERSION_SEGMENT and TEMPLATE_SEGMENT are explicit allowances;
        // re-templating them would churn paths that are already correct.
        assertTemplated("/v1/v2/v10/health", equals: "/v1/v2/v10/health")
        assertTemplated("/api/v1/items/{id}", equals: "/api/v1/items/{id}")
    }

    func testPercentEncodedAndRelativeSegmentsAreTemplated() {
        // The collector decodes before matching, so encoded ids and encoded
        // separators must not survive; `.`/`..` are rejected outright.
        assertTemplated("/api/v1/library/tv%20shows", equals: "/api/v1/library/{id}")
        assertTemplated("/api/v1/library/a%2Fb", equals: "/api/v1/library/{id}")
        assertTemplated("/api/v1/./items", equals: "/api/v1/{id}/items")
        assertTemplated("/api/v1/../items", equals: "/api/v1/{id}/items")
    }

    func testFilesystemPrefixesAreFullyTemplated() {
        // The collector rejects on the prefix alone regardless of the tail, so
        // templating only the tail would not save the report. A filesystem path
        // in network.path is a call-site bug and carries a home directory name
        // or container UUID, so every segment goes.
        assertTemplated("/users/bob/library", equals: "/{id}/{id}/{id}")
        assertTemplated("/var/mobile/Containers/Data", equals: "/{id}/{id}/{id}/{id}")
        assertTemplated("/private/var/tmp", equals: "/{id}/{id}/{id}")
        assertTemplated("/data/user/0/pkg", equals: "/{id}/{id}/{id}/{id}")
    }

    // MARK: - Query strings and fragments

    func testQueryStringsAndFragmentsAreStripped() {
        // Rule 3: never log a query string. Their mere presence rejects the
        // report, and they routinely carry tokens and search terms.
        assertTemplated("/api/v1/items/12345?api_key=secret", equals: "/api/v1/items/{id}")
        assertTemplated("/api/v1/catalog?q=bourne&page=2", equals: "/api/v1/catalog")
        assertTemplated("/api/v1/items/12345#frag", equals: "/api/v1/items/{id}")
        assertTemplated("/api/v1/health?", equals: "/api/v1/health")
    }

    func testURLEntryPointDropsHostQueryAndFragment() {
        let url = URL(string: "https://media.example.com:8096/api/v1/items/12345?token=abc#top")!
        let templated = DiagnosticsPathTemplate.templatedPath(for: url)

        XCTAssertEqual(templated, "/api/v1/items/{id}")
        // The host is logged nowhere, by anyone: rule 2 forbids raw hostnames.
        XCTAssertFalse(templated.contains("example.com"))
        assertCollectorWouldAccept(templated)
    }

    // MARK: - Hosted bundle behavior is unchanged

    func testHostedTemplateKeepsItsHistoricalSegmentRules() {
        // DiagnosticsBundleBuilder's accepted output must not move. Its rules
        // are deliberately narrower than the emission rules: a ULID or a
        // `subtitle_appearance` segment is left alone here even though the
        // collector rejects the latter. That is pre-existing hosted behavior
        // this refactor must not change, not an oversight.
        XCTAssertEqual(DiagnosticsPathTemplate.template("/api/v1/items/12345"), "/api/v1/items/{id}")
        XCTAssertEqual(
            DiagnosticsPathTemplate.template("/api/v1/settings/values/nav_shortcuts"),
            "/api/v1/settings/values/nav_shortcuts"
        )
        XCTAssertEqual(DiagnosticsPathTemplate.template("/v1/reports/01H8XK3P2Q"), "/v1/reports/01H8XK3P2Q")
        XCTAssertEqual(
            DiagnosticsPathTemplate.template("/api/v1/settings/subtitle_appearance/effective"),
            "/api/v1/settings/subtitle_appearance/effective"
        )
        // …but a 20+ char segment still hits the historical OPAQUE rule, so the
        // static `library-playback-prefs` route was already collapsing to {id}
        // on the hosted path before this change.
        XCTAssertEqual(
            DiagnosticsPathTemplate.template("/api/v1/library-playback-prefs"),
            "/api/v1/{id}"
        )
        XCTAssertEqual(
            DiagnosticsPathTemplate.template("/x/550e8400-e29b-41d4-a716-446655440000"),
            "/x/{id}"
        )
        XCTAssertEqual(DiagnosticsPathTemplate.template("/x/abcdef0123456789"), "/x/{id}")
        XCTAssertEqual(DiagnosticsPathTemplate.template("/x/abcdefghijklmnopqrst"), "/x/{id}")
    }

    func testTemplatingIsIdempotent() {
        // Instrumentation may template a route that was already templated at a
        // lower layer; a second pass must not mangle the placeholder.
        for path in [
            "/api/v1/items/12345",
            "/v1/reports/01H8XK3P2Q",
            "/users/bob/library",
            "/api/v1/health",
        ] {
            let once = DiagnosticsPathTemplate.templatedPath(forRawPath: path)
            XCTAssertEqual(
                DiagnosticsPathTemplate.templatedPath(forRawPath: once),
                once,
                "templating \(path) is not idempotent"
            )
        }
    }

    // MARK: - Helpers

    private func assertTemplated(
        _ input: String,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = DiagnosticsPathTemplate.templatedPath(forRawPath: input)
        XCTAssertEqual(actual, expected, "templating \(input)", file: file, line: line)
        assertCollectorWouldAccept(actual, file: file, line: line)
    }

    /// Mirrors `silo-diagnostics/src/privacy.ts` `hasPrivatePathSegment`. Kept
    /// in the test rather than the helper on purpose: the helper must satisfy
    /// the collector's rules, so checking it against a copy of its own logic
    /// would prove nothing.
    private func assertCollectorWouldAccept(
        _ path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(path.contains("?"), "path contains a query marker: \(path)", file: file, line: line)
        XCTAssertFalse(path.contains("#"), "path contains a fragment marker: \(path)", file: file, line: line)

        let lowercased = path.lowercased()
        for prefix in ["/users/", "/private/", "/var/mobile/", "/data/user/"] {
            XCTAssertFalse(
                lowercased.hasPrefix(prefix),
                "path keeps collector-rejected prefix \(prefix): \(path)",
                file: file,
                line: line
            )
        }

        for rawPart in path.split(separator: "/", omittingEmptySubsequences: true) {
            let segment = String(rawPart)
            guard let decoded = Self.fullyPercentDecoded(segment) else {
                XCTFail("segment \(segment) is undecodable in \(path)", file: file, line: line)
                continue
            }
            XCTAssertFalse(decoded.contains("/"), "segment decodes to a separator: \(path)", file: file, line: line)
            // Checked on the decoded segment *before* punctuation trimming.
            // Trimming strips `.` from both ends, so "." and ".." collapse to
            // "" — asserting against the trimmed form can never fail and would
            // claim coverage of the `.`/`..` rule that does not exist.
            XCTAssertNotEqual(decoded, ".", "relative segment survived: \(path)", file: file, line: line)
            XCTAssertNotEqual(decoded, "..", "relative segment survived: \(path)", file: file, line: line)

            // The collector trims surrounding punctuation before applying its
            // segment rules, so everything below works from the trimmed form.
            let normalized = Self.trimmingPunctuation(decoded)
            if normalized.isEmpty
                || Self.matches(Self.templateSegment, normalized)
                || Self.matches(Self.safeVersionSegment, normalized) {
                continue
            }
            let candidates = [normalized] + normalized.components(
                separatedBy: CharacterSet(charactersIn: ".,;:()[]")
            )
            for candidate in candidates where !candidate.isEmpty {
                for (name, regex) in Self.privateSegmentRules {
                    XCTAssertFalse(
                        Self.matches(regex, candidate),
                        "segment \(candidate) matches collector rule \(name) in \(path)",
                        file: file,
                        line: line
                    )
                }
            }
        }
    }

    /// Percent-decodes to a fixed point, mirroring the collector's decode step.
    /// Deliberately does *not* trim punctuation: `.`/`..` are rejected on the
    /// decoded segment, and trimming first would erase them.
    private static func fullyPercentDecoded(_ raw: String) -> String? {
        var segment = raw
        for _ in 0..<3 {
            guard let decoded = segment.removingPercentEncoding else { return nil }
            if decoded == segment { return segment }
            segment = decoded
        }
        guard let decoded = segment.removingPercentEncoding, decoded == segment else { return nil }
        return segment
    }

    private static func trimmingPunctuation(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: #"([]"'.,;!:)"#))
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    private static let templateSegment = regex(#"^\{[a-z][a-z0-9_]*\}$"#)
    private static let safeVersionSegment = regex(#"(?i)^v[0-9]+$"#)
    private static let privateSegmentRules: [(String, NSRegularExpression)] = [
        ("UUID_VALUE", regex(#"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#)),
        ("NUMERIC", regex(#"^[0-9]+$"#)),
        (
            "PRIVATE_ID_SEGMENT",
            regex(#"(?i)^(?:ps|playback|session|file|item|media|plan|attempt|profile|account|user|device|content|library|request|req|correlation|server|subtitle|track|run)[_-][a-z0-9_-]{4,}$"#)
        ),
        ("HEX_ID_SEGMENT", regex(#"(?i)^[a-f0-9]{16,}$"#)),
        ("OPAQUE_ID_SEGMENT", regex(#"(?i)^[a-z0-9_-]{20,}$"#)),
    ]
}

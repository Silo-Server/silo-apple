import XCTest
@testable import Silo

/// The classification layer that stands between `HTTPClient` and the
/// diagnostics ring: path hardening, decode-failure rendering, and the
/// transport/decode/status error vocabulary.
///
/// These are tested rather than the log calls themselves because they are the
/// only part of network instrumentation that can *fail*. A missing log line
/// costs one piece of evidence; a path or message that the hosted collector's
/// privacy scanner rejects costs the user's entire report, silently, after
/// upload. So every assertion here checks the *output* against a
/// reimplementation of the collector's own rules
/// (`silo-diagnostics/src/privacy.ts`), not merely that a value changed.
///
/// Two scanners are modelled, and the distinction matters:
///
/// * `assertPathAccepted` mirrors `hasPrivatePathSegment`, applied to
///   `attrs.path`.
/// * `assertMessageAccepted` mirrors the *text-context* rules
///   (`PRIVATE_ID_IN_TEXT`, `UUID_VALUE`, `COMPACT_UUID_VALUE`, the bare-MAC
///   arm of `MAC_ADDRESS`, and the dotted hostname/route scan) applied to
///   `msg`. A value that is a legal path segment can still be rejected from
///   inside a message, which is why the decode renderer has its own rules.
final class HTTPClientDiagnosticsClassificationTests: XCTestCase {

    // MARK: - Path attribute

    func testStaticRoutesStayLegible() {
        // Over-templating is a real cost, not a safe default: a report where
        // every route is `{id}` cannot be grouped by endpoint at all.
        assertPath("/api/v1/health", equals: "/api/v1/health")
        assertPath("/api/v1/auth/refresh", equals: "/api/v1/auth/refresh")
        assertPath("/api/v1/catalog/filters", equals: "/api/v1/catalog/filters")
        assertPath("/api/v1/collections/groups/order", equals: "/api/v1/collections/groups/order")
        assertPath("/api/v1/home/sections", equals: "/api/v1/home/sections")
    }

    func testIdentifierSegmentsAreTemplated() {
        assertPath("/api/v1/items/12345", equals: "/api/v1/items/{id}")
        assertPath("/v1/reports/01H8XK3P2Q", equals: "/v1/reports/{id}")
        assertPath(
            "/api/v1/catalog/items/550e8400-e29b-41d4-a716-446655440000",
            equals: "/api/v1/catalog/items/{id}"
        )
        assertPath("/api/v1/playback/sessions/abc123def/control/ws",
                   equals: "/api/v1/playback/sessions/{id}/control/ws")
    }

    func testDottedSettingKeysAreTemplatedEvenThoughTheyAreStatic() {
        // The motivating case for hardening on top of DiagnosticsPathTemplate.
        // `/api/v1/settings/values/downloads.default_quality` is a static route
        // with a compile-time key and no identifier anywhere in it, but the
        // collector reads the dotted segment as a hostname and rejects the
        // report. Its `SAFE_DOTTED_SETTING_KEYS` allowlist does not cover most
        // of our generated SettingKey table, so we cannot rely on it.
        assertPath(
            "/api/v1/settings/values/downloads.default_quality",
            equals: "/api/v1/settings/values/{id}"
        )
        assertPath(
            "/api/v1/settings/values/nav.shortcuts",
            equals: "/api/v1/settings/values/{id}"
        )
        assertPath(
            "/api/v1/settings/values/catalog.metadata_language/item",
            equals: "/api/v1/settings/values/{id}/item"
        )
    }

    func testQueryStringsAndFragmentsCanNeverSurvive() {
        // A query string is both a leak (tokens, search terms) and an outright
        // scanner rejection on the `?` alone.
        assertPath("/api/v1/items?token=secret&q=bourne", equals: "/api/v1/items")
        assertPath("/api/v1/items#fragment", equals: "/api/v1/items")
        assertPath("/api/v1/items/12345?fields=a,b#z", equals: "/api/v1/items/{id}")
    }

    func testAbsoluteURLsContributeOnlyTheirPath() {
        // The host is the single most identifying thing in a Silo request, and
        // a self-hosted server's hostname is often the user's own domain.
        assertPath(
            url: "https://media.example.com:8096/api/v1/items/12345?tag=abc#z",
            equals: "/api/v1/items/{id}"
        )
        assertPath(url: "http://127.0.0.1:8096/api/v1/health", equals: "/api/v1/health")
    }

    func testFilesystemPathsAndOddSegmentsFailClosed() {
        // A filesystem path in `network.path` is a call-site bug. It is not
        // correlatable as a route and its tail carries the user's home
        // directory name, so nothing is preserved.
        assertPath("/Users/alice/Library/Caches/x", equals: "/{id}/{id}/{id}/{id}/{id}")
        assertPath("/api/v1/a b/c", equals: "/api/v1/{id}/c")
        assertPath("/api/v1/%2e%2e/admin", equals: "/api/v1/{id}/admin")
        assertPath("//api//v1//health", equals: "/api/v1/health")
        assertPath("", equals: "/")
    }

    func testMissingURLDoesNotProduceAnEmptyAttribute() {
        XCTAssertEqual(HTTPDiagnosticsPath.attribute(for: nil), "{id}")
    }

    func testEveryRealSiloRouteShapeIsAcceptedByTheCollectorRules() {
        // Runtime substitutions for the interpolated segments real call sites
        // build, including the shapes most likely to slip through.
        let identifiers = [
            "12345", "550e8400-e29b-41d4-a716-446655440000", "01H8XK3P2Q",
            "session_abcdefgh", "item-90210", "tt1234567", "12345.json",
            "a%2Fb", "..", "My Movie (2019)", "deadbeefdeadbeefdead",
        ]
        let routes = [
            "/api/v1/items/%@/images/Primary",
            "/api/v1/catalog/series/%@/seasons/%@/episodes",
            "/api/v1/settings/values/%@",
            "/api/v1/favorites/%@",
            "/api/v1/library/%@/sections",
            "/api/v1/playback/%@/replan",
        ]
        for route in routes {
            for identifier in identifiers {
                let raw = route.replacingOccurrences(of: "%@", with: identifier)
                assertPathAccepted(HTTPDiagnosticsPath.attribute(forRawPath: raw), source: raw)
                assertPathAccepted(
                    HTTPDiagnosticsPath.attribute(forRawPath: raw + "?token=abc"),
                    source: raw
                )
            }
        }
    }

    func testRefreshURLsReduceToTheRouteAndNothingElse() {
        // Refresh is instrumented from `performRefreshTransport`, which sees an
        // absolute URL built from the user's own server address — a LAN host, a
        // bare IP, a nonstandard port, a reverse-proxy subpath. None of that may
        // reach a report, and the route is static, so every one of these must
        // collapse to the same attribute the ordinary path helper produces.
        for origin in [
            "https://silo.example.com",
            "http://192.168.1.50:8096",
            "https://media.internal:8443",
            "http://localhost:8080",
            "https://host.example.com/silo",
        ] {
            let actual = HTTPDiagnosticsPath.attribute(
                for: URL(string: origin + "/api/v1/auth/refresh")
            )
            XCTAssertTrue(
                actual.hasSuffix("/api/v1/auth/refresh"),
                "refresh route lost its shape: \(actual)"
            )
            XCTAssertFalse(actual.contains("example"), "host survived in \(actual)")
            XCTAssertFalse(actual.contains("192"), "host survived in \(actual)")
            XCTAssertFalse(actual.contains("localhost"), "host survived in \(actual)")
            assertPathAccepted(actual, source: origin)
        }
    }

    // MARK: - Decode failure rendering

    func testTypeNamesAreRenderedWithoutDots() {
        // Dots are the hazard: a dotted token in message text is scanned as a
        // hostname candidate. Module qualification and generics survive as
        // underscores, which keeps the model identifiable.
        XCTAssertEqual(HTTPDecodingDiagnostics.typeName("MediaItem"), "MediaItem")
        XCTAssertEqual(HTTPDecodingDiagnostics.typeName("Silo.MediaItem"), "Silo_MediaItem")
        XCTAssertEqual(HTTPDecodingDiagnostics.typeName("Array<MediaItem>"), "Array_MediaItem")
        XCTAssertEqual(
            HTTPDecodingDiagnostics.typeName("Dictionary<String, JSONValue>"),
            "Dictionary_String_JSONValue"
        )
    }

    func testTypeNamesThatWouldReadAsIdentifiersFailClosed() {
        // Joining tokens can manufacture a private shape that neither token
        // had on its own, so the finished string is what gets tested.
        XCTAssertEqual(HTTPDecodingDiagnostics.typeName("Session.Abcdefgh"), "unknown")
        XCTAssertEqual(HTTPDecodingDiagnostics.typeName("server_abcdefgh"), "unknown")
        XCTAssertEqual(HTTPDecodingDiagnostics.typeName(""), "unknown")
        XCTAssertEqual(HTTPDecodingDiagnostics.typeName("12345"), "unknown")
    }

    func testCodingPathsKeepArrayIndicesAndTemplateServerSuppliedKeys() {
        // Indices are positional, not identifying, and are the most useful part
        // of the path when a single element of a collection mismatches.
        XCTAssertEqual(
            HTTPDecodingDiagnostics.codingPath([Key("items"), Key(0), Key("title")]),
            "items > 0 > title"
        )
        XCTAssertEqual(HTTPDecodingDiagnostics.codingPath([]), "<root>")
        // A dictionary-shaped model's CodingKey is a *server* key, not source
        // text: the settings API decodes opaque JSON whose object keys are
        // setting keys. Those are templated for the same reason a URL segment
        // is.
        XCTAssertEqual(
            HTTPDecodingDiagnostics.codingPath([Key("values"), Key("catalog.metadata_language")]),
            "values > {id}"
        )
        XCTAssertEqual(HTTPDecodingDiagnostics.codingPath([Key("session_abcdefgh")]), "{id}")
        // A 7+ digit index reads as a numeric identifier to the collector.
        XCTAssertEqual(HTTPDecodingDiagnostics.codingPath([Key(9_999_999)]), "{id}")
        XCTAssertEqual(HTTPDecodingDiagnostics.codingPath([Key(-1)]), "{id}")
    }

    func testKeyNotFoundContributesTheMissingKeyItself() {
        // The defect this guards is silent: `keyNotFound` supplies the absent
        // key *separately* from its context, whose `codingPath` describes only
        // the container that was missing it. Reading the context alone still
        // renders a perfectly plausible line — it just names the parent object,
        // or `<root>` for a top-level field, and omits the one thing that
        // identifies which model field drifted from the server's JSON.
        let root = DecodingError.Context(codingPath: [], debugDescription: "")
        XCTAssertEqual(
            HTTPDecodingDiagnostics.codingPath(
                HTTPClient.failureCodingPath(.keyNotFound(Key("mediaSources"), root))
            ),
            "mediaSources"
        )
        let nested = DecodingError.Context(
            codingPath: [Key("items"), Key(0)],
            debugDescription: ""
        )
        XCTAssertEqual(
            HTTPDecodingDiagnostics.codingPath(
                HTTPClient.failureCodingPath(.keyNotFound(Key("runTimeTicks"), nested))
            ),
            "items > 0 > runTimeTicks"
        )
        // A missing key in a dictionary-shaped model is server data, so it is
        // templated like any other server-supplied key rather than logged.
        XCTAssertEqual(
            HTTPDecodingDiagnostics.codingPath(
                HTTPClient.failureCodingPath(
                    .keyNotFound(Key("catalog.metadata_language"), root)
                )
            ),
            "{id}"
        )
    }

    func testOtherDecodingCasesKeepTheirContextPathUnchanged() {
        // Only `keyNotFound` carries a key outside its context; appending
        // anything for the rest would invent a payload location that does not
        // exist.
        let context = DecodingError.Context(
            codingPath: [Key("items"), Key(0), Key("title")],
            debugDescription: ""
        )
        let errors: [DecodingError] = [
            .typeMismatch(Int.self, context),
            .valueNotFound(String.self, context),
            .dataCorrupted(context),
        ]
        for error in errors {
            XCTAssertEqual(
                HTTPDecodingDiagnostics.codingPath(HTTPClient.failureCodingPath(error)),
                "items > 0 > title"
            )
        }
    }

    func testRenderedDecodeMessagesAreAcceptedByTheTextRules() {
        let types = [
            "MediaItem", "Swift.Array<Silo.MediaItem>", "SettingsValuesResponse",
            "session_abcdefgh", "550e8400-e29b-41d4-a716-446655440000", "",
        ]
        let paths: [[CodingKey]] = [
            [],
            [Key("items"), Key(0), Key("title")],
            [Key("values"), Key("catalog.metadata_language")],
            [Key("mediaSources"), Key(0), Key("container")],
            [Key("a/b")],
            [Key("550e8400-e29b-41d4-a716-446655440000")],
        ]
        for type in types {
            for path in paths {
                let message = """
                    decode failed \
                    type=\(HTTPDecodingDiagnostics.typeName(type)) \
                    coding path \(HTTPDecodingDiagnostics.codingPath(path))
                    """
                assertMessageAccepted(message)
            }
        }
    }

    // MARK: - Error vocabulary

    func testTransportClassificationCoversTheConnectivityFailures() {
        XCTAssertEqual(classify(.timedOut), "timed_out")
        XCTAssertEqual(classify(.cannotConnectToHost), "cannot_connect_to_host")
        XCTAssertEqual(classify(.cannotFindHost), "cannot_find_host")
        XCTAssertEqual(classify(.notConnectedToInternet), "not_connected_to_internet")
        XCTAssertEqual(classify(.cancelled), "cancelled")
    }

    func testCertificateCodesAvoidTheCollectorsForbiddenServerPrefix() {
        // Foundation spells these `serverCertificate*`, but any `server_<token>`
        // value matches PRIVATE_ID_IN_TEXT and is rejected. The `tls_` spelling
        // is not cosmetic — it is what keeps the attribute shippable.
        XCTAssertEqual(classify(.serverCertificateUntrusted), "tls_certificate_untrusted")
        XCTAssertEqual(classify(.secureConnectionFailed), "tls_handshake_failed")
        for code in [URLError.serverCertificateUntrusted, .serverCertificateHasBadDate,
                     .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot] {
            assertMessageAccepted(classify(code))
        }
    }

    func testUnmappedAndNonURLErrorsDegradeWithoutLeakingText() {
        // The point of a fallback is that it never carries a description: those
        // embed the failing URL and host.
        XCTAssertEqual(
            HTTPDiagnosticsErrorCode.classify(transport: NSError(domain: "custom", code: 42)),
            "transport_other"
        )
        XCTAssertEqual(classify(URLError.Code(rawValue: -424_242)), "urlerror_-424242")
    }

    func testEveryURLErrorCodeProducesACollectorSafeValue() {
        // Exhaustive over the whole documented range rather than the mapped
        // subset: the `urlerror_<n>` fallback is the arm most likely to produce
        // something unexpected, and a new OS release can add codes.
        for raw in (-4_000)...100 {
            let value = HTTPDiagnosticsErrorCode.classify(
                transport: URLError(URLError.Code(rawValue: raw))
            )
            assertMessageAccepted(value)
        }
    }

    func testDecodeAndStatusClassification() {
        let context = DecodingError.Context(codingPath: [], debugDescription: "")
        XCTAssertEqual(
            HTTPDiagnosticsErrorCode.classify(
                decoding: DecodingError.keyNotFound(Key("a"), context)
            ),
            "key_not_found"
        )
        XCTAssertEqual(
            HTTPDiagnosticsErrorCode.classify(
                decoding: DecodingError.typeMismatch(Int.self, context)
            ),
            "type_mismatch"
        )
        XCTAssertEqual(
            HTTPDiagnosticsErrorCode.classify(decoding: NSError(domain: "x", code: 1)),
            "decoding_other"
        )
        XCTAssertEqual(HTTPDiagnosticsErrorCode.http(status: 404), "http_404")
    }

    func testOutcomeVocabularyIsCollectorSafe() {
        // `outcome` is a closed set, so it can be asserted whole. The values
        // that read most naturally are not always the shippable ones — e.g.
        // `identity_changed` is used precisely because HTTPError's own
        // `request_identity_changed` matches PRIVATE_ID_IN_TEXT.
        for value in [
            HTTPDiagnosticsOutcome.success,
            HTTPDiagnosticsOutcome.quiet,
            HTTPDiagnosticsOutcome.httpError,
            HTTPDiagnosticsOutcome.transportError,
            HTTPDiagnosticsOutcome.cancelled,
            HTTPDiagnosticsOutcome.identityChanged,
            HTTPDiagnosticsOutcome.invalidResponse,
            HTTPDiagnosticsOutcome.decodeFailed,
            HTTPDiagnosticsOutcome.retried,
            HTTPDiagnosticsOutcome.notRetried,
            HTTPDiagnosticsOutcome.reachable,
            HTTPDiagnosticsOutcome.unreachable,
            HTTPDiagnosticsOutcome.online,
            HTTPDiagnosticsOutcome.offline,
        ] {
            assertMessageAccepted(value)
        }
    }

    // MARK: - Helpers

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(_ value: String) { stringValue = value; intValue = nil }
        init(_ value: Int) { stringValue = String(value); intValue = value }
        init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
    }

    private func classify(_ code: URLError.Code) -> String {
        HTTPDiagnosticsErrorCode.classify(transport: URLError(code))
    }

    private func assertPath(
        _ raw: String,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = HTTPDiagnosticsPath.attribute(forRawPath: raw)
        XCTAssertEqual(actual, expected, file: file, line: line)
        assertPathAccepted(actual, source: raw, file: file, line: line)
    }

    private func assertPath(
        url raw: String,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = HTTPDiagnosticsPath.attribute(for: URL(string: raw))
        XCTAssertEqual(actual, expected, file: file, line: line)
        assertPathAccepted(actual, source: raw, file: file, line: line)
    }

    /// Mirrors `silo-diagnostics/src/privacy.ts` `hasPrivatePathSegment`, the
    /// gate applied to `attrs.path`.
    private func assertPathAccepted(
        _ path: String,
        source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(path.contains("?"), "query marker survived \(source)", file: file, line: line)
        XCTAssertFalse(path.contains("#"), "fragment survived \(source)", file: file, line: line)
        let lowercased = path.lowercased()
        for prefix in ["/users/", "/private/", "/var/mobile/", "/data/user/"] {
            XCTAssertFalse(
                lowercased.hasPrefix(prefix),
                "rejected prefix \(prefix) survived \(source)",
                file: file,
                line: line
            )
        }
        for rawSegment in path.split(separator: "/", omittingEmptySubsequences: true) {
            let segment = String(rawSegment)
            XCTAssertFalse(segment.contains("%"), "encoded segment in \(path)", file: file, line: line)
            if segment == "{id}" || Self.matches(Self.safeVersion, segment) { continue }
            let candidates = [segment] + segment.components(
                separatedBy: CharacterSet(charactersIn: ".,;:()[]")
            )
            for candidate in candidates where !candidate.isEmpty {
                for (name, regex) in Self.privateSegmentRules {
                    XCTAssertFalse(
                        Self.matches(regex, candidate),
                        "\(candidate) matches \(name) in \(path) (from \(source))",
                        file: file,
                        line: line
                    )
                }
            }
        }
    }

    /// Mirrors the collector's text-context rules, which apply to `msg` and to
    /// string attribute values. Strictly different from the path rules above:
    /// a dotted token is fine in neither, but `PRIVATE_ID_IN_TEXT` matches
    /// unanchored here, so `Session_Abcdefgh` is rejected inside a sentence
    /// even though no path segment equals it.
    private func assertMessageAccepted(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (name, regex) in Self.textRules {
            XCTAssertFalse(
                Self.matches(regex, message),
                "message matches collector rule \(name): \(message)",
                file: file,
                line: line
            )
        }
        // The dotted hostname/route scan: any `a.b` token in text is treated as
        // a hostname or route candidate unless it is on a hand-curated
        // allowlist we deliberately do not depend on.
        XCTAssertNil(
            Self.dottedToken.firstMatch(
                in: message,
                range: NSRange(location: 0, length: (message as NSString).length)
            ),
            "message contains a dotted token: \(message)",
            file: file,
            line: line
        )
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        regex.firstMatch(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length)
        ) != nil
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static let safeVersion = regex(#"(?i)^v[0-9]+$"#)

    /// privacy.ts `UUID_VALUE`, numeric, `PRIVATE_ID_SEGMENT`,
    /// `HEX_ID_SEGMENT`, `OPAQUE_ID_SEGMENT`.
    private static let privateSegmentRules: [(String, NSRegularExpression)] = [
        ("UUID_VALUE", regex(#"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#)),
        ("NUMERIC", regex(#"^[0-9]+$"#)),
        ("PRIVATE_ID_SEGMENT", regex(#"(?i)^(?:ps|playback|session|file|item|media|plan|attempt|profile|account|user|device|content|library|request|req|correlation|server|subtitle|track|run)[_-][a-z0-9_-]{4,}$"#)),
        ("HEX_ID_SEGMENT", regex(#"(?i)^[0-9a-f]{16,}$"#)),
        ("OPAQUE_ID_SEGMENT", regex(#"^[A-Za-z0-9_-]{20,}$"#)),
    ]

    /// privacy.ts text-context rules.
    private static let textRules: [(String, NSRegularExpression)] = [
        ("PRIVATE_ID_IN_TEXT", regex(#"(?i)(?:^|[^A-Za-z0-9])(?:ps|playback|session|file|item|media|plan|attempt|profile|account|user|device|content|library|request|req|correlation|server|subtitle|track|run)[_-](?:[0-9]+|[A-Za-z0-9][A-Za-z0-9_-]{7,})(?=$|[^A-Za-z0-9_-])"#)),
        ("UUID_VALUE", regex(#"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#)),
        ("COMPACT_UUID_VALUE", regex(#"(?i)(?:^|[^0-9a-f])[0-9a-f]{32}(?=$|[^0-9a-f])"#)),
        ("MAC_ADDRESS", regex(#"(?i)(?:^|[^0-9a-f-])[0-9a-f]{12}(?=$|[^0-9a-f-])"#)),
    ]

    private static let dottedToken = regex(#"[A-Za-z0-9][A-Za-z0-9_-]*\.[A-Za-z0-9][A-Za-z0-9_.-]*"#)
}

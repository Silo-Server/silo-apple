#if os(iOS) || os(tvOS)
import XCTest
@testable import Silo

/// Gates the three copies of the client-diagnostics attribute registry that
/// live in this repository against each other:
///
/// 1. `Tests/Fixtures/DiagnosticsContract/attr-registry.json`, vendored verbatim
///    from silo-server `docs/design/schemas/client-diagnostics/v1/`.
/// 2. `DiagLogAttributeRegistry.registry`, which decides what this client is
///    allowed to emit at all.
/// 3. `DiagnosticsBundleBuilder.hostedAttributeRegistry`, the narrower privacy
///    allowlist applied when building a bundle for the hosted collector.
///
/// The registry drifted once already: keys were added to the Swift tables and
/// hand-patched into the vendored fixture instead of being re-vendored. The
/// collectors do not forgive that — the self-hosted Go collector silently drops
/// unregistered keys, and the hosted collector rejects the entire report. These
/// tests are the guard that was missing.
final class DiagnosticsAttributeRegistryParityTests: XCTestCase {
    private typealias CanonicalRegistry = [DiagnosticsLogCategory: [String: DiagLogAttributeRegistry.ValueType]]

    // MARK: - Canonical fixture

    func testVendoredRegistryFixtureMatchesTheCanonicalV1Contract() throws {
        let (schemaVersion, canonical) = try loadCanonicalRegistry()
        XCTAssertEqual(schemaVersion, 1)

        XCTAssertEqual(
            Set(canonical.keys),
            [.playback, .focus, .network, .lifecycle, .crash],
            "Categories changed in the vendored contract; re-check every consumer."
        )

        XCTAssertEqual(canonical[.playback], [
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
        ])
        XCTAssertEqual(canonical[.focus], [
            "target": .string,
            "action": .string,
        ])
        XCTAssertEqual(canonical[.network], [
            "method": .string,
            "path": .string,
            "status": .integer,
            "duration_ms": .integer,
            "outcome": .string,
            "error_code": .string,
            "attempt": .integer,
        ])
        XCTAssertEqual(canonical[.lifecycle], [
            "state": .string,
            "phase": .string,
            "duration_ms": .integer,
            "outcome": .string,
            "reason": .string,
            "launch_type": .string,
        ])
        XCTAssertEqual(canonical[.crash], [
            "fingerprint": .string,
            "source": .string,
        ])
    }

    /// The self-hosted collector's registry is a Go map with no floating-point
    /// attribute type, so a `number` in the contract is unrepresentable there.
    /// `playback.position_seconds` was exactly that mistake; it is now
    /// `position_ms`, an integer.
    func testCanonicalRegistryDeclaresNoFloatingPointAttributes() throws {
        let (_, canonical) = try loadCanonicalRegistry()
        for (category, attributes) in canonical {
            for (key, type) in attributes {
                XCTAssertNotEqual(
                    type,
                    .number,
                    "\(category.rawValue).\(key) is a float; the Go registry cannot express it"
                )
            }
            XCTAssertNil(
                attributes["position_seconds"],
                "position_seconds was retired in favour of position_ms"
            )
        }
    }

    // MARK: - Emission registry

    func testDiagLogEmissionRegistryEqualsTheCanonicalRegistry() throws {
        let (_, canonical) = try loadCanonicalRegistry()
        let emitted = DiagLogAttributeRegistry.registry

        XCTAssertEqual(
            Set(emitted.keys),
            Set(canonical.keys),
            "DiagLog registers a different set of categories than the vendored contract"
        )

        for category in Set(canonical.keys).union(emitted.keys).sorted(by: { $0.rawValue < $1.rawValue }) {
            let expected = canonical[category] ?? [:]
            let actual = emitted[category] ?? [:]
            XCTAssertEqual(
                Set(actual.keys).subtracting(expected.keys),
                [],
                "\(category.rawValue): DiagLog emits keys the collectors do not register"
            )
            XCTAssertEqual(
                Set(expected.keys).subtracting(actual.keys),
                [],
                "\(category.rawValue): DiagLog is missing canonical keys"
            )
            XCTAssertEqual(actual, expected, "\(category.rawValue): attribute types disagree")
        }
    }

    // MARK: - Hosted privacy allowlist

    /// The hosted allowlist is intentionally *narrower* than canonical, so this
    /// is a subset assertion in one direction only. It is pinned to an exact key
    /// set in the other direction: a key silently appearing here is a privacy
    /// regression, and a key silently disappearing is a telemetry regression.
    func testHostedAttributeAllowlistIsACanonicalSubset() throws {
        let (_, canonical) = try loadCanonicalRegistry()
        let hosted = DiagnosticsBundleBuilder.hostedAttributeRegistry

        for (category, attributes) in hosted {
            let canonicalAttributes = canonical[category]
            XCTAssertNotNil(
                canonicalAttributes,
                "Hosted allowlist has category \(category.rawValue) the contract does not register"
            )
            for (key, type) in attributes {
                guard let canonicalType = canonicalAttributes?[key] else {
                    XCTFail("Hosted allowlist has unregistered key \(category.rawValue).\(key)")
                    continue
                }
                XCTAssertEqual(
                    canonicalType,
                    type.canonicalValueType,
                    "\(category.rawValue).\(key) has a different type in the hosted allowlist"
                )
            }
        }

        XCTAssertEqual(hostedKeys(hosted), [
            .playback: [
                "sink", "fmt", "decoder", "width", "height", "hdr_mode",
                "bitrate_kbps", "dropped_frames", "audio_underruns",
            ],
            .focus: ["target", "action"],
            .network: [
                "method", "path", "status", "duration_ms", "outcome",
                "error_code",
            ],
            .lifecycle: [
                "state", "phase", "duration_ms", "outcome", "reason", "launch_type",
            ],
            .crash: ["fingerprint", "source"],
        ])
    }

    /// The keys canonical registers but the hosted collector is deliberately not
    /// given. Two separate reasons, and they fail differently:
    ///
    /// - The `playback` keys identify one user's specific viewing session. The
    ///   hosted collector would accept them; we choose not to send them.
    /// - `network.attempt` collides with the hosted collector's `FORBIDDEN_KEYS`
    ///   privacy scanner (silo-diagnostics `src/privacy.ts`). Sending it does
    ///   not reject the bundle — the report reaches `ready` but permanently
    ///   fails the `privacy_fields` check and shows as `privacy_flagged`. Since
    ///   a routine 401-token-refresh retry emits it, forwarding it would flag
    ///   ordinary reports as privacy incidents.
    ///
    /// Stated explicitly so that widening the allowlist has to be a deliberate
    /// edit here rather than a side effect of a re-vendor.
    func testHostedAllowlistWithholdsSessionIdentifyingAndCollectorForbiddenAttributes() throws {
        let (_, canonical) = try loadCanonicalRegistry()
        let hosted = DiagnosticsBundleBuilder.hostedAttributeRegistry

        var withheld: [DiagnosticsLogCategory: Set<String>] = [:]
        for (category, attributes) in canonical {
            let allowed = Set((hosted[category] ?? [:]).keys)
            let difference = Set(attributes.keys).subtracting(allowed)
            if !difference.isEmpty {
                withheld[category] = difference
            }
        }

        XCTAssertEqual(withheld, [
            .playback: ["session_id", "play_method", "reason", "position_ms"],
            .network: ["attempt"],
        ])

        // Called out on its own so the failure names the consequence rather than
        // just printing a set diff: this key is canonical and type-valid, so the
        // subset assertion above will not catch it coming back.
        XCTAssertNil(
            hosted[.network]?["attempt"],
            """
            network.attempt is back in the hosted allowlist. `attempt` is in the \
            hosted collector's FORBIDDEN_KEYS, so every hosted report from a \
            session with a 401 refresh retry would be permanently privacy_flagged. \
            The retry line's msg ("401 retry" / "401 not retried") already carries \
            the distinction; keep the attribute self-hosted only.
            """
        )
    }

    // MARK: - Helpers

    private func hostedKeys(
        _ registry: [DiagnosticsLogCategory: [String: DiagnosticsBundleBuilder.HostedAttributeType]]
    ) -> [DiagnosticsLogCategory: Set<String>] {
        registry.mapValues { Set($0.keys) }
    }

    private func loadCanonicalRegistry() throws -> (schemaVersion: Int, registry: CanonicalRegistry) {
        let url = try fixtureURL("attr-registry.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let object = root as? [String: Any],
              let schemaVersion = object["schema_version"] as? Int,
              let categories = object["categories"] as? [String: Any] else {
            throw registryError("attr-registry.json is not a v1 attribute registry")
        }

        var registry: CanonicalRegistry = [:]
        for (rawCategory, rawAttributes) in categories {
            guard let category = DiagnosticsLogCategory(rawValue: rawCategory) else {
                throw registryError("Unknown diagnostics category in contract: \(rawCategory)")
            }
            guard let attributes = rawAttributes as? [String: Any] else {
                throw registryError("Category \(rawCategory) is not an object")
            }
            var mapped: [String: DiagLogAttributeRegistry.ValueType] = [:]
            for (key, rawAttribute) in attributes {
                guard let attribute = rawAttribute as? [String: Any],
                      let rawType = attribute["type"] as? String else {
                    throw registryError("Attribute \(rawCategory).\(key) has no declared type")
                }
                switch rawType {
                case "string": mapped[key] = .string
                case "integer": mapped[key] = .integer
                case "number": mapped[key] = .number
                case "boolean", "bool": mapped[key] = .bool
                default:
                    throw registryError("Attribute \(rawCategory).\(key) has unsupported type \(rawType)")
                }
            }
            registry[category] = mapped
        }
        return (schemaVersion, registry)
    }

    private func registryError(_ message: String) -> NSError {
        NSError(
            domain: "DiagnosticsAttributeRegistryParityTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// Mirrors `DiagnosticsContractTests.fixtureURL`: XcodeGen may flatten the
    /// fixture tree into the bundle root, so try that first and fall back to the
    /// on-disk directory layout.
    private func fixtureURL(_ fileName: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        let baseName = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        if let flattened = bundle.url(forResource: baseName, withExtension: ext) {
            return flattened
        }

        let candidates = [
            bundle.resourceURL?
                .appendingPathComponent("DiagnosticsContract")
                .appendingPathComponent(fileName),
            bundle.resourceURL?
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("DiagnosticsContract")
                .appendingPathComponent(fileName),
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        throw registryError("Diagnostics contract fixture missing from test bundle: \(fileName)")
    }
}

private extension DiagnosticsBundleBuilder.HostedAttributeType {
    var canonicalValueType: DiagLogAttributeRegistry.ValueType {
        switch self {
        case .string: return .string
        case .integer: return .integer
        }
    }
}
#endif

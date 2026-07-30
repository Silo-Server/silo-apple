import XCTest
@testable import Silo

/// The Swift runner for the cross-platform settings conformance fixture — the
/// contract's named drift gate.
///
/// The same hand-authored cases in `contracts/settings/v1/conformance.json` run
/// against the Go resolver (`internal/settingsresolve/conformance_test.go`), the
/// TypeScript one (`web/src/lib/settingsConformance.test.ts`), the Kotlin one in
/// silo-android, and this one. Four independently written resolvers agreeing on
/// every case is the whole point, so this runner takes the fixture at face
/// value: it decodes strictly, resolves through `resolveSettingValues` against
/// the real vendored manifest, and compares every declared expectation.
///
/// Both JSON files are vendored byte-identically from the server repo; see the
/// SOURCE file beside them. Nothing here touches the network.
///
/// Four things fail this suite, and each of them is drift:
///
/// 1. A resolution disagreement — this client would show a user a different
///    effective setting than the server resolves.
/// 2. A manifest revision mismatch between the fixture, the vendored manifest,
///    and the generated `SettingKey`. A revision bump changes definitions, so
///    the expectations have to be re-derived rather than assumed to still hold.
/// 3. A key the bindings and the vendored manifest disagree about, which catches
///    the two JSON files being vendored from different server commits — skew the
///    revision check cannot see, since a revision only moves on a manifest PR
///    and both copies would still read the same number.
/// 4. A fixture field this runner does not know. Schema drift in the fixture is
///    itself drift: a field one platform reads and another silently skips means
///    the platforms are no longer running the same cases, which is precisely the
///    failure the fixture exists to prevent. Strictness here is not pedantry —
///    it is the only thing keeping a silent skip from looking like a pass.
///
/// Swift has no `DisallowUnknownFields`, so strictness is two passes over the
/// same bytes: a typed decode for the values, and a walk of the raw tree that
/// rejects an unknown field at every level and answers the one question typed
/// decoding cannot — whether `stored_value` was absent or authored as JSON null.
final class SettingsConformanceTests: XCTestCase {

    // MARK: - Fixture model

    private struct ConformanceFixture: Decodable {
        let fixtureVersion: Int
        let manifestRevision: Int
        let description: String
        let cases: [ConformanceCase]

        enum CodingKeys: String, CodingKey {
            case fixtureVersion = "fixture_version"
            case manifestRevision = "manifest_revision"
            case description
            case cases
        }
    }

    private struct ConformanceCase: Decodable {
        let name: String
        let description: String?
        let keys: [String]
        let context: ConformanceContext?
        let stored: [ConformanceRow]
        /// Policy inputs by name, as the policy layer would supply them. Keys
        /// here are data, not schema, so they are deliberately not field-checked.
        let constraints: [String: SettingJSONValue]
        /// Attaches a constraint to a copy of a real definition, so constraint
        /// kinds no shipped definition carries stay testable.
        let constraintBindings: [ConformanceBinding]
        let expected: [ConformanceExpected]

        enum CodingKeys: String, CodingKey {
            case name
            case description
            case keys
            case context
            case stored
            case constraints
            case constraintBindings = "constraint_bindings"
            case expected
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            keys = try container.decode([String].self, forKey: .keys)
            context = try container.decodeIfPresent(ConformanceContext.self, forKey: .context)
            stored = try container.decodeIfPresent([ConformanceRow].self, forKey: .stored) ?? []
            constraints = try container.decodeIfPresent(
                [String: SettingJSONValue].self, forKey: .constraints
            ) ?? [:]
            constraintBindings = try container.decodeIfPresent(
                [ConformanceBinding].self, forKey: .constraintBindings
            ) ?? []
            expected = try container.decode([ConformanceExpected].self, forKey: .expected)
        }
    }

    private struct ConformanceContext: Decodable {
        let profileId: String?
        let deviceId: String?
        let libraryIds: [Int]
        let seriesIds: [String]

        enum CodingKeys: String, CodingKey {
            case profileId = "profile_id"
            case deviceId = "device_id"
            case libraryIds = "library_ids"
            case seriesIds = "series_ids"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            profileId = try container.decodeIfPresent(String.self, forKey: .profileId)
            deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
            libraryIds = try container.decodeIfPresent([Int].self, forKey: .libraryIds) ?? []
            seriesIds = try container.decodeIfPresent([String].self, forKey: .seriesIds) ?? []
        }
    }

    private struct ConformanceRow: Decodable {
        let key: String
        let scope: String
        let profileId: String?
        let deviceId: String?
        let libraryId: Int?
        let seriesId: String?
        /// Required, and typed non-optional: a stored row whose authored value
        /// is JSON null must decode to `.null` rather than collapsing onto the
        /// same Swift nil an omission produces.
        let value: SettingJSONValue

        enum CodingKeys: String, CodingKey {
            case key
            case scope
            case profileId = "profile_id"
            case deviceId = "device_id"
            case libraryId = "library_id"
            case seriesId = "series_id"
            case value
        }
    }

    private struct ConformanceBinding: Decodable {
        let key: String
        let policyInput: String
        let constraint: SettingConstraintKind

        enum CodingKeys: String, CodingKey {
            case key
            case policyInput = "policy_input"
            case constraint
        }
    }

    private struct ConformanceExpected: Decodable {
        let key: String
        let value: SettingJSONValue
        let source: String
        /// Defaults to false; when true, stored_value and constraint_kind must
        /// be present.
        let constrained: Bool
        /// `nil` means the field was absent, `.null` an authored JSON null —
        /// two bitrate cases and one allowlist case rely on the difference, so
        /// this decodes through an explicit `contains` check rather than
        /// `decodeIfPresent`.
        let storedValue: SettingJSONValue?
        let constraintKind: SettingConstraintKind?

        enum CodingKeys: String, CodingKey {
            case key
            case value
            case source
            case constrained
            case storedValue = "stored_value"
            case constraintKind = "constraint_kind"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            value = try container.decode(SettingJSONValue.self, forKey: .value)
            source = try container.decode(String.self, forKey: .source)
            constrained = try container.decodeIfPresent(Bool.self, forKey: .constrained) ?? false
            if container.contains(.storedValue) {
                storedValue = try container.decode(SettingJSONValue.self, forKey: .storedValue)
            } else {
                storedValue = SettingJSONValue?.none
            }
            constraintKind = try container.decodeIfPresent(
                SettingConstraintKind.self, forKey: .constraintKind
            )
        }
    }

    // MARK: - Loading

    /// Field names this runner understands, per level. Anything else fails.
    private enum FixtureFields {
        static let root = ["fixture_version", "manifest_revision", "description", "cases"]
        static let testCase = [
            "name", "description", "keys", "context", "stored",
            "constraints", "constraint_bindings", "expected",
        ]
        static let context = ["profile_id", "device_id", "library_ids", "series_ids"]
        static let row = [
            "key", "scope", "profile_id", "device_id", "library_id", "series_id", "value",
        ]
        static let binding = ["key", "policy_input", "constraint"]
        static let expected = [
            "key", "value", "source", "constrained", "stored_value", "constraint_kind",
        ]
    }

    private func fixtureData(_ fileName: String) throws -> Data {
        try Data(contentsOf: try Self.resourceURL(fileName))
    }

    /// Locates a vendored contract file in the test bundle.
    ///
    /// XcodeGen adds a resource under `Tests/` as a plain file reference, which
    /// lands flattened at the bundle root; the subdirectory candidates are the
    /// fallback for a build that preserves the folder, matching what
    /// `DiagnosticsContractTests` does for its own vendored schemas.
    private static func resourceURL(_ fileName: String) throws -> URL {
        let bundle = Bundle(for: SettingsConformanceTests.self)
        let baseName = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        if let flattened = bundle.url(forResource: baseName, withExtension: ext) {
            return flattened
        }
        let candidates = [
            bundle.resourceURL?
                .appendingPathComponent("SettingsContract")
                .appendingPathComponent(fileName),
            bundle.resourceURL?
                .appendingPathComponent("Fixtures")
                .appendingPathComponent("SettingsContract")
                .appendingPathComponent(fileName),
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        // A hard failure rather than a skip: a fixture that is not bundled is a
        // gate that silently stopped running, which is the failure mode this
        // whole suite exists to prevent.
        throw FixtureSchemaError(
            "settings contract resource missing from the test bundle: \(fileName) — "
                + "check the SiloTests resources entry in iosApp/project.yml"
        )
    }

    private func loadManifest() throws -> SettingsContractManifest {
        try SettingsContractManifest.decode(from: try fixtureData("manifest.json"))
    }

    private func loadFixture() throws -> ConformanceFixture {
        let data = try fixtureData("conformance.json")
        try Self.assertNoUnknownFixtureFields(in: data)
        return try SettingsWireCoding.makeDecoder().decode(ConformanceFixture.self, from: data)
    }

    // MARK: - Strict field checking

    /// Walks the raw fixture tree and throws on the first field this runner
    /// does not know, at any level.
    ///
    /// A `constraints` map and any setting `value` are deliberately skipped:
    /// their keys are data authored by the contract, not fixture schema.
    private static func assertNoUnknownFixtureFields(in data: Data) throws {
        let parsed = try JSONSerialization.jsonObject(with: data)
        let root = try object(parsed, at: "fixture")
        try requireOnly(FixtureFields.root, in: root, at: "fixture")

        let cases = try array(root["cases"], at: "fixture.cases")
        for (index, rawCase) in cases.enumerated() {
            let path = "cases[\(index)]"
            let testCase = try object(rawCase, at: path)
            try requireOnly(FixtureFields.testCase, in: testCase, at: path)

            if let context = testCase["context"] {
                try requireOnly(
                    FixtureFields.context,
                    in: try object(context, at: "\(path).context"),
                    at: "\(path).context"
                )
            }
            for (rowIndex, rawRow) in try array(testCase["stored"], at: "\(path).stored").enumerated() {
                let rowPath = "\(path).stored[\(rowIndex)]"
                let row = try object(rawRow, at: rowPath)
                try requireOnly(FixtureFields.row, in: row, at: rowPath)
                // Required and possibly null: JSONSerialization renders an
                // authored null as NSNull, so presence is the only check that
                // separates it from an omission.
                guard row.keys.contains("value") else {
                    throw FixtureSchemaError("\(rowPath) must spell an authored null as null")
                }
            }
            let rawBindings = try array(
                testCase["constraint_bindings"], at: "\(path).constraint_bindings"
            )
            for (bindingIndex, rawBinding) in rawBindings.enumerated() {
                let bindingPath = "\(path).constraint_bindings[\(bindingIndex)]"
                try requireOnly(
                    FixtureFields.binding,
                    in: try object(rawBinding, at: bindingPath),
                    at: bindingPath
                )
            }
            let expectations = try array(testCase["expected"], at: "\(path).expected")
            for (expectedIndex, rawExpected) in expectations.enumerated() {
                let expectedPath = "\(path).expected[\(expectedIndex)]"
                let expectation = try object(rawExpected, at: expectedPath)
                try requireOnly(FixtureFields.expected, in: expectation, at: expectedPath)
                guard expectation.keys.contains("value") else {
                    throw FixtureSchemaError("\(expectedPath) must spell an expected null as null")
                }
                // The null-vs-absent gate the typed decode cannot express, and
                // the shape rule the fixture's own description states: a
                // constrained expectation declares both extra fields, an
                // unconstrained one declares neither.
                let constrained = expectation["constrained"] as? Bool ?? false
                let declaresStored = expectation.keys.contains("stored_value")
                let declaresKind = expectation.keys.contains("constraint_kind")
                if constrained {
                    guard declaresStored, declaresKind else {
                        throw FixtureSchemaError(
                            "\(expectedPath): a constrained expectation must declare "
                                + "stored_value and constraint_kind"
                        )
                    }
                } else if declaresStored || declaresKind {
                    throw FixtureSchemaError(
                        "\(expectedPath): an unconstrained expectation must declare neither "
                            + "stored_value nor constraint_kind"
                    )
                }
            }
        }
    }

    private struct FixtureSchemaError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func object(_ value: Any, at path: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw FixtureSchemaError("\(path) must be a JSON object")
        }
        return object
    }

    /// An optional array field: absent is fine, present-but-not-an-array is
    /// not. `as? [Any] ?? []` would treat a mistyped field as an empty list and
    /// skip every element inside it — a silent hole in the walk.
    private static func array(_ value: Any?, at path: String) throws -> [Any] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            throw FixtureSchemaError("\(path) must be an array")
        }
        return array
    }

    private static func requireOnly(
        _ allowed: [String],
        in object: [String: Any],
        at path: String
    ) throws {
        let unknown = object.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw FixtureSchemaError(
                "unknown fixture field(s) at \(path): \(unknown.joined(separator: ", "))"
            )
        }
    }

    // MARK: - Revision agreement

    func testTheFixtureTargetsThisBuildsManifestRevision() throws {
        let manifest = try loadManifest()
        let fixture = try loadFixture()

        XCTAssertEqual(fixture.fixtureVersion, 1, "this runner understands fixture_version 1")
        XCTAssertEqual(manifest.apiVersion, 1, "this runner understands settings api_version 1")

        // Three copies of one number, and they are only equal by maintenance:
        // the fixture, the manifest it was authored against, and the bindings
        // generated from that manifest. A bump to any one without the others is
        // a client resolving against a contract it no longer carries.
        XCTAssertEqual(
            fixture.manifestRevision,
            manifest.revision,
            "the fixture targets manifest revision \(fixture.manifestRevision) but the vendored "
                + "manifest is revision \(manifest.revision); re-vendor both and re-derive the "
                + "fixture expectations"
        )
        XCTAssertEqual(
            manifest.revision,
            SettingKey.revision,
            "the vendored manifest is revision \(manifest.revision) but the generated bindings "
                + "are revision \(SettingKey.revision); re-run make settings-bindings on the "
                + "server and re-vendor"
        )
        XCTAssertFalse(fixture.cases.isEmpty, "the fixture declares no cases")
    }

    func testTheVendoredManifestCoversTheGeneratedBindings() throws {
        let manifest = try loadManifest()

        // The bindings are generated from this manifest, so every key must
        // resolve against it with the same persistence. A key in one and not the
        // other means the two files were vendored from different server commits
        // — the exact drift the revision check cannot catch, because a revision
        // only moves on a manifest PR and both copies would still read 1.
        for key in SettingKey.remote {
            guard let definition = manifest.lookup(key.rawValue) else {
                XCTFail("\(key.rawValue) is not in the vendored manifest")
                continue
            }
            XCTAssertTrue(
                definition.isRemote,
                "\(key.rawValue) is remote in the bindings but not in the manifest"
            )
        }
        for key in SettingKey.clientLocal {
            guard let definition = manifest.lookup(key.rawValue) else {
                XCTFail("\(key.rawValue) is not in the vendored manifest")
                continue
            }
            XCTAssertFalse(
                definition.isRemote,
                "\(key.rawValue) is client_local in the bindings but remote in the manifest"
            )
        }
        XCTAssertEqual(
            manifest.definitions.count,
            SettingKey.allCases.count,
            "the vendored manifest and the generated bindings define a different number of keys"
        )
    }

    func testEveryCaseIsDeclaredOnce() throws {
        let names = try loadFixture().cases.map(\.name)
        XCTAssertFalse(names.contains(where: \.isEmpty), "a conformance case has no name")
        XCTAssertEqual(names.count, Set(names).count, "duplicate conformance case name")
    }

    // MARK: - The cases

    func testEveryCaseResolvesToItsExpectedEffectiveValues() throws {
        let manifest = try loadManifest()
        let fixture = try loadFixture()

        var executed: [String] = []
        for testCase in fixture.cases {
            // One activity per case, so a failing report names the case that
            // failed rather than attributing all 24 to one opaque test.
            XCTContext.runActivity(named: "conformance case: \(testCase.name)") { _ in
                run(testCase, manifest: manifest)
                executed.append(testCase.name)
            }
        }

        // The fixture is a gate only if every case in it ran. A case this
        // runner skips — because it carries a shape the file mishandles, or
        // because a later edit adds an early exit to the loop — must fail
        // rather than shrink the suite quietly.
        XCTAssertEqual(
            executed,
            fixture.cases.map(\.name),
            "not every conformance case was executed"
        )
    }

    /// Runs one fixture case: builds its injected constraint bindings,
    /// resolves, and checks every declared expectation.
    private func run(_ testCase: ConformanceCase, manifest: SettingsContractManifest) {
        XCTAssertFalse(testCase.keys.isEmpty, "\(testCase.name): declares no keys")
        XCTAssertFalse(testCase.expected.isEmpty, "\(testCase.name): declares no expectations")

        var bindings: [String: SettingsContractConstraint] = [:]
        for binding in testCase.constraintBindings {
            XCTAssertNotNil(
                manifest.lookup(binding.key),
                "\(testCase.name): constraint binding names unknown key \(binding.key)"
            )
            XCTAssertFalse(
                binding.policyInput.isEmpty,
                "\(testCase.name): constraint binding on \(binding.key) has no policy_input"
            )
            if case .other(let raw) = binding.constraint {
                XCTFail(
                    "\(testCase.name): constraint binding on \(binding.key) names unknown "
                        + "kind \(raw)"
                )
            }
            XCTAssertNil(
                bindings.updateValue(
                    SettingsContractConstraint(
                        policyInput: binding.policyInput,
                        constraint: binding.constraint
                    ),
                    forKey: binding.key
                ),
                "\(testCase.name): duplicate constraint binding for \(binding.key)"
            )
        }

        let resolved = resolveSettingValues(
            manifest: manifest,
            keys: testCase.keys,
            stored: testCase.stored.map { row in
                StoredSettingRow(
                    key: row.key,
                    scope: row.scope,
                    profileId: row.profileId,
                    deviceId: row.deviceId,
                    libraryId: row.libraryId,
                    seriesId: row.seriesId,
                    value: row.value
                )
            },
            context: SettingResolutionContext(
                profileId: testCase.context?.profileId,
                deviceId: testCase.context?.deviceId,
                libraryIds: testCase.context?.libraryIds ?? [],
                seriesIds: testCase.context?.seriesIds ?? []
            ),
            constraints: testCase.constraints,
            constraintBindings: bindings
        )

        XCTAssertEqual(
            resolved.count,
            testCase.expected.count,
            "\(testCase.name): resolved \(resolved.count) settings, the fixture expects "
                + "\(testCase.expected.count)"
        )
        let byKey = Dictionary(
            resolved.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for expectation in testCase.expected {
            let label = "\(testCase.name): \(expectation.key)"
            guard let entry = byKey[expectation.key] else {
                XCTFail("\(label): no resolved value")
                continue
            }
            XCTAssertTrue(
                entry.value.isSemanticallyEquivalent(to: expectation.value),
                "\(label): value = \(entry.value), want \(expectation.value)"
            )
            XCTAssertEqual(entry.source, expectation.source, "\(label): source")
            XCTAssertEqual(entry.constrained, expectation.constrained, "\(label): constrained")
            XCTAssertEqual(
                entry.constraintKind,
                expectation.constraintKind,
                "\(label): constraint_kind"
            )
            if expectation.constrained {
                guard let storedValue = entry.storedValue else {
                    XCTFail("\(label): a constrained result must report stored_value")
                    continue
                }
                // Non-nil by the shape rule the strict pass already enforced;
                // the fallback only keeps this side of the check total.
                let expectedStored = expectation.storedValue ?? .null
                XCTAssertTrue(
                    storedValue.isSemanticallyEquivalent(to: expectedStored),
                    "\(label): stored_value = \(storedValue), want \(expectedStored)"
                )
            } else {
                XCTAssertNil(
                    entry.storedValue,
                    "\(label): stored_value reported without a constraint"
                )
            }
        }
    }

    // MARK: - The gate's own gate

    func testAnUnknownFixtureFieldFails() throws {
        // The unknown-field gate is the one thing here that would otherwise be
        // untested — it only ever fires on a fixture this repo does not carry
        // yet, so its own regression would be invisible until the day it was
        // needed. Injecting a field at each level proves the walk actually
        // reaches that level.
        let original = String(decoding: try fixtureData("conformance.json"), as: UTF8.self)
        let injections: [(label: String, find: String, replace: String)] = [
            ("root", "\"cases\":", "\"cases_v2\": [], \"cases\":"),
            ("case", "\"keys\":", "\"keys_v2\": [], \"keys\":"),
            ("stored row", "\"scope\": \"profile\"", "\"scope_v2\": \"x\", \"scope\": \"profile\""),
            ("expectation", "\"source\":", "\"source_v2\": \"x\", \"source\":"),
        ]
        for injection in injections {
            let drifted = original.replacingOccurrences(
                of: injection.find,
                with: injection.replace,
                options: [],
                range: original.range(of: injection.find)
            )
            XCTAssertNotEqual(
                drifted, original, "failed to inject a drifted field at the \(injection.label) level"
            )
            XCTAssertThrowsError(
                try Self.assertNoUnknownFixtureFields(in: Data(drifted.utf8)),
                "an unknown field at the \(injection.label) level passed; strict checking is off "
                    + "and drift in the fixture schema would go unnoticed"
            )
        }
    }

    func testTheVendoredFixturePassesItsOwnStrictCheck() throws {
        // The mirror of the test above: the injections only prove anything if
        // the untouched document is accepted.
        XCTAssertNoThrow(try Self.assertNoUnknownFixtureFields(in: try fixtureData("conformance.json")))
    }
}

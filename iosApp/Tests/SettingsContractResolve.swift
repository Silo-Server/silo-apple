//
//  SettingsContractResolve.swift
//  SiloTests
//
//  Client-side settings resolution, mirroring the server's
//  `internal/settingsresolve` semantics: the definition's declared resolution
//  order decides which stored value wins, an identity absent from the context
//  drops the scopes that need it, and a policy constraint narrows the answer
//  without destroying what the user authored.
//
//  The Apple clients do not resolve settings in production — they write through
//  `/settings/values` and read effective values back from
//  `/settings/values/effective`, so the server stays the single authority. This
//  resolver exists for one reason: the cross-platform conformance fixture in
//  contracts/settings/v1/conformance.json names a Swift implementation as one
//  of the four that must agree, and four independently written resolvers
//  agreeing is what makes the fixture a drift gate rather than a tautology. It
//  therefore lives in the test target, and every behavioural choice in it is
//  pinned by `SettingsConformanceTests` — do not change one without the fixture
//  agreeing.
//
//  The Go implementation is internal/settingsresolve/resolve.go, the TypeScript
//  one web/src/lib/settingsResolve.ts, and the Kotlin one
//  shared/src/commonTest/kotlin/.../SettingsResolve.kt in silo-android. The four
//  are meant to be readable side by side.
//
//  Everything here is driven by the vendored manifest in
//  Fixtures/SettingsContract/manifest.json rather than by a hand-copied table of
//  keys and defaults. A table would pass the fixture while having drifted from
//  the contract, which is the one failure this file cannot be allowed to have.
//

import Foundation
@testable import Silo

// MARK: - Manifest

/// The vendored settings manifest, modelled only as far as resolution reads it.
///
/// Decoded leniently on purpose: this is a copy pinned by its revision, and the
/// server may add advisory metadata in a revision this build still understands.
/// The fixture is the document that gets the strict treatment, because a field
/// one platform reads and another skips means the platforms stopped running the
/// same cases.
///
/// Coded through ``SettingsWireCoding`` with explicit `CodingKeys` and no key
/// strategy, per the rule in SettingValueModels.swift: `default_value` for
/// `playback.subtitle_appearance` is an object whose own keys are camelCase
/// (`fontSize`), and a decoder carrying `.convertFromSnakeCase` is free to
/// rewrite dictionary keys.
struct SettingsContractManifest: Decodable {
    let apiVersion: Int
    let revision: Int
    let definitions: [SettingsContractDefinition]

    private let byKey: [String: SettingsContractDefinition]

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case revision
        case definitions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try container.decode(Int.self, forKey: .apiVersion)
        revision = try container.decode(Int.self, forKey: .revision)
        definitions = try container.decode([SettingsContractDefinition].self, forKey: .definitions)

        // A duplicate key would let the last definition silently win, which is
        // how one resolver ends up ranking against a definition another never
        // saw. Reported rather than absorbed.
        var index: [String: SettingsContractDefinition] = [:]
        for definition in definitions {
            guard index.updateValue(definition, forKey: definition.key) == nil else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "duplicate setting key \(definition.key)"
                    )
                )
            }
        }
        byKey = index
    }

    static func decode(from data: Data) throws -> SettingsContractManifest {
        try SettingsWireCoding.makeDecoder().decode(SettingsContractManifest.self, from: data)
    }

    func lookup(_ key: String) -> SettingsContractDefinition? {
        byKey[key]
    }
}

/// One setting's contract, as far as resolution needs it.
struct SettingsContractDefinition: Decodable {
    let key: String
    let persistence: String
    let resolutionOrder: [String]
    let valueSchema: SettingsContractValueSchema
    let defaultValue: SettingJSONValue
    let constrainedBy: SettingsContractConstraint?

    enum CodingKeys: String, CodingKey {
        case key
        case persistence
        case resolutionOrder = "resolution_order"
        case valueSchema = "value_schema"
        case defaultValue = "default_value"
        case constrainedBy = "constrained_by"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        persistence = try container.decode(String.self, forKey: .persistence)
        resolutionOrder = try container.decode([String].self, forKey: .resolutionOrder)
        valueSchema = try container.decode(SettingsContractValueSchema.self, forKey: .valueSchema)
        // Not `decodeIfPresent`: a definition whose default is JSON null — every
        // nullable language tag, and playback.max_bitrate_kbps — must decode to
        // `.null`, and an omitted default must fail rather than become one.
        defaultValue = try container.decode(SettingJSONValue.self, forKey: .defaultValue)
        constrainedBy = try container.decodeIfPresent(
            SettingsContractConstraint.self, forKey: .constrainedBy
        )
    }

    /// Server-stored settings. `client_local` ones never have server rows.
    var isRemote: Bool { persistence == "remote" }

    var isNumeric: Bool {
        valueSchema.type == "integer" || valueSchema.type == "number"
    }
}

struct SettingsContractValueSchema: Decodable {
    let type: String
    let ordered: Bool
    let values: [SettingsContractEnumMember]

    enum CodingKeys: String, CodingKey {
        case type
        case ordered
        case values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        ordered = try container.decodeIfPresent(Bool.self, forKey: .ordered) ?? false
        values = try container.decodeIfPresent([SettingsContractEnumMember].self, forKey: .values) ?? []
    }
}

/// One allowed enum member. Only `value` matters to resolution; the declared
/// order of the members is what gives an ordered enum a direction to cap in.
struct SettingsContractEnumMember: Decodable {
    let value: SettingJSONValue
}

/// Binds a definition to a policy input that narrows it at resolution time.
struct SettingsContractConstraint: Decodable, Equatable {
    let policyInput: String
    let constraint: SettingConstraintKind

    enum CodingKeys: String, CodingKey {
        case policyInput = "policy_input"
        case constraint
    }

    init(policyInput: String, constraint: SettingConstraintKind) {
        self.policyInput = policyInput
        self.constraint = constraint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        policyInput = try container.decode(String.self, forKey: .policyInput)
        constraint = try container.decode(SettingConstraintKind.self, forKey: .constraint)
    }
}

// MARK: - Resolution inputs and outputs

/// Where a resolved value came from, spelled as the wire spells it.
///
/// Deliberately a plain string rather than the app's `SettingSource`: the
/// fixture compares raw scope names, and going through a type with an `other`
/// case would turn a scope this runner mis-spells into a silent pass.
enum SettingsContractSource {
    static let `default` = "default"
    static let account = "account"
    static let profile = "profile"
    static let profileDevice = "profile_device"
    static let profileLibrary = "profile_library"
    static let profileSeries = "profile_series"
}

/// One stored row, as the server's values API reports it.
struct StoredSettingRow {
    let key: String
    let scope: String
    var profileId: String?
    var deviceId: String?
    var libraryId: Int?
    var seriesId: String?
    let value: SettingJSONValue
}

/// The identity a resolution happens against. An absent field drops its scopes.
struct SettingResolutionContext {
    var profileId: String?
    var deviceId: String?
    var libraryIds: [Int] = []
    var seriesIds: [String] = []
}

/// One resolved setting.
struct ResolvedSetting {
    let key: String
    let value: SettingJSONValue
    let source: String
    /// True when a policy constraint narrowed `value` away from what was stored.
    var constrained: Bool = false
    /// What the user authored — may be `.null`. Present only when constrained.
    var storedValue: SettingJSONValue?
    var constraintKind: SettingConstraintKind?
}

// MARK: - Resolution

/// Resolves the effective value for each requested key against stored rows.
///
/// Unknown and `client_local` keys are omitted rather than throwing, matching
/// the server: they have no server-resolved answer, so a newer client asking
/// for a setting this contract does not carry gets a short answer, not a
/// failure.
///
/// `constraintBindings` lets a caller — in practice the conformance runner —
/// attach a constraint to a key the shipped manifest does not bind, so
/// constraint kinds no definition currently carries stay testable. A key with
/// no entry uses the manifest's own `constrained_by`.
func resolveSettingValues(
    manifest: SettingsContractManifest,
    keys: [String],
    stored: [StoredSettingRow],
    context: SettingResolutionContext,
    constraints: [String: SettingJSONValue] = [:],
    constraintBindings: [String: SettingsContractConstraint] = [:]
) -> [ResolvedSetting] {
    var seen = Set<String>()
    return keys.compactMap { key in
        guard seen.insert(key).inserted else { return nil }
        guard let definition = manifest.lookup(key), definition.isRemote else { return nil }
        return resolveOne(
            definition: definition,
            stored: stored,
            context: context,
            constraints: constraints,
            bindingOverride: constraintBindings[key]
        )
    }
}

private func resolveOne(
    definition: SettingsContractDefinition,
    stored: [StoredSettingRow],
    context: SettingResolutionContext,
    constraints: [String: SettingJSONValue],
    bindingOverride: SettingsContractConstraint?
) -> ResolvedSetting {
    let candidates = stored.filter { $0.key == definition.key }

    var value = definition.defaultValue
    var source = SettingsContractSource.default
    for scope in definition.resolutionOrder {
        if scope == SettingsContractSource.default { break }
        guard let row = pickForScope(scope, candidates: candidates, context: context) else { continue }
        value = row.value
        source = scope
        break
    }

    return applyConstraint(
        definition: definition,
        resolved: ResolvedSetting(key: definition.key, value: value, source: source),
        constraints: constraints,
        bindingOverride: bindingOverride
    )
}

/// Returns the candidate row for one scope, mirroring the server: an identity
/// missing from the context matches nothing, and a tie between several content
/// rows breaks deterministically by (libraryId, seriesId).
///
/// The device case checks the context's device id is non-empty as well as
/// equal. Without that, a caller with no device identity — the anonymous
/// jellycompat seed — matches every row whose own device id is also empty, and
/// one device's settings leak to every client.
///
/// That non-empty guard is currently unpinned by the fixture, in every
/// language: `missing_device_identity_drops_device_scope` supplies no device id
/// in the context but every stored `profile_device` row it carries names "d1",
/// so plain equality already excludes them and removing the guard still passes.
/// It is kept because the Go, TypeScript, and Kotlin resolvers all have it and
/// a row with an empty device_id is reachable in production. Closing the gap
/// means a case upstream in contracts/settings/v1/conformance.json — a stored
/// `profile_device` row with an empty device_id against a context with none —
/// so that all four runners gain it at once; fixing it only here would defeat
/// the point.
private func pickForScope(
    _ scope: String,
    candidates: [StoredSettingRow],
    context: SettingResolutionContext
) -> StoredSettingRow? {
    let profileId = context.profileId ?? ""
    let deviceId = context.deviceId ?? ""

    let matches = candidates.filter { row in
        guard row.scope == scope else { return false }
        switch scope {
        case SettingsContractSource.account:
            return true
        case SettingsContractSource.profile:
            return (row.profileId ?? "") == profileId
        case SettingsContractSource.profileDevice:
            return (row.profileId ?? "") == profileId
                && (row.deviceId ?? "") == deviceId
                && !deviceId.isEmpty
        case SettingsContractSource.profileLibrary:
            return (row.profileId ?? "") == profileId
                && context.libraryIds.contains(row.libraryId ?? 0)
        case SettingsContractSource.profileSeries:
            return (row.profileId ?? "") == profileId
                && context.seriesIds.contains(row.seriesId ?? "")
        default:
            return false
        }
    }

    guard matches.count > 1 else { return matches.first }
    // Deterministic rather than arbitrary: a batch spanning several libraries
    // or series has no single right answer and the caller is expected to
    // resolve per item, but two identical requests must not disagree.
    return matches.sorted { lhs, rhs in
        let leftLibrary = lhs.libraryId ?? 0
        let rightLibrary = rhs.libraryId ?? 0
        if leftLibrary != rightLibrary { return leftLibrary < rightLibrary }
        return (lhs.seriesId ?? "") < (rhs.seriesId ?? "")
    }.first
}

/// Narrows an effective value to what policy permits without destroying the
/// authored one: a preference capped today must take effect the day the cap
/// lifts, so the stored value is reported alongside the cap rather than
/// replaced.
private func applyConstraint(
    definition: SettingsContractDefinition,
    resolved: ResolvedSetting,
    constraints: [String: SettingJSONValue],
    bindingOverride: SettingsContractConstraint?
) -> ResolvedSetting {
    guard let binding = bindingOverride ?? definition.constrainedBy else { return resolved }
    guard let limit = constraints[binding.policyInput] else { return resolved }
    guard let narrowed = narrowValue(
        definition: definition,
        kind: binding.constraint,
        value: resolved.value,
        limit: limit
    ) else {
        return resolved
    }

    return ResolvedSetting(
        key: resolved.key,
        value: narrowed,
        source: resolved.source,
        constrained: true,
        storedValue: resolved.value,
        constraintKind: binding.constraint
    )
}

/// Applies one constraint kind, returning the narrowed value or nil when the
/// value stands as authored.
private func narrowValue(
    definition: SettingsContractDefinition,
    kind: SettingConstraintKind,
    value: SettingJSONValue,
    limit: SettingJSONValue
) -> SettingJSONValue? {
    switch kind {
    case .locked:
        // The policy value replaces the user's outright. An already-equal value
        // is not a narrowing, so clients do not tell the user their own choice
        // was overridden.
        return settingJSONEquivalent(value, limit) ? nil : limit

    case .ceiling:
        // null on a nullable numeric means "no cap of my own" — unbounded
        // above, which is exactly what a ceiling exists to bring down. It has
        // no numeric rank, so a plain comparison reports 0 and the one value
        // that most needs capping would slip past.
        if value.isNull && definition.isNumeric { return limit }
        return compareSettingValues(definition: definition, value, limit) <= 0 ? nil : limit

    case .floor:
        // The mirror rule: unbounded above already satisfies any floor.
        if value.isNull && definition.isNumeric { return nil }
        return compareSettingValues(definition: definition, value, limit) >= 0 ? nil : limit

    case .allowlist:
        guard let allowed = limit.arrayValue, let fallback = allowed.first else { return nil }
        if allowed.contains(where: { settingJSONEquivalent($0, value) }) { return nil }
        // Falling back to the first allowed member rather than the definition
        // default: the default may itself be outside the allowlist, and an
        // effective value the policy forbids is the one thing this must never
        // return.
        return fallback

    case .other:
        // A constraint kind this build has never heard of narrows nothing. The
        // runner rejects one in a fixture binding; a future manifest carrying
        // one reaches an older client, which must not invent a narrowing.
        return nil
    }
}

/// Ranks two values through the definition's own schema: numbers numerically,
/// ordered enums by declared member position. Anything unrankable compares
/// equal, so an unrecognized value is never silently narrowed — validation is a
/// separate concern and has already rejected it by the time a constraint
/// applies.
private func compareSettingValues(
    definition: SettingsContractDefinition,
    _ lhs: SettingJSONValue,
    _ rhs: SettingJSONValue
) -> Int {
    if definition.isNumeric {
        guard let left = lhs.doubleValue, let right = rhs.doubleValue else { return 0 }
        if left < right { return -1 }
        return left > right ? 1 : 0
    }
    if definition.valueSchema.type == "enum" && definition.valueSchema.ordered {
        let members = definition.valueSchema.values
        guard
            let left = members.firstIndex(where: { settingJSONEquivalent($0.value, lhs) }),
            let right = members.firstIndex(where: { settingJSONEquivalent($0.value, rhs) })
        else {
            return 0
        }
        if left < right { return -1 }
        return left > right ? 1 : 0
    }
    return 0
}

/// Structural equality over setting values, ignoring object key order and
/// numeric spelling.
///
/// `SettingJSONValue` is already `Equatable`, but its synthesized conformance
/// separates `.int(8000)` from `.double(8000.0)` — the same JSON number, and
/// the fixture is free to author either. The Go runner decodes to `any` before
/// comparing, which collapses both to a float64; this does the same by hand.
func settingJSONEquivalent(_ lhs: SettingJSONValue, _ rhs: SettingJSONValue) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null):
        return true
    case (.bool(let left), .bool(let right)):
        return left == right
    case (.string(let left), .string(let right)):
        return left == right
    case (.array(let left), .array(let right)):
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { settingJSONEquivalent($0, $1) }
    case (.object(let left), .object(let right)):
        guard left.count == right.count else { return false }
        return left.allSatisfy { key, value in
            guard let counterpart = right[key] else { return false }
            return settingJSONEquivalent(value, counterpart)
        }
    default:
        // Numbers only: `doubleValue` is nil for every non-numeric case, so a
        // bool never compares equal to 1.
        guard let left = lhs.doubleValue, let right = rhs.doubleValue else { return false }
        return left == right
    }
}

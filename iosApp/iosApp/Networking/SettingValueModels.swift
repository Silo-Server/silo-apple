//
//  SettingValueModels.swift
//  Silo (iOS + tvOS + macOS)
//
//  Wire types for the canonical settings API — the typed
//  `/settings/values/*` routes:
//
//    GET    /api/v2/settings/values/effective            — batched resolution
//    PUT    /api/v2/settings/values/{key}                — write one scope
//    PUT    /api/v2/settings/values/nav.shortcuts/item   — add or remove a shortcut
//    DELETE /api/v2/settings/values/{key}                — clear one scope
//
//  The v2 capability document lives in APIv2SettingsModels.swift.
//
//  These types are deliberately *not* the legacy `/settings/{key}` registry types in
//  SubtitleAppearance.swift: values here are typed JSON rather than strings,
//  every value names the scope it lives at, and a key that is not in the
//  manifest cannot be expressed because `SettingKey` is generated from it.
//
//  Coding note — read before adding a call site. Every type here spells its
//  wire field names out in explicit `CodingKeys` and MUST be coded through
//  ``SettingsWireCoding``, a coder carrying no key strategy. Passing one of
//  these types to `HTTPClient.get`/`put` instead is a silent-data-loss bug,
//  not a style preference (SettingValuesAPITests pins the failure).
//
//  Why the models are built this way: setting values are opaque JSON authored
//  by the contract, and their object keys must survive byte-for-byte —
//  `playback.subtitle_appearance` is camelCase on the wire (`fontSize`), other
//  schemas use snake_case. Foundation's key strategy happens not to reach into
//  `[String: …]` payloads today, but that is an implementation detail rather
//  than a documented guarantee, and a value whose keys get rewritten is
//  corrupted silently and permanently in the user's stored settings.
//
//  Why that forces the rest: with no strategy, the envelope's snake_case field
//  names have to be written out by hand. That inverts HTTPClient's convention
//  (camelCase properties, CodingKeys only for genuinely odd names), and the two
//  do not mix — `.convertFromSnakeCase` camel-cases an incoming key *before*
//  matching it, so `profile_id` looks for a CodingKey named `profileId`, misses
//  the `"profile_id"` one, and decodes as nil without throwing. Hence the rule
//  at the top. Nothing here changes the app-wide convention: the generated
//  bindings and every other model keep it.
//

import Foundation

// MARK: - Coding boundary

/// JSON coders for the canonical settings API.
///
/// No key strategy in either direction: see the file header. Use these for
/// anything that touches a setting *value*, including a caller decoding an
/// object-valued setting into its own model — that keeps the value's keys out
/// of reach of any strategy the app's shared coders carry now or later.
enum SettingsWireCoding {
    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Stable ordering keeps a re-encoded value byte-comparable, which is
        // what lets a caller diff "what I sent" against "what came back", and
        // makes a retry of the same value send the same bytes.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

// MARK: - Values

/// One setting value, exactly as the contract defines it.
///
/// Settings are heterogeneous — bool, int, double, string, object, array, or
/// null — so the client holds the JSON shape rather than pretending every
/// value is a string the way the legacy registry did.
enum SettingJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([SettingJSONValue])
    case object([String: SettingJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SettingJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SettingJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension SettingJSONValue {
    /// Structural equality for contract values, treating the two Swift
    /// representations of the same JSON number (`1` and `1.0`) as equivalent.
    /// Other JSON types remain distinct, and arrays/objects compare
    /// recursively so a numeric spelling nested inside a value behaves the
    /// same way as one at the top level.
    func isSemanticallyEquivalent(to other: SettingJSONValue) -> Bool {
        switch (self, other) {
        case (.null, .null):
            return true
        case (.bool(let left), .bool(let right)):
            return left == right
        case (.int(let left), .int(let right)):
            return left == right
        case (.double(let left), .double(let right)):
            return left == right
        case (.int(let left), .double(let right)):
            return Int(exactly: right) == left
        case (.double(let left), .int(let right)):
            return Int(exactly: left) == right
        case (.string(let left), .string(let right)):
            return left == right
        case (.array(let left), .array(let right)):
            guard left.count == right.count else { return false }
            return zip(left, right).allSatisfy { lhs, rhs in
                lhs.isSemanticallyEquivalent(to: rhs)
            }
        case (.object(let left), .object(let right)):
            guard left.count == right.count else { return false }
            return left.allSatisfy { key, value in
                guard let counterpart = right[key] else { return false }
                return value.isSemanticallyEquivalent(to: counterpart)
            }
        default:
            return false
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        // A whole-number double (`1` re-serialized as `1.0` by some
        // intermediary) is still the integer the contract declared.
        case .double(let value) where value == value.rounded(): return Int(exactly: value.rounded())
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [SettingJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: SettingJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Decode an object- or array-valued setting into a caller model.
    ///
    /// Goes through ``SettingsWireCoding`` so the value's own key casing is
    /// preserved — decoding `playback.subtitle_appearance` with the app's
    /// shared snake_case decoder would look for `font_size`.
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try SettingsWireCoding.makeEncoder().encode(self)
        return try SettingsWireCoding.makeDecoder().decode(T.self, from: data)
    }

    /// Build a value from a caller model, without key rewriting.
    static func encoding<T: Encodable>(_ value: T) throws -> SettingJSONValue {
        let data = try SettingsWireCoding.makeEncoder().encode(value)
        return try SettingsWireCoding.makeDecoder().decode(SettingJSONValue.self, from: data)
    }
}

/// Literal conveniences so a call site can write `putValue(…, value: "2160p")`
/// rather than `.string("2160p")`.
///
/// Deliberately *not* `ExpressibleByNilLiteral`, even though `.null` is a real
/// case: it makes `nil` ambiguous wherever a `SettingJSONValue?` is in play.
/// `storedValue = present ? try decode(…) : nil` type-checks with both branches
/// as `SettingJSONValue`, turning the absent branch into `.some(.null)` — which
/// silently erases exactly the distinction (field absent vs. authored JSON
/// null) that the effective-value model exists to preserve. Write `.null` when
/// that is what you mean.
extension SettingJSONValue: ExpressibleByBooleanLiteral,
                            ExpressibleByIntegerLiteral,
                            ExpressibleByFloatLiteral,
                            ExpressibleByStringLiteral,
                            ExpressibleByArrayLiteral,
                            ExpressibleByDictionaryLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: SettingJSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, SettingJSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Scopes

/// The scopes a value can be stored at.
///
/// `other` exists because the settings API is additive: a newer server may resolve a
/// value at a scope this build has never heard of, and one unfamiliar row must
/// not fail the whole batch.
///
/// Coded by hand rather than by synthesis: these are open enums with an
/// associated value, and Swift's derived `Codable` for such an enum emits a
/// nested payload (`{"other":{"_0":"…"}}`) instead of the bare string the wire
/// format uses.
enum SettingScope: RawRepresentable, Hashable, Sendable {
    case account
    case profile
    case profileClient
    case profileDevice
    case profileLibrary
    case profileSeries
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "account": self = .account
        case "profile": self = .profile
        case "profile_client": self = .profileClient
        case "profile_device": self = .profileDevice
        case "profile_library": self = .profileLibrary
        case "profile_series": self = .profileSeries
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .account: return "account"
        case .profile: return "profile"
        case .profileClient: return "profile_client"
        case .profileDevice: return "profile_device"
        case .profileLibrary: return "profile_library"
        case .profileSeries: return "profile_series"
        case .other(let raw): return raw
        }
    }
}

/// Where a resolved value came from: the scope holding it, or the contract
/// default when nothing was stored anywhere.
enum SettingSource: RawRepresentable, Hashable, Sendable {
    case scope(SettingScope)
    case contractDefault

    init(rawValue: String) {
        self = rawValue == "default" ? .contractDefault : .scope(SettingScope(rawValue: rawValue))
    }

    var rawValue: String {
        switch self {
        case .scope(let scope): return scope.rawValue
        case .contractDefault: return "default"
        }
    }
}

/// How policy narrowed a value at resolution time.
enum SettingConstraintKind: RawRepresentable, Hashable, Sendable {
    case ceiling
    case floor
    case allowlist
    case locked
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "ceiling": self = .ceiling
        case "floor": self = .floor
        case "allowlist": self = .allowlist
        case "locked": self = .locked
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .ceiling: return "ceiling"
        case .floor: return "floor"
        case .allowlist: return "allowlist"
        case .locked: return "locked"
        case .other(let raw): return raw
        }
    }
}

// Coding for the three open enums above: one bare wire string in, one out.
//
// Written out per type rather than derived. Synthesis is wrong here — a
// derived `Codable` for an enum with an associated value emits a nested
// payload (`{"other":{"_0":"…"}}`) instead of the bare string the wire uses —
// and a blanket `extension RawRepresentable where RawValue == String: Codable`
// would be worse still, silently replacing the synthesized coding of every
// string-backed enum in the app.
//
// The point of each is the same: an unfamiliar member decodes to `.other`
// rather than throwing, which is what keeps a newer server's row from taking a
// whole batched resolution down with it.

extension SettingScope: Codable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension SettingSource: Codable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension SettingConstraintKind: Codable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A scope plus the ids that scope needs, as one value.
///
/// Modelled as an enum rather than a struct of optionals so an identity that
/// the server would reject with 400 — `profile_library` with no library id —
/// cannot be built in the first place. The profile and device parts are never
/// carried here: the server takes those from the session headers so one
/// profile cannot write another's settings by naming it in the query.
enum SettingScopeIdentity: Hashable, Sendable {
    case account
    case profile
    case profileClient
    case profileDevice
    case profileLibrary(libraryId: Int)
    case profileSeries(seriesId: String)

    var scope: SettingScope {
        switch self {
        case .account: return .account
        case .profile: return .profile
        case .profileClient: return .profileClient
        case .profileDevice: return .profileDevice
        case .profileLibrary: return .profileLibrary
        case .profileSeries: return .profileSeries
        }
    }

    /// The query the scope travels in. Scope rides the query string rather
    /// than the path so one route serves every scope.
    var queryItems: [String: String] {
        var query = ["scope": scope.rawValue]
        switch self {
        case .profileLibrary(let libraryId):
            query["library_id"] = String(libraryId)
        case .profileSeries(let seriesId):
            query["series_id"] = seriesId
        case .account, .profile, .profileClient, .profileDevice:
            break
        }
        return query
    }
}

// MARK: - Responses

/// One explicitly stored value, as returned by a write (`SettingValue` in
/// the v2 contract).
struct StoredSettingValue: Decodable, Hashable, Sendable {
    let key: String
    let scope: SettingScope
    let profileId: String?
    let clientFamily: String?
    let deviceId: String?
    /// The library of a `profile_library` row, as the wire's opaque string id.
    let libraryId: String?
    let seriesId: String?
    let value: SettingJSONValue
    /// Increments on every write to this row, including a repeated write of
    /// the same value.
    let revision: Int
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case key
        case scope
        case profileId = "profile_id"
        case clientFamily = "client_family"
        case deviceId = "device_id"
        case libraryId = "library_id"
        case seriesId = "series_id"
        case value
        case revision
        case updatedAt = "updated_at"
    }

    var settingKey: SettingKey? {
        SettingKey(rawValue: key)
    }
}

/// One resolved value plus where it came from (`EffectiveSettingValue` in
/// the v2 contract). Members this client does not use, such as
/// `definition_revision` and `source_context`, are not decoded.
struct EffectiveSettingValue: Decodable, Hashable, Sendable {
    let key: String
    let value: SettingJSONValue
    let source: SettingSource

    /// The value the user actually authored, present only when policy
    /// narrowed the answer. Reported rather than discarded so a client can say
    /// "your choice is capped" instead of silently showing the cap.
    ///
    /// `nil` means the field was absent; `.null` means the authored value was
    /// JSON null. `decodeIfPresent` would collapse those two, so this decodes
    /// through an explicit `contains` check.
    let storedValue: SettingJSONValue?
    let constrained: Bool
    let constraintKind: SettingConstraintKind?
    /// Advisory picker values for an open setting. These never constrain
    /// writes; they augment the generated contract floor.
    let suggestedValues: [String]?

    /// The scope holding the value, so a reset can target exactly that row.
    /// Absent for a contract default.
    let scope: SettingScope?
    let profileId: String?
    let clientFamily: String?
    let deviceId: String?
    /// The library of the winning row. The wire sends an opaque string id;
    /// the scope identity addresses libraries by number, so a non-numeric id
    /// decodes as nil and that row cannot be targeted by a reset.
    let libraryId: Int?
    let seriesId: String?

    enum CodingKeys: String, CodingKey {
        case key
        case value
        case source
        case storedValue = "stored_value"
        case constrained
        case constraintKind = "constraint_kind"
        case suggestedValues = "suggested_values"
        case scope
        case profileId = "profile_id"
        case clientFamily = "client_family"
        case deviceId = "device_id"
        case libraryId = "library_id"
        case seriesId = "series_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        value = try container.decode(SettingJSONValue.self, forKey: .value)
        source = try container.decode(SettingSource.self, forKey: .source)
        if container.contains(.storedValue) {
            storedValue = try container.decode(SettingJSONValue.self, forKey: .storedValue)
        } else {
            storedValue = SettingJSONValue?.none
        }
        constrained = try container.decodeIfPresent(Bool.self, forKey: .constrained) ?? false
        constraintKind = try container.decodeIfPresent(SettingConstraintKind.self, forKey: .constraintKind)
        suggestedValues = try container.decodeIfPresent([String].self, forKey: .suggestedValues)
        scope = try container.decodeIfPresent(SettingScope.self, forKey: .scope)
        profileId = try container.decodeIfPresent(String.self, forKey: .profileId)
        clientFamily = try container.decodeIfPresent(String.self, forKey: .clientFamily)
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        libraryId = try container.decodeIfPresent(String.self, forKey: .libraryId).flatMap { Int($0) }
        seriesId = try container.decodeIfPresent(String.self, forKey: .seriesId)
    }

    init(
        key: String,
        value: SettingJSONValue,
        source: SettingSource,
        storedValue: SettingJSONValue? = nil,
        constrained: Bool = false,
        constraintKind: SettingConstraintKind? = nil,
        suggestedValues: [String]? = nil,
        scope: SettingScope? = nil,
        profileId: String? = nil,
        clientFamily: String? = nil,
        deviceId: String? = nil,
        libraryId: Int? = nil,
        seriesId: String? = nil
    ) {
        self.key = key
        self.value = value
        self.source = source
        self.storedValue = storedValue
        self.constrained = constrained
        self.constraintKind = constraintKind
        self.suggestedValues = suggestedValues
        self.scope = scope
        self.profileId = profileId
        self.clientFamily = clientFamily
        self.deviceId = deviceId
        self.libraryId = libraryId
        self.seriesId = seriesId
    }

    var settingKey: SettingKey? {
        SettingKey(rawValue: key)
    }

    /// The identity a reset should target, or nil when the value is a
    /// contract default and there is nothing to clear.
    var storedAt: SettingScopeIdentity? {
        guard let scope else { return nil }
        switch scope {
        case .account: return .account
        case .profile: return .profile
        case .profileClient: return .profileClient
        case .profileDevice: return .profileDevice
        case .profileLibrary: return libraryId.map { .profileLibrary(libraryId: $0) }
        case .profileSeries: return seriesId.map { .profileSeries(seriesId: $0) }
        // A scope this build does not know cannot be addressed for a reset.
        case .other: return nil
        }
    }
}

/// A batched resolution plus the contract revision it was computed at
/// (`EffectiveSettingCollection` in the v2 contract). The resolver is
/// bounded, so the optional `page` member is never present and is not read.
struct EffectiveSettingValuesResponse: Decodable, Hashable, Sendable {
    let settings: [EffectiveSettingValue]
    /// The settings manifest revision, an integer here (unlike the opaque
    /// capability document revision).
    let revision: Int

    enum CodingKeys: String, CodingKey {
        case settings = "items"
        case revision
    }

    /// Resolved values addressed by generated key. Keys this build does not
    /// know (a newer server's contract) are dropped here but stay in
    /// ``settings``.
    var byKey: [SettingKey: EffectiveSettingValue] {
        var map: [SettingKey: EffectiveSettingValue] = [:]
        for setting in settings {
            if let key = setting.settingKey {
                map[key] = setting
            }
        }
        return map
    }

    func value(for key: SettingKey) -> EffectiveSettingValue? {
        settings.first { $0.key == key.rawValue }
    }

    /// True when this build was generated from a newer manifest than the
    /// server used for this resolution. Applying the response would silently
    /// substitute missing rows with this client's newer contract defaults.
    var contractIsAheadOfServer: Bool {
        SettingKey.revision > revision
    }
}

/// The result of probing the canonical settings contract.
///
/// A v1-only server has no `/api/v2` settings routes at all, while one on an
/// older manifest revision lacks definitions this build exposes. Both are
/// actionable states: the UI must say "this server needs an upgrade" rather
/// than render an empty or incomplete settings screen, so they are a typed
/// case here instead of dissolving into the generic error path.
enum SettingsCapabilitiesResult: Equatable, Sendable {
    case available(APIv2SettingsContractCapabilities)
    case serverUpgradeRequired
    /// The server answered, but settings are not available to this principal
    /// (`disabled`, `not_configured`, not `allowed`, or a state this build
    /// does not know). An answer, not an incompatibility: nothing is known
    /// about the server's version.
    case unavailable
    case failed(SettingsAPIError)

    var capabilities: APIv2SettingsContractCapabilities? {
        if case .available(let capabilities) = self { return capabilities }
        return nil
    }
}

// MARK: - Request body

/// `PUT /api/v2/settings/values/{key}` takes `{"value": …}` and nothing else:
/// the body schema is closed, so a `mutation_id` member is a 422.
struct SettingValueWriteRequest: Encodable, Sendable {
    let value: SettingJSONValue

    enum CodingKeys: String, CodingKey {
        case value
    }
}

// MARK: - Errors

/// The failure modes of the canonical settings API, named rather than left as
/// a status code so callers can act on them.
enum SettingsAPIError: Error, Equatable, Sendable {
    /// The server does not serve the canonical settings routes at all.
    case serverUpgradeRequired
    /// A profile-scoped call was made with no profile selected. Caught before
    /// the request so the UI gets this instead of the server's generic 400.
    case profileRequired
    /// The key is not in the server's contract, or the server never stores
    /// it (a device-local key). v2 answers both as a 422 at `path.key`.
    case unknownSetting(key: String)
    /// The contract does not allow this key at this scope.
    case scopeNotAllowed(key: String, scope: SettingScope)
    /// The value failed the contract's schema.
    case invalidValue(message: String)
    /// Nothing is stored at the addressed scope.
    case noValueAtScope
    /// The server, account or profile that captured the request is no longer
    /// current. The request was refused before it left, or its answer was
    /// discarded; nothing was applied for the replacement owner.
    case ownerChanged
    /// Any other HTTP failure, with the problem type when there was one.
    case server(status: Int, code: String?, message: String?)
    /// The request never reached the server, or the response did not parse.
    case transport(description: String)

    /// Maps an error from the settings calls onto the contract's vocabulary.
    ///
    /// Every settings route is `/api/v2`, so a failure arrives as an
    /// `APIv2Error`: a v1-only server as `serverUpdateRequired` (the probe
    /// verdict or the legacy listener's plain 404), and a refused request as
    /// a problem document whose `errors` name the rejected member.
    static func from(_ error: Error, key: String? = nil, scope: SettingScope? = nil) -> SettingsAPIError {
        if let settingsError = error as? SettingsAPIError {
            return settingsError
        }
        if let v2Error = error as? APIv2Error {
            return from(v2Error, key: key, scope: scope)
        }
        guard let httpError = error as? HTTPError else {
            return .transport(description: String(describing: error))
        }
        switch httpError {
        case .requestIdentityChanged, .authorityChanged:
            return .ownerChanged
        case .http(let status, _):
            return .server(status: status, code: nil, message: httpError.errorDescription)
        default:
            return .transport(description: httpError.description)
        }
    }

    private static func from(_ error: APIv2Error, key: String?, scope: SettingScope?) -> SettingsAPIError {
        switch error {
        case .serverUpdateRequired:
            return .serverUpgradeRequired
        case .problem(let problem):
            for rejected in problem.status == 422 ? problem.errors ?? [] : [] {
                switch rejected.location {
                case "path.key", "query.keys":
                    return .unknownSetting(key: key ?? "")
                case "query.scope":
                    return .scopeNotAllowed(key: key ?? "", scope: scope ?? .other(""))
                case "body.value", "body.item":
                    return .invalidValue(message: rejected.detail)
                default:
                    continue
                }
            }
            return .server(
                status: problem.status,
                code: problem.identifier,
                message: error.errorDescription
            )
        case .httpStatus(let status):
            return .server(status: status, code: nil, message: nil)
        default:
            return .transport(description: error.errorDescription ?? String(describing: error))
        }
    }
}

// MARK: - Write failures

/// What a failed settings value write means for the change it carried.
///
/// Every value write is `natural_idempotent`: it names the desired state of
/// one row, so sending the same value again converges on the same row. Owner
/// decision D4 therefore allows exactly one kind of replay. Each surface keeps
/// one pending change per key (a newer local value replaces an older one) and
/// retries only that latest value, on a bounded backoff, while the owner that
/// captured it is still current. When the bound runs out the surface holds
/// that one key and offers "Discard held change"; a held change is not sent
/// again until the user asks. No request carries a mutation id.
enum SettingWriteFailure: Equatable, Sendable {
    /// The write may have been lost in flight, or the server refused it for
    /// a reason that can pass (5xx, 408, 429, a 409 compare-and-set conflict,
    /// or a 401 that outlived the token refresh). Retry the latest value
    /// within the bound, then hold it.
    case retry
    /// A definite answer that sending the same value again cannot change:
    /// release the change, surface the error once and log the cause.
    case release
    /// The owner that captured the change is gone. The change still belongs
    /// to that owner and is never sent on behalf of another.
    case ownerChanged
    /// The write was not sent: no profile is selected, or the server cannot
    /// serve settings at all. Keep the change, but without a timer: only a
    /// user action or a reconnect can change the condition.
    case waitForCondition
}

extension SettingsAPIError {
    var writeFailure: SettingWriteFailure {
        switch self {
        case .transport:
            return .retry
        case .server(let status, _, _):
            return status >= 500 || [401, 408, 409, 429].contains(status) ? .retry : .release
        case .ownerChanged:
            return .ownerChanged
        case .profileRequired, .serverUpgradeRequired:
            return .waitForCondition
        case .unknownSetting, .scopeNotAllowed, .invalidValue, .noValueAtScope:
            return .release
        }
    }
}

/// What every settings screen says about a held change, next to "Try Again"
/// and "Discard Held Change".
enum HeldSettingChange {
    static let message =
        "A change couldn't be saved to the server. It stays on this device until you try again or discard it."

    /// Shown after "Discard Held Change" could not reach the server to find
    /// the value to go back to.
    static let discardNeedsServerMessage =
        "Couldn't reach the server to discard this change. It stays on this device until the server can be reached."
}

/// The bounded backoff D4 allows for one key's latest value. After
/// `maximumAutomaticRetries` failed retries the key is held.
struct SettingWriteRetryPolicy: Sendable {
    var maximumAutomaticRetries: Int = 5
    var base: Duration = .seconds(1)
    var maximum: Duration = .seconds(60)

    static let `default` = SettingWriteRetryPolicy()

    /// For a write the user is watching ("Saving…"): three retries over about
    /// seven seconds, then the key is held.
    static let interactive = SettingWriteRetryPolicy(
        maximumAutomaticRetries: 3,
        base: .seconds(1),
        maximum: .seconds(4)
    )

    func delay(forAttempt attempt: Int) -> Duration {
        let shift = min(max(attempt - 1, 0), 6)
        return min(base * (1 << shift), maximum)
    }
}

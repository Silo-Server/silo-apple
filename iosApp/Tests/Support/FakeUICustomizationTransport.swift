import Foundation
@testable import Silo

/// Scriptable in-memory `UICustomizationTransport` for store tests.
///
/// **Reads.** A fixed `effectiveResponse`, when set, is returned unchanged.
/// Otherwise each requested key resolves, in request order, to its
/// highest-precedence stored row (`profileDevice`, then `profileClient`, then
/// `profile`). A customization key with no row gets its contract default
/// (`nav.primary_menu` null, empty `nav.shortcuts`, standard card
/// presentation); any other key is omitted.
///
/// **Writes.** `putValue` stores the value at its scope unless the fake was
/// built with `persistsPuts: false`. `putShortcutItem` edits the `profile`
/// shortcut row: it removes every item with the same id, then appends the
/// item when `present`. `deleteValue` removes the row at its scope, or throws
/// `SettingsAPIError.noValueAtScope` when there is none.
///
/// **Call order.** Every transport call except `contractCapabilities`
/// 1) records itself in `history` and wakes "started" waiters, 2) parks on a
/// gate armed with `hold` for it, 3) takes the first matching `fail` rule,
/// 4) applies the write or throws, and 5) records a `Step` and wakes
/// "completed" waiters. Failed calls count as completed. Step 2 is the only
/// suspension point, and only when a gate matches, so a test that waits for a
/// call to start cannot change the failure rules before that call decides
/// its outcome.
actor FakeUICustomizationTransport: UICustomizationTransport {
    // MARK: Server model

    struct Row: Sendable {
        let key: SettingKey
        let scope: SettingScope
        let value: SettingJSONValue

        init(_ key: SettingKey, _ scope: SettingScope, _ value: SettingJSONValue) {
            self.key = key
            self.scope = scope
            self.value = value
        }

        init<T: Encodable>(_ key: SettingKey, _ scope: SettingScope, encoding value: T) throws {
            self.init(key, scope, try SettingJSONValue.encoding(value))
        }
    }

    // MARK: Failure scripting

    enum Target: Equatable, Sendable {
        case reads
        /// A read whose key list equals `keys`.
        case read(keys: [SettingKey])
        case puts
        case put(SettingKey)
        case shortcuts
        case shortcut(id: String)
        case deletes
        case delete(SettingKey)

        func matches(_ call: Call) -> Bool {
            switch (self, call) {
            case (.reads, .read), (.puts, .put), (.shortcuts, .shortcut), (.deletes, .delete):
                return true
            case (.read(let keys), .read(let callKeys, _)):
                return keys == callKeys
            case (.put(let key), .put(let callKey, _, _, _)):
                return key == callKey
            case (.shortcut(let id), .shortcut(let item, _, _)):
                return id == item.id
            case (.delete(let key), .delete(let callKey, _, _)):
                return key == callKey
            default:
                return false
            }
        }
    }

    enum Failure: Sendable {
        case url(URLError.Code)
        case api(SettingsAPIError)

        static let offline: Failure = .url(.notConnectedToInternet)

        var error: Error {
            switch self {
            case .url(let code): return URLError(code)
            case .api(let error): return error
            }
        }
    }

    // MARK: Inspection

    enum Kind: Hashable, Sendable {
        case read
        case put
        case shortcut
        case delete
        /// Puts, shortcut operations and deletes together.
        case write
    }

    enum Call: Equatable, Sendable {
        case read(keys: [SettingKey], identity: HTTPRequestIdentity)
        case put(key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue, identity: HTTPRequestIdentity)
        case shortcut(item: PrimaryMenuItem, present: Bool, identity: HTTPRequestIdentity)
        case delete(key: SettingKey, scope: SettingScopeIdentity, identity: HTTPRequestIdentity)

        var kind: Kind {
            switch self {
            case .read: return .read
            case .put: return .put
            case .shortcut: return .shortcut
            case .delete: return .delete
            }
        }

        /// The setting a write changes: `nav.shortcuts` for a shortcut
        /// operation, nil for a read.
        var key: SettingKey? {
            switch self {
            case .read: return nil
            case .put(let key, _, _, _), .delete(let key, _, _): return key
            case .shortcut: return .navShortcuts
            }
        }

        /// The keys a read requested.
        var keys: [SettingKey]? {
            guard case .read(let keys, _) = self else { return nil }
            return keys
        }

        var scope: SettingScopeIdentity? {
            switch self {
            case .put(_, let scope, _, _), .delete(_, let scope, _): return scope
            case .read, .shortcut: return nil
            }
        }

        var value: SettingJSONValue? {
            guard case .put(_, _, let value, _) = self else { return nil }
            return value
        }

        var item: PrimaryMenuItem? {
            guard case .shortcut(let item, _, _) = self else { return nil }
            return item
        }

        var present: Bool? {
            guard case .shortcut(_, let present, _) = self else { return nil }
            return present
        }

        var identity: HTTPRequestIdentity {
            switch self {
            case .read(_, let identity),
                 .put(_, _, _, let identity),
                 .shortcut(_, _, let identity),
                 .delete(_, _, let identity):
                return identity
            }
        }
    }

    enum Completion: Equatable, Sendable {
        case succeeded
        case failed
    }

    enum Step: Equatable, Sendable {
        case read(Completion)
        case put(SettingKey, Completion)
        case shortcut(id: String, present: Bool, Completion)
        case delete(SettingKey, SettingScope, Completion)
    }

    static let emptyResponse = EffectiveSettingValuesResponse(
        settings: [],
        revision: SettingKey.revision
    )

    static func capabilities(
        batchedEffective: Bool = true,
        atomicShortcuts: Bool = true,
        clientFamilies: [String] = ["tv", "mobile", "tablet", "desktop", "web"]
    ) -> APIv2SettingsContractCapabilities {
        APIv2SettingsContractCapabilities(
            revision: "test",
            state: "available",
            allowed: true,
            manifestRevision: SettingKey.revision,
            clientFamilies: clientFamilies,
            supportsBatchedEffective: batchedEffective,
            supportsAtomicShortcuts: atomicShortcuts
        )
    }

    /// Calls in the order they started.
    private(set) var history: [Call] = []
    private(set) var capabilityChecks = 0
    private(set) var maxConcurrentWrites = 0

    private struct Slot: Hashable {
        let key: SettingKey
        let scope: SettingScope
    }

    private struct FailureRule {
        let target: Target
        let failure: Failure
        var remaining: Int?
    }

    private struct Gate {
        let id: Int
        let target: Target
        var arrived = false
        var parked: CheckedContinuation<Void, Never>?
    }

    private enum Phase {
        case started
        case completed
    }

    private struct Waiter {
        let phase: Phase
        let kind: Kind
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private static let precedence: [SettingScope] = [.profileDevice, .profileClient, .profile]

    private var capabilitiesResult: SettingsCapabilitiesResult
    private var rows: [Slot: SettingJSONValue] = [:]
    private var effectiveResponse: EffectiveSettingValuesResponse?
    private let persistsPuts: Bool
    private var failureRules: [FailureRule] = []
    private var gates: [Gate] = []
    private var nextGateID = 0
    private var completedSteps: [Step] = []
    private var startedCounts: [Kind: Int] = [:]
    private var completedCounts: [Kind: Int] = [:]
    private var waiters: [Waiter] = []
    private var inFlightWrites = 0

    init(
        capabilities: SettingsCapabilitiesResult = .available(FakeUICustomizationTransport.capabilities()),
        rows: [Row] = [],
        effectiveResponse: EffectiveSettingValuesResponse? = nil,
        persistsPuts: Bool = true
    ) {
        capabilitiesResult = capabilities
        for row in rows {
            self.rows[Slot(key: row.key, scope: row.scope)] = row.value
        }
        self.effectiveResponse = effectiveResponse
        self.persistsPuts = persistsPuts
    }

    // MARK: Configuration

    func setRow(_ row: Row) {
        rows[Slot(key: row.key, scope: row.scope)] = row.value
    }

    func removeRow(_ key: SettingKey, at scope: SettingScope) {
        rows[Slot(key: key, scope: scope)] = nil
    }

    func setCapabilities(_ result: SettingsCapabilitiesResult) {
        capabilitiesResult = result
    }

    /// A fixed read response; `nil` returns reads to the row model.
    func setEffectiveResponse(_ response: EffectiveSettingValuesResponse?) {
        effectiveResponse = response
    }

    func stored<T: Decodable>(_ key: SettingKey, at scope: SettingScope, as type: T.Type) -> T? {
        rows[Slot(key: key, scope: scope)].flatMap { try? $0.decoded(as: type) }
    }

    /// Fails matching calls with `failure`: every one when `times` is nil,
    /// otherwise the next `times`. Rules apply in the order they were added.
    func fail(_ target: Target, with failure: Failure = .offline, times: Int? = nil) {
        failureRules.append(FailureRule(target: target, failure: failure, remaining: times))
    }

    /// Removes the rules added for `target`, or every rule when nil.
    func stopFailing(_ target: Target? = nil) {
        guard let target else {
            failureRules.removeAll()
            return
        }
        failureRules.removeAll { $0.target == target }
    }

    // MARK: Gates

    /// Parks the next call matching `target` after it starts, until `release`.
    func hold(_ target: Target) {
        gates.append(Gate(id: nextGateID, target: target))
        nextGateID += 1
    }

    /// Resumes the call parked by `hold(target)`, or disarms the gate when no
    /// call has reached it yet.
    func release(_ target: Target) {
        guard let index = gates.firstIndex(where: { $0.target == target }) else { return }
        let gate = gates.remove(at: index)
        gate.parked?.resume()
    }

    // MARK: Waiters

    func waitForStarted(_ kind: Kind, count: Int) async {
        await wait(for: .started, kind, count: count)
    }

    func waitForCompleted(_ kind: Kind, count: Int) async {
        await wait(for: .completed, kind, count: count)
    }

    // MARK: Inspection

    /// Outcomes in the order calls finished.
    func steps() -> [Step] {
        completedSteps
    }

    func calls(_ kind: Kind) -> [Call] {
        history.filter { Self.kind($0.kind, isIn: kind) }
    }

    func decodedPuts<T: Decodable>(_ key: SettingKey, as type: T.Type) -> [T] {
        history.compactMap { call in
            guard case .put(let putKey, _, let value, _) = call, putKey == key else { return nil }
            return try? value.decoded(as: type)
        }
    }

    // MARK: UICustomizationTransport

    func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        capabilityChecks += 1
        return capabilitiesResult
    }

    func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        let call = Call.read(keys: keys, identity: requestIdentity)
        if let gateID = start(call) { await park(gateID) }
        return try finish(call) { resolve(keys, identity: requestIdentity) }
    }

    func putShortcutItem(
        _ item: PrimaryMenuItem,
        present: Bool,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        let call = Call.shortcut(item: item, present: present, identity: requestIdentity)
        if let gateID = start(call) { await park(gateID) }
        try finish(call) {
            let slot = Slot(key: .navShortcuts, scope: .profile)
            var shortcuts = try rows[slot]?.decoded(as: NavigationShortcutsPreference.self)
                ?? NavigationShortcutsPreference.empty
            shortcuts.items.removeAll { $0.id == item.id }
            if present { shortcuts.items.append(item) }
            rows[slot] = try SettingJSONValue.encoding(shortcuts)
        }
    }

    func putValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        let call = Call.put(key: key, scope: scope, value: value, identity: requestIdentity)
        if let gateID = start(call) { await park(gateID) }
        try finish(call) {
            if persistsPuts {
                rows[Slot(key: key, scope: scope.scope)] = value
            }
        }
    }

    func deleteValue(
        key: SettingKey,
        scope: SettingScopeIdentity,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        let call = Call.delete(key: key, scope: scope, identity: requestIdentity)
        if let gateID = start(call) { await park(gateID) }
        try finish(call) {
            guard rows.removeValue(forKey: Slot(key: key, scope: scope.scope)) != nil else {
                throw SettingsAPIError.noValueAtScope
            }
        }
    }

    // MARK: Call lifecycle

    /// Step 1: record the call and wake "started" waiters. Returns the gate
    /// the call must park on, if one is armed for it.
    private func start(_ call: Call) -> Int? {
        history.append(call)
        startedCounts[call.kind, default: 0] += 1
        if call.kind != .read {
            inFlightWrites += 1
            maxConcurrentWrites = max(maxConcurrentWrites, inFlightWrites)
        }
        resumeReadyWaiters()
        guard let index = gates.firstIndex(where: { !$0.arrived && $0.target.matches(call) }) else {
            return nil
        }
        gates[index].arrived = true
        return gates[index].id
    }

    /// Step 2: the only suspension in a transport call.
    private func park(_ gateID: Int) async {
        await withCheckedContinuation { continuation in
            guard let index = gates.firstIndex(where: { $0.id == gateID }) else {
                continuation.resume()
                return
            }
            gates[index].parked = continuation
        }
    }

    /// Steps 3-5: take a failure rule or apply the call, then record the
    /// outcome and wake "completed" waiters. Runs without suspending.
    private func finish<T>(_ call: Call, apply: () throws -> T) throws -> T {
        do {
            if let failure = takeFailure(for: call) {
                throw failure.error
            }
            let result = try apply()
            complete(call, .succeeded)
            return result
        } catch {
            complete(call, .failed)
            throw error
        }
    }

    private func takeFailure(for call: Call) -> Failure? {
        guard let index = failureRules.firstIndex(where: {
            $0.target.matches(call) && ($0.remaining ?? 1) > 0
        }) else { return nil }
        let failure = failureRules[index].failure
        if let remaining = failureRules[index].remaining {
            if remaining <= 1 {
                failureRules.remove(at: index)
            } else {
                failureRules[index].remaining = remaining - 1
            }
        }
        return failure
    }

    private func complete(_ call: Call, _ completion: Completion) {
        switch call {
        case .read:
            completedSteps.append(.read(completion))
        case .put(let key, _, _, _):
            completedSteps.append(.put(key, completion))
        case .shortcut(let item, let present, _):
            completedSteps.append(.shortcut(id: item.id, present: present, completion))
        case .delete(let key, let scope, _):
            completedSteps.append(.delete(key, scope.scope, completion))
        }
        completedCounts[call.kind, default: 0] += 1
        if call.kind != .read {
            inFlightWrites -= 1
        }
        resumeReadyWaiters()
    }

    // MARK: Read model

    private func resolve(_ keys: [SettingKey], identity: HTTPRequestIdentity) -> EffectiveSettingValuesResponse {
        if let effectiveResponse { return effectiveResponse }
        var settings: [EffectiveSettingValue] = []
        for key in keys {
            if let scope = Self.precedence.first(where: { rows[Slot(key: key, scope: $0)] != nil }),
               let value = rows[Slot(key: key, scope: scope)] {
                settings.append(EffectiveSettingValue(
                    key: key.rawValue,
                    value: value,
                    source: .scope(scope),
                    scope: scope,
                    profileId: "profile",
                    clientFamily: scope == .profileClient ? identity.clientFamily : nil,
                    deviceId: scope == .profileDevice ? "device" : nil
                ))
            } else if let value = Self.contractDefault(for: key) {
                settings.append(EffectiveSettingValue(
                    key: key.rawValue,
                    value: value,
                    source: .contractDefault,
                    profileId: "profile"
                ))
            }
        }
        return EffectiveSettingValuesResponse(settings: settings, revision: SettingKey.revision)
    }

    private static func contractDefault(for key: SettingKey) -> SettingJSONValue? {
        switch key {
        case .navPrimaryMenu:
            return .null
        case .navShortcuts:
            return try? SettingJSONValue.encoding(NavigationShortcutsPreference.empty)
        case .uiCardPresentation:
            return try? SettingJSONValue.encoding(CardPresentationPreference.standard)
        default:
            return nil
        }
    }

    // MARK: Waiter bookkeeping

    private static func kind(_ kind: Kind, isIn filter: Kind) -> Bool {
        filter == .write ? kind != .read : kind == filter
    }

    private func count(_ phase: Phase, _ kind: Kind) -> Int {
        let counts = phase == .started ? startedCounts : completedCounts
        guard kind == .write else { return counts[kind, default: 0] }
        return counts[.put, default: 0] + counts[.shortcut, default: 0] + counts[.delete, default: 0]
    }

    private func wait(for phase: Phase, _ kind: Kind, count target: Int) async {
        guard count(phase, kind) < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(phase: phase, kind: kind, count: target, continuation: continuation))
        }
    }

    private func resumeReadyWaiters() {
        let ready = waiters.filter { count($0.phase, $0.kind) >= $0.count }
        waiters.removeAll { count($0.phase, $0.kind) >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }
}

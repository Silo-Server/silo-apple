#if os(iOS)
import Foundation
import OSLog

/// A server that may still be pushing to this device after its credentials
/// were deleted (the server was removed, or signed out of). Nonsecret: the
/// installation key that proves the retirement stays in the server's
/// `ApplePushInstallationJournal` record, which outlives the credentials.
struct ApplePushRetirement: Codable, Equatable, Sendable {
    /// The registry id (`ServerEntry.id`) whose journal holds the key.
    let serverID: String
    let serverURL: String
    /// The `device_id` the registrations carried.
    let deviceID: String
    /// The journal generation allocated to this retirement.
    let generation: Int64
    let queuedAt: Date
}

/// The pending retirements, one Keychain item in the journal's audience so
/// they are kept or lost with the journal and the device ID.
struct ApplePushRetirementStore: Sendable {
    let keychain: SharedKeychain

    init(keychain: SharedKeychain = SharedKeychain(audience: .userIndependent)) {
        self.keychain = keychain
    }

    static let account = SharedStorage.keychainAccountPrefix + "push.apple.retirements"

    enum StoreError: Error, Equatable {
        case unreadable
        case writeFailed
    }

    func load() throws -> [ApplePushRetirement] {
        let raw: String?
        do {
            raw = try keychain.getChecked(Self.account)
        } catch {
            throw StoreError.unreadable
        }
        guard let raw else { return [] }
        guard let entries = try? JSONDecoder().decode([ApplePushRetirement].self, from: Data(raw.utf8)) else {
            throw StoreError.unreadable
        }
        return entries
    }

    func save(_ entries: [ApplePushRetirement]) throws {
        if entries.isEmpty {
            guard keychain.delete(Self.account) else { throw StoreError.writeFailed }
            return
        }
        let data = try JSONEncoder().encode(entries)
        guard keychain.set(String(decoding: data, as: UTF8.self), for: Self.account) else {
            throw StoreError.writeFailed
        }
    }
}

/// Sends `retireApplePushInstallation` for servers this device no longer
/// holds credentials for, until each answers for good.
///
/// Per entry:
/// - 200: the server holds no registration for the device at or past this
///   generation. Dropped.
/// - 403 (the key does not match: the journal was lost or replaced), 409 (a
///   newer generation exists: the server was registered again), or another
///   refusal of the request itself (400, 413, 415, 422): the same request
///   would get the same answer. Dropped.
/// - 404 or 405: a server without the endpoint. Kept, and dropped once the
///   entry is `unsupportedLifetime` old.
/// - Anything else (no answer, 408, 429, 5xx): kept, and sent again after a
///   back-off on the next launch, foreground, or push. Dropped without
///   sending once it is `maximumLifetime` old.
///
/// The journal decides too: an entry whose journal generation has moved past
/// it was superseded by a new registration and is dropped unsent.
actor ApplePushRetirementQueue {
    enum Outcome: Equatable, Sendable {
        /// The server dropped the registration, or held none.
        case retired
        /// Dropped without a removal: no later attempt can change the answer.
        case dropped(reason: String)
        /// The server has no retirement endpoint yet. Kept.
        case unsupported
        /// Kept for a later attempt.
        case kept(reason: String)
    }

    typealias Send = @Sendable (_ serverURL: String, _ deviceID: String, _ installationKey: String,
                                _ generation: Int64) async throws -> Void

    static let shared = ApplePushRetirementQueue()

    /// The contract's limit for a server without the endpoint.
    static let unsupportedLifetime: TimeInterval = 30 * 24 * 60 * 60
    /// A server that never answers is not tried forever.
    static let maximumLifetime: TimeInterval = 90 * 24 * 60 * 60
    static let maximumConcurrentSends = 3
    /// The first retry waits this long, doubling per failure up to
    /// `maximumBackOff`.
    static let initialBackOff: TimeInterval = 30
    static let maximumBackOff: TimeInterval = 6 * 60 * 60
    /// A push from a retired server skips the back-off, but not this.
    static let minimumRetryInterval: TimeInterval = 30
    private static let refusalStatuses: Set<Int> = [400, 403, 409, 413, 415, 422]
    private static let unsupportedStatuses: Set<Int> = [404, 405]

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ApplePush"
    )

    private let store: ApplePushRetirementStore
    private let journal: ApplePushInstallationJournal
    private let transport: Send
    private let now: @Sendable () -> Date
    /// Per server, in memory: failed attempts in a row and when the last one
    /// ran. A relaunch starts over.
    private var failures: [String: (count: Int, at: Date)] = [:]
    /// Servers with a send in flight; a second one waits for the next pass.
    private var sending: Set<String> = []

    init(store: ApplePushRetirementStore = ApplePushRetirementStore(),
         journal: ApplePushInstallationJournal = ApplePushInstallationJournal(),
         now: @escaping @Sendable () -> Date = { Date() },
         send: @escaping Send = { serverURL, deviceID, key, generation in
             try await APIv2Client.retireApplePushInstallation(serverURL: serverURL, deviceID: deviceID,
                 installationKey: key, generation: generation)
         }) {
        self.store = store
        self.journal = journal
        self.now = now
        self.transport = send
    }

    /// The pending retirements; empty when the store cannot be read.
    private func pending() -> [ApplePushRetirement] {
        (try? store.load()) ?? []
    }

    /// Persists `entry`, replacing any entry for its server but keeping that
    /// entry's `queuedAt`, so the lifetimes count from the first queueing.
    /// Returns whether the entry reached the Keychain.
    @discardableResult
    func enqueue(_ entry: ApplePushRetirement) -> Bool {
        do {
            var entries = try store.load()
            var stored = entry
            if let earlier = entries.first(where: { $0.serverID == entry.serverID }) {
                stored = ApplePushRetirement(serverID: entry.serverID, serverURL: entry.serverURL,
                    deviceID: entry.deviceID, generation: entry.generation,
                    queuedAt: min(earlier.queuedAt, entry.queuedAt))
            }
            entries.removeAll { $0.serverID == entry.serverID }
            entries.append(stored)
            try store.save(entries)
            failures[entry.serverID] = nil
            return true
        } catch {
            Self.logger.error("Could not queue the Apple push retirement: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Drops the server's retirement, or only one older than `generation`.
    /// A registration that allocated `generation` supersedes it on the
    /// server, so it is never sent once that registration exists.
    func cancel(serverID: String, before generation: Int64? = nil, reason: String) {
        do {
            let entries = try store.load()
            let kept = entries.filter { entry in
                entry.serverID != serverID || generation.map { entry.generation >= $0 } == true
            }
            guard kept.count != entries.count else { return }
            try store.save(kept)
            failures[serverID] = nil
            Self.record("cancelled", reason: reason, generation: nil)
        } catch {
            Self.logger.error("Could not cancel the Apple push retirement: \(String(describing: error), privacy: .public)")
        }
    }

    /// Queues `entry` and sends it at once. An entry the Keychain refused
    /// still gets this one attempt.
    func submit(_ entry: ApplePushRetirement) async -> Outcome? {
        enqueue(entry)
        let stored = pending().first { $0.serverID == entry.serverID && $0.generation == entry.generation }
        return await attempt(stored ?? entry)
    }

    /// Sends every pending retirement whose back-off has passed, a few at a
    /// time. `afterPush` skips the back-off: a push from a server that should
    /// have stopped is the moment to try again.
    func retryDue(afterPush: Bool = false) async {
        let at = now()
        let due = pending().filter { entry in
            guard let failure = failures[entry.serverID] else { return true }
            let wait = afterPush ? Self.minimumRetryInterval : Self.backOff(afterFailures: failure.count)
            return at.timeIntervalSince(failure.at) >= wait
        }
        guard !due.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var next = due.makeIterator()
            for _ in 0..<Self.maximumConcurrentSends {
                guard let entry = next.next() else { break }
                group.addTask { _ = await self.attempt(entry) }
            }
            while await group.next() != nil {
                guard let entry = next.next() else { continue }
                group.addTask { _ = await self.attempt(entry) }
            }
        }
    }

    static func backOff(afterFailures count: Int) -> TimeInterval {
        min(maximumBackOff, initialBackOff * pow(2, Double(max(0, count - 1))))
    }

    private func attempt(_ entry: ApplePushRetirement) async -> Outcome? {
        guard sending.insert(entry.serverID).inserted else { return nil }
        defer { sending.remove(entry.serverID) }
        let age = now().timeIntervalSince(entry.queuedAt)
        if age >= Self.maximumLifetime {
            return finish(entry, .dropped(reason: "expired"))
        }
        let key: String
        do {
            guard let record = try journal.load(serverID: entry.serverID) else {
                return finish(entry, .dropped(reason: "journal_missing"))
            }
            // The journal persists the generation before the entry, so a
            // record behind the entry was replaced, and one ahead of it holds
            // a registration that supersedes the retirement.
            if record.generation > entry.generation {
                return finish(entry, .dropped(reason: "superseded"))
            }
            guard record.generation == entry.generation else {
                return finish(entry, .dropped(reason: "journal_replaced"))
            }
            key = record.installationKey
        } catch {
            // Before first unlock, for example. Nothing was sent.
            return finish(entry, .kept(reason: "journal_unreadable"))
        }
        do {
            try await transport(entry.serverURL, entry.deviceID, key, entry.generation)
            return finish(entry, .retired)
        } catch {
            return finish(entry, Self.outcome(for: error, age: age))
        }
    }

    static func outcome(for error: Error, age: TimeInterval) -> Outcome {
        let status: Int
        let reason: String
        switch error {
        case ApplePushRegistrationError.invalidReceipt:
            return .dropped(reason: "invalid_receipt")
        case ApplePushRegistrationError.invalidInstallation:
            return .dropped(reason: "invalid_installation")
        case APIv2Error.problem(let problem):
            status = problem.status
            reason = "http_\(problem.status)_\(problem.identifier)"
        case APIv2Error.httpStatus(let code):
            status = code
            reason = "http_\(code)"
        case let error as URLError:
            return .kept(reason: "url_\(error.code.rawValue)")
        default:
            return .kept(reason: String(describing: error))
        }
        if refusalStatuses.contains(status) { return .dropped(reason: reason) }
        if unsupportedStatuses.contains(status) {
            return age >= unsupportedLifetime ? .dropped(reason: "unsupported_expired") : .unsupported
        }
        return .kept(reason: reason)
    }

    /// Applies `outcome` to the store and the back-off, and logs it.
    private func finish(_ entry: ApplePushRetirement, _ outcome: Outcome) -> Outcome {
        switch outcome {
        case .retired, .dropped:
            failures[entry.serverID] = nil
            remove(entry)
        case .unsupported, .kept:
            failures[entry.serverID] = ((failures[entry.serverID]?.count ?? 0) + 1, now())
        }
        switch outcome {
        case .retired:
            Self.logger.info("Apple push retirement accepted: generation=\(entry.generation, privacy: .public)")
            Self.record("retired", reason: nil, generation: entry.generation)
        case .dropped(let reason):
            Self.logger.error("Apple push retirement dropped: generation=\(entry.generation, privacy: .public) reason=\(reason, privacy: .public)")
            Self.record("dropped", reason: reason, generation: entry.generation)
        case .unsupported:
            Self.logger.info("Apple push retirement unsupported by the server; kept: generation=\(entry.generation, privacy: .public)")
            Self.record("unsupported", reason: nil, generation: entry.generation)
        case .kept(let reason):
            Self.logger.info("Apple push retirement kept for retry: generation=\(entry.generation, privacy: .public) reason=\(reason, privacy: .public)")
            Self.record("kept", reason: reason, generation: entry.generation)
        }
        return outcome
    }

    /// Removes `entry` only while the store still holds that generation: a
    /// newer retirement queued during the send stays.
    private func remove(_ entry: ApplePushRetirement) {
        do {
            let entries = try store.load()
            let kept = entries.filter { $0.serverID != entry.serverID || $0.generation != entry.generation }
            guard kept.count != entries.count else { return }
            try store.save(kept)
        } catch {
            Self.logger.error("Could not remove the Apple push retirement: \(String(describing: error), privacy: .public)")
        }
    }

    /// One breadcrumb per outcome, beside the PushDisplay lines, so a report
    /// can say why a removed server's pushes kept arriving.
    private static func record(_ outcome: String, reason: String?, generation: Int64?) {
        var attrs: [String: DiagLogAttributeValue] = ["outcome": .string(outcome)]
        if let reason {
            attrs["reason"] = .string(reason)
        }
        let quiet = outcome == "retired" || outcome == "cancelled"
        DiagTrace.breadcrumb(
            .essential,
            level: quiet ? .info : .warning,
            category: .lifecycle,
            tag: "PushRetire",
            message: "push retirement \(outcome)" + (generation.map { " at generation \($0)" } ?? ""),
            attrs: attrs
        )
    }
}
#endif

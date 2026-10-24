import Foundation

/// An opaque, checked view of this Apple TV user's selection and its resolved session.
struct TVAccountSelectionSnapshot: Equatable, Sendable {
    fileprivate let serverID: String
    fileprivate let selection: TVAccountSelection?
    fileprivate let state: AccountSessionPersistence.State
    fileprivate let legacyCredentials: TVLegacyAccountCredentials?

    var resolvedSession: CanonicalAccountSession? {
        guard case .session(let value) = state else { return nil }
        return value
    }
}

fileprivate struct TVLegacyAccountCredentials: Equatable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let epoch: String?
}

/// Only the destination slot, optional default change, and local selector belong
/// to an installation. Rollback never restores a whole, potentially stale envelope.
struct TVAccountInstallationReceipt: Equatable, Sendable {
    let previousSelection: TVAccountSelectionSnapshot
    fileprivate let installedSelection: TVAccountSelection?
    fileprivate let slotID: String
    fileprivate let previousSession: CanonicalAccountSession?
    fileprivate let installedSession: CanonicalAccountSession
    fileprivate let defaultChange: TVAccountDefaultChange?
}

fileprivate struct TVAccountDefaultChange: Equatable, Sendable {
    let previous: String?
    let installed: String?
}

fileprivate struct TVAccountSelection: Codable, Equatable, Sendable {
    let version: Int
    let signedOut: Bool
    let accountID: String?

    static let signedOut = TVAccountSelection(version: 1, signedOut: true, accountID: nil)
    static func selected(_ accountID: String) -> Self {
        TVAccountSelection(version: 1, signedOut: false, accountID: accountID)
    }
}

/// Shared credentials and a current-user selector have different audiences.
/// The app is the envelope's sole writer; extensions only load it. One static
/// synchronous lock serializes all app instances in this process. This is not
/// a cross-process compare-and-swap protocol.
struct TVAccountSessionStorage: Sendable {
    private struct Envelope: Codable {
        let version: Int
        var revision: UUID
        var defaultSlotID: String?
        var sessions: [String: CanonicalAccountSession]

        static var empty: Self {
            Envelope(version: 1, revision: UUID(), defaultSlotID: nil, sessions: [:])
        }
    }

    private static let lock = NSLock()
    private static let legacySlotID = "legacy-default"
    private let sharedRead: @Sendable (String) throws -> String?
    private let sharedWrite: @Sendable (String, String) -> Bool
    private let sharedRemove: @Sendable (String) -> Bool
    private let selectionRead: @Sendable (String) throws -> String?
    private let selectionWrite: @Sendable (String, String) -> Bool
    private let selectionRemove: @Sendable (String) -> Bool

    init(sharedRead: @escaping @Sendable (String) throws -> String?,
         sharedWrite: @escaping @Sendable (String, String) -> Bool,
         sharedRemove: @escaping @Sendable (String) -> Bool,
         selectionRead: @escaping @Sendable (String) throws -> String?,
         selectionWrite: @escaping @Sendable (String, String) -> Bool,
         selectionRemove: @escaping @Sendable (String) -> Bool) {
        self.sharedRead = sharedRead
        self.sharedWrite = sharedWrite
        self.sharedRemove = sharedRemove
        self.selectionRead = selectionRead
        self.selectionWrite = selectionWrite
        self.selectionRemove = selectionRemove
    }

    static func recordKey(_ serverID: String) -> String {
        SharedStorage.keychainAccountPrefix + "\(serverID).accountSessions.v1"
    }

    static func markerKey(_ serverID: String) -> String {
        SharedStorage.keychainAccountPrefix + "\(serverID).accountSessionsAdopted.v1"
    }

    static func selectionKey(_ serverID: String) -> String {
        SharedStorage.keychainAccountPrefix + "\(serverID).selectedAccount.v1"
    }

    private static func slotID(_ value: CanonicalAccountSession) -> String {
        value.accountID.map { "account:\($0)" } ?? legacySlotID
    }

    func load(_ serverID: String) throws -> AccountSessionPersistence.State {
        try Self.lock.withLock { try snapshotUnlocked(serverID).state }
    }

    func hasLegacyAccessToken(serverID: String) -> Bool {
        Self.lock.withLock {
            // Recheck under the same lock: adoption may have happened after a
            // caller observed .legacy and before it checked a raw mirror.
            guard (try? snapshotUnlocked(serverID).state) == .legacy else { return false }
            return (try? sharedRead(SharedStorage.accessTokenAccount(for: serverID)))?.isEmpty == false
        }
    }

    func accountSelectionSnapshot(for serverID: String) throws -> TVAccountSelectionSnapshot {
        try Self.lock.withLock { try snapshotUnlocked(serverID) }
    }

    func savedAccountIDs(for serverID: String) throws -> [String] {
        try Self.lock.withLock {
            guard !serverID.isEmpty else { throw AccountSessionPersistenceError.invalidIdentity }
            if let envelope = try readEnvelopeUnlocked(serverID) {
                return envelope.sessions.values.compactMap(\.accountID).sorted()
            }
            if case .session(let value) = try AccountSessionPersistence.loadLegacy(serverID, read: sharedRead),
               let accountID = value.accountID { return [accountID] }
            return []
        }
    }

    func matchesAccountSelection(_ snapshot: TVAccountSelectionSnapshot, serverID: String) -> Bool {
        Self.lock.withLock {
            do {
                guard snapshot.serverID == serverID else { return false }
                let current = try snapshotUnlocked(serverID)
                if current == snapshot { return true }
                // A failed install may safely migrate raw A into the shared
                // legacy-default slot while rolling back only destination B.
                // Compare that exact authority, including unchanged raw input.
                guard snapshot.selection == current.selection, case .legacy = snapshot.state,
                      let legacy = snapshot.legacyCredentials,
                      try readLegacyCredentialsUnlocked(serverID) == legacy else { return false }
                if legacy.accessToken == nil && legacy.refreshToken == nil {
                    return current.state == .signedOut
                }
                guard case .session(let value) = current.state, value.accountID == nil,
                      value.accessToken == legacy.accessToken, value.refreshToken == legacy.refreshToken else { return false }
                if let epoch = legacy.epoch { return UUID(uuidString: epoch) == value.epoch }
                return true
            } catch { return false }
        }
    }

    func installAccountSession(_ value: CanonicalAccountSession, serverID: String) throws -> TVAccountInstallationReceipt {
        try Self.lock.withLock {
            guard !serverID.isEmpty else { throw AccountSessionPersistenceError.invalidIdentity }
            try AccountSessionPersistence.validateSession(value)
            let previous = try snapshotUnlocked(serverID)
            var envelope = try mutableEnvelopeUnlocked(serverID, origin: value.origin)
            let destination = Self.slotID(value)
            let oldDefault = envelope.defaultSlotID
            let oldSession = envelope.sessions[destination]
            let selection: TVAccountSelection?
            if let accountID = value.accountID {
                selection = .selected(accountID)
            } else {
                // An unverified account is only a legacy family default. It must
                // never impersonate a verified slot or get a per-persona pointer.
                guard previous.selection == nil,
                      envelope.defaultSlotID == Self.legacySlotID || envelope.sessions.isEmpty else {
                    throw AccountSessionPersistenceError.invalidIdentity
                }
                selection = nil
            }
            if envelope.defaultSlotID == nil && envelope.sessions.isEmpty {
                envelope.defaultSlotID = destination
            }
            envelope.sessions[destination] = value
            let change = oldDefault == envelope.defaultSlotID ? nil
                : TVAccountDefaultChange(previous: oldDefault, installed: envelope.defaultSlotID)
            let receipt = TVAccountInstallationReceipt(previousSelection: previous,
                installedSelection: selection, slotID: destination, previousSession: oldSession,
                installedSession: value, defaultChange: change)
            guard persistEnvelopeUnlocked(envelope, serverID: serverID) else {
                // Initial publication can succeed before its adoption marker
                // fails. Undo only this install's fields if it was published.
                _ = rollbackUnlocked(receipt, serverID: serverID, selectorWasInstalled: false)
                throw AccountSessionPersistenceError.unavailable
            }
            // The shared session must be durable before a persona can select it.
            if previous.selection != selection && !persistSelectionUnlocked(selection, serverID: serverID) {
                _ = rollbackUnlocked(receipt, serverID: serverID, selectorWasInstalled: false)
                throw AccountSessionPersistenceError.unavailable
            }
            return receipt
        }
    }

    func rollbackAccountInstallation(_ receipt: TVAccountInstallationReceipt, serverID: String) -> Bool {
        Self.lock.withLock { rollbackUnlocked(receipt, serverID: serverID, selectorWasInstalled: true) }
    }

    func deselectAccount(serverID: String) -> Bool {
        Self.lock.withLock {
            guard !serverID.isEmpty else { return false }
            // A local sign-out has no shared schema mutation or account revocation.
            return persistSelectionUnlocked(.signedOut, serverID: serverID)
        }
    }

    func invalidateAllAccounts(serverID: String) -> Bool {
        Self.lock.withLock {
            guard !serverID.isEmpty else { return false }
            return commitInvalidationUnlocked(.empty, serverID: serverID)
        }
    }

    func invalidate(_ serverID: String) -> Bool {
        Self.lock.withLock { invalidateUnlocked(expected: nil, serverID: serverID) }
    }

    func invalidateSession(_ expected: CanonicalAccountSession, serverID: String) -> Bool {
        Self.lock.withLock { invalidateUnlocked(expected: expected, serverID: serverID) }
    }

    /// Refresh and authenticated identity binding preserve the current selector.
    /// Binding a legacy default moves it to its verified slot with the same epoch.
    /// The synchronous prerequisite runs only after exact-owner validation and
    /// must not re-enter this storage. Failure leaves the previous authority.
    func replaceSession(_ replacement: CanonicalAccountSession, replacing expected: CanonicalAccountSession,
                        serverID: String, beforePublishing: () -> Bool = { true }) -> Bool {
        Self.lock.withLock {
            do {
                guard !serverID.isEmpty,
                      try snapshotUnlocked(serverID).state == .session(expected),
                      replacement.origin == expected.origin, replacement.epoch == expected.epoch,
                      expected.accountID == replacement.accountID || expected.accountID == nil else { return false }
                try AccountSessionPersistence.validateSession(replacement)
                var envelope = try mutableEnvelopeUnlocked(serverID, origin: expected.origin)
                let oldSlot = Self.slotID(expected)
                let newSlot = Self.slotID(replacement)
                guard envelope.sessions[oldSlot] == expected,
                      oldSlot == newSlot || envelope.sessions[newSlot] == nil
                        || envelope.sessions[newSlot]?.origin == replacement.origin else { return false }
                guard beforePublishing() else { return false }
                // An authenticated legacy default may name an account another
                // TV user already saved. Keep the exact authenticated epoch
                // and credentials as that account's single shared authority.
                envelope.sessions.removeValue(forKey: oldSlot)
                envelope.sessions[newSlot] = replacement
                if envelope.defaultSlotID == oldSlot { envelope.defaultSlotID = newSlot }
                return commitEnvelopeUpdateUnlocked(envelope, serverID: serverID,
                    previousRecord: try sharedRead(Self.recordKey(serverID)))
            } catch { return false }
        }
    }

    /// Promote the exact raw credentials authenticated by the caller. This is
    /// identity binding, so it moves the legacy default instead of installing a
    /// second session or selecting an account on behalf of this TV user.
    func bindLegacySession(_ verified: CanonicalAccountSession, serverID: String,
                           beforePublishing: () -> Bool = { true }) -> Bool {
        Self.lock.withLock {
            do {
                try AccountSessionPersistence.validateSession(verified)
                guard verified.accountID != nil,
                      try snapshotUnlocked(serverID).state == .legacy,
                      try sharedRead(SharedStorage.accessTokenAccount(for: serverID)) == verified.accessToken,
                      try sharedRead(SharedStorage.refreshTokenAccount(for: serverID)) == verified.refreshToken,
                      try sharedRead(SharedStorage.accountEpochAccount(for: serverID)).flatMap(UUID.init(uuidString:)) == verified.epoch else {
                    return false
                }
                var envelope = try mutableEnvelopeUnlocked(serverID, origin: verified.origin)
                let destination = Self.slotID(verified)
                guard let legacy = envelope.sessions[Self.legacySlotID], legacy.accountID == nil,
                      legacy.origin == verified.origin, legacy.epoch == verified.epoch,
                      legacy.accessToken == verified.accessToken, legacy.refreshToken == verified.refreshToken,
                      envelope.defaultSlotID == Self.legacySlotID, envelope.sessions[destination] == nil else { return false }
                guard beforePublishing() else { return false }
                envelope.sessions.removeValue(forKey: Self.legacySlotID)
                envelope.sessions[destination] = verified
                envelope.defaultSlotID = destination
                return commitEnvelopeUpdateUnlocked(envelope, serverID: serverID,
                    previousRecord: try sharedRead(Self.recordKey(serverID)))
            } catch { return false }
        }
    }

    private func snapshotUnlocked(_ serverID: String) throws -> TVAccountSelectionSnapshot {
        guard !serverID.isEmpty else { throw AccountSessionPersistenceError.invalidIdentity }
        // Read the marker before any possible legacy lookup. Once adopted,
        // absence of the envelope can never resurrect old canonical/raw tokens.
        let envelope = try readEnvelopeUnlocked(serverID)
        let selection = try readSelectionUnlocked(serverID)
        let state: AccountSessionPersistence.State
        if let selection {
            if selection.signedOut {
                state = .signedOut
            } else {
                let slot = "account:\(selection.accountID!)"
                // A different persona may have signed this account out or
                // removed its server. Keep the explicit pointer but permit a
                // fresh login; an absent slot never inherits the family default.
                state = envelope?.sessions[slot].map { .session($0) } ?? .signedOut
            }
        } else if let envelope {
            if let slot = envelope.defaultSlotID {
                guard let value = envelope.sessions[slot] else {
                    throw AccountSessionPersistenceError.invalidRecord
                }
                state = .session(value)
            } else {
                state = .signedOut
            }
        } else {
            state = try AccountSessionPersistence.loadLegacy(serverID, read: sharedRead)
        }
        let legacy: TVLegacyAccountCredentials?
        if case .legacy = state { legacy = try readLegacyCredentialsUnlocked(serverID) }
        else { legacy = nil }
        return TVAccountSelectionSnapshot(serverID: serverID, selection: selection, state: state, legacyCredentials: legacy)
    }

    private func readLegacyCredentialsUnlocked(_ serverID: String) throws -> TVLegacyAccountCredentials {
        try TVLegacyAccountCredentials(accessToken: sharedRead(SharedStorage.accessTokenAccount(for: serverID)),
            refreshToken: sharedRead(SharedStorage.refreshTokenAccount(for: serverID)),
            epoch: sharedRead(SharedStorage.accountEpochAccount(for: serverID)))
    }

    /// `nil` means never adopted; an adopted, absent record is an empty tombstone.
    private func readEnvelopeUnlocked(_ serverID: String) throws -> Envelope? {
        let adopted = try sharedRead(Self.markerKey(serverID))
        guard let raw = try sharedRead(Self.recordKey(serverID)) else {
            return adopted == nil ? nil : .empty
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(raw.utf8))
        guard envelope.version == 1 else { throw AccountSessionPersistenceError.invalidRecord }
        for (slot, value) in envelope.sessions {
            try AccountSessionPersistence.validateSession(value)
            guard Self.slotID(value) == slot else { throw AccountSessionPersistenceError.invalidRecord }
        }
        if let slot = envelope.defaultSlotID, envelope.sessions[slot] == nil {
            throw AccountSessionPersistenceError.invalidRecord
        }
        return envelope
    }

    private func readSelectionUnlocked(_ serverID: String) throws -> TVAccountSelection? {
        guard let raw = try selectionRead(Self.selectionKey(serverID)) else { return nil }
        let selection = try JSONDecoder().decode(TVAccountSelection.self, from: Data(raw.utf8))
        guard selection.version == 1,
              selection.signedOut ? selection.accountID == nil : selection.accountID?.isEmpty == false else {
            throw AccountSessionPersistenceError.invalidRecord
        }
        return selection
    }

    private func mutableEnvelopeUnlocked(_ serverID: String, origin: String?) throws -> Envelope {
        if let envelope = try readEnvelopeUnlocked(serverID) { return envelope }
        var envelope = Envelope.empty
        let legacy = try AccountSessionPersistence.loadLegacy(serverID, read: sharedRead)
        var session: CanonicalAccountSession?
        if case .session(let value) = legacy {
            session = value
        } else if case .legacy = legacy, let origin {
            // Raw credentials predate verified account IDs. Preserve their
            // existing epoch when available and bind their identity only after
            // the server authenticates them.
            let access = try sharedRead(SharedStorage.accessTokenAccount(for: serverID))
            let refresh = try sharedRead(SharedStorage.refreshTokenAccount(for: serverID))
            let epoch = try sharedRead(SharedStorage.accountEpochAccount(for: serverID))
            if let access, !access.isEmpty, let refresh, !refresh.isEmpty {
                let value = CanonicalAccountSession(version: 1, signedOut: false, origin: origin,
                    accountID: nil, epoch: epoch.flatMap(UUID.init(uuidString:)) ?? UUID(),
                    accessToken: access, refreshToken: refresh)
                try AccountSessionPersistence.validateSession(value)
                session = value
            }
        }
        if let session {
            let slot = Self.slotID(session)
            envelope.sessions[slot] = session
            envelope.defaultSlotID = slot
        }
        return envelope
    }

    private enum EnvelopePublication {
        case failed, committed, unmarked(String)
    }

    private func persistEnvelopeUnlocked(_ value: Envelope, serverID: String) -> Bool {
        if case .committed = publishEnvelopeUnlocked(value, serverID: serverID) { return true }
        return false
    }

    private func publishEnvelopeUnlocked(_ value: Envelope, serverID: String) -> EnvelopePublication {
        var value = value
        value.revision = UUID()
        guard let data = try? JSONEncoder().encode(value) else { return .failed }
        let raw = String(decoding: data, as: UTF8.self)
        do {
            if try sharedRead(Self.markerKey(serverID)) != nil {
                // Adoption already makes missing records fail closed.
                return sharedWrite(raw, Self.recordKey(serverID)) ? .committed : .failed
            }
            // A first write must preserve valid legacy state if publication
            // fails. Readers already treat a present envelope as authoritative,
            // so publishing it before the marker has no legacy fallback window.
            guard sharedWrite(raw, Self.recordKey(serverID)) else { return .failed }
            return sharedWrite("1", Self.markerKey(serverID)) ? .committed : .unmarked(raw)
        } catch { return .failed }
    }

    /// A failed adoption marker must leave the caller's cached owner usable.
    /// Restore the previous bytes only while the unmarked publication is ours.
    private func commitEnvelopeUpdateUnlocked(_ envelope: Envelope, serverID: String, previousRecord: String?) -> Bool {
        do {
            let publication = publishEnvelopeUnlocked(envelope, serverID: serverID)
            if case .committed = publication { return true }
            if case .unmarked(let installed) = publication,
               try sharedRead(Self.markerKey(serverID)) == nil,
               try sharedRead(Self.recordKey(serverID)) == installed {
                if let previousRecord { _ = sharedWrite(previousRecord, Self.recordKey(serverID)) }
                else { _ = sharedRemove(Self.recordKey(serverID)) }
            }
            return false
        } catch { return false }
    }

    private func persistSelectionUnlocked(_ selection: TVAccountSelection?, serverID: String) -> Bool {
        guard let selection else { return selectionRemove(Self.selectionKey(serverID)) }
        guard let data = try? JSONEncoder().encode(selection) else { return false }
        return selectionWrite(String(decoding: data, as: UTF8.self), Self.selectionKey(serverID))
    }

    private func rollbackUnlocked(_ receipt: TVAccountInstallationReceipt, serverID: String,
                                  selectorWasInstalled: Bool) -> Bool {
        do {
            guard receipt.previousSelection.serverID == serverID,
                  try readSelectionUnlocked(serverID) == (selectorWasInstalled
                    ? receipt.installedSelection : receipt.previousSelection.selection),
                  var envelope = try readEnvelopeUnlocked(serverID),
                  envelope.sessions[receipt.slotID] == receipt.installedSession else { return false }
            if let change = receipt.defaultChange {
                guard envelope.defaultSlotID == change.installed else { return false }
                envelope.defaultSlotID = change.previous
            }
            envelope.sessions[receipt.slotID] = receipt.previousSession
            guard persistEnvelopeUnlocked(envelope, serverID: serverID) else { return false }
            return !selectorWasInstalled || receipt.previousSelection.selection == receipt.installedSelection
                || persistSelectionUnlocked(receipt.previousSelection.selection, serverID: serverID)
        } catch { return false }
    }

    private func invalidateUnlocked(expected: CanonicalAccountSession?, serverID: String) -> Bool {
        do {
            guard !serverID.isEmpty else { return false }
            let snapshot = try snapshotUnlocked(serverID)
            if let expected, snapshot.state != .session(expected) { return false }
            var envelope = try mutableEnvelopeUnlocked(serverID, origin: nil)
            if case .session(let value) = snapshot.state {
                let slot = Self.slotID(value)
                envelope.sessions.removeValue(forKey: slot)
                if envelope.defaultSlotID == slot { envelope.defaultSlotID = nil }
            }
            return commitInvalidationUnlocked(envelope, serverID: serverID)
        } catch { return false }
    }

    /// Sign-out selectors fail independently of shared credentials. Publish the
    /// local tombstone first so a failed selector cannot erase other personas'
    /// shared accounts while the caller believes removal was rolled back.
    private func commitInvalidationUnlocked(_ envelope: Envelope, serverID: String) -> Bool {
        do {
            let previousSelection = try selectionRead(Self.selectionKey(serverID))
            let previousRecord = try sharedRead(Self.recordKey(serverID))
            guard persistSelectionUnlocked(.signedOut, serverID: serverID) else { return false }
            if commitEnvelopeUpdateUnlocked(envelope, serverID: serverID, previousRecord: previousRecord) { return true }
            if let previousSelection { _ = selectionWrite(previousSelection, Self.selectionKey(serverID)) }
            else { _ = selectionRemove(Self.selectionKey(serverID)) }
            return false
        } catch { return false }
    }
}

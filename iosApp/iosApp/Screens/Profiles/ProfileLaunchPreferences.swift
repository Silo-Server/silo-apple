import Foundation
import OSLog
import Synchronization

@Observable
final class ProfileLaunchPreferences {
    static let shared = ProfileLaunchPreferences()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ProfileLaunchPreferences"
    )

    private let defaults: SharedDefaults
    private let persistenceOverride: ((ProfileLaunchState) -> Bool)?
    /// SwiftUI reads this state on the main thread while `AuthService`
    /// updates it from profile-switch tasks, so every access takes the lock.
    @ObservationIgnored private let storedState: Mutex<ProfileLaunchState>

    var state: ProfileLaunchState {
        access(keyPath: \.state)
        return storedState.withLock { $0 }
    }

    init(
        defaults: SharedDefaults = .shared,
        persistenceOverride: ((ProfileLaunchState) -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.persistenceOverride = persistenceOverride
        let state = ProfileLaunchState.load(from: defaults)
        self.storedState = Mutex(state)
        _ = persist(state)
    }

    var behavior: ProfileLaunchBehavior {
        get { state.behavior }
        set {
            update { state in
                guard state.behavior != newValue || state.rememberOfferPending != nil else { return }
                let previousState = state
                state.behavior = newValue
                // Choosing a behavior in Settings answers the TV's offer.
                state.rememberOfferPending = nil
                if newValue == .automatic {
                    state.backgroundedAt = nil
                }
                if !persist(state) {
                    state = previousState
                    _ = persist(state)
                }
            }
        }
    }

    var behaviorID: String {
        get { behavior.rawValue }
        set {
            guard let behavior = ProfileLaunchBehavior(rawValue: newValue) else { return }
            self.behavior = behavior
        }
    }

    /// Whether the next profile picked should be offered as the one this TV
    /// opens automatically.
    var isRememberOfferPending: Bool {
        state.rememberOfferPending == true
    }

    /// Answers the TV's one-time offer: `remember` opens the picked profile
    /// automatically from now on (Automatic); otherwise the TV keeps asking.
    @discardableResult
    func answerRememberOffer(remember: Bool) -> Bool {
        update { state in
            guard state.rememberOfferPending == true else { return true }
            let previousState = state
            state.rememberOfferPending = nil
            if remember {
                state.behavior = .automatic
                state.backgroundedAt = nil
            }
            guard persist(state) else {
                state = previousState
                return false
            }
            return true
        }
    }

    func requiresSelectionAfterBackground(at now: Date = .now) -> Bool {
        state.requiresSelectionAfterBackground(at: now)
    }

    /// Persist the start of a real background interval. Inactive transitions
    /// such as alerts and Control Center never call this path.
    @discardableResult
    func markBackgrounded(at date: Date = .now) -> Bool {
        guard behavior != .automatic else {
            return clearBackgroundedAt()
        }
        return update { state in
            let previousState = state
            state.backgroundedAt = date
            guard persist(state) else {
                state = previousState
                return false
            }
            return true
        }
    }

    /// End the current away interval after a non-expired foreground return or
    /// when background playback means the profile is still actively in use.
    @discardableResult
    func clearBackgroundedAt() -> Bool {
        update { state in
            guard state.backgroundedAt != nil else { return true }
            let previousState = state
            state.backgroundedAt = nil
            guard persist(state) else {
                state = previousState
                return false
            }
            return true
        }
    }

    // MARK: - Silo accounts (spec §6.1)

    /// What Ask For says for this Apple TV user. Nil reads as Profile Only.
    var askFor: ProfileLaunchAskFor {
        get { state.effectiveAskFor }
        set {
            update { state in
                guard state.effectiveAskFor != newValue else { return }
                let previousState = state
                state.askFor = newValue
                if !persist(state) {
                    state = previousState
                    _ = persist(state)
                }
            }
        }
    }

    /// Opening an account links it to this Apple TV user.
    @discardableResult
    func link(_ account: SiloAccountRef) -> Bool {
        mutate { state in
            guard state.linkedAccount != account.storageKey else { return false }
            state.linkedAccount = account.storageKey
            return true
        }
    }

    /// A removed account: this Apple TV user's link to it goes. Its sign-in
    /// state is forgotten separately (`forgetSignIn`).
    @discardableResult
    func forgetAccount(_ account: SiloAccountRef) -> Bool {
        mutate { state in
            guard state.linkedAccount == account.storageKey else { return false }
            state.linkedAccount = nil
            return true
        }
    }

    /// The profile remembered for a sign-in, including an entry recorded per
    /// server before sign-ins existed when its epoch is the sign-in's.
    func rememberedProfile(for key: SignInKey, accountEpoch: String?) -> RememberedProfile? {
        state.rememberedProfile(for: key, accountEpoch: accountEpoch)
    }

    func resolution(
        for key: SignInKey,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        knownProfileIDs: Set<String>? = nil,
        legacyOwnerAccountID: String?,
        now: Date = .now
    ) -> ProfileLaunchResolution {
        state.resolution(
            for: key,
            accountEpoch: accountEpoch,
            hasStoredProfileToken: hasStoredProfileToken,
            knownProfileIDs: knownProfileIDs,
            legacyOwnerAccountID: legacyOwnerAccountID,
            now: now
        )
    }

    /// Remembers the profile picked for a sign-in and ends a pending Switch
    /// Profile for it. The sign-in that took over its server's state from
    /// before sign-ins existed also drops that server-keyed state, which
    /// only it could read.
    @discardableResult
    func remember(
        profileID: String,
        requiresPIN: Bool,
        accountEpoch: String,
        for key: SignInKey,
        legacyOwnerAccountID: String?
    ) -> Bool {
        update { state in
            let previousState = state
            var remembered = state.rememberedBySignIn ?? [:]
            remembered[key.storageKey] = RememberedProfile(
                profileID: profileID,
                requiredPINAtSelection: requiresPIN,
                accountEpoch: accountEpoch
            )
            state.rememberedBySignIn = remembered
            Self.removeSelectionRequired(for: key, in: &state)
            if legacyOwnerAccountID == key.accountID {
                state.rememberedByServerID.removeValue(forKey: key.serverID)
                state.selectionRequiredServerIDs.remove(key.serverID)
            }
            state.backgroundedAt = nil
            guard persist(state) else {
                state = previousState
                return false
            }
            return true
        }
    }

    /// Explicit Switch Profile for a sign-in, saved before the profile is
    /// cleared so a killed app can't restore it under Automatic.
    @discardableResult
    func markSelectionRequired(for key: SignInKey) -> Bool {
        update { state in
            guard state.selectionRequiredSignIns?.contains(key.storageKey) != true else { return true }
            let previousState = state
            var pending = state.selectionRequiredSignIns ?? []
            pending.insert(key.storageKey)
            state.selectionRequiredSignIns = pending
            guard persist(state) else {
                state = previousState
                return false
            }
            return true
        }
    }

    /// Ends a pending Switch Profile for a sign-in, including one recorded
    /// per server for the sign-in that owns that server's old state.
    func clearSelectionRequired(for key: SignInKey, legacyOwnerAccountID: String?) {
        mutate { state in
            var changed = Self.removeSelectionRequired(for: key, in: &state)
            if legacyOwnerAccountID == key.accountID,
               state.selectionRequiredServerIDs.remove(key.serverID) != nil {
                changed = true
            }
            return changed
        }
    }

    /// A sign-in that ended or got a new session: its remembered profile and
    /// pending Switch Profile go, plus the server-keyed state from before
    /// sign-ins existed when it owns that.
    @discardableResult
    func forgetSignIn(_ key: SignInKey, legacyOwnerAccountID: String?) -> Bool {
        mutate { state in
            var changed = state.rememberedBySignIn?.removeValue(forKey: key.storageKey) != nil
            if state.rememberedBySignIn?.isEmpty == true { state.rememberedBySignIn = nil }
            if Self.removeSelectionRequired(for: key, in: &state) { changed = true }
            if legacyOwnerAccountID == key.accountID {
                if state.rememberedByServerID.removeValue(forKey: key.serverID) != nil { changed = true }
                if state.selectionRequiredServerIDs.remove(key.serverID) != nil { changed = true }
            }
            return changed
        }
    }

    /// A server removed from the device: everything this Apple TV user kept
    /// for it goes, including a link to an account on it.
    @discardableResult
    func forgetServer(_ serverID: String) -> Bool {
        mutate { state in
            var changed = false
            if state.rememberedByServerID.removeValue(forKey: serverID) != nil { changed = true }
            if state.selectionRequiredServerIDs.remove(serverID) != nil { changed = true }
            let prefix = serverID + "/"
            if let remembered = state.rememberedBySignIn {
                let kept = remembered.filter { !$0.key.hasPrefix(prefix) }
                if kept.count != remembered.count {
                    state.rememberedBySignIn = kept.isEmpty ? nil : kept
                    changed = true
                }
            }
            if let pending = state.selectionRequiredSignIns {
                let kept = pending.filter { !$0.hasPrefix(prefix) }
                if kept.count != pending.count {
                    state.selectionRequiredSignIns = kept.isEmpty ? nil : kept
                    changed = true
                }
            }
            if let linked = state.linkedAccountRef, linked.serverID == serverID {
                state.linkedAccount = nil
                changed = true
            }
            return changed
        }
    }

    /// Moves the server-keyed state recorded before sign-ins existed onto
    /// the sign-in that owns it, once that sign-in is known (plan §3.4). The
    /// remembered profile moves only when its epoch is the sign-in's; the
    /// old entries go either way, since no other account reads them.
    @discardableResult
    func adoptLegacyEntries(for key: SignInKey, accountEpoch: String?, legacyOwnerAccountID: String?) -> Bool {
        guard legacyOwnerAccountID == key.accountID else { return false }
        return mutate { state in
            var changed = false
            if let legacy = state.rememberedByServerID.removeValue(forKey: key.serverID) {
                changed = true
                if legacy.accountEpoch == accountEpoch, state.rememberedBySignIn?[key.storageKey] == nil {
                    var remembered = state.rememberedBySignIn ?? [:]
                    remembered[key.storageKey] = legacy
                    state.rememberedBySignIn = remembered
                }
            }
            if state.selectionRequiredServerIDs.remove(key.serverID) != nil {
                changed = true
                var pending = state.selectionRequiredSignIns ?? []
                pending.insert(key.storageKey)
                state.selectionRequiredSignIns = pending
            }
            return changed
        }
    }

    @discardableResult
    private static func removeSelectionRequired(for key: SignInKey, in state: inout ProfileLaunchState) -> Bool {
        guard state.selectionRequiredSignIns?.remove(key.storageKey) != nil else { return false }
        if state.selectionRequiredSignIns?.isEmpty == true { state.selectionRequiredSignIns = nil }
        return true
    }

    // MARK: - Servers' own sessions (before migration, pending legacy servers)

    /// The profile remembered for a server's own session, which credentials
    /// selected as `.legacy(serverID)` use.
    func legacyRememberedProfile(forServer serverID: String?) -> RememberedProfile? {
        guard let serverID else { return nil }
        return state.rememberedByServerID[serverID]
    }

    func legacyResolution(
        forServer serverID: String,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        knownProfileIDs: Set<String>? = nil,
        now: Date = .now
    ) -> ProfileLaunchResolution {
        state.resolution(
            for: serverID,
            accountEpoch: accountEpoch,
            hasStoredProfileToken: hasStoredProfileToken,
            knownProfileIDs: knownProfileIDs,
            now: now
        )
    }

    @discardableResult
    func rememberLegacy(
        profileID: String,
        requiresPIN: Bool,
        accountEpoch: String,
        forServer serverID: String
    ) -> Bool {
        update { state in
            let previousState = state
            state.rememberedByServerID[serverID] = RememberedProfile(
                profileID: profileID,
                requiredPINAtSelection: requiresPIN,
                accountEpoch: accountEpoch
            )
            state.selectionRequiredServerIDs.remove(serverID)
            state.backgroundedAt = nil
            guard persist(state) else {
                state = previousState
                return false
            }
            return true
        }
    }

    @discardableResult
    func markLegacySelectionRequired(forServer serverID: String) -> Bool {
        update { state in
            guard !state.selectionRequiredServerIDs.contains(serverID) else { return true }
            let previousState = state
            state.selectionRequiredServerIDs.insert(serverID)
            guard persist(state) else {
                state = previousState
                return false
            }
            return true
        }
    }

    func clearLegacySelectionRequired(forServer serverID: String) {
        update { state in
            guard state.selectionRequiredServerIDs.remove(serverID) != nil else { return }
            _ = persist(state)
        }
    }

    /// A server's own session ended or was replaced: its remembered profile
    /// and pending Switch Profile go.
    @discardableResult
    func forgetLegacyProfile(forServer serverID: String) -> Bool {
        mutate { state in
            let removedProfile = state.rememberedByServerID.removeValue(forKey: serverID) != nil
            let removedPending = state.selectionRequiredServerIDs.remove(serverID) != nil
            return removedProfile || removedPending
        }
    }

    @discardableResult
    func migrateLegacyProfile(
        profileID: String?,
        requiresPIN: Bool,
        accountEpoch: String?,
        for serverID: String
    ) -> Bool {
        if let existing = legacyRememberedProfile(forServer: serverID) {
            return existing.profileID == profileID && existing.accountEpoch == accountEpoch
        }
        guard let profileID,
              !profileID.isEmpty,
              let accountEpoch,
              !accountEpoch.isEmpty else {
            return false
        }
        return update { state in
            let previousState = state
            state.rememberedByServerID[serverID] = RememberedProfile(
                profileID: profileID,
                requiredPINAtSelection: requiresPIN,
                accountEpoch: accountEpoch
            )
            state.selectionRequiredServerIDs.remove(serverID)
            state.backgroundedAt = nil
            // A device that remembered a profile before launch state was
            // saved is not fresh: it keeps opening that profile. Saved with
            // the profile, so the two cannot disagree after a failed write.
            if state.rememberOfferPending == true {
                state.behavior = .automatic
                state.rememberOfferPending = nil
            }
            guard persist(state) else {
                state = previousState
                return false
            }
            return true
        }
    }

    /// Applies `change`, which reports whether it changed anything, and
    /// persists it with rollback. Returns false only when a change could not
    /// be saved.
    @discardableResult
    private func mutate(_ change: (inout ProfileLaunchState) -> Bool) -> Bool {
        update { state in
            let previousState = state
            guard change(&state) else { return true }
            guard persist(state) else {
                state = previousState
                return false
            }
            return true
        }
    }

    /// Applies `change` to the state under the lock, so each mutation, its
    /// persistence, and any rollback happen as one step. Observers are
    /// notified after unlocking so they can read `state`.
    private func update<Result>(_ change: (inout ProfileLaunchState) -> Result) -> Result {
        let (result, changed) = storedState.withLock { state in
            let previousState = state
            let result = change(&state)
            return (result, state != previousState)
        }
        if changed {
            withMutation(keyPath: \.state) {}
        }
        return result
    }

    private func persist(_ state: ProfileLaunchState) -> Bool {
        if let persistenceOverride, !persistenceOverride(state) {
            return false
        }
        do {
            let data = try JSONEncoder().encode(state)
            defaults.set(data, forKey: SharedStorage.profileLaunchStateKey)
            return defaults.data(forKey: SharedStorage.profileLaunchStateKey) == data
        } catch {
            Self.logger.error("Profile launch state encode failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

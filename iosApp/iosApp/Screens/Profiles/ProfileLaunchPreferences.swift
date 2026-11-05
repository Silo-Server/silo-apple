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

    func rememberedProfile(forAccount localAccountID: String?) -> RememberedProfile? {
        guard let localAccountID else { return nil }
        return state.rememberedByAccountID[localAccountID]
    }

    func resolution(
        forAccount localAccountID: String,
        accountEpoch: String?,
        hasStoredProfileToken: Bool,
        knownProfileIDs: Set<String>? = nil,
        now: Date = .now
    ) -> ProfileLaunchResolution {
        state.resolution(
            forAccount: localAccountID,
            accountEpoch: accountEpoch,
            hasStoredProfileToken: hasStoredProfileToken,
            knownProfileIDs: knownProfileIDs,
            now: now
        )
    }

    func requiresSelectionAfterBackground(at now: Date = .now) -> Bool {
        state.requiresSelectionAfterBackground(at: now)
    }

    @discardableResult
    func remember(
        profileID: String,
        requiresPIN: Bool,
        accountEpoch: String,
        forAccount localAccountID: String
    ) -> Bool {
        update { state in
            let previousState = state
            state.rememberedByAccountID[localAccountID] = RememberedProfile(
                profileID: profileID,
                requiredPINAtSelection: requiresPIN,
                accountEpoch: accountEpoch
            )
            state.selectionRequiredAccountIDs.remove(localAccountID)
            state.backgroundedAt = nil
            guard persist(state) else {
                state = previousState
                return false
            }
            return true
        }
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

    @discardableResult
    func markSelectionRequired(forAccount localAccountID: String) -> Bool {
        update { state in
            guard !state.selectionRequiredAccountIDs.contains(localAccountID) else { return true }
            let previousState = state
            state.selectionRequiredAccountIDs.insert(localAccountID)
            guard persist(state) else {
                state = previousState
                return false
            }
            return true
        }
    }

    func clearSelectionRequired(forAccount localAccountID: String) {
        update { state in
            guard state.selectionRequiredAccountIDs.remove(localAccountID) != nil else { return }
            _ = persist(state)
        }
    }

    /// Forgets what the accounts open with. Called when they are signed out
    /// or replaced by a new sign-in.
    @discardableResult
    func clearRememberedProfile(forAccounts localAccountIDs: [String]) -> Bool {
        update { state in
            let previousState = state
            for localAccountID in localAccountIDs {
                state.rememberedByAccountID.removeValue(forKey: localAccountID)
                state.selectionRequiredAccountIDs.remove(localAccountID)
            }
            guard state != previousState else { return true }
            guard persist(state) else {
                state = previousState
                return false
            }
            return true
        }
    }

    @discardableResult
    func clearRememberedProfile(forAccount localAccountID: String) -> Bool {
        clearRememberedProfile(forAccounts: [localAccountID])
    }

    /// Moves a registry entry's profile from before launch state existed
    /// into this device user's per-server memory, which
    /// `adoptLegacyServerMemory` then moves onto the server's account. Only
    /// `ServerRegistry`'s registry migration calls this.
    @discardableResult
    func migrateLegacyProfile(
        profileID: String?,
        requiresPIN: Bool,
        accountEpoch: String?,
        for serverID: String
    ) -> Bool {
        if let existing = state.rememberedByServerID[serverID] {
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

    /// Moves this device user's per-server memory from before accounts onto
    /// the account that adopted each server's data (`owners`: server ID to
    /// `localAccountId`). Memory for a server no account adopted is dropped.
    /// A no-op once nothing per-server is left. False when the move could
    /// not be saved.
    @discardableResult
    func adoptLegacyServerMemory(owners: [String: String]) -> Bool {
        update { state in
            guard !state.rememberedByServerID.isEmpty || !state.selectionRequiredServerIDs.isEmpty else { return true }
            let previousState = state
            for (serverID, remembered) in state.rememberedByServerID {
                guard let owner = owners[serverID], state.rememberedByAccountID[owner] == nil else { continue }
                state.rememberedByAccountID[owner] = remembered
            }
            for serverID in state.selectionRequiredServerIDs {
                if let owner = owners[serverID] { state.selectionRequiredAccountIDs.insert(owner) }
            }
            state.rememberedByServerID = [:]
            state.selectionRequiredServerIDs = []
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

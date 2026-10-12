#if os(iOS)
import Foundation
import Synchronization

/// One server and profile this device is registered with for pushes, and
/// the display token that server minted for it. A push that names its
/// server and profile is displayed with exactly this target, whichever
/// server and profile are active.
struct ApplePushDisplayTarget: Codable, Equatable, Sendable {
    /// The deployment identity (`server_id`) pushes name. Nil when neither
    /// the registration receipt nor the saved server knew it; such a target
    /// serves only pushes that name no target.
    let serverID: String?
    let profileID: String
    /// The saved server (`ServerEntry.id`) that registered: its stored
    /// session renews the token, and signing out of it removes the target.
    let registryServerID: String
    let serverURL: String
    let displayToken: String
    /// RFC 3339 expiry of `displayToken`. Nil renews the token at the next
    /// registration pass.
    let expiresAt: String?
}

/// The display targets, kept as one shared Keychain item: the extension can
/// read it on a locked phone (`AfterFirstUnlock`), and a write never pairs
/// a token with another target's server or profile. Only the app writes.
struct ApplePushDisplayTargetStore: Sendable {
    /// `TokenStore` and `ApplePushRegistrar` change targets from different
    /// actors. Each read-modify-write holds this lock so neither drops the
    /// other's change.
    private static let writes = Mutex(())

    var keychain: SharedKeychain = SharedKeychain(audience: .currentUser)

    func targets() -> [ApplePushDisplayTarget] {
        (try? load()) ?? []
    }

    /// Every target claiming the server and profile a push names. A
    /// deployment identity is self-asserted, so more than one means saved
    /// servers disagree about who that deployment is, and none can be
    /// trusted.
    func targets(serverID: String, profileID: String) -> [ApplePushDisplayTarget] {
        targets().filter { $0.serverID == serverID && $0.profileID == profileID }
    }

    func target(registeredBy registryServerID: String) -> ApplePushDisplayTarget? {
        targets().first { $0.registryServerID == registryServerID }
    }

    /// Stores `target` in place of the one its saved server registered
    /// before. A saved server never replaces another's target, even one
    /// claiming the same deployment: a server could claim any identity.
    /// One deployment saved under two addresses still ends up with one
    /// target, because the server refuses the second address's
    /// installation proof.
    @discardableResult
    func save(_ target: ApplePushDisplayTarget) -> Bool {
        update { targets in
            targets.removeAll { $0.registryServerID == target.registryServerID }
            targets.append(target)
        }
    }

    @discardableResult
    func removeTargets(registeredBy registryServerID: String) -> Bool {
        update { $0.removeAll { $0.registryServerID == registryServerID } }
    }

    /// A Keychain read failure leaves the stored targets as they are rather
    /// than overwriting them with a partial list.
    @discardableResult
    private func update(_ change: (inout [ApplePushDisplayTarget]) -> Void) -> Bool {
        Self.writes.withLock { _ in
            guard var targets = try? load() else { return false }
            let previous = targets
            change(&targets)
            guard targets != previous else { return true }
            guard !targets.isEmpty else {
                return keychain.delete(SharedStorage.applePushDisplayTargetsAccount)
            }
            guard let data = try? JSONEncoder().encode(targets) else { return false }
            return keychain.set(String(decoding: data, as: UTF8.self), for: SharedStorage.applePushDisplayTargetsAccount)
        }
    }

    /// `[]` when nothing is stored. Throws when the Keychain cannot be read.
    private func load() throws -> [ApplePushDisplayTarget] {
        guard let raw = try keychain.getChecked(SharedStorage.applePushDisplayTargetsAccount) else { return [] }
        // A record that does not decode is useless to every reader, so the
        // next write replaces it.
        return (try? JSONDecoder().decode([ApplePushDisplayTarget].self, from: Data(raw.utf8))) ?? []
    }
}
#endif

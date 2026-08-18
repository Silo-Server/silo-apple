import Foundation
@testable import Silo

/// Process-local `KeychainBackend` for tests whose subject is the logic
/// *above* the Keychain — `TokenStore` credential commits, `ServerRegistry`
/// profile migrations — rather than the Keychain itself.
///
/// The simulator test host is unsigned (`CODE_SIGNING_ALLOWED=NO`) and so
/// carries no `application-identifier` entitlement: every `SecItem*` call it
/// makes returns `errSecMissingEntitlement (-34018)`. A test that lets those
/// failures through is not asserting the behaviour in its name, it is
/// asserting that a uniformly dead store stays dead.
///
/// Tests whose subject *is* the real Keychain (`BrandMigrationTests`) must
/// keep probing `SharedKeychain.set` and `XCTSkipUnless`-ing instead: a fake
/// cannot stand in for `SecItem` semantics, so passing against one would say
/// nothing about the migration it claims to pin.
///
/// Entries are keyed the way `SharedKeychain.baseQuery` addresses them on
/// iOS: service + access group + account. Audience is deliberately not part
/// of the key — it only reaches the query through
/// `kSecUseUserIndependentKeychain`, which is tvOS-only.
final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    private struct Entry: Hashable {
        let service: String
        let accessGroup: String?
        let account: String
    }

    private let lock = NSLock()
    private var values: [Entry: String] = [:]

    func value(service: String, accessGroup: String?, account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[Entry(service: service, accessGroup: accessGroup, account: account)]
    }

    func setValue(
        _ value: String,
        service: String,
        accessGroup: String?,
        account: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values[Entry(service: service, accessGroup: accessGroup, account: account)] = value
        return true
    }

    func removeValue(service: String, accessGroup: String?, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: Entry(service: service, accessGroup: accessGroup, account: account))
        return true
    }
}

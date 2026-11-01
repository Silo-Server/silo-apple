import Foundation

/// A name someone gave a saved server, shown in place of the name the server
/// advertises.
///
/// Nicknames belong to a person, not a device: each device keeps the current
/// user's records locally and syncs them through that user's iCloud account.
/// A cleared record (`name == nil`) is kept with its time, so going back to
/// the server's own name reaches the other devices too.
struct ServerNickname: Codable, Equatable {
    /// Registry id of the address that was named.
    var serverId: String
    /// Deployment identity of that address when it was named, so another
    /// address of the same server can still find the name.
    var verifiedServerId: String?
    var name: String?
    var updatedAt: Date
    /// Set on a local record this device copied from the record for another
    /// address of the same deployment. A copy is never published, and a
    /// record for this address, or a newer copy, replaces it; an explicit
    /// name for this address never gives way to another address's name.
    var inheritedFrom: String?

    /// Longest nickname kept; anything longer is cut to this.
    static let lengthLimit = 60

    /// A typed name as stored: trimmed, at most `lengthLimit` characters, and
    /// nil when blank.
    static func normalized(_ name: String?) -> String? {
        guard let trimmed = ServerIdentity.usable(name) else { return nil }
        return String(trimmed.prefix(lengthLimit))
    }
}

/// How synced nickname records are matched to saved servers and merged.
enum ServerNicknameSync {
    /// Records kept in the synced copy, newest first. Bounds the store when
    /// many servers have been named or cleared over the years.
    static let recordLimit = 100

    /// The newest record for `entry`'s own address (same origin, see
    /// ``ServerRegistry/serverIdsMatch(_:_:)``).
    static func addressRecord(for entry: ServerEntry, in records: [ServerNickname]) -> ServerNickname? {
        records
            .filter { ServerRegistry.serverIdsMatch($0.serverId, entry.id) }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    /// The newest record for another address of `entry`'s deployment. It
    /// names the server only where its own address has no record, so that
    /// "Home (LAN)" and "Home (Remote)" can keep different names.
    static func deploymentRecord(for entry: ServerEntry, in records: [ServerNickname]) -> ServerNickname? {
        guard let identity = ServerIdentity.usable(entry.verifiedServerId) else { return nil }
        return records
            .filter { $0.verifiedServerId == identity && !ServerRegistry.serverIdsMatch($0.serverId, entry.id) }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    /// `synced` with `record` replacing every record for the same address.
    static func publishing(_ record: ServerNickname, into synced: [ServerNickname]) -> [ServerNickname] {
        var records = synced.filter { !ServerRegistry.serverIdsMatch($0.serverId, record.serverId) }
        records.append(record)
        return Array(records.sorted { $0.updatedAt > $1.updatedAt }.prefix(recordLimit))
    }
}

/// Where nickname records sync between one person's devices.
protocol ServerNicknameCloud: AnyObject {
    func load() -> [ServerNickname]
    func save(_ records: [ServerNickname])
    /// Called on the main queue after another device changes the records,
    /// with `true` when the store now belongs to a different iCloud account.
    var onExternalChange: ((_ accountChanged: Bool) -> Void)? { get set }
}

/// iCloud key-value storage for nickname records, shared by the iPhone, iPad
/// and Apple TV apps through one store identifier (see the
/// `ubiquity-kvstore-identifier` entitlement).
///
/// The records live under one key as JSON: key names are capped at 64 bytes,
/// which registry ids can exceed. iCloud keeps whichever device wrote a key
/// last, so the registry merges before every write rather than replacing.
/// Without the entitlement or an iCloud account the store quietly keeps
/// nothing, and the registry's local copy stays the source of truth.
final class UbiquitousServerNicknameCloud: ServerNicknameCloud {
    static let key = "siloServerNicknames.v1"

    var onExternalChange: ((_ accountChanged: Bool) -> Void)?

    private let store: NSUbiquitousKeyValueStore
    private var observer: NSObjectProtocol?

    init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let accountChanged = reason == NSUbiquitousKeyValueStoreAccountChange
            // An account change or first sync may list no keys; only skip a
            // change that names other keys.
            if !accountChanged,
               let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
               !keys.contains(Self.key) {
                return
            }
            self?.onExternalChange?(accountChanged)
        }
        // Asks iCloud for changes made while the app was not running.
        store.synchronize()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func load() -> [ServerNickname] {
        guard let data = store.data(forKey: Self.key),
              let records = try? JSONDecoder().decode([ServerNickname].self, from: data) else { return [] }
        return records
    }

    func save(_ records: [ServerNickname]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        store.set(data, forKey: Self.key)
    }
}

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

    /// The record that names `entry`: the newest one for the same address
    /// (same origin, see ``ServerRegistry/serverIdsMatch(_:_:)``), else the
    /// newest one for another address of the same deployment. The address
    /// wins so that "Home (LAN)" and "Home (Remote)" can keep different names.
    static func record(for entry: ServerEntry, in records: [ServerNickname]) -> ServerNickname? {
        let sameAddress = records.filter { ServerRegistry.serverIdsMatch($0.serverId, entry.id) }
        if let newest = sameAddress.max(by: { $0.updatedAt < $1.updatedAt }) {
            return newest
        }
        guard let identity = ServerIdentity.usable(entry.verifiedServerId) else { return nil }
        return records
            .filter { $0.verifiedServerId == identity }
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
    /// Called on the main queue after another device changes the records.
    var onExternalChange: (() -> Void)? { get set }
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

    var onExternalChange: (() -> Void)?

    private let store: NSUbiquitousKeyValueStore
    private var observer: NSObjectProtocol?

    init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            // An account change or first sync may list no keys; only skip a
            // change that names other keys.
            if let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
               !keys.contains(Self.key) {
                return
            }
            self?.onExternalChange?()
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

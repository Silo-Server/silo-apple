import Foundation
import OSLog

/// Lifecycle of one durable command. Exactly one of the three outcomes in
/// `docs/native-api-v2.md` applies to a dispatched mutation:
///
/// - definite success: `applied`;
/// - definite failure (never left the device, non-success status, terminal
///   recovery): `failed`;
/// - uncertain (sent, no answer): stays `uncertain` and is held until the user
///   discards it. It is never replayed automatically.
enum DurableCommandState: String, Codable, Equatable, Sendable {
    /// Recorded, not yet handed to the transport.
    case prepared
    /// Claimed for dispatch. A record found in this state after a relaunch
    /// was in flight when the process died; its outcome is unknown.
    case uncertain
    case applied
    case failed

    var isTerminal: Bool { self == .applied || self == .failed }
}

/// Terminal resolution of a command.
enum DurableCommandResolution: Equatable, Sendable {
    case applied
    case failed

    var state: DurableCommandState {
        switch self {
        case .applied: return .applied
        case .failed: return .failed
        }
    }
}

/// A record every write surface persists through `DurableCommandStore`.
///
/// `authority` is the nonsecret durable owner captured when the command was
/// prepared (server, account, epoch, profile, device). The store never
/// interprets it; `snapshot(owner:)` filters with a predicate the caller
/// supplies so each surface decides what "same owner" means for its commands.
protocol DurableCommandRecord: Codable, Sendable {
    associatedtype Authority: Codable & Sendable

    var id: UUID { get }
    var authority: Authority { get }
    var state: DurableCommandState { get set }
    var updatedAt: Date { get set }
}

enum DurableCommandStoreError: Error, Equatable {
    /// `append` was given an id the store already holds.
    case duplicateID(UUID)
    /// The id names no record.
    case unknownID(UUID)
    /// `claim` on a record that is not `prepared`, `resolve(.applied)` on a
    /// record that was never claimed, or any transition out of a terminal
    /// state.
    case invalidTransition(id: UUID, from: DurableCommandState)
}

/// One JSON file of durable command records with an atomic writer, reaping
/// inside `persist`, and no I/O on the main actor.
///
/// Modeled on `PendingReportStore`: records are written with
/// `Data.write(options: .atomic)`, terminal records older than
/// `expiryInterval` are dropped every time the file is persisted, and a file
/// that cannot be decoded is logged and treated as empty rather than crashing
/// or being trusted. The actor is the lock; there is no `flock`. Every
/// method runs on the actor's executor, never on the main actor.
///
/// Write surfaces specialize this with their own `Record`. They do not write
/// another store.
actor DurableCommandStore<Record: DurableCommandRecord> {
    /// Terminal records older than this are dropped by `persist`.
    static var expiryInterval: TimeInterval { 7 * 24 * 60 * 60 }

    private static var logger: Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo", category: "DurableCommandStore")
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var records: [Record] = []
    private var loaded = false
    /// The document bytes last read from or written to `fileURL`, so
    /// `persist` can skip the write when nothing changed without re-reading
    /// the file.
    private var persistedDocument: Data?

    /// - Parameters:
    ///   - fileURL: the JSON document. Its parent directory is created on the
    ///     first write and excluded from backup.
    ///   - now: the clock used for `updatedAt` stamps and reaping; injected
    ///     for tests.
    init(fileURL: URL, fileManager: FileManager = .default, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.now = now
    }

    // MARK: Reads

    /// Every live record, after loading the file on first use. Terminal
    /// records past `expiryInterval` are never returned, even before the next
    /// `persist` rewrites the file without them.
    func all() -> [Record] {
        ensureLoaded()
        return records
    }

    func record(id: UUID) -> Record? {
        ensureLoaded()
        return records.first { $0.id == id }
    }

    /// The records whose authority the caller recognizes as its own. The
    /// predicate is the surface's durable-owner comparison; the store does not
    /// guess at it.
    func snapshot(owner isOwned: @Sendable (Record.Authority) -> Bool) -> [Record] {
        ensureLoaded()
        return records.filter { isOwned($0.authority) }
    }

    // MARK: Writes

    /// Records a prepared command. The record's `state` is forced to
    /// `prepared` and `updatedAt` to now; the caller supplies everything else.
    func append(_ record: Record) throws {
        ensureLoaded()
        guard !records.contains(where: { $0.id == record.id }) else {
            throw DurableCommandStoreError.duplicateID(record.id)
        }
        var stored = record
        stored.state = .prepared
        stored.updatedAt = now()
        records.append(stored)
        try persist()
    }

    /// Moves a `prepared` record to `uncertain` immediately before dispatch,
    /// so a crash between the claim and the answer leaves the hold in place.
    /// A record that is already `uncertain` cannot be claimed again: that
    /// would be an automatic replay.
    @discardableResult
    func claim(id: UUID) throws -> Record {
        ensureLoaded()
        let index = try index(of: id)
        guard records[index].state == .prepared else {
            throw DurableCommandStoreError.invalidTransition(id: id, from: records[index].state)
        }
        records[index].state = .uncertain
        records[index].updatedAt = now()
        try persist()
        return records[index]
    }

    /// Records the terminal outcome of a command. `.applied` requires a
    /// prior `claim` (a success is always the answer to a dispatch);
    /// `.failed` is also accepted from `prepared`, because a pre-dispatch
    /// guard can refuse a command before it is ever claimed. Terminal records
    /// stay for `expiryInterval` so a surface can still refuse a duplicate,
    /// then `persist` reaps them. A second resolution throws.
    @discardableResult
    func resolve(id: UUID, _ resolution: DurableCommandResolution) throws -> Record {
        ensureLoaded()
        let index = try index(of: id)
        let current = records[index].state
        switch (current, resolution) {
        case (.uncertain, _), (.prepared, .failed):
            break
        default:
            throw DurableCommandStoreError.invalidTransition(id: id, from: current)
        }
        records[index].state = resolution.state
        records[index].updatedAt = now()
        try persist()
        return records[index]
    }

    /// Removes a record in any state. This is the user-visible exit from an
    /// uncertain hold ("Discard held change"); it is also how sign-out and a
    /// server switch clear a barrier without knowing its outcome.
    func discard(id: UUID) throws {
        ensureLoaded()
        records.remove(at: try index(of: id))
        try persist()
    }

    /// Removes every record the predicate selects. Sign-out and server switch
    /// use this with their owner predicate.
    func discardAll(where shouldDiscard: @Sendable (Record) -> Bool) throws {
        ensureLoaded()
        let before = records.count
        records.removeAll(where: shouldDiscard)
        guard records.count != before else { return }
        try persist()
    }

    /// Writes the file. Terminal records older than `expiryInterval` are
    /// dropped first. Nothing is written when the encoded document equals the
    /// one already on disk; the return value says whether a write happened.
    @discardableResult
    func persist() throws -> Bool {
        ensureLoaded()
        reap()
        let data = try Self.makeEncoder().encode(Document(records: records))
        if data == persistedDocument {
            return false
        }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.excludeFromBackup(directory)
        try data.write(to: fileURL, options: .atomic)
        persistedDocument = data
        return true
    }

    // MARK: Internals

    private struct Document: Codable {
        var version = 1
        var records: [Record]
    }

    private func index(of id: UUID) throws -> Int {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw DurableCommandStoreError.unknownID(id)
        }
        return index
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try Self.makeDecoder().decode(Document.self, from: data).records
            persistedDocument = data
        } catch {
            // A corrupt or foreign file must not crash the app or be trusted.
            // Start empty; the next persist replaces it. The cause is logged
            // because a silent reset would hide a real bug (F47).
            Self.logger.error(
                "Durable command file unreadable; starting empty: \(String(describing: error), privacy: .public) file=\(self.fileURL.lastPathComponent, privacy: .public)"
            )
            records = []
            persistedDocument = nil
        }
        // Reaped records are invisible to readers immediately; the file is
        // rewritten without them on the next persist.
        reap()
    }

    private func reap() {
        let cutoff = now().addingTimeInterval(-Self.expiryInterval)
        records.removeAll { $0.state.isTerminal && $0.updatedAt < cutoff }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }
}

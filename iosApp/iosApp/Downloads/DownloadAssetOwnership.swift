import Foundation
import Darwin

struct DownloadLocalAuthority: Codable, Equatable, Sendable {
    let serverID: String
    let origin: String
    let accountID: String
    let accountEpoch: UUID
    let profileID: String

    init(_ auth: CapturedDurableAccountAuth) throws {
        guard case .persistentServer = auth.request.credentialOwner,
              let profile = auth.request.profileId, !profile.isEmpty else { throw DownloadOwnershipError.wrongAuthority }
        serverID = auth.request.account.serverId
        origin = auth.request.account.serverURL
        accountID = auth.accountID
        accountEpoch = auth.accountEpoch
        profileID = profile
    }
}

enum DownloadOwnershipError: Error {
    case disabled, wrongAuthority, corrupt, stale, unknownTask, missingAsset, incompleteAction
}

struct DownloadAssetLease: Codable, Equatable, Sendable {
    let downloadID: String
    let authority: DownloadLocalAuthority
    let generation: UUID
}

struct DownloadTaskBinding: Codable, Equatable, Sendable {
    let transferID: UUID
    let sessionID: String
    let taskID: Int
    let lease: DownloadAssetLease
    let operationID: UUID
}

struct DownloadParkedArrival: Sendable {
    let arrivalID: UUID
    let sessionID: String
    let taskID: Int
    let transferID: UUID?
    let status: Int
    let directory: URL
    var payload: URL { directory.appendingPathComponent("payload") }
}

/// The delegate may only create an exclusive parking location. It never adopts,
/// overwrites, or removes an existing staged file, including an unknown old task.
enum DownloadArrivalParking {
    private struct Metadata: Codable {
        let arrivalID: UUID
        let sessionID: String
        let taskID: Int
        let transferID: UUID?
        let status: Int
    }

    static func recover(directory: URL) throws -> DownloadParkedArrival {
        let metadata = try JSONDecoder().decode(Metadata.self,
            from: Data(contentsOf: directory.appendingPathComponent("arrival.json")))
        guard directory.lastPathComponent == metadata.arrivalID.uuidString,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("payload").path) else {
            throw DownloadOwnershipError.corrupt
        }
        return DownloadParkedArrival(arrivalID: metadata.arrivalID, sessionID: metadata.sessionID,
            taskID: metadata.taskID, transferID: metadata.transferID, status: metadata.status, directory: directory)
    }

    static func park(data: Data, root: URL, sessionID: String, taskID: Int,
                     transferID: UUID?, status: Int) throws -> DownloadParkedArrival {
        let arrival = try prepare(root: root, sessionID: sessionID, taskID: taskID, transferID: transferID, status: status)
        try data.write(to: arrival.payload, options: .withoutOverwriting)
        return arrival
    }

    private static func prepare(root: URL, sessionID: String, taskID: Int,
                                transferID: UUID?, status: Int) throws -> DownloadParkedArrival {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let arrival = DownloadParkedArrival(arrivalID: id, sessionID: sessionID, taskID: taskID,
            transferID: transferID, status: status, directory: directory)
        let metadata = Metadata(arrivalID: id, sessionID: sessionID, taskID: taskID, transferID: transferID, status: status)
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("arrival.json"), options: .atomic)
        return arrival
    }

    static func park(source: URL, root: URL, sessionID: String, taskID: Int,
                     transferID: UUID?, status: Int) throws -> DownloadParkedArrival {
        let arrival = try prepare(root: root, sessionID: sessionID, taskID: taskID, transferID: transferID, status: status)
        try FileManager.default.moveItem(at: source, to: arrival.payload)
        return arrival
    }
}

private struct DownloadAssetEntry: Codable {
    var lease: DownloadAssetLease
    var files: Set<String>
}

private struct DownloadAssetAction: Codable {
    let id: UUID
    let lease: DownloadAssetLease
    let filename: String
    var copied: Bool
    var committed: Bool
    var removal: Bool = false
}

private struct DownloadPhysicalScope: Codable, Equatable {
    let serverID: String
    let origin: String
    let profileID: String

    init(_ authority: DownloadLocalAuthority) {
        serverID = authority.serverID
        origin = authority.origin
        profileID = authority.profileID
    }
}

private struct DownloadAssetManifest: Codable {
    var scope: DownloadPhysicalScope?
    var version = 1
    var revision: UInt64 = 0
    var assets: [String: DownloadAssetEntry] = [:]
    var tasks: [UUID: DownloadTaskBinding] = [:]
    var actions: [UUID: DownloadAssetAction] = [:]
    var transferredLegacy = false
}

/// Common physical-scope arbitration across account epochs. All filesystem effects
/// use this lock before any epoch-state lock; no method suspends or performs network IO.
struct DownloadAssetOwnership: Sendable {
    let root: URL
    private var directory: URL { root.appendingPathComponent("assets", isDirectory: true) }
    private var manifestURL: URL { directory.appendingPathComponent("ownership.json") }

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("ownership.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }

    private func read() throws -> DownloadAssetManifest {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return DownloadAssetManifest() }
        let value = try JSONDecoder().decode(DownloadAssetManifest.self, from: Data(contentsOf: manifestURL))
        guard value.version == 1 else { throw DownloadOwnershipError.corrupt }
        return value
    }

    private func write(_ input: DownloadAssetManifest) throws {
        var value = input
        guard value.revision < UInt64.max else { throw DownloadOwnershipError.corrupt }
        value.revision += 1
        try JSONEncoder().encode(value).write(to: manifestURL, options: .atomic)
    }

    /// Only the migration gate calls this while holding the common lock.
    func markLegacyTransferredLocked(authority: DownloadLocalAuthority) throws {
        var value = try read()
        try bindScope(authority, in: &value)
        value.transferredLegacy = true
        try write(value)
    }

    private func bindScope(_ authority: DownloadLocalAuthority, in value: inout DownloadAssetManifest) throws {
        let expected = DownloadPhysicalScope(authority)
        guard value.scope == nil || value.scope == expected else { throw DownloadOwnershipError.wrongAuthority }
        value.scope = expected
    }

    func requireLegacyWriterLocked() throws {
        guard !(try read()).transferredLegacy else { throw DownloadOwnershipError.stale }
    }

    func currentLease(downloadID: String) throws -> DownloadAssetLease? {
        try withLock { try read().assets[downloadID]?.lease }
    }

    func adopt(downloadID: String, authority: DownloadLocalAuthority, retainedFiles: Set<String>) throws -> DownloadAssetLease {
        try withLock {
            var value = try read()
            try bindScope(authority, in: &value)
            guard !downloadID.isEmpty, downloadID != ".", downloadID != "..",
                  !downloadID.contains("/"), !downloadID.contains("\\") else { throw DownloadOwnershipError.corrupt }
            if let existing = value.assets[downloadID] {
                guard existing.lease.authority == authority else { throw DownloadOwnershipError.stale }
                return existing.lease
            }
            let lease = DownloadAssetLease(downloadID: downloadID, authority: authority, generation: UUID())
            let retained = retainedFiles.union(value.assets[downloadID]?.files ?? [])
            value.assets[downloadID] = DownloadAssetEntry(lease: lease, files: retained)
            try write(value)
            return lease
        }
    }

    private func require(_ lease: DownloadAssetLease, in value: DownloadAssetManifest) throws {
        guard value.scope == DownloadPhysicalScope(lease.authority),
              value.assets[lease.downloadID]?.lease == lease else { throw DownloadOwnershipError.stale }
    }

    func validateLocked(_ lease: DownloadAssetLease) throws {
        try require(lease, in: read())
    }

    func bind(_ binding: DownloadTaskBinding) throws {
        try withLock {
            var value = try read()
            try require(binding.lease, in: value)
            guard value.tasks[binding.transferID] == nil else { throw DownloadOwnershipError.stale }
            value.tasks[binding.transferID] = binding
            try write(value)
        }
    }

    func binding(transferID: UUID?, taskID: Int, sessionID: String) throws -> DownloadTaskBinding {
        try withLock {
            let value = try read()
            guard let transferID, let binding = value.tasks[transferID], binding.taskID == taskID,
                  binding.sessionID == sessionID else { throw DownloadOwnershipError.unknownTask }
            try require(binding.lease, in: value)
            return binding
        }
    }

    /// A unique destination is copied first; state publication runs under the same
    /// asset lease. Failed state writes leave the action and both byte copies for recovery.
    func attach(source: URL, suffix: String, lease: DownloadAssetLease,
                publish: (String) throws -> Void) throws {
        try withLock {
            var value = try read()
            try require(lease, in: value)
            guard !suffix.isEmpty, suffix.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw DownloadOwnershipError.corrupt }
            let id = UUID()
            let filename = "asset-\(id.uuidString).\(suffix)"
            let targetDirectory = root.appendingPathComponent(lease.downloadID, isDirectory: true)
            guard targetDirectory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { throw DownloadOwnershipError.corrupt }
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            value.actions[id] = DownloadAssetAction(id: id, lease: lease, filename: filename, copied: false, committed: false)
            try write(value)
            try FileManager.default.copyItem(at: source, to: targetDirectory.appendingPathComponent(filename))
            value.actions[id]?.copied = true
            try write(value)
            try publish(filename)
            value.actions[id]?.committed = true
            value.assets[lease.downloadID]?.files.insert(filename)
            try write(value)
        }
    }

    /// Recovery never guesses that a partial physical action authorized removal.
    /// It retains its unique file as owned recovery material and closes the journal
    /// entry before new work; the epoch state remains the source of visible references.
    func recoverLocked(authority: DownloadLocalAuthority) throws {
        var value = try read()
        try bindScope(authority, in: &value)
        var changed = false
        for (id, action) in value.actions where !action.committed && action.lease.authority == authority {
            guard value.assets[action.lease.downloadID]?.lease == action.lease else { continue }
            if action.copied && !action.removal { value.assets[action.lease.downloadID]?.files.insert(action.filename) }
            value.actions[id]?.committed = true
            changed = true
        }
        if changed { try write(value) }
    }

    /// Explicit adoption requires the previous physical generation. Ordinary old
    /// actor commands cannot reclaim assets after a newer epoch has adopted them.
    func adoptReplacing(_ previous: DownloadAssetLease, authority: DownloadLocalAuthority) throws -> DownloadAssetLease {
        try withLock {
            var value = try read()
            try require(previous, in: value)
            try bindScope(authority, in: &value)
            guard !value.actions.values.contains(where: { $0.lease.downloadID == previous.downloadID && !$0.committed }) else {
                throw DownloadOwnershipError.incompleteAction
            }
            let lease = DownloadAssetLease(downloadID: previous.downloadID, authority: authority, generation: UUID())
            value.assets[previous.downloadID]?.lease = lease
            try write(value)
            return lease
        }
    }

    func resume(_ binding: DownloadTaskBinding, operation: () -> Void) throws {
        try withLock {
            let value = try read()
            guard value.tasks[binding.transferID] == binding else { throw DownloadOwnershipError.unknownTask }
            try require(binding.lease, in: value)
            operation()
        }
    }

    /// Delete only individually tracked files under the current generation. Old epoch
    /// metadata and unknown directories cannot authorize directory-wide deletion.
    func remove(lease: DownloadAssetLease, publish: () throws -> Void) throws {
        try withLock {
            var value = try read()
            try require(lease, in: value)
            guard !value.actions.values.contains(where: { $0.lease.downloadID == lease.downloadID && !$0.committed }) else {
                throw DownloadOwnershipError.incompleteAction
            }
            let actionID = UUID()
            value.actions[actionID] = DownloadAssetAction(id: actionID, lease: lease, filename: "", copied: false, committed: false, removal: true)
            try write(value)
            // Removing the record first can leave recoverable bytes after a crash;
            // deleting bytes first could publish a record pointing at lost media.
            try publish()
            for filename in value.assets[lease.downloadID]?.files ?? [] {
                guard URL(fileURLWithPath: filename).lastPathComponent == filename else { throw DownloadOwnershipError.corrupt }
                let path = root.appendingPathComponent(lease.downloadID, isDirectory: true).appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            }
            value.assets.removeValue(forKey: lease.downloadID)
            value.actions[actionID]?.committed = true
            try write(value)
        }
    }
}

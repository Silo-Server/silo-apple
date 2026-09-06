import Foundation
import OSLog

/// Off-main persistence for the offline-downloads blob. Keeps disk I/O and
/// JSON (de)serialization off the MainActor; `DownloadManager` owns the
/// in-memory `@Observable` truth and reads/writes through this actor.
actor DownloadStore {
    static let shared = DownloadStore()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Downloads"
    )

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// Missing is an empty inventory; corrupt or unsupported bytes are retained and
    /// reported. This boundary is read/migration-only after whole-blob transfer.
    func load(serverId: String, profileId: String) throws -> DownloadStoreFile {
        guard !serverId.isEmpty, !profileId.isEmpty else { throw DownloadOwnershipError.wrongAuthority }
        let url = DownloadFilePaths.storeFileURL(serverId: serverId, profileId: profileId)
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let file = try decoder.decode(DownloadStoreFile.self, from: Data(contentsOf: url))
        guard file.version == DownloadStoreFile.currentVersion else { throw DownloadOwnershipError.corrupt }
        return file
    }

    /// The common asset lock fences even a delayed pre-transfer save. No active
    /// manager calls this whole-blob compatibility boundary after transfer.
    func save(_ file: DownloadStoreFile, serverId: String, profileId: String) throws {
        guard !serverId.isEmpty, !profileId.isEmpty else { throw DownloadOwnershipError.wrongAuthority }
        let root = DownloadFilePaths.scopeDirectory(serverId: serverId, profileId: profileId)
        let assets = DownloadAssetOwnership(root: root)
        try assets.withLock {
            try assets.requireLegacyWriterLocked()
            try encoder.encode(file).write(to: root.appendingPathComponent("store.json"), options: .atomic)
        }
    }

    func loadManifest(at url: URL) -> OfflineManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(OfflineManifest.self, from: data)
    }
}

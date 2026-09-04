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

    /// Load the persisted blob for a scope, or a fresh empty one. Tolerant
    /// of a missing/corrupt file (returns empty so the feature self-heals).
    func load(serverId: String, profileId: String) -> DownloadStoreFile {
        guard !serverId.isEmpty, !profileId.isEmpty else { return .empty }
        let url = DownloadFilePaths.storeFileURL(serverId: serverId, profileId: profileId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return .empty
        }
        do {
            var file = try decoder.decode(DownloadStoreFile.self, from: data)
            if file.version != DownloadStoreFile.currentVersion {
                file.version = DownloadStoreFile.currentVersion
            }
            return file
        } catch {
            Self.logger.error("Download store decode failed; starting empty: \(String(describing: error), privacy: .public)")
            return .empty
        }
    }

    /// Atomically persist the blob for a scope. No-op for an empty scope.
    func save(_ file: DownloadStoreFile, serverId: String, profileId: String) {
        guard !serverId.isEmpty, !profileId.isEmpty else { return }
        let url = DownloadFilePaths.storeFileURL(serverId: serverId, profileId: profileId)
        do {
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Download store save failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Persist an offline manifest beside its media file. Uses the same bare
    /// coder pair as `loadManifest` so the on-disk round-trip is consistent.
    func saveManifest(_ manifest: OfflineManifest, to url: URL) {
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func loadManifest(at url: URL) -> OfflineManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(OfflineManifest.self, from: data)
    }
}

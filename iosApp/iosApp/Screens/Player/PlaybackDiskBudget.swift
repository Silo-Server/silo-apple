import Foundation

/// Shared disk-budget policy for the playback caches that spill to the
/// temp/caches volume (the origin source cache and the loopback segment
/// store). Both tiers size their retention against the same clamp so disk
/// pressure behaves predictably when they are active together.
enum PlaybackDiskBudget {
    /// Free space on the volume backing the app sandbox.
    /// `volumeAvailableCapacityForImportantUsage` is unavailable on tvOS and
    /// the plain capacity key can report 0 for the sandboxed temp volume
    /// there, so use the filesystem-attributes helper (valid on every
    /// platform).
    static func freeDiskSpaceBytes() -> Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// Pure clamp for a spill retention budget: quarter of the available
    /// volume capacity, capped at 2 GiB, floored at 512 MiB. An unknown or
    /// non-positive capacity reading means the query is broken, not that the
    /// disk is full — use the cap, never 0: a zero budget disables pruning
    /// outright and deadlocks a budget-gated producer once the spill gate
    /// fills.
    static func retentionBudget(availableBytes: Int64?) -> Int64 {
        let cap: Int64 = 2 << 30
        let floor: Int64 = 512 << 20
        guard let availableBytes, availableBytes > 0 else { return cap }
        return min(cap, max(floor, availableBytes / 4))
    }

    /// One-shot per process: delete stale spill directories left behind by a
    /// force-killed predecessor (their deinit cleanup never ran, and a
    /// stranded directory can hold up to the full retention budget). Only
    /// directories older than an hour qualify. That age guard plus UUID
    /// session names means cleanup can never race a newly-created active
    /// session, and also avoids disturbing a cache owned by another process.
    /// Deletions run on a utility queue so startup is not blocked.
    static let sweepOrphanedSpillDirectories: Void = {
        let fm = FileManager.default
        let staleBefore = Date().addingTimeInterval(-60 * 60)
        var parents: [URL] = []
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            parents.append(caches.appendingPathComponent("silo-source-cache", isDirectory: true))
        }
        parents.append(fm.temporaryDirectory.appendingPathComponent("silo-dv-hls", isDirectory: true))
        // The spill/debug directories were renamed with the app. Nothing in
        // this build writes the old trees, so they are dead weight (whole GBs
        // on tvOS) and go wholesale, without the age guard the live names need.
        var retired: [URL] = []
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            retired.append(caches.appendingPathComponent(
                LegacyBrandKeys.sourceCacheDirectoryName, isDirectory: true
            ))
        }
        retired.append(fm.temporaryDirectory.appendingPathComponent(
            LegacyBrandKeys.loopbackSpillDirectoryName, isDirectory: true
        ))
        retired.append(fm.temporaryDirectory.appendingPathComponent(
            LegacyBrandKeys.loopbackDebugDirectoryName, isDirectory: true
        ))
        let orphans = parents.flatMap { parent in
            let urls = (try? fm.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
            )) ?? []
            return urls.filter { url in
                guard let values = try? url.resourceValues(
                    forKeys: [.creationDateKey, .contentModificationDateKey]
                ) else { return false }
                let timestamp = values.creationDate ?? values.contentModificationDate
                return timestamp.map { $0 < staleBefore } ?? false
            }
        }
        let doomed = orphans + retired.filter { fm.fileExists(atPath: $0.path) }
        guard !doomed.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for orphan in doomed {
                try? FileManager.default.removeItem(at: orphan)
            }
        }
    }()
}

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

    /// One-shot per process: delete spill directories left behind by a
    /// force-killed predecessor (their deinit cleanup never ran, and a
    /// stranded directory can hold up to the full retention budget). Runs
    /// before the first spilling cache of this process creates its own
    /// directory, so everything found here is orphaned. `static let`
    /// initialization makes the sweep thread-safe and exactly-once.
    static let sweepOrphanedSpillDirectories: Void = {
        let fm = FileManager.default
        var parents: [URL] = []
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            parents.append(caches.appendingPathComponent("continuum-source-cache", isDirectory: true))
        }
        parents.append(fm.temporaryDirectory.appendingPathComponent("continuum-dv-hls", isDirectory: true))
        for parent in parents {
            guard let children = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else {
                continue
            }
            for child in children {
                try? fm.removeItem(at: child)
            }
        }
    }()
}

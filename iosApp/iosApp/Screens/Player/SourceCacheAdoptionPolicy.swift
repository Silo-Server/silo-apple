import Foundation

/// Decides whether a stashed source cache from a torn-down proxy may be
/// adopted by the replacement proxy instead of starting empty (see
/// `docs/tvos-player/10-playback-continuity.md`).
///
/// Adoption is only sound when the cached bytes are guaranteed to be the
/// bytes the new session will serve: direct-play delivery of the *same*
/// media file, with a cache built to the same budget and spill
/// configuration the new route would build. Anything else — a different
/// file, a re-planned delivery, a changed budget or a toggled Seek Cache
/// setting — rejects, and the stash is released (its disk spans are cleaned
/// by the cache's deinit).
enum SourceCacheAdoptionPolicy {
    /// - Parameters:
    ///   - handoffFileId: media file id the stashed cache was filled from.
    ///   - planFileId: media file id of the incoming playback plan.
    ///   - handoffBudgetBytes / planBudgetBytes: cache memory budgets; the
    ///     budget drives eviction watermarks and is immutable per cache, so
    ///     a mismatch (e.g. loopback ↔ native-direct route) rejects.
    ///   - handoffDiskSpill / planDiskSpill: effective disk-spill states.
    ///   - cachedTotalLength: total file length the stashed cache learned
    ///     from its origin, if any.
    ///   - expectedFileSize: the incoming version's catalog file size, if
    ///     known. A known-known mismatch means the file was replaced under
    ///     the same id — the cached bytes are stale.
    static func shouldAdopt(
        handoffFileId: Int,
        planFileId: Int?,
        handoffBudgetBytes: Int,
        planBudgetBytes: Int,
        handoffDiskSpill: Bool,
        planDiskSpill: Bool,
        cachedTotalLength: Int64?,
        expectedFileSize: Int64?
    ) -> Bool {
        guard let planFileId, planFileId == handoffFileId else { return false }
        guard handoffBudgetBytes == planBudgetBytes else { return false }
        guard handoffDiskSpill == planDiskSpill else { return false }
        if let cachedTotalLength, cachedTotalLength > 0,
           let expectedFileSize, expectedFileSize > 0,
           cachedTotalLength != expectedFileSize {
            return false
        }
        return true
    }
}
